# Copyright (c) 2022 Matthias Wolf, Mawosoft.

<#
.SYNOPSIS
    Analyzes AppVeyor NuGet feeds and build history
.NOTES
    Sample Urls:
    - build history. first query w/o &startBuildId= (0 is not valid); recordsNumber <= 100
      https://ci.appveyor.com/api/projects/dotnetfoundation/benchmarkdotnet/history?recordsNumber=100&startBuildId=$buildId
    - last build
      https://ci.appveyor.com/api/projects/dotnetfoundation/benchmarkdotnet
    - specific build
      https://ci.appveyor.com/api/projects/dotnetfoundation/benchmarkdotnet/builds/42432236
    - build job artifacts (JobId from build info; other subpages: messages, tests, log (log is a text file))
      https://ci.appveyor.com/api/buildjobs/hjhb9sxedig8wsrb/artifacts
    - Documentation
      https://www.appveyor.com/docs/api/
#>

#Requires -Version 7

using namespace System
using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.Xml
using namespace Microsoft.PowerShell.Commands

[CmdletBinding()]
param (
    [Alias('r')]
    # Defaults to ./BdnAppVeyorResults
    [string]$ResultsDirectory,
    # Processes previously cached data only
    [switch]$Offline,
    # Throttle parallel requests. Defaults to no throttling.
    [int]$ThrottleLimit
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Base Uris for REST API and NuGet API
[string]$script:BaseUriNuGetV2 = 'https://ci.appveyor.com/nuget'
[string]$script:BaseUriProjectApi = 'https://ci.appveyor.com/api/projects'
[string]$script:BaseUriJobsApi = 'https://ci.appveyor.com/api/buildjobs'

# Build job states https://github.com/appveyor/website/issues/256
# Somewhat old and not complete ('starting' is missing). See also CSS of web history.
# Known in-progress states: 'queued', 'starting', 'running', 'cancelling'
[string[]]$script:StatusCompleted = @('success', 'failed', 'cancelled')

# Repo/project definitions
[string]$script:AccountName = 'dotnetfoundation'
[string]$script:ProjectSlug = 'benchmarkdotnet'
[string]$script:PackageId = 'BenchmarkDotNet'
[string]$script:DefaultBranch = 'master'

#region Classes

# .SYNOPSIS
#   Build info. Can be brief (from history) or detailed.
# .NOTES
#   The history lists builds by BuildId in descending order.
#   Newer builds have a higher BuildId, but the increment varies.
class Build : ICloneable {
    # Unique build ID
    [long]$BuildId
    # PR's will reuse the previous build number
    [int]$BuildNumber
    # Build version with random suffixes for same build number
    [string]$Version
    # Changes until the build has reached one of the completed states.
    [string]$Status
    # Repo branch or target branch for PR
    [string]$Branch
    # Empty if not a PR
    [string]$PullRequestId
    # Can be null (represented by [datetime]::new(0)
    [datetime]$Started
    # Can be null (represented by [datetime]::new(0)
    [datetime]$Finished
    # Not null. Refers to the build info.
    [datetime]$Created
    # Not null. Refers to the build info, and changes until the build has reached one of the completed states.
    [datetime]$Updated
    # From detailed build info
    [int]$JobsCount
    # Calculated from all jobs in detailed build info.
    # $this.JobsCount -eq 0 -and $this.IsCompleted --> No details yet.
    [int]$ArtifactsCount
    # Calculated from the artifacts info of each job in the detailed build info
    [int]$NupkgCount

    [Object]Clone() {
        return $this.MemberwiseClone()
    }

    # Initializes a [Build] instance from brief or detailed JSON build object.
    # Note: Not static to allow in-place updates of Enumerables.
    [void]FromJsonObject([PSCustomObject]$json) {
        # Case-insensitive, thus $build.BuildId = $json.buildId works
        foreach ($p in $this.psobject.Properties) {
            [Object]$v = $json.psobject.Properties[$p.Name]?.Value
            if ($v) {
                $p.Value = $v
            }
            elseif ($p.TypeNameOfValue -eq 'System.DateTime') {
                # [datetime] values cannot accept null
                $p.Value = [datetime]::MinValue
            }
            else {
                $p.Value = $null
            }
        }
        $this.EnsureUtc()
    }

    # Initializes a [Build] instance from the results of multiple REST API calls for a build
    # Note: Not static to allow in-place updates of Enumerables.
    [void]FromRestApi(
        # Response from '/api/projects/$AccountName/$ProjectSlug/builds/$buildId.
        [PSCustomObject]$projectBuildJson,
        # Responses from '/api/buildjobs/$jobId/artifacts' calls for each job in the build
        [IEnumerable]$artifactsJson
    ) {
        $this.FromJsonObject($projectBuildJson.build)
        $this.JobsCount = $projectBuildJson.build.jobs?.Count
        $this.ArtifactsCount = 0
        foreach ($job in $projectBuildJson.build.jobs) { $this.ArtifactsCount += $job.artifactsCount }
        # Flatten in case caller passed an array of arrays from multiple responses
        $this.NupkgCount = $artifactsJson.ForEach({
                if ($_ -and $_.fileName) { $_.fileName }
            }).Where({
                $_.EndsWith('.nupkg', [StringComparison]::OrdinalIgnoreCase)
            }).Count
    }

    # Script to use in 'ForEach-Object -Parallel' for performing REST API calls.
    # Usage: builds | % -Parallel ([Build]::ParallelDetailsRequester) | % -Process {
    #           $_.Build.FromRestApi($_.ProjectBuildJson, $_.ArtifactsJson)
    #        }
    # Notes: Calling (class) methods outside the scriptblock will cause threads blocking
    # each other and severly degrade the performance. Also, none of the usings or preferences
    # of the enclosingscript apply to the scriptblock, hence full typenames, strict etc.
    static [scriptblock]$ParallelDetailsRequester = {
        Set-StrictMode -Version 3.0
        $projectBuild = Invoke-RestMethod -Uri "$using:BaseUriProjectApi/$using:AccountName/$using:ProjectSlug/builds/$($_.BuildId)"
        [System.Collections.ArrayList]$artifacts = @()
        if ($projectBuild.build.status -in $using:StatusCompleted) {
            foreach ($job in $projectBuild.build.jobs) {
                if ($job.ArtifactsCount -ne 0) {
                    $null = $artifacts.AddRange((Invoke-RestMethod -Uri "$using:BaseUriJobsApi/$($job.jobId)/artifacts"))
                }
            }
        }
        return [PSCustomObject]@{
            Build            = $_
            ProjectBuildJson = $projectBuild
            ArtifactsJson    = $artifacts
        }
    }

    # Creates an [Build] instance from imported CSV object.
    static [Build]FromCsvObject([PSCustomObject]$csv) {
        [Build]$build = [Build]::new()
        foreach ($p in $build.psobject.Properties) {
            [Object]$v = $csv.psobject.Properties[$p.Name]?.Value
            # [datetime] values cannot accept null
            if ($v) { $p.Value = $v }
        }
        $build.EnsureUtc()
        return $build
    }

    # Returns a custom copy for CSV export
    [PSCustomObject]ToCsvObject() {
        [Specialized.OrderedDictionary]$custom = [ordered]@{}
        foreach ($p in $this.psobject.Properties) {
            if (-not $p.Value) {
                $custom[$p.Name] = $null
            }
            elseif ($p.Value -is [datetime]) {
                # Ensure roundtrip format
                $custom[$p.Name] = if ($p.Value -ne [datetime]::MinValue) { $p.Value.ToString('o') } else { $null }
            }
            else {
                $custom[$p.Name] = $p.Value
            }
        }
        return [PSCustomObject]$custom
    }

    # Ensures all timestamps are UTC. Assumes 'Unspecified' already is UTC.
    [void]EnsureUtc() {
        foreach ($p in $this.psobject.Properties) {
            if ($p.TypeNameOfValue -eq 'System.DateTime') {
                [datetime]$v = $p.Value
                if ($v.Kind -eq [DateTimeKind]::Unspecified) {
                    $p.Value = [datetime]::SpecifyKind($v, [DateTimeKind]::Utc)
                }
                else {
                    $p.Value = $v.ToUniversalTime()
                }
            }
        }
    }

    [bool]IsCompleted() {
        return $this.Status -in $script:StatusCompleted
    }
}

# .SYNOPSIS
#   Package info from AppVeyor NuGet feed
# .NOTES
#   The feed seems to list packages in alphabetical order by PackageID, Version, , i.e. 0.1.11 < 0.1.2.
#   The feed has the Updated time stamp marked as UTC, but it actually is the account time zone,
#   which can be retrieved from $lastBuild.Project.NuGetFeed.AccountTimeZoneId
class Package : ICloneable {
    [string]$PackageId
    [string]$Version
    [datetime]$Updated

    [Object]Clone() {
        return $this.MemberwiseClone()
    }

    # Creates an [Package] instance from a feed element and adjusts timestamp.
    static [Package]FromXmlElement([XmlElement]$xml, [TimeZoneInfo]$feedTimeZone) {
        [Package]$package = [Package]::new()
        $package.PackageId = $xml.title.innerText # <title type="text">...
        $package.Version = $xml.properties.Version
        $package.Updated = [TimeZoneInfo]::ConvertTimeToUtc([DateTimeOffset]::Parse($xml.updated).DateTime, $feedTimeZone)
        return $package
    }

    # Creates an [Package] instance from imported CSV object.
    static [Package]FromCsvObject([PSCustomObject]$csv) {
        [Package]$package = [Package]::new()
        $package.PackageId = $csv.PackageId
        $package.Version = $csv.Version
        # [datetime] values cannot accept null/empty
        if ($csv.Updated) { $package.Updated = $csv.Updated }
        $package.EnsureUtc()
        return $package
    }

    # Returns a custom copy for CSV export
    [PSCustomObject]ToCsvObject() {
        return [PSCustomObject]@{
            PackageId = $this.PackageId
            Version   = $this.Version
            # Ensure roundtrip format
            Updated   = if ($this.Updated -ne [datetime]::MinValue) { $this.Updated.ToString('o') } else { $null }
        }
    }

    # Ensures all timestamps are UTC. Assumes 'Unspecified' already is UTC.
    [void]EnsureUtc() {
        if ($this.Updated.Kind -eq [DateTimeKind]::Unspecified) {
            $this.Updated = [datetime]::SpecifyKind($this.Updated, [DateTimeKind]::Utc)
        }
        else {
            $this.Updated = $this.Updated.ToUniversalTime()
        }

    }

    # BDN uses the 4th part of the version number (Revision) as build number
    # Returns 0 if that part doesn't exist
    [int]GetBuildNumber() {
        return [regex]::Match($this.Version, '^\d+\.\d+\.\d+\.(\d+)').Groups[1].Value
    }
}

# .SYNOPSIS
#   Build and corresponding package analyzed
class AnalyzedBuild : ICloneable {
    [long]$BuildId
    [int]$BuildNumber
    [string]$BuildVersion
    [string]$Status
    [string]$Branch
    [string]$PR
    [datetime]$Started
    [datetime]$Finished
    [int]$NupkgCount
    # True if this is the last package producing build per build number
    [bool]$LastNupkg
    # Package version mapped to this build
    [string]$PkgVersion
    # Package.Updated relative to Build.Finished
    [timespan]$PkgOffset
    # Package.Updated not within (Build.Started, Build.Finished)
    [bool]$PkgOutOfRange
    # For package producing builds not originating from the default branch: PR/Branch
    [string]$BuildError
    # Build error produced package (i.e. not overwritten later)
    [bool]$PkgError
    # No package found despite LastNupkg being set
    [bool]$PkgNotFound

    [Object]Clone() {
        return $this.MemberwiseClone()
    }
    
    AnalyzedBuild() { }

    AnalyzedBuild([Build]$build, [Package]$package, [bool]$lastNupkg) {
        $this.BuildId = $build.BuildId
        $this.BuildNumber = $build.BuildNumber
        $this.BuildVersion = $build.Version
        $this.Status = $build.Status
        $this.Branch = $build.Branch
        $this.PR = $build.PullRequestId
        $this.Started = $build.Started
        $this.Finished = $build.Finished
        $this.NupkgCount = $build.NupkgCount
        $this.LastNupkg = $lastNupkg
        if ($this.NupkgCount) {
            if ($this.PR) {
                $this.BuildError = 'PR'
            }
            elseif ($this.Branch -ne $script:DefaultBranch) {
                $this.BuildError = 'Branch'
            }
        }
        if ($package) {
            $this.PkgVersion = $package.Version
            $this.PkgOffset = $package.Updated - $this.Finished
            $this.PkgOutOfRange = $package.Updated -gt $this.Finished -or $package.Updated -lt $this.Started
            if ($this.BuildError) { $this.PkgError = $true }
        }
        elseif ($this.LastNupkg) {
            $this.PkgNotFound = $true
        }
    }

    # Returns a custom copy for CSV export
    [PSCustomObject]ToCsvObject() {
        [Specialized.OrderedDictionary]$custom = [ordered]@{}
        foreach ($p in $this.psobject.Properties) {
            if (-not $p.Value) {
                $custom[$p.Name] = $null
            }
            elseif ($p.Value -is [timespan]) {
                $custom[$p.Name] = if ($p.Value -ne 0) { $p.Value } else { $null }
            }
            elseif ($p.Value -is [datetime]) {
                # Ensure roundtrip format
                $custom[$p.Name] = if ($p.Value -ne [datetime]::MinValue) { $p.Value.ToString('o') } else { $null }
            }
            else {
                $custom[$p.Name] = $p.Value
            }
        }
        return [PSCustomObject]$custom
    }
}

# .SYNOPSIS
#   Simple class to manage non-nested count-based progress.
#   Might be worth expanding to support all params, but not needed here
class SimpleProgress {
    # Activity to report progress for
    [string]$Activity
    # Total # of items to process, or 0 if unknown.
    [int]$TotalCount
    # Status description. Can contain {0} and {1} for processed/total count.
    [string]$Status = '{0} of {1} items processed.'
    # Only report new progress after given time has passed.
    [timespan]$ReportInterval = [timespan]::FromSeconds(1)
    # Currently processed # of items
    [int]$ProcessedCount
    # Last time progress was reported
    [datetime]$LastReported

    SimpleProgress() { }

    SimpleProgress([string]$activity, [int]$totalCount) {
        $this.Activity = $activity
        $this.TotalCount = $totalCount
    }

    SimpleProgress([string]$activity, [int]$totalCount, [string]$status) {
        $this.Activity = $activity
        $this.TotalCount = $totalCount
        $this.Status = $status
    }

    [void]StartProgress() {
        $this.LastReported = [datetime]::MinValue
        $this.AddProgress(0)
    }

    [void]AddProgress() { $this.AddProgress(1) }
    
    [void]AddProgress([int]$processed) {
        $this.ProcessedCount += $processed
        if (([datetime]::UtcNow - $this.LastReported) -lt $this.ReportInterval) { return }
        [string]$s = $this.Status -f $this.ProcessedCount, $this.TotalCount
        Write-Progress -Activity $this.Activity -Status $s -PercentComplete $this.GetPercentComplete()
        $this.LastReported = [datetime]::UtcNow
    }

    [int]GetPercentComplete() {
        if ($this.TotalCount -le 0) { return -1 }
        [int]$percent = $this.ProcessedCount * 100.0 / $this.TotalCount
        if ($percent -eq 0 -and $this.ProcessedCount -ne 0) { return 1 }
        if ($percent -gt 100) { return 100 }
        return $percent
    }
}

#endregion Classes

################################################################################
#
#   Main
#
################################################################################

if ($ThrottleLimit -le 0) { $ThrottleLimit = [int]::MaxValue }

if (-not $ResultsDirectory) {
    $ResultsDirectory = Join-Path '.' 'BdnAppVeyorResults'
}
if (Test-Path -LiteralPath $ResultsDirectory -PathType Container) {
    $ResultsDirectory = Convert-Path $ResultsDirectory
}
else {
    $ResultsDirectory = (New-Item $ResultsDirectory -ItemType Directory).FullName
}
[PSCustomObject]$fileNames = [PSCustomObject]@{
    Builds             = Join-Path $ResultsDirectory 'builds.csv'
    Packages           = Join-Path $ResultsDirectory 'packages.csv'
    AnalyzedBuilds     = Join-Path $ResultsDirectory 'analyzed_builds.csv'
    UnassignedPackages = Join-Path $ResultsDirectory 'unassigned_packages.csv'
}

[List[Build]]$builds = $null
[List[Package]]$packages = $null

if (Test-Path $fileNames.Builds) {
    Write-Progress -Activity 'Import builds from file'
    $builds = Import-Csv $fileNames.Builds | ForEach-Object { [Build]::FromCsvObject($_) }
}
if (Test-Path $fileNames.Packages) {
    Write-Progress -Activity 'Import packages from file'
    $packages = Import-Csv $fileNames.Packages | ForEach-Object { [Package]::FromCsvObject($_) }
}

if (-not $builds) { $builds = @() }
if (-not $packages) { $packages = @() }

if (-not $Offline.IsPresent) {
    # Do this first to avoid throwing later
    Write-Progress -Activity 'Get project info'
    $lastBuild = Invoke-RestMethod "$BaseUriProjectApi/$AccountName/$ProjectSlug"
    [string]$feedId = $lastBuild.Project.NuGetFeed.Id
    [string]$feedTimeZoneid = 'UTC'
    try { $feedTimeZoneId = $lastBuild.Project.NuGetFeed.AccountTimeZoneId } catch { }
    if ($feedId -ne 'benchmarkdotnet') { throw "Unexpected feed Id: $feedId" }
    if ($feedTimeZoneId -ne 'Pacific Standard Time') {
        Write-Warning "Unexpected feed time zone Id: $feedTimeZoneid"
    }
    [TimeZoneInfo]$feedTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($feedTimeZoneid)

    [bool]$shouldExport = $false
    try {
        # Update builds that were previously in progress
        [List[Build]]$incompleteBuilds = $builds.FindAll({ param([Build]$b) -not $b.IsCompleted() })
        if ($incompleteBuilds) {
            $shouldExport = $true
            [int]$throttle = [Math]::Min($ThrottleLimit, $incompleteBuilds.Count)
            [SimpleProgress]$progress = [SimpleProgress]::new('Update unfinished builds', $incompleteBuilds.Count)
            $progress.StartProgress()
            $incompleteBuilds | ForEach-Object -ThrottleLimit $throttle -Parallel ([Build]::ParallelDetailsRequester) | ForEach-Object -Process {
                $_.Build.FromRestApi($_.ProjectBuildJson, $_.ArtifactsJson)
                $progress.AddProgress()
            }
        }

        # Try resume with Min(BuildId), then get new builds up to Max(BuildId)
        [GenericMeasureInfo] $minmax = $builds | Measure-Object -Property BuildId -Minimum -Maximum
        [long[]]$startBuildIds = @(0)
        if (${minmax}?.Minimum) { $startBuildIds = @($minmax.Minimum, 0) }
        [SimpleProgress]$progress = [SimpleProgress]::new('Get build history', 0, '{0} items added.')
        $progress.StartProgress()
        foreach ($startBuildId in $startBuildIds) {
            [string]$historyUri = "$BaseUriProjectApi/$AccountName/$ProjectSlug/history?"
            if ($startBuildId -eq 0) {
                $historyUri += 'recordsNumber=10'
            }
            else {
                $historyUri += "recordsNumber=100&startBuildId=$startBuildId"
            }
            do {
                $history = Invoke-RestMethod -Uri $historyUri
                [long]$buildId = 0
                foreach ($entry in $history.builds) {
                    [Build]$build = [Build]::new()
                    $build.FromJsonObject($entry)
                    $buildId = $build.BuildId
                    if (${minmax}?.Maximum -eq $buildId) {
                        $buildId = 0
                        break
                    }
                    $builds.Add($build)
                    $progress.AddProgress()
                    $shouldExport = $true
                }
                $historyUri = "$BaseUriProjectApi/$AccountName/$ProjectSlug/history?recordsNumber=100&startBuildId=$buildId"
            } until ($buildId -eq 0)
        }

        # Get build details
        [List[Build]]$briefBuilds = $builds.FindAll({ param([Build]$b) $b.JobsCount -eq 0 -and $b.IsCompleted() })
        if ($briefBuilds) {
            $shouldExport = $true
            [int]$throttle = [Math]::Min($ThrottleLimit, $briefBuilds.Count)
            [SimpleProgress]$progress = [SimpleProgress]::new('Get build details', $briefBuilds.Count)
            $progress.StartProgress()
            $briefBuilds | ForEach-Object -ThrottleLimit $throttle -Parallel ([Build]::ParallelDetailsRequester) | ForEach-Object -Process {
                $_.Build.FromRestApi($_.ProjectBuildJson, $_.ArtifactsJson)
                $progress.AddProgress()
            }
        }
    }
    finally {
        if ($shouldExport) {
            Write-Progress -Activity 'Save builds to file'
            $builds.Sort({ param([Build]$x, [Build]$y) return [Math]::Sign($x.BuildId - $y.BuildId) })
            # Note: Pwsh ForEach not available due to void List<>.ForEach(Action)
            $builds.ConvertAll([Converter[Build, PSCustomObject]] { param([Build]$b) return $b.ToCsvObject() }) | Export-Csv $fileNames.Builds
        }
    }

    # Because the feed is alpha-sorted, we could probably start with Packages?$skiptoken='benchmarkdotnet',''"
    # and break when the package name changes.
    $packages.Clear()
    [string]$feedUri = "$BaseUriNuGetV2/$feedId/Packages"
    [SimpleProgress]$progress = [SimpleProgress]::new('Get NuGet feed', 0, '{0} index pages processed.')
    $progress.ReportInterval = 0
    for (; ; ) {
        [XmlElement]$feed = ([xml](Invoke-WebRequest -Uri $feedUri).Content).feed
        foreach ($entry in $feed.entry) {
            [Package]$package = [Package]::FromXmlElement($entry, $feedTimeZone)
            if ($packageId -eq '' -or $packageId -eq $package.PackageId) {
                $packages.Add($package)
            }
        }
        $progress.AddProgress()
        $next = $feed.psobject.Properties['link']?.Value.Where({ $_.rel -eq 'next' })
        if (-not $next) { break }
        if ($next.Count -ne 1) { throw ('Invalid "next" link', $next | Out-String ) }
        $feedUri = $next[0].href
    }
    Write-Progress -Activity 'Save packages to file'
    $packages.Sort({ param([Package]$x, [Package]$y) return [Math]::Sign($x.Updated.Ticks - $y.Updated.Ticks) })
    # Note: Pwsh ForEach not available due to void List<>.ForEach(Action)
    $packages.ConvertAll([Converter[Package, PSCustomObject]] { param([Package]$p) return $p.ToCsvObject() }) | Export-Csv $fileNames.Packages
}

Write-Progress -Activity 'Analyze builds'
[Dictionary[int, Package]]$packagesByBuildNumber = $packages.ConvertAll([Converter[Package, KeyValuePair[int, Package]]] { 
        param([Package]$p) 
        return [KeyValuePair[int, Package]]::new($p.GetBuildNumber(), $p) 
    })
[List[AnalyzedBuild]]$analyzedBuilds = $builds | Group-Object -Property BuildNumber | ForEach-Object {
    [bool]$needsPackage = $true
    $_.Group | Sort-Object -Property Finished -Descending | ForEach-Object {
        if ($needsPackage -and $_.NupkgCount) {
            $needsPackage = $false
            [Package]$pkg = $null
            if (-not $packagesByBuildNumber.Remove($_.BuildNumber, [ref]$pkg)) { $pkg = $null }
            return [AnalyzedBuild]::new($_, $pkg, $true)
        }
        else {
            return [AnalyzedBuild]::new($_, $null, $false)
        }
    }
}
if ($packagesByBuildNumber.Count) {
    Write-Warning "Unassigned packages: $($packagesByBuildNumber.Count)"
}

Write-Progress -Activity 'Save analysis to file(s)'
$analyzedBuilds.Sort({ param([AnalyzedBuild]$x, [AnalyzedBuild]$y) return [Math]::Sign($x.BuildId - $y.BuildId) })
$analyzedBuilds.ConvertAll([Converter[AnalyzedBuild, PSCustomObject]] { param([AnalyzedBuild]$b) return $b.ToCsvObject() }) | Export-Csv $fileNames.AnalyzedBuilds
$packagesByBuildNumber.Values | Sort-Object -Property Updated | ForEach-Object { $_.ToCsvObject() } | Export-Csv $fileNames.UnassignedPackages
