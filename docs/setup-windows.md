# Windows 上从零接入 GitHub

目标：让 DSH 既能用 `gh` 命令行操作 GitHub，也能通过远端 MCP 服务器把 GitHub 能力注册成原生工具。

耗时约 5 分钟（不含创建令牌）。

---

## 前置检查

```powershell
git --version          # 需要 git
node --version         # npx 用（可选）
```

## 第一步：装 GitHub CLI

```powershell
winget install --id GitHub.cli -e --accept-package-agreements --accept-source-agreements
```

装到 `C:\Program Files\GitHub CLI\gh.exe`，并会写进机器级 PATH。

> ⚠️ 已经运行的终端 / 应用**不会**自动获得新 PATH——它们的 PATH 是启动时的快照。新开的终端才认 `gh`。

## 第二步：建 classic PAT

在能访问 `github.com` 的设备上打开 <https://github.com/settings/tokens>，新建 **classic** token（不要选 fine-grained，原因见 [gotchas #7](gotchas.md)）。

| scope | 必要性 |
|---|---|
| `repo` | **必需**，gh 明确要求 |
| `read:org` | **必需**，gh 明确要求 |
| `gist` | **必需**，gh 明确要求 |
| `admin:public_key` | 可选，仅用于自动注册 SSH 公钥 |
| `workflow` | 可选，仅当需要改动 `.github/workflows/` 下文件 |

**一定要设过期时间**（建议 90 天）。

把令牌存成一行文本：

```powershell
Set-Content "$env:USERPROFILE\.github_pat" 'ghp_你的令牌' -NoNewline -Encoding ascii
```

> 注意：要**在 PowerShell 里执行这条命令**，不是把这条命令本身存进文件。

## 第三步：生成 SSH 密钥

本机 HTTPS 通道间歇性不可用（见 [network-findings](network-findings.md)），所以 git 传输走 SSH。

```powershell
ssh-keygen -t ed25519 -C "dsh-github-$env:COMPUTERNAME" -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""'
```

先确认链接通：

```powershell
ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@github.com
# 预期：Permission denied (publickey)  ← 这表示链路通，只是还没注册密钥
```

## 第四步：跑接线脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\github-connect.ps1
```

脚本做六件事：

| 步骤 | 动作 | 走哪条通道 |
|---|---|---|
| 1 | `gh auth login --with-token` | api.github.com |
| 2 | `gh auth setup-git`（让 HTTPS 也免密） | 本地配置 |
| 3 | 把令牌写进 `GITHUB_PAT` 用户环境变量 | 注册表 |
| 4 | 拿真令牌打一次 MCP `initialize` 自检 | api.githubcopilot.com |
| 5 | `gh ssh-key add` 注册 SSH 公钥（幂等，已存在则跳过） | api.github.com |
| 6 | 自检：账号 / HTTPS / SSH | 全部 |

令牌只从文件读、只经 stdin 交给 `gh`，**不回显、不写进任何配置文件**。

## 第五步：配 MCP（可选）

把 [`mcp-config.yml`](mcp-config.yml) 里的条目加进你的 profile 补丁层：

```
%USERPROFILE%\.dsh\profiles\<profile>\cordis.patch.yml
```

然后**重启 DSH**。GitHub 工具会以 `mcp__github__*` 的形式出现，例如 `mcp__github__create_pull_request`。

## 第六步：验证

```powershell
gh auth status
gh api user --jq .login
git ls-remote git@github.com:octocat/Hello-World HEAD
```

三行都成功就通了。

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `error validating token: HTTP 401: Bad credentials` | 令牌无效或已撤销 | 重建成 |
| `Failed to connect to github.com:443` | HTTPS 通道抽风 | 改用 SSH：`git@github.com:owner/repo.git` |
| `Permission denied (publickey)` | 公钥没注册 | `gh ssh-key add ~/.ssh/id_ed25519.pub` |
| `Unexpected token` 跑脚本时 | `.ps1` 丢了 UTF-8 BOM | 见 [gotchas #2](gotchas.md) |
| MCP 工具不出现 | 没重启 DSH，或 `GITHUB_PAT` 没生效 | 重启；`[Environment]::GetEnvironmentVariable('GITHUB_PAT','User')` 确认 |

## 收尾：删掉令牌中转文件

```powershell
Remove-Item "$env:USERPROFILE\.github_pat"
```

令牌此时已存在于 gh 的凭据管理器与 `GITHUB_PAT` 环境变量中，文件是多余副本。
