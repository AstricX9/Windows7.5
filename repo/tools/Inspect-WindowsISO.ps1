    [CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$ReportRoot,
    [string]$SevenZipPath,
    [string]$WimlibPath
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

function Find-Wimlib {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path -LiteralPath $RequestedPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $RequestedPath).Path
        }
        return $null
    }

    $command = Get-Command -Name 'wimlib-imagex.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    $portablePath = 'G:\Dev\Tools\wimlib-1.14.5\wimlib-imagex.exe'
    if (Test-Path -LiteralPath $portablePath -PathType Leaf) {
        return $portablePath
    }

    return $null
}

function Get-XmlText {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$XPath
    )

    if ($null -eq $Node) { return $null }
    $child = $Node.SelectSingleNode($XPath)
    if ($null -eq $child -or [string]::IsNullOrWhiteSpace($child.InnerText)) { return $null }
    return $child.InnerText.Trim()
}

function ConvertFrom-WimMetadataXml {
    param([string]$XmlPath)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $xmlReader = [System.Xml.XmlReader]::Create($XmlPath, $settings)
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    try {
        $document.Load($xmlReader)
    }
    finally {
        $xmlReader.Dispose()
    }

    $imageNodes = $document.SelectNodes("/*[local-name()='WIM']/*[local-name()='IMAGE']")
    if ($null -eq $imageNodes -or $imageNodes.Count -eq 0) {
        throw 'The WIM metadata XML contains no IMAGE entries.'
    }

    $images = New-Object 'System.Collections.Generic.List[object]'
    foreach ($imageNode in $imageNodes) {
        $windowsNode = $imageNode.SelectSingleNode("./*[local-name()='WINDOWS']")
        $versionNode = if ($null -ne $windowsNode) { $windowsNode.SelectSingleNode("./*[local-name()='VERSION']") } else { $null }
        $languagesNode = if ($null -ne $windowsNode) { $windowsNode.SelectSingleNode("./*[local-name()='LANGUAGES']") } else { $null }

        $architectureCode = Get-XmlText -Node $windowsNode -XPath "./*[local-name()='ARCH']"
        $architecture = switch -Regex ($architectureCode) {
            '^(0|x86)$' { 'x86'; break }
            '^(5|arm)$' { 'ARM'; break }
            '^(9|amd64|x64)$' { 'x64'; break }
            '^(12|arm64)$' { 'ARM64'; break }
            default { $null }
        }

        $edition = Get-XmlText -Node $windowsNode -XPath "./*[local-name()='EDITIONID']"
        if ([string]::IsNullOrWhiteSpace($edition)) {
            $edition = Get-XmlText -Node $imageNode -XPath "./*[local-name()='FLAGS']"
        }

        $major = Get-XmlText -Node $versionNode -XPath "./*[local-name()='MAJOR']"
        $minor = Get-XmlText -Node $versionNode -XPath "./*[local-name()='MINOR']"
        $version = if ($null -ne $major -and $null -ne $minor) { '{0}.{1}' -f $major, $minor } else { $null }
        $buildText = Get-XmlText -Node $versionNode -XPath "./*[local-name()='BUILD']"
        $servicePackLevelText = Get-XmlText -Node $versionNode -XPath "./*[local-name()='SPLEVEL']"
        $servicePackBuildText = Get-XmlText -Node $versionNode -XPath "./*[local-name()='SPBUILD']"
        $sizeText = Get-XmlText -Node $imageNode -XPath "./*[local-name()='TOTALBYTES']"
        $languages = @()
        if ($null -ne $languagesNode) {
            $languages = @($languagesNode.SelectNodes("./*[local-name()='LANGUAGE']") | ForEach-Object { $_.InnerText.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        $imageIndex = $null
        if ($imageNode.Attributes['INDEX'] -and $imageNode.Attributes['INDEX'].Value -match '^\d+$') {
            $imageIndex = [int]$imageNode.Attributes['INDEX'].Value
        }
        $build = if ($buildText -match '^\d+$') { [long]$buildText } else { $null }
        $servicePackLevel = if ($servicePackLevelText -match '^\d+$') { [int]$servicePackLevelText } else { $null }
        $servicePackBuild = if ($servicePackBuildText -match '^\d+$') { [long]$servicePackBuildText } else { $null }
        $imageSize = if ($sizeText -match '^\d+$') { [long]$sizeText } else { $null }
        $servicePack = if ($null -eq $servicePackLevel) { $null } elseif ($servicePackLevel -eq 0) { 'None (SP level 0)' } else { 'SP{0}' -f $servicePackLevel }

        $images.Add([ordered]@{
            index = $imageIndex
            name = Get-XmlText -Node $imageNode -XPath "./*[local-name()='NAME']"
            description = Get-XmlText -Node $imageNode -XPath "./*[local-name()='DESCRIPTION']"
            edition = $edition
            productName = Get-XmlText -Node $windowsNode -XPath "./*[local-name()='PRODUCTNAME']"
            architecture = $architecture
            version = $version
            build = $build
            servicePack = $servicePack
            servicePackLevel = $servicePackLevel
            servicePackBuild = $servicePackBuild
            sizeBytes = $imageSize
            languages = $languages
            defaultLanguage = Get-XmlText -Node $languagesNode -XPath "./*[local-name()='DEFAULT']"
        })
    }

    return [ordered]@{
        imageCount = $images.Count
        images = @($images.ToArray())
    }
}

function Get-ArchiveEntrySize {
    param(
        [string]$ListingText,
        [string]$ExpectedPath
    )

    $lines = $ListingText -split "`r?`n"
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lines[$lineIndex] -match '^Path = (.+)$' -and $Matches[1].Replace('/', '\').TrimStart('\') -ieq $ExpectedPath) {
            for ($detailIndex = $lineIndex + 1; $detailIndex -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace($lines[$detailIndex]); $detailIndex++) {
                if ($lines[$detailIndex] -match '^Size = (\d+)$') {
                    return [long]$Matches[1]
                }
            }
            return $null
        }
    }
    return $null
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
$wimTemporaryDirectory = $null
$wimMetadata = [ordered]@{
    inspectionCompleted = $false
    reader = $null
    readerPath = $null
    readerVersion = $null
    imageCount = $null
    images = @()
    expectedSizeBytes = $null
    extractedSizeBytes = $null
    error = $null
}
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

if (-not $listingCompleted) {
    $wimMetadata.error = 'WIM metadata inspection was skipped because ISO listing did not complete.'
}
elseif (-not $components.installWim) {
    $wimMetadata.error = 'sources\install.wim was not found; v0.2 metadata inspection supports install.wim only.'
    Add-InspectionMessage $warnings $wimMetadata.error
}
else {
    $wimlibExecutable = Find-Wimlib -RequestedPath $WimlibPath
    if ($null -eq $wimlibExecutable) {
        if ([string]::IsNullOrWhiteSpace($WimlibPath)) {
            $wimMetadata.error = 'wimlib-imagex.exe was not found. Provide it with -WimlibPath or place the portable release under G:\Dev\Tools\wimlib-1.14.5.'
        }
        else {
            $wimMetadata.error = ("The specified wimlib executable was not found: {0}" -f $WimlibPath)
        }
        Add-InspectionMessage $warnings ('WIM metadata inspection failed: ' + $wimMetadata.error)
    }
    else {
        $wimMetadata.reader = 'wimlib-imagex'
        $wimMetadata.readerPath = $wimlibExecutable
        try {
            $readerVersionOutput = @(& $wimlibExecutable --version 2>&1)
            $readerVersionExitCode = $LASTEXITCODE
            if ($readerVersionExitCode -ne 0) {
                throw ("wimlib --version failed with exit code {0}: {1}" -f $readerVersionExitCode, (($readerVersionOutput | ForEach-Object { [string]$_ }) -join ' '))
            }
            $versionLine = $readerVersionOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            $wimMetadata.readerVersion = if ($null -ne $versionLine) { $versionLine.Trim() } else { 'Version unavailable' }

            $wimMetadata.expectedSizeBytes = Get-ArchiveEntrySize -ListingText $listingText -ExpectedPath 'sources\install.wim'
            if ($null -eq $wimMetadata.expectedSizeBytes) {
                throw 'The 7-Zip ISO listing did not provide a size for sources\install.wim; extraction size cannot be verified.'
            }

            $wimTemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('WindowsISOInspector-WIM-' + [Guid]::NewGuid().ToString('N'))
            if (Test-Path -LiteralPath $wimTemporaryDirectory) {
                throw 'The generated WIM temporary directory already exists; refusing to reuse it.'
            }
            [void][System.IO.Directory]::CreateDirectory($wimTemporaryDirectory)

            $extractOutput = @(& $toolPath e $resolvedIsoPath 'sources\install.wim' ("-o{0}" -f $wimTemporaryDirectory) -y 2>&1)
            $extractExitCode = $LASTEXITCODE
            if ($extractExitCode -ne 0) {
                throw ("7-Zip extraction of only sources\install.wim failed with exit code {0}: {1}" -f $extractExitCode, (($extractOutput | ForEach-Object { [string]$_ }) -join ' '))
            }

            $extractedWimPath = Join-Path $wimTemporaryDirectory 'install.wim'
            if (-not (Test-Path -LiteralPath $extractedWimPath -PathType Leaf)) {
                throw ('7-Zip reported success but the temporary install.wim file was not created. Output: ' + (($extractOutput | ForEach-Object { [string]$_ }) -join ' '))
            }
            $wimMetadata.extractedSizeBytes = [long](Get-Item -LiteralPath $extractedWimPath).Length
            if ($wimMetadata.extractedSizeBytes -ne $wimMetadata.expectedSizeBytes) {
                throw ("Extracted install.wim size {0} does not match the ISO listing size {1}." -f $wimMetadata.extractedSizeBytes, $wimMetadata.expectedSizeBytes)
            }

            $metadataXmlPath = Join-Path $wimTemporaryDirectory 'wim-metadata.xml'
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $metadataOutput = @(& $wimlibExecutable info $extractedWimPath ("`"--extract-xml={0}`"" -f $metadataXmlPath) 2>&1)
                $metadataExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($metadataExitCode -ne 0) {
                throw ("wimlib-imagex info failed with exit code {0}: {1}" -f $metadataExitCode, (($metadataOutput | ForEach-Object { [string]$_ }) -join ' '))
            }
            if (-not (Test-Path -LiteralPath $metadataXmlPath -PathType Leaf)) {
                throw ('wimlib-imagex returned success but did not create the requested WIM metadata XML. Output: ' + (($metadataOutput | ForEach-Object { [string]$_ }) -join ' '))
            }

            $parsedWimMetadata = ConvertFrom-WimMetadataXml -XmlPath $metadataXmlPath
            $wimMetadata.inspectionCompleted = $true
            $wimMetadata.imageCount = $parsedWimMetadata.imageCount
            $wimMetadata.images = $parsedWimMetadata.images
            foreach ($image in $wimMetadata.images) {
                if ($null -eq $image.servicePackLevel) {
                    Add-InspectionMessage $warnings ("WIM image index {0} does not record a Service Pack level; SP1 status is unknown." -f $image.index)
                }
                elseif ($image.servicePackLevel -eq 0) {
                    Add-InspectionMessage $warnings ("WIM image index {0} records Service Pack level 0 (no SP1). Some later Windows 7 applications and drivers require SP1." -f $image.index)
                }
            }
        }
        catch {
            $wimMetadata.error = $_.Exception.Message
            Add-InspectionMessage $warnings ('WIM metadata inspection failed: ' + $wimMetadata.error)
        }
        finally {
            if ($null -ne $wimTemporaryDirectory -and (Test-Path -LiteralPath $wimTemporaryDirectory -PathType Container)) {
                try {
                    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
                    $temporaryTarget = [System.IO.Path]::GetFullPath($wimTemporaryDirectory)
                    $allowedPrefix = $temporaryRoot.TrimEnd('\') + '\WindowsISOInspector-WIM-'
                    if (-not $temporaryTarget.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Refusing WIM temporary cleanup because its path is outside the expected temporary directory prefix.'
                    }
                    Remove-Item -LiteralPath $temporaryTarget -Recurse -Force
                }
                catch {
                    $cleanupMessage = 'Could not remove WIM metadata temporary files: ' + $_.Exception.Message
                    if ([string]::IsNullOrWhiteSpace($wimMetadata.error)) { $wimMetadata.error = $cleanupMessage }
                    Add-InspectionMessage $warnings $cleanupMessage
                }
            }
        }
    }
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
        schemaVersion = '0.2'
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
        wimMetadata = $wimMetadata
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
        exitCode = $exitCode
        reportDirectory = $reportDirectory
    }

    $json = $manifest | ConvertTo-Json -Depth 8
    Write-Utf8File -Path (Join-Path $reportDirectory 'manifest.json') -Content ($json + [Environment]::NewLine)

    $summaryLines = New-Object 'System.Collections.Generic.List[string]'
    $summaryLines.Add('Windows 7.5 ISO Inspector v0.2')
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
    $summaryLines.Add(('WIM metadata inspection completed: {0}' -f $wimMetadata.inspectionCompleted))
    if ($null -ne $wimMetadata.reader) { $summaryLines.Add(('WIM metadata reader: {0} ({1})' -f $wimMetadata.reader, $wimMetadata.readerVersion)) }
    if ($null -ne $wimMetadata.imageCount) { $summaryLines.Add(('WIM image count: {0}' -f $wimMetadata.imageCount)) }
    if (-not [string]::IsNullOrWhiteSpace($wimMetadata.error)) { $summaryLines.Add(('WIM metadata status: {0}' -f $wimMetadata.error)) }
    foreach ($image in $wimMetadata.images) {
        $summaryLines.Add('')
        $summaryLines.Add(('Installation image index {0}: {1}' -f $(if ($null -ne $image.index) { $image.index } else { 'unknown' }), $(if ($null -ne $image.name) { $image.name } else { 'unknown name' })))
        $summaryLines.Add(('  Description: {0}' -f $(if ($null -ne $image.description) { $image.description } else { 'unknown' })))
        $summaryLines.Add(('  Edition: {0}' -f $(if ($null -ne $image.edition) { $image.edition } else { 'unknown' })))
        $summaryLines.Add(('  Product: {0}' -f $(if ($null -ne $image.productName) { $image.productName } else { 'unknown' })))
        $summaryLines.Add(('  Architecture: {0}' -f $(if ($null -ne $image.architecture) { $image.architecture } else { 'unknown' })))
        $summaryLines.Add(('  Windows version: {0}' -f $(if ($null -ne $image.version) { $image.version } else { 'unknown' })))
        $summaryLines.Add(('  Build: {0}' -f $(if ($null -ne $image.build) { $image.build } else { 'unknown' })))
        $summaryLines.Add(('  Service Pack: {0}' -f $(if ($null -ne $image.servicePack) { $image.servicePack } else { 'unknown' })))
        $summaryLines.Add(('  Image size: {0}' -f $(if ($null -ne $image.sizeBytes) { $image.sizeBytes } else { 'unknown' })))
        $summaryLines.Add(('  Languages: {0}' -f $(if ($image.languages.Count -gt 0) { $image.languages -join ', ' } else { 'unknown' })))
        $summaryLines.Add(('  Default language: {0}' -f $(if ($null -ne $image.defaultLanguage) { $image.defaultLanguage } else { 'unknown' })))
    }
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
