[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$minimumVersion = [version]'8.22.0'
$computerName = $env:COMPUTERNAME
$scanErrors = [System.Collections.Generic.List[string]]::new()
$moduleScanErrorSamples = [System.Collections.Generic.List[string]]::new()
$moduleScanErrors = 0
$inaccessibleDirectories = 0
$inaccessibleProcesses = 0
$installedApplications = [System.Collections.Generic.List[object]]::new()
$filePaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$loadedProcesses = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($registryPath in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)) {
    try {
        if (Test-Path -LiteralPath ($registryPath -replace '\\\*$', '')) {
            foreach ($application in (Get-ItemProperty -Path $registryPath -ErrorAction Stop)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$application.DisplayName)) {
                    $installedApplications.Add([pscustomobject]@{
                        Name            = [string]$application.DisplayName
                        Publisher       = [string]$application.Publisher
                        DisplayVersion  = [string]$application.DisplayVersion
                        InstallLocation = [string]$application.InstallLocation
                    })
                }
            }
        }
    }
    catch {
        $scanErrors.Add("Installed-app registry '$registryPath': $($_.Exception.Message)")
    }
}

$scanRoots = [System.Collections.Generic.List[string]]::new()
foreach ($root in @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    (Join-Path $env:SystemRoot 'System32'),
    (Join-Path $env:SystemRoot 'SysWOW64')
)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$root) -and (Test-Path -LiteralPath $root -PathType Container)) {
        $scanRoots.Add([System.IO.Path]::GetFullPath($root))
    }
}

$usersDirectory = Join-Path $env:SystemDrive 'Users'
if (Test-Path -LiteralPath $usersDirectory -PathType Container) {
    try {
        foreach ($profile in [System.IO.Directory]::GetDirectories($usersDirectory)) {
            $profileName = [System.IO.Path]::GetFileName($profile)
            if ($profileName -notin @('Default', 'Default User', 'Public', 'All Users')) {
                $scanRoots.Add($profile)
            }
        }
    }
    catch {
        $scanErrors.Add("User profile roots '$usersDirectory': $($_.Exception.Message)")
    }
}

foreach ($application in $installedApplications) {
    $location = $application.InstallLocation
    if (-not [string]::IsNullOrWhiteSpace($location) -and (Test-Path -LiteralPath $location -PathType Container)) {
        try {
            $scanRoots.Add([System.IO.Path]::GetFullPath($location))
        }
        catch {
            $scanErrors.Add("Installed-app root '$location': $($_.Exception.Message)")
        }
    }
}

$uniqueRoots = [System.Collections.Generic.List[string]]::new()
foreach ($root in ($scanRoots | Sort-Object { $_.Length })) {
    $coveredByExistingRoot = $false
    foreach ($existingRoot in $uniqueRoots) {
        $existingPrefix = $existingRoot.TrimEnd('\') + '\'
        if ($root.Equals($existingRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $root.StartsWith($existingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $coveredByExistingRoot = $true
            break
        }
    }

    if (-not $coveredByExistingRoot) {
        $uniqueRoots.Add($root)
    }
}

foreach ($root in $uniqueRoots) {
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($root)

    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        try {
            foreach ($file in [System.IO.Directory]::GetFiles($directory, 'libcurl*.dll', [System.IO.SearchOption]::TopDirectoryOnly)) {
                $fullPath = [System.IO.Path]::GetFullPath($file)
                $filePaths[$fullPath] = $fullPath
            }
        }
        catch {
            $inaccessibleDirectories++
            if ($scanErrors.Count -lt 5) {
                $scanErrors.Add("Directory '$directory': $($_.Exception.Message)")
            }
        }

        try {
            foreach ($childDirectory in [System.IO.Directory]::GetDirectories($directory)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($childDirectory)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $pendingDirectories.Push($childDirectory)
                    }
                }
                catch {
                    $inaccessibleDirectories++
                    if ($scanErrors.Count -lt 5) {
                        $scanErrors.Add("Directory attributes '$childDirectory': $($_.Exception.Message)")
                    }
                }
            }
        }
        catch {
            $inaccessibleDirectories++
            if ($scanErrors.Count -lt 5) {
                $scanErrors.Add("Subdirectories of '$directory': $($_.Exception.Message)")
            }
        }
    }
}

try {
    foreach ($process in (Get-Process -ErrorAction Stop)) {
        try {
            foreach ($module in $process.Modules) {
                if ($module.ModuleName -like 'libcurl*.dll' -and -not [string]::IsNullOrWhiteSpace($module.FileName)) {
                    $modulePath = [System.IO.Path]::GetFullPath($module.FileName)
                    $filePaths[$modulePath] = $modulePath

                    if (-not $loadedProcesses.ContainsKey($modulePath)) {
                        $loadedProcesses[$modulePath] = [System.Collections.Generic.List[object]]::new()
                    }
                    $loadedProcesses[$modulePath].Add([pscustomobject]@{
                        Name = $process.ProcessName
                        Id   = $process.Id
                    })
                }
            }
        }
        catch {
            $moduleScanErrors++
            if ($moduleScanErrorSamples.Count -lt 3) {
                $moduleError = "$($process.ProcessName) (PID $($process.Id)): $($_.Exception.Message)"
                if ($moduleError.Length -gt 160) {
                    $moduleError = $moduleError.Substring(0, 160)
                }
                $moduleScanErrorSamples.Add($moduleError)
            }
            if ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception -is [System.Security.SecurityException]) {
                $inaccessibleProcesses++
            }
        }
        finally {
            $process.Dispose()
        }
    }
}
catch {
    $scanErrors.Add("Process/module enumeration: $($_.Exception.Message)")
}

function Get-ParsedVersion {
    param([string]$Value)

    if ($Value -match '(?<!\d)(\d+\.\d+(?:\.\d+){0,2})') {
        try {
            return [version]$Matches[1]
        }
        catch {
            return $null
        }
    }

    return $null
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($path in $filePaths.Values) {
    $fileName = [System.IO.Path]::GetFileName($path)
    $fileVersion = ''
    $productVersion = ''
    $productName = ''
    $description = ''
    $publisher = ''

    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        $fileVersion = [string]$versionInfo.FileVersion
        $productVersion = [string]$versionInfo.ProductVersion
        $productName = [string]$versionInfo.ProductName
        $description = [string]$versionInfo.FileDescription
        $publisher = [string]$versionInfo.CompanyName
    }
    catch {
        $scanErrors.Add("File metadata '$path': $($_.Exception.Message)")
    }

    $parsedVersion = Get-ParsedVersion -Value $fileVersion
    if ($null -eq $parsedVersion) {
        $parsedVersion = Get-ParsedVersion -Value $productVersion
    }

    if ($null -eq $parsedVersion) {
        $versionStatus = 'VersionUnknown'
        $belowMinimum = $null
    }
    else {
        $belowMinimum = $parsedVersion -lt $minimumVersion
        if ($belowMinimum) {
            $versionStatus = 'BelowMinimum'
        }
        else {
            $versionStatus = 'AtOrAboveMinimum'
        }
    }

    $attributedApplication = $null
    foreach ($application in $installedApplications) {
        $installLocation = $application.InstallLocation
        if ([string]::IsNullOrWhiteSpace($installLocation)) {
            continue
        }

        $normalizedLocation = $installLocation.TrimEnd('\') + '\'
        if ($path.StartsWith($normalizedLocation, [System.StringComparison]::OrdinalIgnoreCase) -and
            ($null -eq $attributedApplication -or $installLocation.Length -gt $attributedApplication.InstallLocation.Length)) {
            $attributedApplication = $application
        }
    }

    $applicationName = if ($null -ne $attributedApplication) {
        $attributedApplication.Name
    }
    elseif (-not [string]::IsNullOrWhiteSpace($productName)) {
        $productName
    }
    else {
        [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($path))
    }

    $processNames = @()
    $processIds = @()
    if ($loadedProcesses.ContainsKey($path)) {
        $processNames = @($loadedProcesses[$path] | ForEach-Object Name | Sort-Object -Unique)
        $processIds = @($loadedProcesses[$path] | ForEach-Object Id | Sort-Object -Unique)
    }

    $results.Add([pscustomobject]@{
        ComputerName       = $computerName
        Type               = 'Dll'
        FileName           = $fileName
        FilePath           = $path
        FileVersion        = $fileVersion
        ProductVersion     = $productVersion
        MinimumVersion     = $minimumVersion.ToString()
        VersionStatus      = $versionStatus
        BelowMinimum       = $belowMinimum
        Application        = $applicationName
        Publisher          = if ($null -ne $attributedApplication -and $attributedApplication.Publisher) { $attributedApplication.Publisher } else { $publisher }
        Description        = $description
        LoadedByProcesses  = ($processNames -join ';')
        LoadedByProcessIds = ($processIds -join ';')
        Details            = if ($processNames.Count -gt 0) { 'DLL observed loaded in the listed processes.' } else { 'Application attribution is inferred from install location or DLL metadata; current process use was not observed.' }
    })
}

$reportDirectory = Join-Path $env:ProgramData 'LibcurlInventory'
$reportPath = Join-Path $reportDirectory ("LibcurlInventory-{0}-{1}-{2}.csv" -f $computerName, (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
try {
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
        New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
    }

    if ($results.Count -gt 0) {
        $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'ComputerName,Type,FileName,FilePath,FileVersion,ProductVersion,MinimumVersion,VersionStatus,BelowMinimum,Application,Publisher,Description,LoadedByProcesses,LoadedByProcessIds,Details' |
            Set-Content -LiteralPath $reportPath -Encoding UTF8
    }
}
catch {
    throw "Unable to write the inventory report to '$reportPath': $($_.Exception.Message)"
}

$belowMinimumCount = @($results | Where-Object { $_.BelowMinimum -eq $true }).Count
$unknownVersionCount = @($results | Where-Object { $_.VersionStatus -eq 'VersionUnknown' }).Count
$loadedDllCount = $loadedProcesses.Count
$scanErrorSamples = @($scanErrors | Select-Object -First 3 | ForEach-Object {
    if ($_.Length -gt 160) { $_.Substring(0, 160) } else { $_ }
})
$summary = [ordered]@{
    ComputerName             = $computerName
    MinimumVersion           = $minimumVersion.ToString()
    DllFilesFound            = $results.Count
    BelowMinimum             = $belowMinimumCount
    UnknownVersion           = $unknownVersionCount
    DllsCurrentlyLoaded      = $loadedDllCount
    InaccessibleDirectories = $inaccessibleDirectories
    InaccessibleProcesses   = $inaccessibleProcesses
    ModuleScanErrors         = $moduleScanErrors
    ScanErrors               = $scanErrors.Count
    ScanErrorSamples         = $scanErrorSamples
    ModuleScanErrorSamples   = @($moduleScanErrorSamples)
    OmittedResults           = 0
    ReportPath               = $reportPath
}

$detailLines = [System.Collections.Generic.List[string]]::new()
$detailBytes = 0
foreach ($result in $results) {
    $line = [ordered]@{
        ComputerName       = $result.ComputerName
        FileName           = $result.FileName
        FilePath           = $result.FilePath
        FileVersion        = $result.FileVersion
        VersionStatus      = $result.VersionStatus
        Application        = $result.Application
        LoadedByProcesses  = $result.LoadedByProcesses
        LoadedByProcessIds = $result.LoadedByProcessIds
    } | ConvertTo-Json -Compress
    $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
    if (($detailBytes + $lineBytes) -le 2000) {
        $detailLines.Add($line)
        $detailBytes += $lineBytes
    }
}

$summaryLine = $summary | ConvertTo-Json -Compress
$outputByteLimit = 3000
while (($detailBytes + [System.Text.Encoding]::UTF8.GetByteCount($summaryLine) + 1) -gt $outputByteLimit -and $detailLines.Count -gt 0) {
    $removedLine = $detailLines[$detailLines.Count - 1]
    $detailBytes -= [System.Text.Encoding]::UTF8.GetByteCount($removedLine) + 1
    $detailLines.RemoveAt($detailLines.Count - 1)
}
$summary.OmittedResults = $results.Count - $detailLines.Count
$summaryLine = $summary | ConvertTo-Json -Compress

foreach ($line in $detailLines) {
    Write-Output $line
}
Write-Output $summaryLine
