    [CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$ReportRoot,
    [string]$SevenZipPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path $PSScriptRoot '..\reports'
}

function Add-InspectionMessage {
    param(
        [System.Collections.Generic.List[string]]$Collection,
        [string]$Message
    )

    $Collection.Add($Message)
}

function Find-SevenZip {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path -LiteralPath $RequestedPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $RequestedPath).Path
        }
        return $null
    }

    foreach ($commandName in @('7z.exe', '7za.exe', '7zz.exe')) {
        $command = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Get-SevenZipVersion {
    param([string]$ExecutablePath)

    try {
        $versionOutput = @(& $ExecutablePath i 2>&1)
        $firstLine = $versionOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ($null -ne $firstLine) {
            return $firstLine.Trim()
        }
    }
    catch {
        return 'Version query failed: ' + $_.Exception.Message
    }

    return 'Version unavailable'
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

$startedAt = [DateTime]::UtcNow
$warnings = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'
$listingText = ''
$resolvedIsoPath = $null
$fileInfo = $null
$isoHash = $null
$toolPath = $null
$toolVersion = $null
$exitCode = 0
$reportDirectory = $null
$listingCompleted = $false
$components = [ordered]@{
    setupExe = $false
    bootWim = $false
    installWim = $false
    installEsd = $false
    splitInstallImages = @()
}

if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    Add-InspectionMessage $errors 'An ISO file path is required. Supply it with -IsoPath.'
    $exitCode = 2
}
elseif (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    Add-InspectionMessage $errors ("ISO file does not exist or is not a file: {0}" -f $IsoPath)
    $exitCode = 2
}
else {
    try {
        $resolvedIsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
        $fileInfo = Get-Item -LiteralPath $resolvedIsoPath
        $readTest = [System.IO.File]::Open($resolvedIsoPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $readTest.Dispose()
        $isoHash = (Get-FileHash -LiteralPath $resolvedIsoPath -Algorithm SHA256).Hash
    }
    catch {
        Add-InspectionMessage $errors ("ISO file is unreadable or could not be hashed: {0}" -f $_.Exception.Message)
        $exitCode = 2
    }
}

if ($exitCode -eq 0) {
    $toolPath = Find-SevenZip -RequestedPath $SevenZipPath
    if ($null -eq $toolPath) {
        if ([string]::IsNullOrWhiteSpace($SevenZipPath)) {
            Add-InspectionMessage $errors 'A compatible 7-Zip command was not found. Install or provide an existing 7-Zip executable with -SevenZipPath.'
        }
        else {
            Add-InspectionMessage $errors ("The specified 7-Zip executable was not found: {0}" -f $SevenZipPath)
        }
        $exitCode = 3
    }
    else {
        $toolVersion = Get-SevenZipVersion -ExecutablePath $toolPath
        try {
            $listingOutput = @(& $toolPath l -slt $resolvedIsoPath 2>&1)
            $listingExitCode = $LASTEXITCODE
            $listingText = ($listingOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            if ($listingExitCode -ne 0) {
                Add-InspectionMessage $errors ("7-Zip listing failed with exit code {0}. {1}" -f $listingExitCode, (($listingOutput | ForEach-Object { [string]$_ }) -join ' '))
                $exitCode = 3
            }
            else {
                $listingCompleted = $true
                $entryPaths = New-Object 'System.Collections.Generic.List[string]'
                foreach ($line in ($listingText -split "`r?`n")) {
                    if ($line -match '^Path = (.+)$') {
                        $entryPaths.Add($Matches[1].Trim())
                    }
                }

                foreach ($entryPath in $entryPaths) {
                    $normalizedPath = $entryPath.Replace('/', '\').TrimStart('\')
                    if ($normalizedPath -match '(?i)^setup\.exe$') { $components.setupExe = $true }
                    if ($normalizedPath -match '(?i)^sources\\boot\.wim$') { $components.bootWim = $true }
                    if ($normalizedPath -match '(?i)^sources\\install\.wim$') { $components.installWim = $true }
                    if ($normalizedPath -match '(?i)^sources\\install\.esd$') { $components.installEsd = $true }
                    if ($normalizedPath -match '(?i)^sources\\install\d*\.swm$') { $components.splitInstallImages += $normalizedPath }
                }
            }
        }
        catch {
            Add-InspectionMessage $errors ("Could not run 7-Zip in read-only listing mode: {0}" -f $_.Exception.Message)
            $exitCode = 3
        }
    }
}

$installationImageFound = $components.installWim -or $components.installEsd -or ($components.splitInstallImages.Count -gt 0)
$windowsSetupAppearsPresent = $components.setupExe -and $components.bootWim

if ($listingCompleted) {
    if (-not $components.setupExe) { Add-InspectionMessage $warnings 'setup.exe was not found at the ISO root.' }
    if (-not $components.bootWim) { Add-InspectionMessage $warnings 'sources\boot.wim was not found.' }
    if (-not $installationImageFound) { Add-InspectionMessage $warnings 'No sources\install.wim, sources\install.esd, or split sources\install*.swm image was found.' }
    if ($components.installWim -and $components.installEsd) { Add-InspectionMessage $warnings 'Both install.wim and install.esd were found; this is unusual.' }
    if (($components.splitInstallImages.Count -gt 0) -and ($components.installWim -or $components.installEsd)) { Add-InspectionMessage $warnings 'Split and unsplit installation image formats are both present; this is unusual.' }
}

try {
    $fullReportRoot = [System.IO.Path]::GetFullPath($ReportRoot)
    [void][System.IO.Directory]::CreateDirectory($fullReportRoot)
    $folderName = 'ISO-Inspection-{0}-{1}' -f $startedAt.ToString('yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N').Substring(0, 6))
    $reportDirectory = Join-Path $fullReportRoot $folderName
    [void][System.IO.Directory]::CreateDirectory($reportDirectory)

    if ([string]::IsNullOrWhiteSpace($listingText)) {
        $listingText = 'ISO contents could not be listed.'
    }
    Write-Utf8File -Path (Join-Path $reportDirectory 'iso-contents.txt') -Content ($listingText + [Environment]::NewLine)

    $manifest = [ordered]@{
        schemaVersion = '0.1'
        generatedAtUtc = $startedAt.ToString('o')
        input = [ordered]@{
            suppliedPath = $IsoPath
            resolvedPath = $resolvedIsoPath
            fileName = if ($null -ne $fileInfo) { $fileInfo.Name } else { $null }
            sizeBytes = if ($null -ne $fileInfo) { [long]$fileInfo.Length } else { $null }
            sha256 = $isoHash
        }
        host = [ordered]@{
            operatingSystem = [Environment]::OSVersion.VersionString
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
        }
        tool = [ordered]@{
            name = '7-Zip'
            path = $toolPath
            version = $toolVersion
            listingMode = 'l -slt (read-only)'
        }
        detection = [ordered]@{
            inspectionCompleted = $listingCompleted
            windowsSetupAppearsPresent = $windowsSetupAppearsPresent
            installationImageFound = $installationImageFound
            components = $components
        }
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
        exitCode = $exitCode
        reportDirectory = $reportDirectory
    }

    $json = $manifest | ConvertTo-Json -Depth 8
    Write-Utf8File -Path (Join-Path $reportDirectory 'manifest.json') -Content ($json + [Environment]::NewLine)

    $summaryLines = New-Object 'System.Collections.Generic.List[string]'
    $summaryLines.Add('Windows ISO Inspector v0.1')
    $summaryLines.Add(('Generated (UTC): {0}' -f $startedAt.ToString('o')))
    $summaryLines.Add(('Input: {0}' -f $(if ($null -ne $resolvedIsoPath) { $resolvedIsoPath } else { $IsoPath })))
    if ($null -ne $fileInfo) {
        $summaryLines.Add(('File: {0} ({1} bytes)' -f $fileInfo.Name, $fileInfo.Length))
        $summaryLines.Add(('SHA-256: {0}' -f $isoHash))
    }
    $summaryLines.Add(('7-Zip: {0}' -f $(if ($null -ne $toolPath) { $toolPath } else { 'unavailable' })))
    if ($null -ne $toolVersion) { $summaryLines.Add(('7-Zip version: {0}' -f $toolVersion)) }
    $summaryLines.Add(('Component listing completed: {0}' -f $listingCompleted))
    $summaryLines.Add(('Windows Setup appears present: {0}' -f $(if ($listingCompleted) { [string]$windowsSetupAppearsPresent } else { 'unknown' })))
    $summaryLines.Add(('Installation image found: {0}' -f $(if ($listingCompleted) { [string]$installationImageFound } else { 'unknown' })))
    $summaryLines.Add(('Components: setup.exe={0}; boot.wim={1}; install.wim={2}; install.esd={3}; split images={4}' -f $components.setupExe, $components.bootWim, $components.installWim, $components.installEsd, $components.splitInstallImages.Count))
    $summaryLines.Add(('Exit code: {0}' -f $exitCode))
    $summaryLines.Add('')
    $summaryLines.Add('Warnings:')
    if ($warnings.Count -eq 0) { $summaryLines.Add('- None') } else { foreach ($warning in $warnings) { $summaryLines.Add('- ' + $warning) } }
    $summaryLines.Add('Errors:')
    if ($errors.Count -eq 0) { $summaryLines.Add('- None') } else { foreach ($errorMessage in $errors) { $summaryLines.Add('- ' + $errorMessage) } }
    $summaryLines.Add('')
    $summaryLines.Add('A SHA-256 hash identifies file contents; it does not verify authenticity by itself.')
    Write-Utf8File -Path (Join-Path $reportDirectory 'summary.txt') -Content (($summaryLines -join [Environment]::NewLine) + [Environment]::NewLine)
}
catch {
    [Console]::Error.WriteLine(('Could not create inspection report: {0}' -f $_.Exception.Message))
    exit 4
}

Write-Output ('Report: {0}' -f $reportDirectory)
Write-Output ('Exit code: {0}' -f $exitCode)
exit $exitCode
