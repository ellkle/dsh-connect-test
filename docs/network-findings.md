# 网络实测数据

测量日期：2026-10-14
测量环境：Windows，无代理（已确认 `127.0.0.1:7897` 未监听、系统代理关闭、无 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量）
测量方法：`curl.exe` + `git ls-remote` + `Test-NetConnection`

## 结论

**GitHub 的不同子域在本机表现完全不同。** 关键区分：

| 主机 | 用途 | 表现 |
|---|---|---|
| `api.github.com` | gh 命令行、REST API、MCP 认证 | ✅ 一直稳定（200） |
| `api.githubcopilot.com` | 远端 GitHub MCP 端点 | ✅ 一直稳定（无令牌 401，有令牌 200） |
| `github.com:443` | HTTPS 方式 clone / push | ⚠️ **间歇性**失败 |
| `github.com:22` | SSH 方式 clone / push | ✅ 一直稳定 |
| `ssh.github.com:443` | SSH 备用端口 | ✅ 可达 |
| `codeload.github.com` | 打包下载 | ✅ 可达 |
| `raw.githubusercontent.com` | 原始文件 | ✅ 可达 |
| `objects.githubusercontent.com` | Release 资源 | ✅ 可达 |

## 关于 `github.com:443` 的间歇性

同一个会话内观察到**三种不同状态**，说明它不是「封死」而是「看运气」：

| 时间点 | 表现 |
|---|---|
| 会话前段 | 连续超时：`Failed to connect to github.com:443 after 21086 ms` |
| 会话中段 | **8/8 全部通过**，稳定在 ~1.0s；真实 `git clone` 成功 |
| 会话后段 | 又开始失败：`Recv failure: Connection was reset` |

同一时段 `git ls-remote` 走 SSH 则是 **100% 成功**。

### 排除掉的因素

怀疑过是代理救场，逐一验证后排除：

```
127.0.0.1:7897                 → 未监听
系统代理 ProxyEnable           → 0（关闭）
HTTP_PROXY / HTTPS_PROXY       → 空
```

### IP 与 DNS 排查

`github.com` 解析到 `20.205.243.166`（亚洲节点）。用 `--resolve` 固定到多个 GitHub IP 测试：

```
140.82.116.3   → 200
140.82.121.3   → 200
20.205.243.166 → 200（即使它就是 DNS 给出的那个 IP）
20.27.177.113  → 200
```

**和 DNS 解析结果无关**——固定到同一个 IP 用 `--resolve` 能通，不固定时却超时。`github.com` 没有可用的 AAAA 记录（IPv6 不通，但这也不是主因）。所以是链路层面的间歇性干扰，不是解析或单点 IP 问题。

## 对方案的影响

1. **git 传输用 SSH**，不要依赖 HTTPS。这是本机唯一 100% 稳定的 git 通道
2. **认证走 API**，与 git 传输解耦——`gh auth login --with-token` 只碰 `api.github.com`，所以即使 `github.com:443` 全挂，认证依然能做
3. **MCP 端点不受影响**——它是独立域名，和 `github.com` 的抽风无关
4. GitHub Actions 跑在 GitHub 自己的机器上，**完全不受本机网络影响**

## 复现命令

```powershell
# 各端点连通性
curl.exe -sS -o NUL -w '%{http_code}' --max-time 15 https://api.github.com
curl.exe -sS -o NUL -w '%{http_code}' --max-time 15 https://api.githubcopilot.com/mcp/
curl.exe -sS -o NUL -w '%{http_code}' --max-time 15 https://github.com

# 固定 IP 测试（绕过 DNS）
curl.exe -sS -o NUL -w '%{http_code}' --max-time 10 --resolve github.com:443:140.82.121.3 https://github.com

# 两条 git 通道对比
git ls-remote https://github.com/octocat/Hello-World HEAD
git ls-remote git@github.com:octocat/Hello-World HEAD
```
