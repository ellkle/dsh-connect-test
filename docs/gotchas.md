# 踩坑清单

接入过程中真实踩到的坑，按「谁踩的」分组。每条都附现象和修法——下次直接照抄。

## PowerShell 5.1

### 1. 原生命令的 stderr 会被当成终止性错误

**现象**：脚本跑到一半突然退出，报 `NativeCommandError`，但被指向的那条命令其实**成功了**。

```
gh.exe : ✓ Public key added to your account
    + CategoryInfo : NotSpecified: (✓ Public key ... ) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
At github-connect.ps1:76 char:9
```

**原因**：`gh` 把成功消息也写到 stderr。而在 `$ErrorActionPreference='Stop'` 下，PS 5.1 会把原生命令的 stderr 输出提升为终止性错误——**脚本被自己的成功提示打断**。

**修法**：用 `$ErrorActionPreference = 'Continue'`，失败判定改成显式检查：

```powershell
& $gh ssh-key add $pub --title $title 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw '注册失败' }
```

`throw` 不受 `ErrorActionPreference` 影响，仍然会终止脚本，所以安全性不打折。

### 2. 无 BOM 的 UTF-8 脚本会被乱码读坏

**现象**：脚本明明语法正确，运行却报：

```
Unexpected token '鍐欏叆' in expression or statement.
```

**原因**：PS 5.1 读取 `.ps1` 时，**如果没有 UTF-8 BOM，就按系统 ANSI（中文系统是 GBK）解码**。UTF-8 的中文注释被当成 GBK 后会解出乱七八糟的字节，其中可能包含引号之类的字符，直接把语法结构撑爆。

**修法**：给脚本加 UTF-8 BOM。

```powershell
$txt = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($p, $txt, (New-Object System.Text.UTF8Encoding($true)))
# 校验：前 3 字节应为 239,187,191
([System.IO.File]::ReadAllBytes($p))[0..2] -join ','
```

> 注意 PS 5.1 的 `Set-Content -Encoding UTF8` **会**写 BOM，而 `[IO.File]::WriteAllText` 配 `UTF8Encoding($false)` 不写——两者行为不一致，容易踩。

### 3. 某些编辑器 / 工具重写文件会**丢掉** BOM

**现象**：脚本本来跑得好好的，用编辑器改几行中文注释后再跑就报 `Unexpected token`。

**原因**：很多工具默认按「UTF-8 无 BOM」保存，把原来的 BOM 吃掉了。

**修法**：每次改完 `.ps1` 都重新加一遍 BOM，并跑一次解析校验：

```powershell
$errs = $null
[System.Management.Automation.PSParser]::Tokenize((Get-Content $p -Raw), [ref]$errs) | Out-Null
"parse errors: " + ($errs | Measure-Object).Count
```

## PowerShell 通用

### 4. 变量名大小写不敏感

`$T` 和 `$t` 是**同一个变量**。用 `$T` 存临时目录、又用 `$t` 当循环变量，循环一跑 `$T` 就被覆盖了：

```
Remove-Item : 无法检索 cmdlet 的动态参数。指定的通配符模式无效:
@{annotations=; description=...; name=update_pull_request_branch; ...}
```

**修法**：命名别只用大小写区分，比如 `$tempDir` / `$tool`。

### 5. `Set-Location` 失败不会中断脚本

**现象**：`git clone` 失败 → `Set-Location $dir` 失败 → 但脚本继续往下跑，后面的 `Set-Content README.md` 就**写进了当前目录**（不是你以为的那个目录）。

**修法**：`cd` 之后立刻验证，或者干脆全程用绝对路径：

```powershell
if (-not (Test-Path $dir)) { Write-Error "目录不存在，中止"; exit 1 }
Set-Location $dir
# 更稳：所有路径都用 Join-Path $dir 'xxx'
```

### 6. 传给原生命令的参数被按空格拆开

**现象**：`--jq` 传入含空格 / 管道的表达式时：

```
gh.exe : accepts 1 arg(s), received 7
```

命令行被拆成了 7 个参数。

**修法**：别跟引号搏斗，改用 PowerShell 自己解析 JSON：

```powershell
$obj = (& $gh api repos/owner/repo/commits 2>&1 | Out-String) | ConvertFrom-Json
$obj[0].sha
```

## gh / GitHub

### 7. `--with-token` 要用 classic token

`gh auth login --help` 原文：

> Alternatively, use `--with-token` to pass in a personal access token **(classic)** on standard input.
> The minimum required scopes for the token are: `repo`, `read:org`, and `gist`.
> Take care when passing a **fine-grained** personal access token to `--with-token` as the inherent scoping to certain resources may cause confusing behaviour... Favour setting `GH_TOKEN` for fine-grained personal access token usage.

所以：走 `--with-token` 就用 classic；非要用 fine-grained，得改走 `GH_TOKEN` 环境变量。

`admin:public_key` 只有调用 `gh ssh-key add` 才需要——公钥注册完之后就可以从令牌里去掉。

### 8. clone 空仓库会警告

```
warning: You appear to have cloned an empty repository.
```

正常现象，不是错误。

### 9. 推空仓库时的默认分支名取决于本地分支

GitHub 的默认分支是 `main`，但 `git init` 的默认可能是 `master`。往空仓库首次 push 时，**推上去的那个分支就成了默认分支**。

**修法**：显式建 main。

```powershell
git checkout -b main    # 空仓库里也有效（HEAD 未出生状态）
```

### 10. Windows 上 `core.autocrlf`

```
warning: in the working copy of 'README.md', LF will be replaced by CRLF
```

只是警告。想让仓库里保持 LF，加 `.gitattributes`：

```
* text=auto eol=lf
```

## DSH 配置

### 11. `!!js` 是怎么求值的

DSH 的配置方言里，`!!js` 标量会被这样求值：

```js
const evaluate = new Function("ctx", "expr", ` with (ctx) { return eval(expr) } `);
```

`eval` 跑在 Node 全局作用域，`process` 是 Node 全局对象，所以在 `with (ctx)` 里依然能取到。于是这个写法可行：

```yaml
headers:
  Authorization: !!js '`Bearer ${process.env.GITHUB_PAT}`'
```

### 12. MCP 配置项加载失败不会拖垮 DSH

给 `dsh-mcp-client` 的配置项设 `failOnStartupError: false`，那么令牌缺失或端点连不上时，harness 照常启动，只是不注册那批工具。配置期间不太可能把自己锁在门外。

### 13. 环境变量要重启进程才生效

写进注册表的用户级环境变量，**已经运行的进程读不到**。`GITHUB_PAT` 写完之后必须重启 DSH，配置里的 `${process.env.GITHUB_PAT}` 才有值。
