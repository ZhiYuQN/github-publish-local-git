# github-publish-local-git

> 用 Windows 已有的 Git 凭据把本地目录发布到 GitHub，不装 `gh`，不碰浏览器自动化。

一个 Agent Skill。适用于 `gh` 不可用、但 Git Credential Manager 里已经存有 GitHub 登录凭据的环境。

---

## 它解决什么

常见的发布路径有两条断点：

- **`gh` 未安装**，或者装了但需要重新走一次交互式登录；
- **`git push` 能过，但创建仓库需要另一套权限** —— 能推不等于能建。

这个 skill 把两件事拆开，各用最合适的通道：

| 步骤 | 通道 |
|---|---|
| 核对身份、创建仓库、验证结果 | GitHub REST API（`api.github.com`） |
| 上传提交 | 原生 `git push` |

凭据从 `git credential fill` 取，全程留在进程内存里。

---

## 流程

1. **检查发布范围** —— 确认目录是仓库根，读取 `git status` / `git remote` / `git log`，排除凭据、`.env`、私钥。
2. **取凭据并核对账号** —— `git credential fill` 读 `manager` 中的登录信息，调 `/user` 校验账号匹配，不匹配即中止。
3. **查找或创建仓库** —— 先 GET；只有明确 404 才 POST `/user/repos`，`auto_init=false` 避免与本地历史冲突。
4. **提交并推送** —— 逐项 `git add`，检查 `git diff --cached`，`git push -u origin <branch>`。禁止 force push。
5. **验证交付** —— 匿名请求确认 public 状态与文件树，比对本地 `HEAD` 与远端 ref。

细节、代码与退出码处理见 `SKILL.md`。

---

## 前置条件

- Windows + PowerShell + Git for Windows
- Git credential helper 已保存 GitHub 凭据（`git config --get credential.helper` 返回 `manager` 即符合）
- `git config user.name` / `user.email` 已配置
- 能访问 `api.github.com` 与 `github.com`

---

## 安装

```bash
git clone https://github.com/YOUR-NAME/github-publish-local-git.git ~/.claude/skills/github-publish-local-git
```

WorkBuddy 用户把目标路径换成 `~/.workbuddy/skills/`。其他支持 Agent Skills 规范（`SKILL.md` + YAML frontmatter）的宿主，整个目录放进去即可。

---

## 安全设计

这几条不是建议，是硬约束：

- **凭据不回显** —— 不打印 `$credentialLines`、`$headers`，不写入文件、远端 URL、提交信息或日志。
- **凭据不落盘** —— 只存在于 PowerShell 进程内存，进程结束即释放。绝不把 token 拼进 remote URL（中断后会长期留在 `.git/config`）。
- **不索取聊天中的 token** —— 凭据缺失时要求用户完成 Git Credential Manager 登录，而不是让用户把 PAT 贴进对话框。
- **不静默覆盖** —— 目标仓库已存在时先检查归属与可见性；私有仓库不因本次新增文件就改为公开。
- **不 force push** —— 远端有提交时先 fetch 再判断。

---

## 一个真实结果

某个 Agent Skill 仓库（9 个文件，含 `references/` 子目录）用此流程发布：核对账号 → 建公开空仓库 → 沿用本地既有提交 → 添加 origin → 推送。随后用**匿名** API 请求确认 public 状态、MIT 许可证与 9 个文件全部就位。

安装地址占位符（`YOUR-NAME`）在发布时被替换为实际账号，这是流程的一部分。

---

## 许可证

MIT。注意：公开访问不等于获得再分发授权，沿用目标项目自身的许可证。
