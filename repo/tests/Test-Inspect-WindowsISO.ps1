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

    $successfulExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', $mockSevenZip)
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

    $missingSevenZipExit = Invoke-InspectorProcess -Arguments @('-IsoPath', $isoFixture, '-ReportRoot', $reportRoot, '-SevenZipPath', (Join-Path $temporaryRoot 'missing 7z.exe'))
    Assert-True ($missingSevenZipExit -eq 3) 'Unavailable 7-Zip did not return exit code 3.'
    $sevenZipReport = Get-LatestReport -Root $reportRoot
    $sevenZipManifest = Get-Content -LiteralPath (Join-Path $sevenZipReport.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($sevenZipManifest.errors -match '7-Zip executable was not found') 'Unavailable 7-Zip error was not recorded in the manifest.'

    Write-Output 'PASS: missing path, invalid path, SHA-256, JSON/text report creation, component detection, and unavailable 7-Zip handling.'
    Write-Output 'The ISO fixture and 7-Zip listing were synthetic; this does not validate a genuine Windows 7 ISO.'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
