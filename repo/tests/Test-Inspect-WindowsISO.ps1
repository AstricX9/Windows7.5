[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$inspectorPath = Join-Path $PSScriptRoot '..\tools\Inspect-WindowsISO.ps1'
$inspectorPath = [System.IO.Path]::GetFullPath($inspectorPath)
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('WindowsISOInspector Test ' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temporaryRoot)

function Assert-True {
    param([object]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-InspectorProcess {
    param([string[]]$Arguments)

    $script:lastInspectorOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inspectorPath @Arguments 2>&1)
    return $LASTEXITCODE
}

function Get-LatestReport {
    param([string]$Root)
    return Get-ChildItem -LiteralPath $Root -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
}

try {
    $reportRoot = Join-Path $temporaryRoot 'test reports'
    [void][System.IO.Directory]::CreateDirectory($reportRoot)

    $missingPathExit = Invoke-InspectorProcess -Arguments @('-ReportRoot', $reportRoot)
    Assert-True ($missingPathExit -eq 2) 'Missing ISO path did not return exit code 2.'
    $missingReport = Get-LatestReport -Root $reportRoot
    Assert-True ($null -ne $missingReport) 'Missing-path invocation did not create a report directory.'
    $missingManifest = Get-Content -LiteralPath (Join-Path $missingReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($missingManifest.errors.Count -gt 0) 'Missing-path error was not recorded in the manifest.'

    $invalidPathExit = Invoke-InspectorProcess -Arguments @('-IsoPath', (Join-Path $temporaryRoot 'does not exist.iso'), '-ReportRoot', $reportRoot)
    Assert-True ($invalidPathExit -eq 2) 'Invalid ISO path did not return exit code 2.'

    $isoFixture = Join-Path $temporaryRoot 'fixture with spaces.iso'
    [System.IO.File]::WriteAllBytes($isoFixture, [byte[]](0, 1, 2, 3, 4, 255))
    $expectedHash = (Get-FileHash -LiteralPath $isoFixture -Algorithm SHA256).Hash
    $mockSevenZip = Join-Path $temporaryRoot 'mock 7zip.cmd'
    @(
        '@echo off'
        'echo 7-Zip mock 1.0'
        'echo Path = setup.exe'
        'echo Path = sources\boot.wim'
        'echo Path = sources\install.wim'
        'exit /b 0'
    ) | Set-Content -LiteralPath $mockSevenZip -Encoding ASCII

    $successfulExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', $mockSevenZip, '-WimlibPath', (Join-Path $temporaryRoot 'missing wimlib.exe'))
    if ($successfulExit -ne 0) {
        Write-Output $script:lastInspectorOutput
        $failedReport = Get-LatestReport -Root $reportRoot
        if (Test-Path -LiteralPath (Join-Path $failedReport.FullName 'manifest.json')) {
            (Get-Content -LiteralPath (Join-Path $failedReport.FullName 'manifest.json') -Raw | ConvertFrom-Json).errors | Write-Output
        }
    }
    Assert-True ($successfulExit -eq 0) 'Mocked successful inspection did not return exit code 0.'
    $successfulReport = Get-LatestReport -Root $reportRoot
    foreach ($requiredFile in @('manifest.json', 'iso-contents.txt', 'summary.txt')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $successfulReport.FullName $requiredFile) -PathType Leaf) ("Report file is missing: {0}" -f $requiredFile)
    }
    $manifest = Get-Content -LiteralPath (Join-Path $successfulReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.input.sha256 -eq $expectedHash) 'Manifest SHA-256 does not match the fixture file.'
    Assert-True ($manifest.detection.windowsSetupAppearsPresent -eq $true) 'Mocked setup components were not detected.'
    Assert-True ($manifest.detection.components.installWim -eq $true) 'Mocked install.wim was not detected.'
    Assert-True (-not $manifest.wimMetadata.inspectionCompleted) 'Missing wimlib unexpectedly reported metadata inspection success.'
    Assert-True ($manifest.wimMetadata.error -match 'not found') 'Missing wimlib dependency was not reported clearly.'

    $mockArchiveV02 = Join-Path $temporaryRoot 'mock 7zip v02.cmd'
    @(
        '@echo off'
        'setlocal EnableDelayedExpansion'
        'if /I "%~1"=="l" ('
        '  echo Path = fixture.iso'
        '  echo.'
        '  echo Path = setup.exe'
        '  echo Folder = -'
        '  echo Size = 10'
        '  echo.'
        '  echo Path = sources\boot.wim'
        '  echo Folder = -'
        '  echo Size = 20'
        '  echo.'
        '  echo Path = sources\install.wim'
        '  echo Folder = -'
        '  echo Size = 5'
        '  echo Packed Size = 5'
        '  exit /b 0'
        ')'
        'if /I "%~1"=="e" ('
        '  set "outputArg=%~4"'
        '  set "outputDir=!outputArg:~2!"'
        '  if not exist "!outputDir!" exit /b 1'
        '  > "!outputDir!\install.wim" echo abc'
        '  exit /b 0'
        ')'
        'exit /b 2'
    ) | Set-Content -LiteralPath $mockArchiveV02 -Encoding ASCII

    $mockXmlPath = Join-Path $temporaryRoot 'mock-wim-metadata.xml'
    $mockXml = @'
<?xml version="1.0" encoding="UTF-16"?>
<WIM>
  <IMAGE INDEX="1">
    <NAME>Windows 7 Ultimate</NAME><DESCRIPTION>Windows 7 Ultimate image</DESCRIPTION><FLAGS>Ultimate</FLAGS><TOTALBYTES>300</TOTALBYTES>
    <WINDOWS><ARCH>9</ARCH><EDITIONID>Ultimate</EDITIONID><PRODUCTNAME>Windows 7</PRODUCTNAME><VERSION><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7600</BUILD><SPBUILD>16384</SPBUILD><SPLEVEL>0</SPLEVEL></VERSION><LANGUAGES><LANGUAGE>en-US</LANGUAGE><DEFAULT>en-US</DEFAULT></LANGUAGES></WINDOWS>
  </IMAGE>
  <IMAGE INDEX="2">
    <NAME>Windows 7 Professional</NAME><DESCRIPTION>Windows 7 Professional image</DESCRIPTION><FLAGS>Professional</FLAGS><TOTALBYTES>250</TOTALBYTES>
    <WINDOWS><ARCH>0</ARCH><EDITIONID>Professional</EDITIONID><PRODUCTNAME>Windows 7</PRODUCTNAME><VERSION><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD><SPBUILD>17514</SPBUILD><SPLEVEL>1</SPLEVEL></VERSION><LANGUAGES><LANGUAGE>en-US</LANGUAGE><LANGUAGE>fr-FR</LANGUAGE><DEFAULT>en-US</DEFAULT></LANGUAGES></WINDOWS>
  </IMAGE>
</WIM>
'@
    [System.IO.File]::WriteAllText($mockXmlPath, $mockXml, (New-Object System.Text.UnicodeEncoding($false, $true)))

    $mockWimlib = Join-Path $temporaryRoot 'mock wimlib.cmd'
    @(
        '@echo off'
        'setlocal EnableDelayedExpansion'
        'if /I "%~1"=="--version" ('
        '  echo wimlib-imagex 1.14.5'
        '  exit /b 0'
        ')'
        'if /I "%~1"=="info" ('
        '  set "xmlArg=%~3"'
        '  set "xmlPath=!xmlArg:~14!"'
        '  copy /b /y "%~dp0mock-wim-metadata.xml" "!xmlPath!" >nul'
        '  if errorlevel 1 exit /b 12'
        '  echo Mock WIM metadata read succeeded'
        '  exit /b 0'
        ')'
        'exit /b 2'
    ) | Set-Content -LiteralPath $mockWimlib -Encoding ASCII

    $temporaryWimDirectoriesBefore = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'WindowsISOInspector-WIM-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $metadataExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', $mockArchiveV02, '-WimlibPath', $mockWimlib)
    Assert-True ($metadataExit -eq 0) 'Mocked WIM metadata inspection did not preserve successful v0.1 exit status.'
    $metadataReport = Get-LatestReport -Root $reportRoot
    $metadataManifest = Get-Content -LiteralPath (Join-Path $metadataReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($metadataManifest.wimMetadata.inspectionCompleted -eq $true) 'Mocked WIM metadata was not marked complete.'
    Assert-True ($metadataManifest.wimMetadata.imageCount -eq 2) 'Multiple WIM image indexes were not counted.'
    Assert-True ($metadataManifest.wimMetadata.images[0].index -eq 1) 'First WIM image index was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[1].index -eq 2) 'Second WIM image index was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].edition -eq 'Ultimate') 'First WIM edition was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].architecture -eq 'x64') 'WIM x64 architecture mapping failed.'
    Assert-True ($metadataManifest.wimMetadata.images[1].architecture -eq 'x86') 'WIM x86 architecture mapping failed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].build -eq 7600) 'WIM RTM build was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].servicePackLevel -eq 0) 'WIM SP0 metadata was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].servicePack -eq 'None (SP level 0)') 'WIM SP0 was not represented accurately.'
    Assert-True ($metadataManifest.wimMetadata.images[1].servicePack -eq 'SP1') 'WIM SP1 metadata was not parsed.'
    Assert-True ($metadataManifest.wimMetadata.images[0].languages[0] -eq 'en-US') 'WIM installation language was not parsed.'
    Assert-True (($metadataManifest.warnings -join ' ') -match 'require SP1') 'SP1 compatibility warning was not generated for the SP0 image.'
    $temporaryWimDirectoriesAfter = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'WindowsISOInspector-WIM-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    Assert-True (@(Compare-Object $temporaryWimDirectoriesBefore $temporaryWimDirectoriesAfter).Count -eq 0) 'Inspector left WIM temporary directories behind.'

    $missingMetadataXmlPath = Join-Path $temporaryRoot 'missing-wim-metadata.xml'
    $missingMetadataXml = '<?xml version="1.0" encoding="UTF-16"?><WIM><IMAGE INDEX="1"><NAME>Image without Windows metadata</NAME></IMAGE></WIM>'
    [System.IO.File]::WriteAllText($missingMetadataXmlPath, $missingMetadataXml, (New-Object System.Text.UnicodeEncoding($false, $true)))
    $mockWimlibMissing = Join-Path $temporaryRoot 'mock wimlib missing metadata.cmd'
    @(
        '@echo off'
        'setlocal EnableDelayedExpansion'
        'if /I "%~1"=="--version" ('
        '  echo wimlib-imagex 1.14.5'
        '  exit /b 0'
        ')'
        'if /I "%~1"=="info" ('
        '  set "xmlArg=%~3"'
        '  set "xmlPath=!xmlArg:~14!"'
        '  copy /b /y "%~dp0missing-wim-metadata.xml" "!xmlPath!" >nul'
        '  if errorlevel 1 exit /b 12'
        '  exit /b 0'
        ')'
        'exit /b 2'
    ) | Set-Content -LiteralPath $mockWimlibMissing -Encoding ASCII
    $missingMetadataExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', $mockArchiveV02, '-WimlibPath', $mockWimlibMissing)
    Assert-True ($missingMetadataExit -eq 0) 'Missing WIM metadata changed the v0.1 exit status.'
    $missingMetadataReport = Get-LatestReport -Root $reportRoot
    $missingMetadataManifest = Get-Content -LiteralPath (Join-Path $missingMetadataReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($null -eq $missingMetadataManifest.wimMetadata.images[0].edition) 'Missing edition metadata was guessed.'
    Assert-True ($null -eq $missingMetadataManifest.wimMetadata.images[0].architecture) 'Missing architecture metadata was guessed.'
    Assert-True ($null -eq $missingMetadataManifest.wimMetadata.images[0].build) 'Missing build metadata was guessed.'
    Assert-True ($null -eq $missingMetadataManifest.wimMetadata.images[0].servicePack) 'Missing Service Pack metadata was guessed.'

    $mockWimlibUnsupported = Join-Path $temporaryRoot 'mock wimlib unsupported.cmd'
    @(
        '@echo off'
        'if /I "%~1"=="--version" ('
        '  echo wimlib-imagex 1.14.5'
        '  exit /b 0'
        ')'
        'if /I "%~1"=="info" ('
        '  echo unsupported WIM format 1>&2'
        '  exit /b 7'
        ')'
        'exit /b 2'
    ) | Set-Content -LiteralPath $mockWimlibUnsupported -Encoding ASCII
    $unsupportedExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', $mockArchiveV02, '-WimlibPath', $mockWimlibUnsupported)
    Assert-True ($unsupportedExit -eq 0) 'Unsupported WIM changed a successful v0.1 exit status.'
    $unsupportedReport = Get-LatestReport -Root $reportRoot
    $unsupportedManifest = Get-Content -LiteralPath (Join-Path $unsupportedReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($unsupportedManifest.wimMetadata.error -match 'exit code 7.*unsupported WIM format') 'Unsupported WIM failure was not reported precisely.'

    $missingSevenZipExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', (Join-Path $temporaryRoot 'missing 7z.exe'))
    Assert-True ($missingSevenZipExit -eq 3) 'Unavailable 7-Zip did not return exit code 3.'
    $sevenZipReport = Get-LatestReport -Root $reportRoot
    $sevenZipManifest = Get-Content -LiteralPath (Join-Path $sevenZipReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($sevenZipManifest.errors -match '7-Zip executable was not found') 'Unavailable 7-Zip error was not recorded in the manifest.'

    Write-Output 'PASS: v0.1 behavior, WIM metadata parsing, multiple indexes, architectures, Service Packs, unknown fields, unsupported WIMs, missing wimlib, and temp cleanup.'
    Write-Output 'WIM metadata and 7-Zip output were synthetic; real Windows 7 metadata requires a separate ISO inspection.'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
