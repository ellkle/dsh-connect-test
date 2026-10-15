# dsh-connect-test

DSH（DeepSeek Harness）接入 GitHub 的**验证仓库 + 经验沉淀**。

创建于 2026-10-14。这个仓库同时干两件事：证明链路真的可用，以及把接入过程中试错出来的东西记下来——那些东西基本查不到，重来一遍还得再踩一次。

## 内容

| 路径 | 说明 |
|---|---|
| `github-connect.ps1` | 一键接线脚本：登录 gh、配置 git 凭据助手、写入 `GITHUB_PAT`、MCP 端点自检、注册 SSH 公钥 |
| `docs/setup-windows.md` | Windows 上从零接入的完整步骤 |
| `docs/network-findings.md` | 网络实测数据：哪些域名稳定、哪些间歇性抽风 |
| `docs/gotchas.md` | 踩过的坑清单（PowerShell 5.1、UTF-8 BOM、参数拆分……） |
| `docs/mcp-config.yml` | DSH 的 `mcp-github` 配置片段 |
| `.github/workflows/ci.yml` | CI：BOM 检查 + PowerShell 语法检查 + 文档完整性 + 凭据泄漏扫描 |

## 结论速览

- **认证**走 `api.github.com`（稳定）；**git 传输**走 SSH（`github.com:22`，稳定）
- `github.com:443` 在本机**间歇性** reset，不要依赖它做 clone / push
- 远端 GitHub MCP 端点 `https://api.githubcopilot.com/mcp/` 可用，`initialize` + `tools/list` 实测返回 **46 个工具**
- `gh` 命令行与 MCP 服务器**互不依赖**，任一条路通就能干活

## 快速开始

```powershell
# 1. 建 classic PAT（scope 至少：repo / read:org / gist）
#    存成一行文本到 %USERPROFILE%\.github_pat
# 2. 跑接线脚本
powershell -ExecutionPolicy Bypass -File .\github-connect.ps1
# 3. 重启 DSH —— GITHUB_PAT 是环境变量，运行中的进程读不到
```

脚本跑完会自己打印四项自检：登录账号、MCP 端点是否接受令牌、git over HTTPS、git over SSH。

## 已验证的链路

| 能力 | 通道 | 状态 |
|---|---|---|
| `gh` 命令行（repo / pr / issue / release / search / api） | api.github.com | ✅ |
| git clone / commit / push | SSH (`git@github.com`) | ✅ |
| git clone / push | HTTPS (`github.com:443`) | ⚠️ 间歇性失败 |
| 远端 GitHub MCP（46 个工具） | api.githubcopilot.com | ✅ |
| GitHub Actions | GitHub 侧运行 | 见 Actions 页签 |

## 安全

**这个仓库不应包含任何凭据。** `.gitignore` 已挡掉常见令牌文件名与 `.env` 之类，CI 里也有一道泄漏扫描。

接线脚本从文件读取令牌、经 stdin 交给 `gh`，**不回显、不写入任何配置文件**；MCP 配置里只放 `${process.env.GITHUB_PAT}` 引用。

提交前请自查：

```powershell
git diff --cached | Select-String 'ghp_|github_pat_|sk-|AKIA'
```

---

由 DeepSeek Harness 创建。
