# github-publish-local-git

使用 Windows 本机 Git 登录，将指定文件发布到个人 GitHub 仓库。无需安装 `gh`。

## 依赖

- PowerShell 7+（`pwsh`）与 Git for Windows
- Git credential helper 已保存有效的 GitHub 登录凭据；仅配置 `manager` 不代表已登录
- 已配置 Git 提交作者，凭据具备目标仓库操作权限
- 可访问 `github.com` 和 `api.github.com`

## 安装

```bash
# Claude Code
git clone https://github.com/ZhiYuQN/github-publish-local-git.git ~/.claude/skills/github-publish-local-git

# WorkBuddy
git clone https://github.com/ZhiYuQN/github-publish-local-git.git ~/.workbuddy/skills/github-publish-local-git
```

其他支持 Agent Skills 的宿主将整个目录放入其 skills 目录；安装后新开会话。

## 使用

给 AI 指定本地目录、GitHub 个人账号、仓库名、可见性和需要上传的文件。例如：

> 使用 github-publish-local-git，将 E:/projects/my-skill 发布到我的 GitHub 账号，仓库名 my-skill，设为公开。包含主文件、README、许可证和引用的参考文件。

AI 按 [SKILL.md](SKILL.md) 检查内容后，调用 [Publish-GitHub.ps1](scripts/Publish-GitHub.ps1)。脚本支持 CheckOnly 预检、创建新仓库、更新已有仓库以及 public/private；不改变已有仓库可见性，不处理组织仓库。

## 执行行为

- 显式列出实际文件，不依赖固定的 `references/` 目录。
- 范围外已有暂存文件时停止，保留用户暂存内容。
- 非交互获取凭据并核对账号；临时环境变量在退出时恢复。
- 仓库查询 404 视为“当前凭据不可见”；创建必须显式指定，遇到同名冲突不循环重试。
- 提交后推送当前分支，自动比较远端 SHA，并通过 API 确认提交可访问。
- 公开仓库匿名验证，返回固定到该提交的 ZIP 下载链接。

凭据不输出、不写文件、不拼入 URL。Files 只控制本次暂存，已有提交历史仍会随 Git 推送；发布前须检查历史。失败时保留已完成的本地提交，不自动回滚或 force push。

## 验证

```powershell
pwsh -NoProfile -File ./tests/Test-Publish-GitHub.ps1
```

测试使用临时本地仓库与模拟 API，不访问 GitHub 或真实凭据。详细参数与失败处理见 SKILL.md。

## 许可证

MIT。使用本 skill 发布其他项目时，沿用该项目的许可证。
