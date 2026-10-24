#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LocalPath,
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][ValidateSet('public', 'private')][string]$Visibility,
    [Parameter(Mandatory)][string[]]$Files,
    [string]$Description = '',
    [string]$CommitMessage = 'Publish project updates',
    [switch]$CreateIfMissing,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
# Explicit exit-code handling also works when callers enable this PS 7 option.
$PSNativeCommandUseErrorActionPreference = $false
$savedPrompt = $env:GIT_TERMINAL_PROMPT
$savedInteractive = $env:GCM_INTERACTIVE
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = '0'

function Invoke-Git {
    param([string[]]$Arguments)
    $output = @(& git -c "credential.username=$Owner" -c core.quotepath=false @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Git operation failed: $($Arguments[0]) (exit $LASTEXITCODE)" }
    $output
}

function Invoke-Api {
    param([string]$Path, [string]$Method = 'Get', [object]$Body, [switch]$Anonymous, [switch]$AllowNotFound)
    $requestHeaders = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if (-not $Anonymous) { $requestHeaders.Authorization = $headers.Authorization }
    $request = @{ Uri = "https://api.github.com$Path"; Headers = $requestHeaders; Method = $Method; TimeoutSec = 30 }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json))
    }
    try { Invoke-RestMethod @request }
    catch {
        $status = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        if ($Method -eq 'Post' -and $status -eq 422) {
            throw 'Repository creation rejected (422). Check name conflicts and credential access; an earlier 404 does not prove absence. Do not retry creation blindly.'
        }
        throw "GitHub API $Method $Path failed (HTTP $status; 0 means network/timeout). Check connectivity and credential permissions."
    }
}

try {
    if ($Owner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$' -or $Repository -notmatch '^[A-Za-z0-9_.-]+$' -or $Repository -in @('.', '..')) {
        throw 'Use a GitHub personal account and repository name, not a URL.'
    }
    Push-Location -LiteralPath $LocalPath
    try {
        $root = (Get-Item -LiteralPath '.').FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
        $existingRoot = @(& git rev-parse --show-toplevel 2>$null)
        $hasRepo = $LASTEXITCODE -eq 0
        if ($hasRepo -and [IO.Path]::GetFullPath($existingRoot[0]).TrimEnd([IO.Path]::DirectorySeparatorChar) -ne $root) {
            throw 'LocalPath must be the Git repository root, not a child of another repository.'
        }
        # Exact relative files only: no fixed references/ requirement or broad directory staging.
        $selected = @()
        foreach ($file in $Files) {
            if ([IO.Path]::IsPathRooted($file)) { throw "Files must be relative: $file" }
            $full = [IO.Path]::GetFullPath((Join-Path $root $file))
            $prefix = $root + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "File is outside LocalPath: $file" }
            $relative = $full.Substring($prefix.Length).Replace('\', '/')
            if ($relative -match '^\.git(/|$)') { throw 'Do not publish Git metadata.' }
            if (Test-Path -LiteralPath $full -PathType Container) { throw "List individual files instead of a directory: $file" }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                # Allow explicitly selected deletions of tracked files.
                $tracked = if ($hasRepo) { & git ls-files --error-unmatch -- ":(literal)$relative" 2>$null | Out-Null; $LASTEXITCODE -eq 0 } else { $false }
                if (-not $tracked) { throw "Selected file does not exist and is not tracked: $file" }
            }
            $selected += $relative
        }
        $selected = @($selected | Select-Object -Unique)
        if ($selected.Count -eq 0) { throw 'Select at least one file.' }
        if ($hasRepo) {
            $staged = @(Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--no-renames'))
            $outside = @($staged | Where-Object { $_ -cnotin $selected })
            if ($outside.Count) { throw "Unrelated staged files; preserve them and resolve before publishing: $($outside -join ', ')" }
            Invoke-Git -Arguments @('diff', '--cached', '--check') | Out-Null
        }
        $author = @(& git config user.name)
        $authorEmail = @(& git config user.email)
        if (-not $author -or -not $authorEmail) { throw 'Configure the intended Git author before publishing; do not guess or change global identity.' }
        $remoteUrl = "https://github.com/$Owner/$Repository.git"
        $origins = if ($hasRepo) { @(Invoke-Git -Arguments @('remote')) } else { @() }
        if ('origin' -in $origins) {
            $urls = @(Invoke-Git -Arguments @('remote', 'get-url', '--all', 'origin'))
            $pushUrls = @(Invoke-Git -Arguments @('remote', 'get-url', '--push', '--all', 'origin'))
            foreach ($url in @($urls) + @($pushUrls)) {
                if ($url.TrimEnd('/') -ine $remoteUrl -and $url.TrimEnd('/') -ine $remoteUrl.Substring(0, $remoteUrl.Length - 4)) {
                    throw 'origin does not match the requested HTTPS repository. Resolve it explicitly; do not overwrite it silently.'
                }
            }
        }
        if ($hasRepo) {
            $branch = (Invoke-Git -Arguments @('branch', '--show-current'))
            if (-not $branch) { throw 'Detached HEAD: select the intended branch before publishing.' }
        } else { $branch = 'main' }

        # Capture secrets locally. Never emit the raw credential response or headers.
        $credentialLines = "protocol=https`nhost=github.com`nusername=$Owner`n`n" | & git credential fill 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'No usable noninteractive GitHub credential. Complete Git Credential Manager login, then retry.' }
        $credentialMap = @{}
        foreach ($line in $credentialLines) {
            $pair = $line -split '=', 2
            if ($pair.Length -eq 2) { $credentialMap[$pair[0]] = $pair[1] }
        }
        if (-not $credentialMap['password']) { throw 'Git credential helper returned no token.' }
        $headers = @{ Authorization = 'Bearer ' + $credentialMap['password'] }
        $profile = Invoke-Api -Path '/user'
        if ($profile.login -ine $Owner) { throw 'Credential account does not match Owner. Select the correct saved login.' }
        $repo = Invoke-Api -Path "/repos/$Owner/$Repository" -AllowNotFound
        if ($null -ne $repo) {
            if ($repo.full_name -ine "$Owner/$Repository") { throw 'Repository lookup resolved to another name; inspect rename/redirect before publishing.' }
            if ([bool]$repo.private -ne ($Visibility -eq 'private')) { throw 'Existing repository visibility differs. This script does not change existing visibility.' }
            # Prevent a successful feature-branch push from being reported as a default-branch update.
            Write-Host "Existing repository: $($repo.full_name); pushing branch $branch (default: $($repo.default_branch))."
        } elseif (-not $CreateIfMissing -and -not $CheckOnly) {
            throw 'Repository is not visible to this credential (404). Check access, or use CreateIfMissing only when creation is intended.'
        }
        if ($CheckOnly) {
            [pscustomobject]@{ Account = $profile.login; Repository = "$Owner/$Repository"; RepositoryVisible = ($null -ne $repo); Branch = $branch; SelectedFiles = $selected; Mode = 'CheckOnly' }
            return
        }

        if (-not $hasRepo) { Invoke-Git -Arguments @('init', '-b', 'main') | Out-Null }
        # Stage and validate the actual commit before creating an empty remote repository.
        $pathspecs = @($selected | ForEach-Object { ":(literal)$_" })
        Invoke-Git -Arguments (@('add', '-A', '--') + $pathspecs) | Out-Null
        Invoke-Git -Arguments @('diff', '--cached', '--check') | Out-Null
        $staged = @(Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--no-renames'))
        if (@($staged | Where-Object { $_ -cnotin $selected }).Count) { throw 'Staged scope changed; inspect the index before retrying.' }
        if ($staged.Count) { Invoke-Git -Arguments @('commit', '-m', $CommitMessage) | Out-Null }
        $localSha = (Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD')).Trim()
        if ($null -eq $repo) {
            $repo = Invoke-Api -Path '/user/repos' -Method Post -Body @{
                name = $Repository; description = $Description; private = ($Visibility -eq 'private'); auto_init = $false
            }
        }
        if ('origin' -notin $origins) { Invoke-Git -Arguments @('remote', 'add', 'origin', $remoteUrl) | Out-Null }
        Invoke-Git -Arguments @('push', '-u', 'origin', "HEAD:refs/heads/$branch") | Out-Null
        $remote = @(Invoke-Git -Arguments @('ls-remote', '--exit-code', 'origin', "refs/heads/$branch"))
        if ($remote.Count -ne 1 -or ($remote[0] -split '\s+')[0] -ne $localSha) { throw 'Verification failed: remote branch SHA differs from local HEAD.' }
        $published = Invoke-Api -Path "/repos/$Owner/$Repository" -Anonymous:($Visibility -eq 'public')
        if ([bool]$published.private -ne ($Visibility -eq 'private')) { throw 'Verification failed: unexpected visibility.' }
        $commit = Invoke-Api -Path "/repos/$Owner/$Repository/commits/$localSha" -Anonymous:($Visibility -eq 'public')
        if ($commit.sha -ne $localSha) { throw 'Verification failed: GitHub API did not confirm the pushed commit.' }
        [pscustomobject]@{
            Repository = $published.html_url; Visibility = $Visibility; Branch = $branch; Commit = $localSha
            Download = if ($Visibility -eq 'public') { "https://github.com/$Owner/$Repository/archive/$localSha.zip" } else { $null }
        }
    } finally { Pop-Location }
} finally {
    $env:GIT_TERMINAL_PROMPT = $savedPrompt
    $env:GCM_INTERACTIVE = $savedInteractive
    $headers = $null
    $credentialLines = $null
    $credentialMap = $null
}
