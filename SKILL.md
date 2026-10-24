---
name: github-publish-local-git
description: 使用 Windows 本机 Git 凭据、GitHub REST API 和 git push，将用户指定的本地目录发布或更新到其 GitHub 仓库；适用于 gh 不可用且已保存 GitHub 登录凭据的环境。
---

# 使用本机 Git 登录发布到 GitHub

本流程复用 Git credential helper 中的登录凭据：REST API 负责创建仓库，Git 负责上传提交。无需安装 `gh`，无需浏览器自动化。后续更新仍须 commit + push；本流程不是后台自动同步。

## 依赖与输入

- Windows、PowerShell、Git for Windows，能够访问 `api.github.com` 和 `github.com`。
- 已配置的 Git credential helper（本机实测为 `manager`，即 Git Credential Manager），并已保存 GitHub 登录凭据。凭据须拥有目标操作权限；能 push 不一定能创建仓库。
- Git 已配置提交作者。检查 `git config user.name`、`git config user.email`；缺失时询问用户，不猜测作者邮箱，不修改全局配置。
- 输入：本地目录、目标账号、仓库名、可见性、发布范围。账号必须在每次执行时通过 `/user` 核对，不要硬编码。
- 用户要求“公开分享”时采用 public；其他场景按用户要求。许可证沿用已有文件，不能把公开访问等同于获得修改、再分发授权。

如平台提供足够的 GitHub 连接器能力，优先使用；当连接器缺少创建仓库能力时采用本流程。连接器登录和本机 Git 登录互相独立，必须分别核对账号。

## 1. 检查本地发布范围

先用绝对路径进入用户指定目录，读取目录内适用的项目指令。确认它是否是 Git 仓库根目录，避免把父目录的项目一并上传。

```powershell
Set-Location -LiteralPath 'E:/path/to/project'
git --version
git config --get credential.helper
git rev-parse --show-toplevel
git status --short
git remote -v
git log -3 --oneline
git ls-files
```

尚未初始化时，`rev-parse`、`status` 等报错是预期结果，先检查目录内容，再 `git init -b main`。已有仓库则保留历史和当前分支，不重新初始化。

检查要公开的文件及现有历史。不要上传凭据、`.env`、私钥或无关文件；不要执行会把 token 打印到输出的命令。检查 SKILL.md 引用的文件是否齐全、README 是否有占位安装地址、许可证是否存在。发布 skill 时保留全部必要 references。

## 2. 在内存中取得凭据并核对账号

以下代码必须在同一个 PowerShell 进程内执行，或与后续 API 操作合并为同一次执行；不要把凭据作为工具返回值传回 AI。

```powershell
$ErrorActionPreference = 'Stop'
$expectedOwner = 'your-account'   # 替换为实际账号；或先调 /user 取 $profile.login 再回填
$repoName = 'your-repository-name'
$apiBase = 'https://api.github.com'

$credentialLines = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
if ($LASTEXITCODE -ne 0) { throw 'GitHub Git credential unavailable' }
$credentialMap = @{}
foreach ($line in $credentialLines) {
    $pair = $line -split '=', 2
    if ($pair.Length -eq 2) { $credentialMap[$pair[0]] = $pair[1] }
}
if (-not $credentialMap['password']) { throw 'GitHub Git credential missing password/token' }
$headers = @{
    Authorization = 'Bearer ' + $credentialMap['password']
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$profile = Invoke-RestMethod -Uri "$apiBase/user" -Headers $headers
if ($profile.login -ne $expectedOwner) { throw 'GitHub account does not match requested owner' }
Write-Output ('GitHub account: ' + $profile.login)
```

`git credential fill` 会向已配置的 helper 查询凭据，也可能触发登录交互。若没有可用凭据或需要交互，停止依赖该凭据的操作，告诉用户需要完成 Git Credential Manager 登录。不要要求用户把 token 发到聊天中，不扫描其他应用的凭据文件。

不要打印 `$credentialLines`、`$credentialMap`、`$headers`，不要写入文件、远端 URL、提交或调试日志。结束 PowerShell 进程即可释放这些进程内变量。

## 3. 查找或创建目标仓库

先 GET，只有明确 404 才创建。401/403 是身份或权限问题，不是仓库不存在；422 可能是同名或参数问题，检查后再处理，不盲目重复创建。

```powershell
$repo = $null
try {
    $repo = Invoke-RestMethod -Uri "$apiBase/repos/$expectedOwner/$repoName" -Headers $headers
} catch {
    if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
}

if ($null -eq $repo) {
    # 仅在用户已要求创建公开仓库时执行此分支。
    $body = @{
        name = $repoName
        description = '替换为当前项目的简短说明'
        private = $false
        auto_init = $false
    } | ConvertTo-Json
    $repo = Invoke-RestMethod -Method Post -Uri "$apiBase/user/repos" `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
}
$repo | Select-Object full_name, html_url, private, default_branch
```

此创建端点针对个人账号，不用于组织仓库。`auto_init=false` 避免远端自动生成 README 后与本地历史冲突。JSON 显式转 UTF-8 字节，避免中文描述编码问题。

如果目标仓库已经存在，检查其归属、内容和可见性再继续。现有私有仓库不要仅因本次新增文件就改为公开；公开它会连带公开既有内容，必须有覆盖该范围的用户授权。

## 4. 准备提交并推送

README 中的安装地址按实际 `owner/repo` 更新，仅修改本次发布所需内容。许可证已有则保留。将允许发布的文件逐项暂存；下面文件列表仅为 skill 示例。

```powershell
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Diff check failed' }
git add -- SKILL.md README.md LICENSE references
if ($LASTEXITCODE -ne 0) { throw 'Staging failed' }
git diff --cached --stat
# 有暂存改动时再提交；新仓库须有首个提交才能推送。
git diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
    git commit -m 'Publish skill and documentation'
    if ($LASTEXITCODE -ne 0) { throw 'Commit failed' }
} elseif ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect staged changes'
}
```

PowerShell 的 `$ErrorActionPreference='Stop'` 不能普遍替代对 Git 退出码的检查。不要在 commit 失败后继续 push。

检查 `origin`。没有则添加；已有且正确则复用；指向其他仓库时先解决目标差异，不能静默覆盖。

```powershell
# 仅在 origin 尚不存在时执行。
git remote add origin "https://github.com/$expectedOwner/$repoName.git"
if ($LASTEXITCODE -ne 0) { throw 'Remote setup failed' }

$branch = git branch --show-current
if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'No current branch; inspect repository state' }
git push -u origin $branch
if ($LASTEXITCODE -ne 0) { throw 'Push failed' }
```

新仓库通常使用 main；已有仓库保留其分支约定。远端已有提交时先 fetch 并检查差异，禁止为绕过拒绝而 force push。后续更新省略创建仓库和添加 remote，只需审查改动、commit、push。

## 5. 验证与交付

用 API 确认实际可见性、分支和文件；将本地 `git rev-parse HEAD` 与 `git ls-remote origin refs/heads/<分支>` 对比，确认推送的是当前提交。公开仓库再用不带 Authorization 的请求验证可访问性。

```powershell
$publicHeaders = @{ Accept = 'application/vnd.github+json' }
$publishedRepo = Invoke-RestMethod -Uri "$apiBase/repos/$expectedOwner/$repoName" -Headers $publicHeaders
if ($publishedRepo.private) { throw 'Repository is not public' }
$tree = Invoke-RestMethod -Uri "$apiBase/repos/$expectedOwner/$repoName/git/trees/${branch}?recursive=1" -Headers $publicHeaders
$tree.tree | Where-Object type -eq 'blob' | Select-Object -ExpandProperty path
git rev-parse HEAD
git ls-remote origin "refs/heads/$branch"
git status --short
```

对于私有仓库使用授权请求，不做匿名公开访问检查。最终给出实际仓库链接、分支、许可证和公开状态；公开仓库提供 `https://github.com/<owner>/<repo>/archive/refs/heads/<branch>.zip`。不要在未验证时声称发布成功。

## 本次已验证实例

- 本地目录：`<一个 Agent Skill 仓库，含 SKILL.md 与 references/>`
- 账号：`ZhiYuQN`；仓库：`ui-readability-skill`；分支：`main`
- 环境：Git 2.49.0.windows.1，credential helper 为 manager，未安装 gh。
- 使用本机凭据调用 `/user`，核对账号后，POST `/user/repos` 创建公开空仓库。
- 沿用本地既有提交和 MIT 许可证，替换 README 安装地址，新增提交，添加 origin 并推送。
- 通过匿名 API 请求确认 public、MIT 和 9 个文件均已发布。

## 官方参考

- Git credential 的 fill 协议：https://git-scm.com/docs/git-credential
- GitHub 创建仓库 API：https://docs.github.com/en/rest/repos/repos#create-a-repository-for-the-authenticated-user

这些接口与本次实际执行对应；其他机器仍需检查依赖、登录账号和权限，不能假定本机凭据随 skill 一起迁移。
