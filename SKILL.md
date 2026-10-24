---
name: github-publish-local-git
description: 使用 Windows 本机 Git 凭据、GitHub REST API 和 git push，将用户指定的本地文件发布或更新到其个人 GitHub 仓库；适用于 gh 不可用但本机已有 GitHub 登录凭据的环境。
---

# 使用本机 Git 登录发布到 GitHub

使用 [scripts/Publish-GitHub.ps1](scripts/Publish-GitHub.ps1) 执行发布。API 负责核对身份和创建仓库，Git 负责提交和推送，脚本自动核对远端 SHA。凭据和共享变量留在同一次执行中，不要把脚本拆成多次 shell 调用。

## 依赖与范围

- PowerShell **7+**（`pwsh`）、Git for Windows，可访问 `api.github.com` 和 `github.com`。
- Git credential helper 中已保存 GitHub 凭据。`git config --get credential.helper` 返回 `manager` 只说明配置存在，不能证明已登录或权限充足。
- Git 作者已配置：`git config user.name`、`git config user.email`。缺失时使用用户指定身份；不猜测邮箱、不修改全局身份。
- 用户指定本地目录、目标个人账号、仓库名、public/private 和发布范围。支持新建个人仓库、更新已有仓库；不处理组织仓库或改动已有仓库的可见性。
- 若平台连接器已具备完整发布能力，优先使用；缺少创建仓库能力时可采用本路径。连接器与本机 Git 登录独立，不能互相推定身份。

## 发布前

1. 读取项目适用指令，确认 `LocalPath` 是预期仓库根目录，检查 `git status --short`、`git remote -v` 和提交历史。
2. 检查发布文件及将被推送的历史，不包含凭据、私钥、`.env` 或无关内容。**Files 限制本次暂存范围，不会过滤既有提交历史。**
3. 生成实际存在的相对文件列表。`Files` 接受逐个文件，不接受目录或通配符；需要 references 时逐个列出，不存在的可选目录直接省略。已跟踪文件的删除也可显式列入。
4. 检查 README 安装地址、skill 引用和许可证。保留已有许可证；公开访问不等于获得再分发授权，不擅自补选许可证。
5. 检查已有暂存内容。范围外文件会使脚本在联网和提交前停止；保留用户暂存区，先解决范围差异。不能通过清空暂存区绕过检查。

## 调用

在 PowerShell 7 中执行，替换脚本绝对路径及项目参数。下面是无 references 目录的 skill 文件列表示例；按当前项目调整。

```powershell
$publish = @{
    LocalPath = 'E:/path/to/project'
    Owner = 'your-account'
    Repository = 'your-repository'
    Visibility = 'public'
    Files = @('SKILL.md', 'README.md', 'LICENSE')
    CommitMessage = 'Publish skill updates'
}
& 'E:/path/to/github-publish-local-git/scripts/Publish-GitHub.ps1' @publish -CheckOnly
```

`CheckOnly` 检查文件、暂存区、身份、origin 和可见性；不初始化仓库、不提交、不创建远端仓库。404 表示仓库对当前凭据不可见，不证明它不存在。

用户已授权发布后执行同一组参数，无须重复询问已有授权：

```powershell
# 更新已有仓库。
& 'E:/path/to/github-publish-local-git/scripts/Publish-GitHub.ps1' @publish

# 仅在本次任务包含新建仓库时使用；Description 按项目填写。
& 'E:/path/to/github-publish-local-git/scripts/Publish-GitHub.ps1' @publish -CreateIfMissing -Description 'Project description'
```

脚本复用正确的 HTTPS origin；没有 origin 时添加；URL 不匹配或已有仓库可见性不同则停止。新目录初始化 main，已有仓库沿用当前分支；若要求更新默认分支，先确认当前分支与远端默认分支一致。

脚本只在有暂存改动时提交，提交前检查 staged diff；推送后自动比较本地 HEAD 与远端分支 SHA，并通过 API 确认提交可访问。公开仓库的最终 API 验证不带登录凭据。输出仓库、实际分支、提交 SHA 和固定到该提交的 ZIP 链接。

## 失败处理

| 情况 | 处理 |
|---|---|
| 缺少文件、文件列表含目录、范围外已有暂存文件 | 在本地修正范围，保留用户已有修改；此时尚未创建远端仓库 |
| 没有非交互凭据或账号不匹配 | 完成/选择 Git Credential Manager 登录后重试；不要索取聊天中的 token |
| API 401/403 | 检查凭据有效性与权限；能 push 不保证能创建仓库 |
| GET 404 | 检查是否为无权访问的私有仓库；只有用户授权创建时才传 CreateIfMissing |
| 创建返回 422 | 检查同名仓库、访问权限或参数，不循环创建 |
| 已有 origin 指向其他地址、SSH 地址或另有 push URL | 明确处理远端配置；不静默覆盖 |
| 推送被拒、远端已有提交 | fetch 后检查差异，按任务解决；不 force push、不自动合并不明历史 |
| API 超时/网络失败 | 先解决具体网络问题；API 30 秒超时，Git 网络命令仍由调用工具管理超时并等待其结束 |
| 推送后验证失败 | 不报告成功；核对远端状态，不盲目重复创建或提交 |

脚本会临时设置 `GCM_INTERACTIVE=0` 和 `GIT_TERMINAL_PROMPT=0`，退出时恢复，避免无人值守时卡在登录窗口。凭据只在进程内存中使用，不回显、不写文件、不拼入远端 URL。不要启用会记录凭据的调试跟踪。

失败不会自动回滚：提交成功但推送失败时，本地提交仍保留，可能也已创建空远端。检查 `git status`、`git log` 和远端后重试；同样内容不会产生重复提交。不要为回滚执行 reset 或删除用户数据。

## 验证与交付

只有脚本正常结束且 SHA 一致才能报告发布成功。告知实际仓库链接、可见性、分支和提交；公开仓库提供脚本输出的 ZIP 链接。该流程按次执行，不是后台自动同步。

运行本仓库的离线回归测试：

```powershell
& 'E:/path/to/github-publish-local-git/tests/Test-Publish-GitHub.ps1'
```

测试使用临时本地 Git 仓库和模拟 API，不读取真实凭据、不写 GitHub。实际发布仍需检查本机登录与权限。

## 官方参考

- [Git credential 协议](https://git-scm.com/docs/git-credential)
- [GitHub 创建仓库 API](https://docs.github.com/en/rest/repos/repos#create-a-repository-for-the-authenticated-user)
- [GitHub 404 与权限诊断](https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api#404-not-found-for-an-existing-resource)
- [GCM 非交互设置](https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/environment.md#gcm_interactive)
