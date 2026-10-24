#requires -Version 7.0
# Offline integration tests: real local Git, fake credentials/API, no GitHub writes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$global:PublishTestGitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$global:PublishTestPublishScript = Join-Path $PSScriptRoot '../scripts/Publish-GitHub.ps1'
$global:PublishTestFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('github-publish-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $global:PublishTestFixtureRoot | Out-Null
$global:PublishTestPassed = 0

function Assert-True($Condition, $Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Fixture {
    $global:PublishTestProject = Join-Path $global:PublishTestFixtureRoot ([guid]::NewGuid().ToString('N'))
    $global:PublishTestBare = "$global:PublishTestProject.git"
    New-Item -ItemType Directory -Path $global:PublishTestProject | Out-Null
    & $global:PublishTestGitExe -C $global:PublishTestProject init -q -b main
    & $global:PublishTestGitExe -C $global:PublishTestProject config user.name 'Publish Test'
    & $global:PublishTestGitExe -C $global:PublishTestProject config user.email 'test@example.invalid'
    & $global:PublishTestGitExe init -q --bare -b main $global:PublishTestBare
    Set-Content -LiteralPath (Join-Path $global:PublishTestProject 'SKILL.md') -Value '# fixture'
    Set-Content -LiteralPath (Join-Path $global:PublishTestProject 'README.md') -Value '# fixture'
    $global:PublishTestCalls = @()
    $global:PublishTestNoCredential = $false
    $global:PublishTestMissingRepo = $false
    $global:PublishTestCreationConflict = $false
    $global:PublishTestWrongSha = $false
    $global:PublishTestFixtureVisibility = $false
    $global:PublishTestFixtureAccount = 'fixture-owner'
    $global:PublishTestPublishArgs = @{
        LocalPath = $global:PublishTestProject; Owner = 'fixture-owner'; Repository = 'fixture-repo'
        Visibility = 'public'; Files = @('SKILL.md', 'README.md')
    }
}

# Intercept only credentials and transport, leaving staging/commits real.
function git {
    $nativeArgs = @($args)
    if ($nativeArgs.Count -ge 2 -and $nativeArgs[0] -eq 'credential') {
        Assert-True ($env:GCM_INTERACTIVE -eq '0' -and $env:GIT_TERMINAL_PROMPT -eq '0') 'credential lookup must be noninteractive'
        $global:PublishTestCalls += 'credential'
        $global:LASTEXITCODE = if ($global:PublishTestNoCredential) { 1 } else { 0 }
        if (-not $global:PublishTestNoCredential) { 'username=fixture-owner'; 'password=fixture-not-a-real-token' }
        return
    }
    if ('push' -in $nativeArgs -or 'ls-remote' -in $nativeArgs) {
        $index = [Array]::IndexOf($nativeArgs, 'origin')
        Assert-True ($index -ge 0) 'transport must target origin'
        $nativeArgs[$index] = $global:PublishTestBare
    }
    $result = @(& $global:PublishTestGitExe @nativeArgs)
    $global:LASTEXITCODE = $LASTEXITCODE
    if ('ls-remote' -in $nativeArgs -and $global:PublishTestWrongSha -and $result.Count) {
        $result[0] = ('0' * 40) + "`trefs/heads/main"
    }
    $result
}

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $TimeoutSec, $ContentType, $Body)
    $global:PublishTestCalls += "$Method $Uri"
    Assert-True ($TimeoutSec -eq 30) 'API timeout'
    if ($Uri -eq 'https://api.github.com/user') { return @{ login = $global:PublishTestFixtureAccount } }
    if ($Method -eq 'Post' -and $Uri -eq 'https://api.github.com/user/repos') {
        if ($global:PublishTestCreationConflict) {
            $exception = [Exception]::new('fixture creation conflict')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 422 })
            throw $exception
        }
        $created = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        Assert-True ($created.private -eq $global:PublishTestFixtureVisibility) 'creation visibility'
        Assert-True (-not $created.auto_init) 'no remote initialization'
        $global:PublishTestMissingRepo = $false
        return @{ full_name = 'fixture-owner/fixture-repo'; private = $global:PublishTestFixtureVisibility; default_branch = 'main' }
    }
    if ($Uri -like 'https://api.github.com/repos/fixture-owner/fixture-repo/commits/*') {
        Assert-True (($Headers.ContainsKey('Authorization')) -eq $global:PublishTestFixtureVisibility) 'final commit auth matches visibility'
        return @{ sha = (& $global:PublishTestGitExe -C $global:PublishTestProject rev-parse HEAD) }
    }
    if ($Uri -eq 'https://api.github.com/repos/fixture-owner/fixture-repo') {
        if ($global:PublishTestMissingRepo) {
            $exception = [Exception]::new('fixture inaccessible repository')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 })
            throw $exception
        }
        return @{ full_name = 'fixture-owner/fixture-repo'; private = $global:PublishTestFixtureVisibility; default_branch = 'main'; html_url = 'https://github.com/fixture-owner/fixture-repo' }
    }
    throw "Unexpected API call: $Method $Uri"
}

function Expect-Failure([string]$Pattern, [hashtable]$Extra = @{}) {
    $failed = $false
    try { & $global:PublishTestPublishScript @global:PublishTestPublishArgs @Extra | Out-Null }
    catch {
        $failed = $true
        Assert-True ($_.Exception.Message -like $Pattern) "expected '$Pattern', got '$($_.Exception.Message)'"
    }
    Assert-True $failed "expected failure $Pattern"
}

function Pass([string]$Name) { $global:PublishTestPassed++; Write-Host "PASS $Name" }

try {
    New-Fixture
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedInteractive = $env:GCM_INTERACTIVE
    $result = & $global:PublishTestPublishScript @global:PublishTestPublishArgs
    Assert-True ($result.Commit -eq (& $global:PublishTestGitExe --git-dir=$global:PublishTestBare rev-parse main)) 'successful publication SHA'
    Assert-True ($env:GIT_TERMINAL_PROMPT -ceq $savedPrompt -and $env:GCM_INTERACTIVE -ceq $savedInteractive) 'restore environment'
    $firstSha = $result.Commit
    $result = & $global:PublishTestPublishScript @global:PublishTestPublishArgs
    Assert-True ($result.Commit -eq $firstSha) 'retry must not create another commit'
    Pass 'publish without references; verify SHA; retry is idempotent; restore environment'

    New-Fixture
    Set-Content -LiteralPath (Join-Path $global:PublishTestProject 'unrelated.txt') -Value 'user work'
    & $global:PublishTestGitExe -C $global:PublishTestProject add -- unrelated.txt
    Expect-Failure '*Unrelated staged files*'
    $staged = & $global:PublishTestGitExe -C $global:PublishTestProject diff --cached --name-only
    Assert-True ($staged -eq 'unrelated.txt') 'preserve original index'
    Assert-True ($global:PublishTestCalls.Count -eq 0) 'stop before credentials/API'
    Pass 'unrelated staged files preserved and excluded'

    New-Fixture
    $global:PublishTestPublishArgs.Files += 'missing.md'
    Expect-Failure '*Selected file does not exist*'
    Assert-True ($global:PublishTestCalls.Count -eq 0) 'missing files stop before API'
    Pass 'missing selected file fails before remote creation'

    New-Fixture
    $global:PublishTestNoCredential = $true
    Expect-Failure '*No usable noninteractive*'
    Assert-True ($global:PublishTestCalls.Count -eq 1) 'no API without credentials'
    Assert-True ($env:GCM_INTERACTIVE -ceq $savedInteractive) 'restore environment on failure'
    Pass 'missing credential fails promptly and restores environment'

    New-Fixture
    $global:PublishTestFixtureAccount = 'another-owner'
    Expect-Failure '*Credential account does not match*'
    Pass 'account mismatch stops publication'

    New-Fixture
    $global:PublishTestMissingRepo = $true
    $result = & $global:PublishTestPublishScript @global:PublishTestPublishArgs -CheckOnly
    Assert-True (-not $result.RepositoryVisible) '404 is not visible, not proven absent'
    Assert-True (-not (& $global:PublishTestGitExe -C $global:PublishTestProject status --porcelain | Where-Object { $_ -match '^[AM]' })) 'CheckOnly leaves index untouched'
    Expect-Failure '*Repository is not visible*'
    Assert-True (@($global:PublishTestCalls | Where-Object { $_ -like 'Post *' }).Count -eq 0) '404 must not automatically create'
    Pass 'CheckOnly is nonmutating; 404 requires explicit create intent'

    New-Fixture
    $global:PublishTestMissingRepo = $true
    $result = & $global:PublishTestPublishScript @global:PublishTestPublishArgs -CreateIfMissing
    Assert-True ($null -ne $result.Commit) 'explicit creation succeeds'
    Assert-True (@($global:PublishTestCalls | Where-Object { $_ -like 'Post *' }).Count -eq 1) 'one creation request'
    Pass 'explicit creation followed by verified push'

    New-Fixture
    $global:PublishTestMissingRepo = $true
    $global:PublishTestCreationConflict = $true
    Expect-Failure '*creation rejected (422)*' @{ CreateIfMissing = $true }
    Assert-True (@($global:PublishTestCalls | Where-Object { $_ -like 'Post *' }).Count -eq 1) 'no creation retry loop'
    Pass '404 then 422 reports conflict without retries'

    New-Fixture
    $global:PublishTestWrongSha = $true
    Expect-Failure '*remote branch SHA differs*'
    Pass 'remote SHA mismatch cannot report success'

    New-Fixture
    $global:PublishTestPublishArgs.Visibility = 'private'
    $global:PublishTestFixtureVisibility = $true
    $global:PublishTestMissingRepo = $true
    $result = & $global:PublishTestPublishScript @global:PublishTestPublishArgs -CreateIfMissing
    Assert-True ($result.Visibility -eq 'private' -and $null -eq $result.Download) 'private output'
    Pass 'private creation and authenticated verification'

    New-Fixture
    & $global:PublishTestGitExe -C $global:PublishTestProject remote add origin 'https://github.com/another-owner/another-repo.git'
    Expect-Failure '*origin does not match*'
    Assert-True ($global:PublishTestCalls.Count -eq 0) 'wrong remote stops before API'
    Pass 'incorrect existing origin is preserved'

    Write-Host "$global:PublishTestPassed integration scenarios passed. Fixtures: $global:PublishTestFixtureRoot"
} catch {
    Write-Host "Test fixtures retained: $global:PublishTestFixtureRoot"
    throw
}
