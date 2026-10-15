# github-connect.ps1 —— 用一次性 GitHub 令牌完成本机 GitHub 接入
#
# 本机实测（2026-10-14）：
#   api.github.com            ✅ 200        认证走 API，稳定
#   api.githubcopilot.com/mcp ✅ 401→令牌   远端 MCP 端点可用
#   github.com HTTPS          ⚠ 间歇性      实测 8/8 通过、真实克隆成功；
#                                           但本会话早先多次超时，所以保留 SSH 备用
#   github.com:22 / ssh.github.com:443 ✅    SSH 传输可用
#
# 结论：HTTPS 做主路径（gh 做凭据助手，不需要 SSH 密钥即可推送），
#       SSH 作为 HTTPS 抽风时的备用通道。
#
# 用法：
#   1. 在能访问 github.com 的设备建 classic PAT
#      （勾 repo、read:org；admin:public_key 用于自动注册 SSH 备用公钥；workflow 可选），
#      存成一行文本到 %USERPROFILE%\.github_pat
#   2. powershell -ExecutionPolicy Bypass -File D:\develop\github-connect.ps1
#   3. 重启 DSH（GITHUB_PAT 是环境变量，运行中的进程读不到）
#
# 令牌只从文件读入、只经 stdin 交给 gh，不回显、不写进任何配置文件。

[CmdletBinding()]
param(
    [string]$TokenFile = "$env:USERPROFILE\.github_pat",
    [switch]$SkipSshKey
)

# 注意：必须是 Continue。gh 把「成功」消息也写到 stderr，而 PS 5.1 在 Stop 下
# 会把原生命令的 stderr 当成终止性错误抛出——上轮就在第 5 步被自己的成功提示打断。
# 所有失败路径都改用显式 if ($LASTEXITCODE -ne 0) { throw } 判定。
$ErrorActionPreference = 'Continue'

$gh = 'C:\Program Files\GitHub CLI\gh.exe'
if (-not (Test-Path $gh)) { $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source }
if (-not $gh) { throw 'gh 未安装，先执行：winget install --id GitHub.cli -e' }
if (-not (Test-Path $TokenFile)) { throw "找不到令牌文件：$TokenFile" }

# 1) 用令牌登录 gh（api.github.com 可达，不需要浏览器）
Write-Host '[1/6] gh auth login --with-token ...'
Get-Content $TokenFile -Raw | & $gh auth login --with-token --hostname github.com
if ($LASTEXITCODE -ne 0) { throw 'gh 登录失败：令牌无效或已过期' }
& $gh auth status --hostname github.com

# 2) 让 git 的 HTTPS 走 gh 的令牌，clone/push 免密
Write-Host '[2/6] gh auth setup-git ...'
& $gh auth setup-git --hostname github.com
Write-Host "      credential.helper = $((& git config --global --get-regexp 'credential.*github' | Out-String).Trim())"

# 3) 同一令牌同步给 DSH 的 MCP 配置：GITHUB_PAT 用户环境变量
Write-Host '[3/6] 写入 GITHUB_PAT 用户环境变量 ...'
$tok = (& $gh auth token --hostname github.com).Trim()
[Environment]::SetEnvironmentVariable('GITHUB_PAT', $tok, 'User')
Write-Host "      GITHUB_PAT 已写入（长度 $($tok.Length)）"

# 4) MCP 端点自检：拿真令牌打一次 initialize，确认线路 B 真的能用
Write-Host '[4/6] 远端 MCP 端点自检 ...'
$probePath = Join-Path $env:TEMP 'dsh-mcp-probe.json'
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dsh","version":"0"}}}' |
    Out-File -FilePath $probePath -Encoding ascii -NoNewline
$resp = & curl.exe -sS -i --max-time 30 -X POST 'https://api.githubcopilot.com/mcp/' `
    -H 'Content-Type: application/json' `
    -H 'Accept: application/json, text/event-stream' `
    -H "Authorization: Bearer $tok" `
    --data-binary "@$probePath" 2>&1
Remove-Item $probePath -ErrorAction SilentlyContinue
$statusLine = ($resp | Select-Object -First 1)
if ($statusLine -match 'HTTP/\S+\s+2\d\d') {
    Write-Host "      MCP 端点接受令牌 OK  ($statusLine)"
} else {
    Write-Warning "      MCP 端点未接受令牌（$statusLine）"
    $resp | Select-Object -First 6 | ForEach-Object { Write-Host "        $_" }
}

# 5) 注册 SSH 备用公钥
if (-not $SkipSshKey) {
    Write-Host '[5/6] 注册 SSH 备用公钥 ...'
    $pub = "$env:USERPROFILE\.ssh\id_ed25519.pub"
    $title = "dsh-$env:COMPUTERNAME"
    if (Test-Path $pub) {
        # 先查是否已注册，避免重复执行时报 "key is already in use"
        $listed = (& $gh ssh-key list 2>$null | Out-String)
        if ($listed -match [regex]::Escape($title)) {
            Write-Host "      公钥 '$title' 已在 GitHub 上，跳过"
        } else {
            & $gh ssh-key add $pub --title $title 2>&1 | ForEach-Object { Write-Host "      $_" }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning '      自动注册失败（多半是令牌缺 admin:public_key）'
                Write-Host '      手动注册：把下面这行贴到 https://github.com/settings/keys'
                Write-Host "      $((Get-Content $pub -Raw).Trim())"
            }
        }
    } else {
        Write-Host "      未找到 $pub，跳过"
    }
} else {
    Write-Host '[5/6] 已跳过 SSH 公钥注册'
}

# 6) 自检
Write-Host '[6/6] 自检 ...'
$login = & $gh api user --jq '.login' 2>$null
if ($login) { Write-Host "      已登录账号：$login" }

& git ls-remote https://github.com/octocat/Hello-World HEAD *> $null
if ($LASTEXITCODE -eq 0) { Write-Host '      git over HTTPS：OK' } else { Write-Host '      git over HTTPS：暂不可用' }

& git ls-remote git@github.com:octocat/Hello-World HEAD *> $null
if ($LASTEXITCODE -eq 0) { Write-Host '      git over SSH：OK' } else { Write-Host '      git over SSH：不可用（公钥未注册）' }

Write-Host ''
Write-Host '完成。重启 DSH 后，GitHub 工具会以 mcp__github__* 出现在工具列表里。'
Write-Host "令牌文件仍留在 $TokenFile，确认无误后请自行删除。"
Write-Host ''
Write-Host '附：若 HTTPS 以后变抽风，可临时切 SSH：'
Write-Host '    git config --global url."git@github.com:".insteadOf "https://github.com/"'
Write-Host '  撤销：'
Write-Host '    git config --global --unset url."git@github.com:".insteadOf'
