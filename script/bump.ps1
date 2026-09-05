<#
.SYNOPSIS
    Bump WinGet manifests from GitHub latest releases and submit them with wingetcreate.

.DESCRIPTION
    Discovers package directories in this repo, syncs the siakhooi/winget-pkgs fork,
    copies each app's previous manifest (preserving per-app fields), updates version /
    installer URLs / SHA-256 / dates, submits a PR with wingetcreate.exe, and commits
    the new files in this repo.

    With no package arguments, every package is processed. Otherwise only the named
    packages are processed (directory name, PackageName, or PackageIdentifier).

.EXAMPLE
    .\script\bump.ps1
    .\script\bump.ps1 jexl-executor picsum
    .\script\bump.ps1 -DryRun
    .\script\bump.ps1 -SkipSubmit -Commit
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipSubmit,
    [switch]$SkipSync,
    [switch]$Commit,
    [switch]$Push,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Packages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot
$ForkRepo = 'siakhooi/winget-pkgs'
$ForkBranch = 'master'
$WingetPkgsRepo = 'microsoft/winget-pkgs'
$UserAgent = 'siakhooi-winget-manifests-bump'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Test-GitHubActions {
    return $env:GITHUB_ACTIONS -eq 'true'
}

function Get-EnvToken {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return $null
}

function Get-GhCliToken {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        return $null
    }
    $token = & gh auth token 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($token)) {
        return $token.Trim()
    }
    return $null
}

function Get-ApiToken {
    $token = Get-EnvToken @('GH_TOKEN', 'GITHUB_TOKEN', 'WINGET_TOKEN', 'WINGET_CREATE_GITHUB_TOKEN')
    if ($token) {
        return $token
    }
    return Get-GhCliToken
}

function Get-SubmitToken {
    $token = Get-EnvToken @('WINGET_TOKEN', 'WINGET_CREATE_GITHUB_TOKEN', 'WINGET_GITHUB_TOKEN')
    if ($token) {
        return $token
    }
    if (Test-GitHubActions) {
        return $null
    }
    $token = Get-EnvToken @('GH_TOKEN', 'GITHUB_TOKEN')
    if ($token) {
        return $token
    }
    return Get-GhCliToken
}

function Get-GitHubHeaders {
    param([string]$Token)
    $headers = @{
        'User-Agent'           = $UserAgent
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($Token) {
        $headers['Authorization'] = "Bearer $Token"
    }
    return $headers
}

function Invoke-GitHubApi {
    param(
        [string]$Url,
        [string]$Token
    )
    return Invoke-RestMethod -Uri $Url -Headers (Get-GitHubHeaders -Token $Token) -Method Get
}

function ConvertTo-VersionSortKey {
    param([string]$Version)
    $parts = [regex]::Split($Version, '(\d+)') | Where-Object { $_ -ne '' }
    $key = foreach ($part in $parts) {
        if ($part -match '^\d+$') {
            $part.PadLeft(10, '0')
        }
        else {
            $part.ToLowerInvariant()
        }
    }
    return ($key -join '.')
}

function ConvertFrom-ReleaseTag {
    param([string]$Tag)
    if ($Tag.Length -gt 1 -and ($Tag.StartsWith('v') -or $Tag.StartsWith('V')) -and [char]::IsDigit($Tag[1])) {
        return $Tag.Substring(1)
    }
    return $Tag
}

function Get-YamlField {
    param(
        [string]$Text,
        [string]$Key
    )
    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key)):\s*(.+?)\s*$")
    if (-not $match.Success) {
        return $null
    }
    $value = $match.Groups[1].Value.Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Get-YamlFields {
    param(
        [string]$Text,
        [string]$Key
    )
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Text, "(?m)^.*\b$([regex]::Escape($Key)):\s*(\S+)\s*$")) {
        $values.Add($match.Groups[1].Value.Trim())
    }
    return $values
}

function Set-YamlField {
    param(
        [string]$Text,
        [string]$Key,
        [string]$Value
    )
    $pattern = "(?m)^($([regex]::Escape($Key))):\s*.*$"
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
    $updated = $regex.Replace($Text, { param($m) "$($m.Groups[1].Value): $Value" }, 1)
    if ($updated -eq $Text) {
        throw "Could not update YAML field $Key"
    }
    return $updated
}

function Get-Newline {
    param([string]$Text)
    if ($Text -match "`r`n") {
        return "`r`n"
    }
    return "`n"
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Get-ManifestFile {
    param(
        [string]$VersionDir,
        [ValidateSet('installer', 'locale', 'version')]
        [string]$Kind
    )
    $files = @(Get-ChildItem -Path $VersionDir -Filter '*.yaml' -File)
    switch ($Kind) {
        'installer' {
            $files = @($files | Where-Object { $_.Name -like '*.installer.yaml' })
        }
        'locale' {
            $files = @($files | Where-Object { $_.Name -like '*.locale.en-US.yaml' })
        }
        'version' {
            $files = @($files | Where-Object { $_.Name -notlike '*.installer.yaml' -and $_.Name -notlike '*.locale.*' })
        }
    }
    if ($files.Count -eq 0) {
        throw "No $Kind manifest in $VersionDir"
    }
    return $files[0]
}

function Get-GitHubRepoFromUrl {
    param([string]$Url)
    $match = [regex]::Match($Url, 'github\.com/([^/]+)/([^/#\s]+)')
    if (-not $match.Success) {
        return $null
    }
    return '{0}/{1}' -f $match.Groups[1].Value, $match.Groups[2].Value.TrimEnd('/')
}

function Get-PackageList {
    $packages = @()
    Get-ChildItem -Path $Root -Directory | Sort-Object Name | ForEach-Object {
        $manifests = Join-Path $_.FullName 'manifests'
        if (-not (Test-Path -LiteralPath $manifests -PathType Container)) {
            return
        }
        $versionDirs = @(
            Get-ChildItem -Path $manifests -Recurse -Directory |
                Where-Object {
                    $relative = $_.FullName.Substring($manifests.Length).TrimStart('\', '/')
                    $parts = @($relative -split '[\\/]' | Where-Object { $_ })
                    $parts.Count -eq 4
                }
        )
        if ($versionDirs.Count -eq 0) {
            throw "$($_.Name): no version directories under manifests/"
        }
        $localDir = $versionDirs | Sort-Object { ConvertTo-VersionSortKey $_.Name } | Select-Object -Last 1
        $versionText = [System.IO.File]::ReadAllText((Get-ManifestFile -VersionDir $localDir.FullName -Kind version).FullName)
        $localeText = [System.IO.File]::ReadAllText((Get-ManifestFile -VersionDir $localDir.FullName -Kind locale).FullName)
        $installerText = [System.IO.File]::ReadAllText((Get-ManifestFile -VersionDir $localDir.FullName -Kind installer).FullName)
        $identifier = Get-YamlField -Text $versionText -Key 'PackageIdentifier'
        $packageUrl = Get-YamlField -Text $localeText -Key 'PackageUrl'
        if (-not $identifier) {
            throw "$($_.Name): missing PackageIdentifier"
        }
        if (-not $packageUrl) {
            throw "$($_.Name): missing PackageUrl"
        }
        $repo = Get-GitHubRepoFromUrl -Url $packageUrl
        if (-not $repo) {
            throw "$($_.Name): PackageUrl is not a GitHub URL: $packageUrl"
        }
        $installerUrls = @(Get-YamlFields -Text $installerText -Key 'InstallerUrl')
        if ($installerUrls.Count -eq 0) {
            throw "$($_.Name): no InstallerUrl entries"
        }
        $packages += [pscustomobject]@{
            DirName        = $_.Name
            Path           = $_.FullName
            Identifier     = $identifier
            LocalVersion   = $localDir.Name
            LocalDir       = $localDir.FullName
            GitHubRepo     = $repo
            InstallerUrls  = $installerUrls
        }
    }
    if ($packages.Count -eq 0) {
        throw "No package directories with manifests found in $Root"
    }
    return $packages
}

function Resolve-PackageSelection {
    param(
        [object[]]$AllPackages,
        [string[]]$Names
    )
    $expanded = @()
    foreach ($name in @($Names)) {
        $expanded += $name -split '[,\s]+' | Where-Object { $_ }
    }
    if ($expanded.Count -eq 0) {
        return $AllPackages
    }
    $selected = @()
    $known = ($AllPackages | ForEach-Object { $_.DirName }) -join ', '
    foreach ($name in $expanded) {
        $lower = $name.ToLowerInvariant()
        $match = $AllPackages | Where-Object {
            $idTail = $_.Identifier.Split('.')[-1]
            @(
                $_.DirName.ToLowerInvariant(),
                $_.Identifier.ToLowerInvariant(),
                $idTail.ToLowerInvariant()
            ) -contains $lower
        } | Select-Object -First 1
        if (-not $match) {
            throw "Unknown package '$name'. Known packages: $known"
        }
        $already = @($selected | ForEach-Object { $_.DirName })
        if ($already -notcontains $match.DirName) {
            $selected += $match
        }
    }
    return $selected
}

function Get-LatestRelease {
    param(
        [string]$Repo,
        [string]$Token
    )
    $data = Invoke-GitHubApi -Url "https://api.github.com/repos/$Repo/releases/latest" -Token $Token
    $assets = @{}
    foreach ($asset in @($data.assets)) {
        if ($asset.name -and $asset.browser_download_url) {
            $assets[$asset.name] = $asset.browser_download_url
        }
    }
    $published = [string]$data.published_at
    return [pscustomobject]@{
        Tag           = [string]$data.tag_name
        Version       = ConvertFrom-ReleaseTag -Tag ([string]$data.tag_name)
        PublishedDate = if ($published.Length -ge 10) { $published.Substring(0, 10) } else { '' }
        HtmlUrl       = if ($data.html_url) { [string]$data.html_url } else { "https://github.com/$Repo/releases/tag/$($data.tag_name)" }
        Assets        = $assets
    }
}

function Get-WingetPkgsVersions {
    param(
        [string]$Identifier,
        [string]$Token
    )
    $first = $Identifier.Substring(0, 1).ToLowerInvariant()
    $path = ($Identifier.Split('.') -join '/')
    $url = "https://api.github.com/repos/$WingetPkgsRepo/contents/manifests/$first/$path"
    try {
        $data = Invoke-GitHubApi -Url $url -Token $Token
    }
    catch {
        if ("$_" -match '404') {
            return @()
        }
        throw
    }
    return @($data | Where-Object { $_.type -eq 'dir' -and $_.name } | ForEach-Object { [string]$_.name })
}

function Resolve-InstallerAsset {
    param(
        [string]$OldUrl,
        [string]$OldVersion,
        [string]$NewVersion,
        [hashtable]$Assets
    )
    $oldName = ($OldUrl.TrimEnd('/') -split '/')[-1]
    $idx = $oldName.IndexOf($OldVersion)
    if ($idx -ge 0) {
        $expected = $oldName.Substring(0, $idx) + $NewVersion + $oldName.Substring($idx + $OldVersion.Length)
    }
    else {
        $expected = $oldName.Replace($OldVersion, $NewVersion)
    }
    if ($Assets.ContainsKey($expected)) {
        return @{ Name = $expected; Url = $Assets[$expected] }
    }
    foreach ($name in $Assets.Keys) {
        if ($name.ToLowerInvariant() -eq $expected.ToLowerInvariant()) {
            return @{ Name = $name; Url = $Assets[$name] }
        }
    }
    $available = if ($Assets.Count -gt 0) { ($Assets.Keys | Sort-Object) -join ', ' } else { '(none)' }
    throw "Release has no installer named '$expected' (from $oldName). Assets: $available"
}

function Update-InstallerYaml {
    param(
        [string]$Text,
        [string]$Version,
        [string]$ReleaseDate,
        [hashtable]$Replacements
    )
    $text = Set-YamlField -Text $Text -Key 'PackageVersion' -Value $Version
    if ($ReleaseDate) {
        if ([regex]::IsMatch($text, '(?m)^ReleaseDate:\s*')) {
            $text = Set-YamlField -Text $text -Key 'ReleaseDate' -Value $ReleaseDate
        }
        else {
            $text = [regex]::Replace(
                $text,
                '(?m)^(PackageVersion:\s*.*)$',
                { param($m) "$($m.Groups[1].Value)$(Get-Newline $text)ReleaseDate: $ReleaseDate" },
                1
            )
        }
    }
    $nl = Get-Newline $text
    $lines = $text -split "`r?`n", -1
    $pendingSha = $null
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '\bInstallerUrl:') {
            $oldUrl = ($line.Split('InstallerUrl:', 2)[1]).Trim()
            if ($Replacements.ContainsKey($oldUrl)) {
                $replacement = $Replacements[$oldUrl]
                $line = $line.Replace($oldUrl, $replacement.Url)
                $pendingSha = $replacement.Sha
            }
        }
        elseif ($null -ne $pendingSha -and $line -match '\bInstallerSha256:') {
            $parts = $line.Split('InstallerSha256:', 2)
            $oldSha = $parts[1].Trim()
            $sha = if ($oldSha -cmatch '^[0-9A-F]+$') { $pendingSha.ToUpperInvariant() } else { $pendingSha.ToLowerInvariant() }
            $line = '{0}InstallerSha256: {1}' -f $parts[0], $sha
            $pendingSha = $null
        }
        $out.Add($line)
    }
    $joined = [string]::Join($nl, $out.ToArray())
    if ($Text.EndsWith("`n") -and -not $joined.EndsWith("`n")) {
        $joined += $nl
    }
    return $joined
}

function New-ManifestVersion {
    param(
        [object]$Package,
        [object]$Release,
        [hashtable]$Replacements,
        [switch]$WhatIf
    )
    $dest = Join-Path (Split-Path -Parent $Package.LocalDir) $Release.Version
    if ($WhatIf) {
        Write-Log "    would write manifests to $($dest.Substring($Root.Length + 1))"
        return $dest
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem -Path $Package.LocalDir -File | Where-Object { $_.Extension -in '.yaml', '.yml' } | ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        if ($_.Name -like '*.installer.yaml') {
            $text = Update-InstallerYaml -Text $text -Version $Release.Version -ReleaseDate $Release.PublishedDate -Replacements $Replacements
        }
        else {
            $text = Set-YamlField -Text $text -Key 'PackageVersion' -Value $Release.Version
            if ($_.Name -like '*.locale.*' -and (Get-YamlField -Text $text -Key 'ReleaseNotesUrl')) {
                $text = Set-YamlField -Text $text -Key 'ReleaseNotesUrl' -Value $Release.HtmlUrl
            }
        }
        Write-Utf8NoBom -Path (Join-Path $dest $_.Name) -Content $text
    }
    Write-Log "    wrote $($dest.Substring($Root.Length + 1))"
    return $dest
}

function Update-PackageJustfile {
    param(
        [object]$Package,
        [string]$NewVersion,
        [switch]$WhatIf
    )
    $justfile = Join-Path $Package.Path 'justfile'
    if (-not (Test-Path -LiteralPath $justfile)) {
        return
    }
    $text = [System.IO.File]::ReadAllText($justfile)
    $regex = New-Object System.Text.RegularExpressions.Regex('(?m)^(packageVersion\s*:=\s*)"[^"]*"')
    $updated = $regex.Replace($text, { param($m) "$($m.Groups[1].Value)`"$NewVersion`"" }, 1)
    if ($updated -eq $text) {
        return
    }
    $rel = $justfile.Substring($Root.Length + 1)
    if ($WhatIf) {
        Write-Log "    would set $rel packageVersion := `"$NewVersion`""
        return
    }
    Write-Utf8NoBom -Path $justfile -Content $updated
    Write-Log "    updated $rel"
}

function Get-WingetCreatePath {
    foreach ($name in @('wingetcreate.exe', 'wingetcreate')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }
    $dest = Join-Path ([System.IO.Path]::GetTempPath()) 'wingetcreate.exe'
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Log '    downloading wingetcreate.exe'
        Invoke-WebRequest -Uri 'https://aka.ms/wingetcreate/latest' -OutFile $dest -UseBasicParsing
    }
    return $dest
}

function Sync-WingetPkgsFork {
    param(
        [string]$Token,
        [switch]$WhatIf
    )
    if ($WhatIf) {
        Write-Log "Syncing fork $ForkRepo (dry-run: skipped)"
        return
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh is required to sync the winget-pkgs fork. Install GitHub CLI: https://cli.github.com/'
    }
    if (-not $Token) {
        throw "No token available to sync $ForkRepo. Set WINGET_TOKEN to a PAT that can write to that fork."
    }
    Write-Log "Syncing fork $ForkRepo from $WingetPkgsRepo ($ForkBranch)"
    $previous = $env:GH_TOKEN
    $env:GH_TOKEN = $Token
    try {
        & gh repo sync $ForkRepo --source $WingetPkgsRepo --branch $ForkBranch
        if ($LASTEXITCODE -ne 0) {
            throw "gh repo sync $ForkRepo failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if ($null -eq $previous) {
            Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        }
        else {
            $env:GH_TOKEN = $previous
        }
    }
}

function Submit-Manifest {
    param(
        [string]$ManifestDir,
        [string]$Identifier,
        [string]$Version,
        [string]$Token,
        [switch]$WhatIf
    )
    $rel = $ManifestDir.Substring($Root.Length + 1)
    if ($WhatIf) {
        Write-Log "    would submit $rel to $WingetPkgsRepo"
        return
    }
    if (-not $Token) {
        if (Test-GitHubActions) {
            throw "No token available to submit to $WingetPkgsRepo. Set repository secret WINGET_TOKEN (classic PAT with public_repo) from the account that owns $ForkRepo."
        }
        Write-Log "    skip submit: no WINGET_TOKEN (set it, or run wingetcreate token -s)"
        return
    }
    $wingetcreate = Get-WingetCreatePath
    $title = "$Identifier $Version"
    Write-Log "    submitting $rel to $WingetPkgsRepo"
    $previous = $env:WINGET_CREATE_GITHUB_TOKEN
    $env:WINGET_CREATE_GITHUB_TOKEN = $Token
    try {
        & $wingetcreate submit --prtitle $title --no-open $ManifestDir
        if ($LASTEXITCODE -ne 0) {
            throw "wingetcreate submit failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if ($null -eq $previous) {
            Remove-Item Env:WINGET_CREATE_GITHUB_TOKEN -ErrorAction SilentlyContinue
        }
        else {
            $env:WINGET_CREATE_GITHUB_TOKEN = $previous
        }
    }
}

function Save-GitHistory {
    param(
        [object[]]$PackageList,
        [switch]$WhatIf
    )
    $inActions = Test-GitHubActions
    $shouldCommit = $Commit -or $inActions
    $shouldPush = $Push -or $inActions
    if (-not $shouldCommit) {
        return
    }
    if ($WhatIf) {
        Write-Log 'Would commit local manifest changes in this repo'
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Log 'skip commit: git not found'
        return
    }
    Push-Location $Root
    try {
        & git rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'skip commit: not a git repository'
            return
        }
        foreach ($package in $PackageList) {
            & git add -- $package.Path
        }
        $status = @(git status --porcelain -- $PackageList.Path)
        if ($status.Count -eq 0) {
            Write-Log 'No local manifest changes to commit'
            return
        }
        if ($inActions) {
            $env:GIT_AUTHOR_NAME = 'github-actions[bot]'
            $env:GIT_AUTHOR_EMAIL = '41898282+github-actions[bot]@users.noreply.github.com'
            $env:GIT_COMMITTER_NAME = $env:GIT_AUTHOR_NAME
            $env:GIT_COMMITTER_EMAIL = $env:GIT_AUTHOR_EMAIL
        }
        & git commit -m "Bump winget manifests to latest GitHub releases"
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed with exit code $LASTEXITCODE"
        }
        Write-Log 'Committed local manifest changes'
        if ($shouldPush) {
            & git push
            if ($LASTEXITCODE -ne 0) {
                throw "git push failed with exit code $LASTEXITCODE"
            }
            Write-Log 'Pushed local manifest changes'
        }
    }
    finally {
        Pop-Location
    }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Update-Package {
    param(
        [object]$Package,
        [string]$ApiToken,
        [string]$SubmitToken,
        [switch]$WhatIf
    )
    Write-Log "==> $($Package.DirName) ($($Package.Identifier))"
    $release = Get-LatestRelease -Repo $Package.GitHubRepo -Token $ApiToken
    $published = @(Get-WingetPkgsVersions -Identifier $Package.Identifier -Token $ApiToken)
    $publishedText = if ($published.Count -gt 0) { ($published | Sort-Object { ConvertTo-VersionSortKey $_ }) -join ', ' } else { 'none' }
    Write-Log "    GitHub:      $($release.Tag) ($($release.Version))"
    Write-Log "    local:       $($Package.LocalVersion)"
    Write-Log "    winget-pkgs: $publishedText"

    if ((ConvertTo-VersionSortKey $release.Version) -lt (ConvertTo-VersionSortKey $Package.LocalVersion)) {
        Write-Log '    skip: local version is newer than GitHub latest'
        return 'skipped'
    }

    $dest = Join-Path (Split-Path -Parent $Package.LocalDir) $release.Version
    $needWrite = -not (Test-Path -LiteralPath $dest -PathType Container)
    $needSubmit = $published -notcontains $release.Version

    if ($needWrite) {
        $replacements = @{}
        foreach ($oldUrl in $Package.InstallerUrls) {
            $asset = Resolve-InstallerAsset -OldUrl $oldUrl -OldVersion $Package.LocalVersion -NewVersion $release.Version -Assets $release.Assets
            Write-Log "    installer:   $($asset.Name)"
            $replacements[$oldUrl] = @{ Url = $asset.Url; Sha = '' }
        }
        if ($WhatIf) {
            $null = New-ManifestVersion -Package $Package -Release $release -Replacements $replacements -WhatIf
            Update-PackageJustfile -Package $Package -NewVersion $release.Version -WhatIf
        }
        else {
            $temp = New-TemporaryFile
            Remove-Item -LiteralPath $temp
            $tempDir = New-Item -ItemType Directory -Path "$temp.d"
            try {
                $hashed = @{}
                foreach ($oldUrl in $replacements.Keys) {
                    $url = $replacements[$oldUrl].Url
                    $filename = ($url.TrimEnd('/') -split '/')[-1]
                    $destFile = Join-Path $tempDir.FullName $filename
                    Write-Log "    downloading  $filename"
                    Invoke-WebRequest -Uri $url -OutFile $destFile -UseBasicParsing
                    $hashed[$oldUrl] = @{ Url = $url; Sha = Get-FileSha256 -Path $destFile }
                }
                $dest = New-ManifestVersion -Package $Package -Release $release -Replacements $hashed
            }
            finally {
                Remove-Item -LiteralPath $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            Update-PackageJustfile -Package $Package -NewVersion $release.Version
        }
    }
    else {
        Write-Log '    local manifests already at latest GitHub version'
    }

    if ($SkipSubmit) {
        Write-Log '    skip submit (-SkipSubmit)'
        if ($needWrite) { return 'updated' } else { return 'current' }
    }
    if (-not $needSubmit) {
        Write-Log '    skip submit: already in microsoft/winget-pkgs'
        return 'current'
    }

    Submit-Manifest -ManifestDir $dest -Identifier $Package.Identifier -Version $release.Version -Token $SubmitToken -WhatIf:$WhatIf
    return 'submitted'
}

function Add-StepSummary {
    param([string[]]$Lines)
    if (-not $env:GITHUB_STEP_SUMMARY) {
        return
    }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($Lines -join [Environment]::NewLine)
}

# --- main ---
$exitCode = 0
try {
    $apiToken = Get-ApiToken
    $submitToken = Get-SubmitToken
    $allPackages = Get-PackageList
    $selected = @(Resolve-PackageSelection -AllPackages $allPackages -Names $Packages)
}
catch {
    Write-Err "error: $_"
    exit 2
}

try {
    if (-not $SkipSync) {
        Sync-WingetPkgsFork -Token $submitToken -WhatIf:$DryRun
    }
    else {
        Write-Log 'Skipping fork sync (-SkipSync)'
    }

    $failures = @()
    $results = @('| Package | Result |', '| --- | --- |')
    foreach ($package in $selected) {
        try {
            $status = Update-Package -Package $package -ApiToken $apiToken -SubmitToken $submitToken -WhatIf:$DryRun
            $results += "| $($package.DirName) | $status |"
        }
        catch {
            Write-Err "error: $($package.DirName): $_"
            $failures += $package.DirName
            $results += "| $($package.DirName) | failed |"
        }
        Write-Log ''
    }
    Add-StepSummary -Lines (@('## WinGet bump', '') + $results)
    if ($failures.Count -gt 0) {
        Write-Err ('failed: ' + ($failures -join ', '))
        $exitCode = 1
    }
}
finally {
    Save-GitHistory -PackageList $allPackages -WhatIf:$DryRun
}

exit $exitCode
