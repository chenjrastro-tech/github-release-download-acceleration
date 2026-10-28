---
name: github-release-download-acceleration
description: 从 GitHub Releases 下载几十到几百 MB 的大资产时，先只读自检宿主环境（已在监听的本地代理端口、系统代理/环境变量、本机 Clash Verge 内核与配置、curl 是否可用），并行实测「现有代理 / 无头拉起内核 / 公共镜像 / 直连」各路线 KB/s，在胜出路线上做并发阶梯，再用 curl 多段 range 并发下载并以 release digest 校验字节数与 SHA256，全程不要求预装 aria2/7z、不改系统代理、不向用户索要参数；用户给的资产文件名可能记错时，先按 release API 校验资产名，对不上就报 ASSET_NOT_FOUND 并列出真实候选，绝不静默换成近似文件名继续下载。当用户说 GitHub 下载太慢、镜像不通、没装 Clash Verge、想让它自己挑下载方式、想多线程下大安装包、文件名可能记错、或只想「无脑下下来」时使用。
whenToUse: 用户要把 GitHub Release 里的大文件（几十 MB 以上）下到本机且抱怨慢、镜像超时、网络受限；或用户机器上可能装了 Clash Verge 但不确定内核在不在跑；或用户明确说「别问我，自己看着办」「我电脑上什么都没装」这类无前置条件的下载请求；或用户给的 release 资产文件名可能记错（此时先校验资产名，对不上就报 ASSET_NOT_FOUND，不猜文件名）。
metadata:
  min_size_for_ladder_mb: "100"
  single_conn_fast_kbps: "3072"
---

# GitHub Release 大资产下载加速（自检环境 → 并行选路 → 并发阶梯 → digest 校验）

目标：用户只说一句「帮我下这个 / 太慢了」，技能自己探清机器家底、实测选出最快路线、分段并发下载，最后用 release digest 闭环校验。**前置条件为零**：不假设装了 Clash Verge，不假设有 aria2/7z，不假设系统代理可用，也不需要用户报端口、路径或仓库名。

围栏内代码都在 Windows PowerShell 5.1 上用夹具实跑过（2026-10：fzf 1.86MB 小资产、写错的资产名、obs-studio 223MB 大资产），不是伪代码；照抄前确认宿主是 5.1。**围栏内禁用 `Format-Table`/`Format-List`**：抽块按顺序连跑时上一条 `format-*` 会污染下一条输出（实测报 `out-lineoutput` 顺序错误），统一用 `'{0,-28} ...' -f` 显式拼串。

## 环境自适应决策表（先读这张表再动手）

| 自检发现 | 走哪条路线 |
| --- | --- |
| 环境变量 / 系统代理（`ProxyEnable=1`）/ 常见端口任一在监听 | A：现有代理，直接实测，能用就用，别再起第二个内核 |
| 无监听端口，但找到 `verge-mihomo.exe` 且配置目录里有 `clash-verge.yaml` | B：无头拉起内核，只监听 `127.0.0.1:7897` |
| 没装 Clash Verge，或配置目录/`clash-verge.yaml` 缺失、里面没有可用节点 | 跳过 B，走 C（镜像实测）+ D（直连多段） |
| 镜像全灭或 <100 KB/s | D：直连多段，直连把并发拉到 8–16（32 段实测无收益） |
| 所有路线都 <100 KB/s 但仍有字节 | 取最高的一条照下，先报预计耗时再后台跑，别静默卡住，也别声明「无解」 |
| 资产 <100 MB（默认门槛，见 frontmatter 的 `metadata.min_size_for_ladder_mb`） | 不测并发，单流 `curl -L` 一次拿完：阶梯要 20–26s + 上百 MB 采样，小包纯亏 |
| 资产 ≥100 MB，但第 4/5 步的单连接探针 ≥3 MB/s（`metadata.single_conn_fast_kbps`） | 同样单流——单连接没被限速，多开线程只是把同一条管子切碎（实测 16 段 0.72×） |
| 资产 ≥100 MB，且单连接 <3 MB/s 或探不到速度 | 跑 1/16 两档阶梯，多段必须快 1.25 倍才分段；想强制测就置 `$ForceLadder = $true` |

### 错误路径（这些状态必须原样报出来，不许自己猜着继续）

| 判定 | 必须的动作 |
| --- | --- |
| release tag 不存在（API 404 / `message: Not Found`） | 报 `RELEASE_NOT_FOUND` 并停，先确认 tag，别回头猜资产名 |
| API 200 但用户给的 asset 名不在列表里 | 报 `ASSET_NOT_FOUND`，列出该 release 全部候选（名字 + MB）与最接近的一条，**停在这里**，等用户给确认后的链接 |
| API 403 限流（`API rate limit exceeded`） | 报 `API_RATE_LIMITED` 但**不停**：用已知 total/digest 继续，缺 total 用 `Content-Range` 反推，digest 缺失就只做字节数校验 |
| 资产存在但所有路线 0 字节 / 非 2xx | 报 `NO_ROUTE`，列每条路线的 code，不要在同一循环里重试十几轮 |
| 拼装总字节 ≠ total，或 SHA256 ≠ digest | 报 `DOWNLOAD_VERIFY_FAILED`，不许说「下好了」 |

**API 200 只说明 release/tag 存在，既不说明资产名对，也不说明资产可下**；资产名对不上是唯一必须回问用户的状态，其余情况一律自己探。

## 为什么先选路线、再谈线程（2026-10 两次实测，同一台机器）

同一台机器、同一个 ~214MB 资产（obs-studio 33.0.0 Windows x64 zip）两次测量差异极大，这本身就是最重要的证据：**任何历史数字都不能套用，必须每轮重新实测**。

| 路线 | 并发 | 实测吞吐 |
| --- | --- | --- |
| 直连 release-assets | 1（整包 223.7MB 平均）/ 8MB 短探针 | ≈1.2 MB/s / ≈3.0 MB/s（前段给得快，不能当整包速度） |
| 公共镜像 gh-proxy | 1 | ≈119 KB/s |
| 公共镜像 ghfast / ghproxy.net / moeyy / llkk / ghproxy.cc | 1 | 0（TLS 握手超时，code 000） |
| 本机 mihomo 7897 | 1 / 4 / **16** / 24 / 32 段 | ≈4.9 / ≈5.3 / **≈7.7（整包 223.7MB / 28.2s，SHA256 通过）** / ≈6.0 / ≈6.3 MB/s |

同一天节点恢复后（rclone 31.6MB 整包对照）：**单流 5.8 MB/s 已经快过 16 段 4.2 MB/s（0.72×）**，1/4/16 三档中位数 5.7 / 5.1 / 5.2 MB/s 基本持平。结论：**并发只在「单连接被限速」时才有收益，节点不限速时多开线程是负收益**，所以第 6 步必须现测并用「多段快 1.25 倍才分段」的门槛。再加一条成本约束：阶梯两档 × 三遍 × 4 秒 ≈ 20–26 秒，节点快时还要顺带下载上百 MB 采样流量（5.8 MB/s × 4s × 6 ≈ 140MB），对 30–60MB 的包比省下的时间还贵——所以先用第 5 步的 8MB 单连接探针检验前提，单连接 ≥3 MB/s 或资产 <100 MB 就不测，只有「大包 + 单连接明显被限速」才值得花这笔测量费，想强行测就 `$ForceLadder = $true`。这两个阈值（默认 100MB / 3 MB/s）写在 frontmatter 的 `metadata` 里，`scripts\validate.ps1` 会比对代码里的 `$ladderMinMB`/`$fastKB`。

结论：路线决定量级（镜像 119 KB/s vs 代理 7.7 MB/s ≈ 65 倍），线程在限速节点上再多 1.5–6 倍、在快节点上可能略亏。顺序固定：**自检 → 校验资产名 → 测路线 → 在胜出路线上做限时阶梯 → 按 `$winN` 下载**。裸机上没有「装个工具再说」这一步：全程只用系统自带 `curl.exe` 和 PowerShell。

### 宿主 shell 的硬约束（先看这条，否则代码会直接报错）

本机默认 shell 是 **Windows PowerShell 5.1**（`$PSVersionTable.PSEdition -eq 'Desktop'`）：

- **不能用 `ForEach-Object -Parallel`**（7.x 才有）。并行探测改用 `Start-Process curl.exe` 一次拉起多条 + `Wait-Process -Timeout`，见第 4 步。
- **`Start-Process -ArgumentList` 传数组时不会替你加引号**：含空格的参数（`-w 'code=... got=...'`、`-H 'User-Agent: ...'`）会被拆坏，表现为 `-o` 失效、二进制写进 stdout、分片 0 字节。**本技能所有 curl 参数串都不含空格**（`-w` 用 `|`、UA 用 `-A dsh`、输出用 `NUL`），否则改成整条命令串自己加引号，或 `& curl.exe @arg`（绝不配 `2>&1`）。
- `Where-Object Length -lt $mb*1MB` 在 5.1 会把 `$mb*1MB` 当字符串再比数值，报 Ilt 转换失败；先算好变量再比较。
- `Start-Process -RedirectStandardOutput` 的文件用 `Get-Content` 读，遇到二进制会乱码；重定向文件里只允许出现纯 ASCII 的 `-w` 统计行。
- **写脚本文件必须 UTF-8 with BOM**：5.1 把无 BOM 的 UTF-8 按 GBK 解码，中文字符串里的引号被吞掉、引号错配（实测 `validate.ps1` 首跑直接 exit=1）。

## Steps

0. **先把用户给的地址拆成 `repo/tag/asset`，后面所有步骤都靠这三个值。** 用户通常只丢一个 release 页面或直链，不要反问他。

   ```powershell
   $u = 'https://github.com/owner/repo/releases/download/v1.2.3/asset.zip'   # 或用户给的任意链接
   if ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/download/(?<t>[^/]+)/(?<a>[^/?#]+)') {
     $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t; $asset = $Matches.a
   } elseif ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/tag/(?<t>[^/?#]+)') {
     $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t; $asset = ''
   }
   if (-not $repo) { throw 'BAD_URL: 既不是 /releases/download/ 也不是 /releases/tag/ 链接，先把 release 地址确定下来再交给本技能' }
   "repo=$repo tag=$tag asset=$asset"
   ```

   `$asset` 为空说明用户只给了 tag 页：去第 3 步按 `size` 降序列出资产，挑最大的那个（大文件才有加速价值），并把选择理由写进报告。

1. **只读自检：探清家底，不装东西、不改系统、不问用户。** `Get-NetTCPConnection` 的监听列表才是「代理真的在跑」的证据（`ProxyServer` 残留值不算）。

   ```powershell
   $ProgressPreference = 'SilentlyContinue'
   if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { 'NO_CURL：改用 Invoke-WebRequest 单流，功能降级' }
   $portList = 7890,7891,7897,7898,1080,10808,10809,2080,8889,20171,8080
   $listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
             Where-Object { $_.LocalPort -in $portList } | Select-Object -ExpandProperty LocalPort -Unique
   $sp = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
   "listen=$($listen -join ',')  ProxyEnable=$($sp.ProxyEnable)  ProxyServer=$($sp.ProxyServer)"
   "env=$($env:HTTPS_PROXY)|$($env:HTTP_PROXY)|$($env:ALL_PROXY)"
   Get-Process -ErrorAction SilentlyContinue |
     Where-Object { $_.ProcessName -match 'mihomo|clash|verge|sing-box|v2ray|xray' } |
     ForEach-Object { '{0,-12} {1,6} {2}' -f $_.ProcessName, $_.Id, $_.Path }
   ```

2. **定位本机 Clash Verge 的内核与配置（找不到就跳过 B 路线，不要报错退出）。** 实测常装在非系统盘（`D:\Clash Verge`、`E:\Apps\Clash Verge`），候选要覆盖「标准安装目录 + 每个固定盘根 × `<盘>:\Clash Verge` 与 `<盘>:\Apps\Clash Verge` + 开始菜单快捷方式反查」，别只写死 C 盘。

   ```powershell
   $coreDirs = @()
   if ($env:ProgramFiles) { $coreDirs += @(Join-Path $env:ProgramFiles 'Clash Verge') }
   if (${env:ProgramFiles(x86)}) { $coreDirs += @(Join-Path ${env:ProgramFiles(x86)} 'Clash Verge') }
   if ($env:LOCALAPPDATA) {
     $coreDirs += @((Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge'), (Join-Path $env:LOCALAPPDATA 'Clash Verge'))
   }
   # 只遍历本地固定盘（排除网络盘/光驱，避免 Test-Path 卡在离线盘上）；开销量级是毫秒。
   foreach ($drv in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.Name })) {
     $coreDirs += @((Join-Path $drv 'Clash Verge'), (Join-Path $drv 'Apps\Clash Verge'))
   }
   $coreDirs += @(Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
     Where-Object Name -match 'Clash.*Verge' |
     ForEach-Object { Split-Path (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName).TargetPath -Parent })
   # 多份安装（升级残留、重装到别的盘）优先「最新的那个 exe」：旧内核配新配置会读不懂字段。
   $picked = @($coreDirs | Where-Object { $_ -and (Test-Path (Join-Path $_ 'verge-mihomo.exe')) } |
     Sort-Object { (Get-Item (Join-Path $_ 'verge-mihomo.exe')).LastWriteTime } -Descending)
   $coreDir = $picked | Select-Object -First 1
   $cfgDir  = @("$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev","$env:APPDATA\clash-verge",
                "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev") |
              Where-Object { Test-Path (Join-Path $_ 'clash-verge.yaml') } | Select-Object -First 1
   "core=$coreDir  cfg=$cfgDir  candidates=$($picked.Count)"
   ```

   `$coreDir` 或 `$cfgDir` 为空、或 `clash-verge.yaml` 里没有可用节点，都说明 B 路线走不通——直接进第 4 步的镜像/直连，不要拉起空转内核。**候选为空是正常降级，不是脚本坏了。** 真实机器只有一份安装时 `$picked` 只有 1 个，测不出「取最新」；要验证排序就做 FakeSort 副本：两份假目录各放新旧 `verge-mihomo.exe`，跑同一段 `Where-Object` + `Sort-Object`，应选中新的（实测 `SORT_PICK_NEWEST=True`）。

3. **取 release 元数据并校验资产名：`total`、digest，以及「改名就报 ASSET_NOT_FOUND」。** 这是**测速之前的**硬闸门：资产名对不上就不许进第 4 步。API 只读元数据，不要拿 API 200 当「资产可下」。**API 403 限流不是 NO_ROUTE**：已有 total/digest 就继续，缺 total 用一次 range 探针从 `Content-Range` 反推，digest 缺失时最后只做字节数校验。

   ```powershell
   $repo='<owner>/<repo>'; $tag='<tag>'; $asset='<asset>'
   $total = [int64]$total                 # 保留上一轮/用户已知的 total
   $want  = [string]$want                 # 保留上一轮/用户已知的 digest
   $tmp = Join-Path $env:TEMP ("meta_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
   if ($tmp -match ' ') { throw "SPACE_IN_PATH: $tmp 含空格，换一个不含空格的 TEMP/目录" }   # Start-Process 数组传参怕空格
   Start-Process curl.exe -NoNewWindow -Wait `
     -ArgumentList @('-sS','-L','-m','20','-A','dsh','-o',"$tmp.json",'-w','%{http_code}',
                     "https://api.github.com/repos/$repo/releases/tags/$tag") `
     -RedirectStandardOutput "$tmp.code" -RedirectStandardError "$tmp.err" | Out-Null
   $apiCode = ((Get-Content "$tmp.code" -Raw -ErrorAction SilentlyContinue) + '').Trim()
   $apiErr  = ((Get-Content "$tmp.err"  -Raw -ErrorAction SilentlyContinue) + '').Trim()
   $apiBody = ((Get-Content "$tmp.json" -Raw -ErrorAction SilentlyContinue) + '')
   if ($apiCode -eq '404') { throw "RELEASE_NOT_FOUND: $repo@$tag 不存在（API 404）——先确认 tag，别去猜资产名" }
   $apiLimited = ($apiCode -eq '403' -and $apiBody -match 'rate limit')
   if ($apiCode -ne '200' -and -not $apiLimited) { throw "API_FAILED: code=$apiCode err=$apiErr" }

   if ($apiLimited) {
     Remove-Item "$tmp.json","$tmp.code","$tmp.err" -Force -ErrorAction SilentlyContinue
     # 未认证 API 限流不等于资产不可下，更不是 NO_ROUTE：已有 total/digest 就继续；
     # 缺 total 就用一次 range 探针从 Content-Range 反推；digest 缺失时最后只做字节数校验。
     'API_RATE_LIMITED: 跳过资产名/API 元数据校验，改用已知 total/digest 或 Content-Range 继续'
     if (-not $asset) { throw 'API_RATE_LIMITED_NEED_ASSET: API 限流且没给具体资产名，无法自动挑资产；请给完整资产直链或稍后重试' }
     $u0 = "https://github.com/$repo/releases/download/$tag/$asset"
     if ($total -le 0) {
       $hdr = Join-Path $env:TEMP ("range_{0}.hdr" -f [guid]::NewGuid().ToString('N').Substring(0,6))
       $ro  = Join-Path $env:TEMP ("range_{0}.out" -f [guid]::NewGuid().ToString('N').Substring(0,6))
       Start-Process curl.exe -NoNewWindow -Wait `
         -ArgumentList @('-sS','-L','-m','20','-A','dsh','-r','0-0','-D',$hdr,'-o','NUL','-w','%{http_code}',$u0) `
         -RedirectStandardOutput $ro -RedirectStandardError "$ro.err" | Out-Null
       $rc = ((Get-Content $ro -Raw -ErrorAction SilentlyContinue) + '').Trim()
       $h  = ((Get-Content $hdr -Raw -ErrorAction SilentlyContinue) + '')
       $m  = [regex]::Matches($h,'(?im)^content-range:\s*bytes\s+\d+-\d+/(\d+)')
       if ($m.Count) { $total = [int64]$m[$m.Count - 1].Groups[1].Value }
       Remove-Item $hdr,$ro,"$ro.err" -Force -ErrorAction SilentlyContinue
       "range_probe code=$rc total=$total"
     }
   } else {
     $meta = Get-Content "$tmp.json" -Raw -Encoding UTF8 | ConvertFrom-Json
     Remove-Item "$tmp.json","$tmp.code","$tmp.err" -Force -ErrorAction SilentlyContinue

     $names = @($meta.assets | ForEach-Object { $_.name })
     if ($names.Count -eq 0) { throw 'ASSET_NOT_FOUND: 该 release 没有任何 asset（只发了 tag 或附件还没传完），先把 release 页面地址给用户确认' }
     if (-not $asset) {                                   # 只给了 tag 页：自己挑最大的资产
       $a = $meta.assets | Sort-Object size -Descending | Select-Object -First 1
       $asset = $a.name
     } else {
       $a = $meta.assets | Where-Object { $_.name -eq $asset }
     }
     if (-not $a) {                                       # 用户给的资产名对不上：报错并停，不许静默替换
       $at   = $asset -split '[-_.]'
       $near = $names |
         ForEach-Object { [pscustomobject]@{ Name=$_; Score=@(($_ -split '[-_.]') | Where-Object { $at -contains $_ }).Count } } |
         Sort-Object Score -Descending | Select-Object -First 1
       $list = ($meta.assets | Sort-Object name | ForEach-Object { '  - {0}  ({1:N1} MB)' -f $_.name, ($_.size/1MB) }) -join "`n"
       throw ("ASSET_NOT_FOUND: 你给的 '{0}' 不在 {1}@{2} 里。真实候选：`n{3}`n最接近的是 '{4}'；把确认后的完整下载链接发我，我不会静默替换文件名继续下。" -f $asset,$repo,$tag,$list,$near.Name)
     }
     $total = [int64]$a.size
     $want  = if ($a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLower() } else { '' }
   }
   $digestText = if ($want) { "sha256:$want" } else { '(none)' }
   "asset=$asset total=$total digest=$digestText want=$want apiLimited=$apiLimited"
   ```

   规则：**资产名对不上 = 到此为止**，不测速、不下载、不拿「x64 换 amd64 / 点换横线」去猜；报 `ASSET_NOT_FOUND` + 候选清单（名字 + MB）+ 最接近的一条，等用户确认新链接后从第 0 步重跑。候选清单必须来自 API 的 `assets`，不要手写。`$want` 为空 = 该 release 没有 digest（老资产常见），第 10 步只能做字节数基准并如实说明，不要伪造校验。同一失败路线不重复重试：每条探测只跑一次，`--retry` 只用在第 7 步真正的整包下载上。

4. **组装候选路线并并行短测，每条路线都要真跑一次 range GET。** 此步**只在第 3 步资产名校验通过后**执行；直连永远作为兜底。超时压到 8s，`--connect-timeout 5`，串行会白等几十秒。**B 路线（本机内核）不在这一步测**——内核还没起来，测出来的是直连，留到第 5 步。

   ```powershell
   # 测速前置守卫：7897 没在监听时，任何「基线」都会是 code=000|got=0（实测 BASELINE bytes=0 code=000），
   # 那只是「没有代理」，不能当单流对照。先跑第 5 步拉起内核并轮询到监听，再回来补测。
   $port7897 = [bool](Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue)
   if (-not $port7897) { 'PORT_7897_NOT_LISTENING: 跳过 7897 基线；先跑第 5 步' }

   $u       = "https://github.com/$repo/releases/download/$tag/$asset"
   $mirrors = @('https://ghfast.top','https://ghproxy.net','https://gh-proxy.com',
                'https://github.moeyy.xyz','https://gh.llkk.cc','https://ghproxy.cc')
   $probes = @()
   if ($listen) { $probes += [pscustomobject]@{Name="A 现有代理 :$($listen[0])"; Url=$u; Proxy="http://127.0.0.1:$($listen[0])"} }
   $probes += @($mirrors | ForEach-Object { [pscustomobject]@{Name="C 镜像 $_"; Url="$_/$u"; Proxy=$null} })
   $probes += [pscustomobject]@{Name='D 直连'; Url=$u; Proxy=$null}

   # 5.1 没有 -Parallel：逐条 Start-Process 拉起 curl，再统一 Wait-Process。
   # 所有参数都不含空格（-w 用 | 分隔、输出到 NUL），这样数组传参才不会被拆坏。
   $pdir = Join-Path $env:TEMP ("probe_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
   New-Item -ItemType Directory $pdir -Force | Out-Null
   $run = foreach ($p in $probes) {
     $f   = Join-Path $pdir (($p.Name -replace '[^\w]','_') + '.out')
     $arg = @('-sS','-L','--connect-timeout','5','-m','8','-r','0-1048575',
              '-A','Mozilla/5.0','-o','NUL','-w','%{http_code}|%{size_download}|%{speed_download}')
     if ($p.Proxy) { $arg += @('--proxy',$p.Proxy) }
     $arg += $p.Url
     $proc = Start-Process curl.exe -ArgumentList $arg -NoNewWindow -PassThru `
               -RedirectStandardOutput $f -RedirectStandardError ($f -replace '\.out$','.err')
     [pscustomobject]@{ Name=$p.Name; Proxy=$p.Proxy; Log=$f; Proc=$proc }
   }
   $run.Proc | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
   $results = foreach ($r in $run) {
     $line = Get-Content $r.Log -Raw -ErrorAction SilentlyContinue
     $o = if ($line) { $line.Trim() -split '\|' } else { @() }
     if ($o.Count -lt 3) { $o = @('000','0','0') }
     [pscustomobject]@{ Name=$r.Name; Proxy=$r.Proxy; Code=$o[0]
       Bytes=($(if ($o[1] -match '^\d+$') { [int64]$o[1] } else { 0 }))
       KBps =$(if ($o[2] -match '^[\d.]+$') { [math]::Round([double]$o[2]/1KB,0) } else { 0 }) }
   }
   # 先按「是否真的拿到 range 数据（Bytes ≥ 512KB）」排，再按速度排：镜像回一页 HTML 错误页也会「很快」。
   $results | Sort-Object @{Expression={$_.Bytes -ge 524288};Descending=$true}, @{Expression='KBps';Descending=$true} |
     ForEach-Object { '{0,-28} code={1} bytes={2,9} KBps={3,6}' -f $_.Name,$_.Code,$_.Bytes,$_.KBps }
   # 基线守卫：只有 code=206/200 且 Bytes ≥ 1MB 的 A 路线才算「节点可用」。
   $aUsable = @($results | Where-Object { $_.Name -like 'A *' -and $_.Code -in '200','206' -and $_.Bytes -ge 1048576 })
   "A_usable=$($aUsable.Count)"
   Remove-Item $pdir -Recurse -Force -ErrorAction SilentlyContinue
   ```

   判定：只有回 `206`/`200` **且 `Bytes ≥ 512KB`（证明拿的是资产本身，不是镜像错误页）**、`KBps` 够高的路线才继续；<100 KB/s 的淘汰，**但全灭时不要放弃**——取 Bytes 合格里 KBps 最高的一条照下并在报告里说明。全部 `000`/非 2xx 时按决策表报 `NO_ROUTE` 并列出每条线路的 code，不要在这个循环里反复重试十几轮。

5. **没有可用代理时才无头拉起内核，只监听 127.0.0.1:7897。** 先确认 `config.yaml` 的 `mixed-port: 7897`，再用运行配置 `clash-verge.yaml` 显式 `-d/-f` 起内核；不启动 GUI，不写注册表代理项。**只记自己起的 pid**，用户本来就在跑的 7897 不许停。

   ```powershell
   $corePid = $null
   $canStart = [bool]($coreDir -and (Test-Path (Join-Path $coreDir 'verge-mihomo.exe')))
   if (-not $canStart) { 'NO_CLASH_CORE: 没找到 verge-mihomo.exe，跳过 B 路线，只用镜像/直连' }
   elseif (-not (Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue)) {
     (Get-Content "$cfgDir\config.yaml" -TotalCount 20 | Select-String 'mixed-port').Line   # 只确认端口，别把 secret/pipe 路径打进日志
     $core = Start-Process -FilePath (Join-Path $coreDir 'verge-mihomo.exe') `
       -ArgumentList @('-d',$cfgDir,'-f',"$cfgDir\clash-verge.yaml") -WindowStyle Hidden -PassThru
     $corePid = $core.Id
     for ($i=0; $i -lt 15; $i++) {
       Start-Sleep -Milliseconds 700
       if (Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue) { break }
     }
   } else { 'PORT_7897_ALREADY_LISTENING: 用现成的，收尾不要停' }
   $up = [bool](Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue)
   "corePid=$corePid port7897=$up"
   # 基线守卫：$up=False 时不要测 A/B 基线；此时 code=000/got=0 只能记为「无代理」。

   # 起来后补测 B 路线（必须带 -L：资产会 302 到 release-assets.githubusercontent.com）
   # 用 Start-Process + 临时文件取结果，别写 `& curl ... 2>&1`：5.1 会把 curl 的 stderr 变成 ErrorRecord，
   # 撞上 $ErrorActionPreference='Stop' 就成终止错误（TLS/DNS 一失败整条流程就死在这）。
   if ($up) {
     $bo   = Join-Path $env:TEMP ("probe_b_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
     $bnul = Join-Path $env:TEMP ("probe_b_{0}.bin" -f [guid]::NewGuid().ToString('N').Substring(0,6))
     Start-Process curl.exe -Wait -NoNewWindow -ErrorAction SilentlyContinue `
       -ArgumentList @('-sS','-L','-m','20','-r','0-8388607','--proxy','http://127.0.0.1:7897','-A','Mozilla/5.0',
                       '-o',$bnul,'-w','%{http_code}|%{size_download}|%{speed_download}',$u) `
       -RedirectStandardOutput $bo -RedirectStandardError "$bo.err"
     $raw  = ((Get-Content $bo -Raw -ErrorAction SilentlyContinue) + '').Trim()
     $bErr = ((Get-Content "$bo.err" -Raw -ErrorAction SilentlyContinue) + '').Trim()
     Remove-Item $bo,"$bo.err",$bnul -Force -ErrorAction SilentlyContinue
     $b = $raw -split '\|'
     $bCode = if ($b.Count -ge 3 -and $b[0] -match '^\d{3}$') { $b[0] } else { '000' }
     $bGot  = if ($b.Count -ge 3 -and $b[1] -match '^\d+$')   { [int64]$b[1] } else { 0 }
     $bKBps = if ($b.Count -ge 3 -and $b[2] -match '^[\d.]+$') { [math]::Round([double]$b[2]/1KB,0) } else { 0 }
     "B 本机内核: code=$bCode got=$bGot KBps=$bKBps"
     $needGot = if ($total -gt 0) { [math]::Min([int64]8388608, $total) } else { [int64]8388608 }   # 小于 8MB 的资产只可能拿回整个文件
     if ($bCode -notin '200','206' -or $bGot -lt ($needGot * 0.5)) { "B 不可用: raw=$raw err=$bErr" ; if ($corePid) { Stop-Process -Id $corePid -Force; $corePid = $null } }
   }

   # 单连接证据：交给第 6 步判断「值不值得花 20 秒测并发」。
   # 以 8MB 探针为准；1MB 探针会被建连 + TCP 慢启动拉低（实测同节点 1MB 段 742KB/s vs 整包单流 5829KB/s），只作兜底。
   $singleKB = 0
   if ($up -and $bCode -in '200','206' -and $bGot -gt 0) { $singleKB = [int]$bKBps }
   if ($singleKB -le 0 -and $aUsable) {
     $aBest = $aUsable | Sort-Object KBps -Descending | Select-Object -First 1
     $singleKB = [int]$aBest.KBps
   }
   "singleKB=$singleKB  (>=3072 视为单连接没被限速，第 6 步直接单流)"
   ```

   15 秒内没起来、或 `code` 不是 206/200、或 `got` 远小于 8388608，就判定 B 不可用：`if ($corePid) { Stop-Process -Id $corePid -Force }`，回 C/D 路线，别让半死的内核占着 7897 干扰后面的分段。

6. **先判值不值得测，再在胜出路线上做并发阶梯：资产 ≥100 MB 且单连接探针 <3 MB/s 才测；测就测 1/16 两档。** 阶梯两档 × 三遍 × 4 秒 ≈ 24 秒，节点快时还要顺带下载上百 MB 采样流量，对 30–60 MB 的包比省下的时间还贵——所以先用第 5 步的 `$singleKB` 检验前提：「单连接是否被限速」不成立就不测。测的时候每档开 n 条连接、从各自起点读到文件尾，**只跑同样几秒**（`-m $sec`），比同一时间窗内的聚合吞吐；**同时看「完成连接数」**——某条 0 字节但其它连接很快时总 KB/s 会骗人。**每档至少三遍、交错进行，报告写中位数与 min–max 波动**：单次采样噪声极大（实测同一 1MB 段 72 KB/s 与 2,245 KB/s 并存）。历史形状（2026-10，限速期）：1 段 4.9 MB/s、4 段 5.3、**16 段 7.7（最优）**、24 段 6.0、32 段 6.3，所以限速档只测 1/16；但节点不限速时（同日另一时段）整包单流 5.8 反而快过 16 段 4.2，必须现测。要回答「单流 vs 多段」时，再用第 7 步分别整包跑一次并各自做 digest 校验，别拿 4 秒阶梯窗口当整包结论。

   ```powershell
   function Test-Ladder([int]$n,[string]$url,[string]$proxy,[int64]$total=0,[int]$sec=4) {
     if ($n -lt 1) { return }
     # 每段从各自起点 open-range 到文件尾，只跑 $sec 秒（--max-time 到点就断，curl exit 28 属正常）。
     # 别用固定 1MB/8MB 小段：小段的时间被建连 + TCP 慢启动吃掉，阶梯会一边倒地偏向高并发。
     $per = if ($total -gt 0) { [int64][math]::Floor($total / $n) } else { [int64][math]::Floor(64MB / $n) }
     $dir = Join-Path $env:TEMP ("ladder_{0}_{1}" -f $n,[guid]::NewGuid().ToString('N').Substring(0,4))
     New-Item -ItemType Directory $dir -Force | Out-Null
     $sw = [Diagnostics.Stopwatch]::StartNew()
     $procs = 1..$n | ForEach-Object {           # 参数不含空格，数组传参在 5.1 里才安全
       $i=$_; $s=[int64](($i-1)*$per)
       $arg = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0',
                '-r',"$s-",'-o','NUL','-m',"$sec",
                '-w','%{http_code}|%{size_download}|%{speed_download}')
       if ($proxy) { $arg += @('--proxy',$proxy) }
       $arg += $url
       Start-Process curl.exe -ArgumentList $arg -NoNewWindow -PassThru `
         -RedirectStandardOutput (Join-Path $dir "p$i.out") `
         -RedirectStandardError  (Join-Path $dir "p$i.err")
     }
     $procs | Wait-Process -Timeout ($sec+30) -ErrorAction SilentlyContinue
     $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
     $sw.Stop()
     $bytes = 0; $ok = 0
     Get-ChildItem $dir -Filter 'p*.out' -ErrorAction SilentlyContinue | ForEach-Object {
       $o = ((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) + '').Trim() -split '\|'
       if ($o.Count -ge 3 -and $o[0] -match '^20[06]$') {
         $ok++
         if ($o[1] -match '^\d+$') { $bytes += [int64]$o[1] }
       }
     }
     $kbps = [int](($bytes/1KB)/[math]::Max($sw.Elapsed.TotalSeconds,0.1))
     $line = '{0,2} 段: 完成 {1}/{0}  {2,7:N1} MB / {3,4:N1}s = {4,6:N0} KB/s' -f `
       $n, $ok, ($bytes/1MB), $sw.Elapsed.TotalSeconds, $kbps
     Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
     # 既打印给人看，也把结果交给第 7 步选并发数——只打印不返回，阶梯就白测了。
     [pscustomobject]@{ N = $n; Full = $ok; KBps = $kbps; Text = $line }
   }
   # 胜出路线（第 4/5 步的结果）：镜像胜出就换 $winUrl，直连/镜像胜出就把 $winProxy 置 $null
   $winUrl   = $u                       # 例："https://ghfast.top/$u"
   $winProxy = 'http://127.0.0.1:7897'
   # 先判「值不值得测」：阶梯 ≈ 20–26s，节点快时还要顺带下载上百 MB 采样流量，小包纯亏。
   # 判据用第 5 步的 8MB 单连接探针（$singleKB）——它直接检验并发收益的前提「单连接是否被限速」。
   # 两个阈值来自 frontmatter.metadata（改阈值就改 SKILL.md 头部，validate.ps1 会校验这里同步过）。
   # 想要「无论多大都测一遍」的老行为，就把 $ForceLadder 置 $true。
   $ForceLadder = $false
   $ladderMinMB = 100            # = metadata.min_size_for_ladder_mb
   $fastKB      = 3072           # = metadata.single_conn_fast_kbps（3 MB/s）
   $bigEnough   = ($total -ge ($ladderMinMB * 1MB))
   $throttled   = ($singleKB -le 0) -or ($singleKB -lt $fastKB)
   $rungs = @(1,16)              # 4 段极少单独胜出（同日实测 4.24 vs 16 3.95，差异在噪声内），砍掉省 1/3 测量时间
   $runs  = @()
   if ($ForceLadder -or ($bigEnough -and $throttled)) {
     # 每档只跑几秒、各段同时开跑：比「同一时间窗内的聚合吞吐」，与资产大小无关，也不受块大小影响。
     # 每档三遍、交错进行：单次采样噪声极大（同一路线同一天实测 72KB/s 与 2245KB/s 都出现过）。
     $sec = 4
     foreach ($rep in 1..3) { foreach ($n in $rungs) { $runs += @(Test-Ladder $n $winUrl $winProxy $total $sec) } }
     $runs | ForEach-Object { $_.Text }
   } else {
     "SKIP_LADDER: total=$([math]::Round($total/1MB,1))MB singleKB=$singleKB (门槛 ${ladderMinMB}MB / ${fastKB}KB/s) -> 直接单流（没花时间测并发）"
   }
   $agg = foreach ($n in $rungs) {
     $s = @($runs | Where-Object { $_.N -eq $n })
     if ($s.Count -eq 0) { continue }
     $vals = @($s | ForEach-Object { [int]$_.KBps } | Sort-Object)
     $mid  = [int][math]::Floor($vals.Count / 2)
     $med  = if (($vals.Count % 2) -eq 1) { $vals[$mid] } else { [int](($vals[$mid - 1] + $vals[$mid]) / 2) }
     $spread = if ($vals[0] -gt 0) { [math]::Round($vals[$vals.Count - 1] / $vals[0], 2) } else { 0 }
     [pscustomobject]@{ N = $n; Full = ($s | Measure-Object Full -Minimum).Minimum
       Med = $med; Min = $vals[0]; Max = $vals[$vals.Count - 1]; Spread = $spread }
   }
   $agg | ForEach-Object { '{0,2} 段: 完成 {1}/{0}  中位 {2,6} KB/s  范围 {3}-{4} KB/s  波动 {5}x' -f $_.N,$_.Full,$_.Med,$_.Min,$_.Max,$_.Spread }
   # 胜出档：先要求「完成数 = n/n」且三次波动 ≤2×，再比中位 KB/s；多段必须快过单段 1.25 倍才值得用。
   $best = $agg | Where-Object { $_.Full -ge $_.N -and $_.Spread -le 2 } | Sort-Object Med -Descending | Select-Object -First 1
   if (-not $best) { $best = $agg | Where-Object { $_.Full -ge $_.N } | Sort-Object Med -Descending | Select-Object -First 1 }
   $n1   = $agg | Where-Object { $_.N -eq 1 } | Select-Object -First 1
   $winN = if (-not $best) { 1 } elseif ($best.N -gt 1 -and $n1 -and $best.Med -lt (1.25 * $n1.Med)) { 1 } else { $best.N }
   "winN=$winN"
   ```

   判定：取「中位 KB/s 最高、完成数 = n/n、三次波动 ≤2×」的档位，结果存进 `$winN` 交给第 7 步；多段必须比单段快 1.25 倍以上才分段，否则 `$winN=1` 走单流；两次中位数差在 10% 以内也选低并发。`$total` 未知时函数按 64MB 估起点。**不满足「资产 ≥100MB 且 `$singleKB < 3072`」又不给 `$ForceLadder=$true` 时，整个阶梯跳过**，日志打印 `SKIP_LADDER: …`、`$winN=1` 走单流——这是设计里的省时分支，不是漏测。

7. **按胜出组合下载：`$winN=1` 或小于 `$ladderMinMB` 单流一次拿完，否则按 `$winN` 段并发。先查空间、每段独立日志、带 `--retry`，并按 curl 版本决定是否加 `--retry-all-errors`。** 分片目录先清空重建；`--fail` 让 4xx/5xx 直接失败，避免把错误页写成合法分片；`-w` 用 `|` 分隔（**不能含空格**），每段独立日志，卡住时能定位到具体段。

   ```powershell
   $ErrorActionPreference = 'Stop'
   $url   = '<第 4/5/6 步胜出的地址>'
   $proxy = 'http://127.0.0.1:7897'      # 直连/镜像路线就置 $null
   $parts = $winN                        # 第 6 步算出的胜出并发；1 就是单流
   if (-not $parts) { $parts = 1 }       # 没有阶梯结果就单流，绝不退回写死的 16（本轮修掉的真 bug）
   $total = [int64]$total                # 第 3 步已赋值；API 限流时来自 Content-Range
   $base  = Join-Path $env:USERPROFILE 'Downloads\_dl'   # 不写死盘符；空间不够再改到别的盘
   $dir   = Join-Path $base 'parts'
   $out   = Join-Path $base $asset

   # curl 版本守卫：--retry-all-errors 要 7.71+，Win10 自带的 7.55 会直接报 unknown option
   if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'NO_CURL: 第 7 步依赖 curl.exe' }
   $curlVer = [version](((& curl.exe -V) -split '\s+')[1])
   $retry   = @('--retry','3','--retry-delay','2')
   if ($curlVer -ge [version]'7.71') { $retry += '--retry-all-errors' }

   # 决策表落地：`$winN` 判成单流、或小于 ladderMinMB、或 total 未知时，不分段，一次拿完（分段只增加失败面）
   if (-not $ladderMinMB) { $ladderMinMB = 100 }   # 单块连跑（没执行第 6 步）时也要有值
   if ($total -le 0 -or $total -lt ($ladderMinMB * 1MB) -or $parts -le 1) {
     New-Item -ItemType Directory (Split-Path -Parent $out) -Force | Out-Null
     $arg = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0',
              '-o',$out,'-m','1800',
              '-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}|t=%{time_total}') + $retry
     if ($proxy) { $arg += @('--proxy',$proxy) }
     $arg += $url
     $stat = (& curl.exe @arg | Out-String).Trim()   # 不要写 2>&1：5.1 会把 curl 的 stderr 变成终止错误
     "SINGLE exit=$LASTEXITCODE $stat"
     if ($LASTEXITCODE -ne 0) { throw "SINGLE_FAILED: exit=$LASTEXITCODE $stat" }
     if ($total -le 0) { $total = (Get-Item $out).Length; "total_from_download=$total" }
     $parts = 1
   } else {
     # 决策表落地：每段至少 2MB，否则 16 个进程的调度开销比省下的时间还多。
     if ($dir -match ' ') { throw "SPACE_IN_PATH: $dir 含空格，5.1 的 Start-Process 会把 -o 参数拆坏，请换到不含空格的目录" }
     if ($parts -gt 1 -and [math]::Floor($total / $parts) -lt 2MB) { $parts = [math]::Max(1, [int][math]::Floor($total / 2MB)) }

     # 空间预检：分片和成品要同时存在，约需 2 倍资产大小
     $letter = ([IO.Path]::GetPathRoot($dir)).TrimEnd('\').TrimEnd(':')
     $freeGB = [math]::Round((Get-PSDrive $letter).Free / 1GB, 1)
     $needGB = [math]::Round(($total * 2 / 1GB), 1)
     if ($freeGB -lt $needGB) { throw "SPACE_LOW: free=${freeGB}GB need=${needGB}GB" }
     "free=${freeGB}GB need=${needGB}GB parts=$parts"

     Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
     New-Item -ItemType Directory $dir -Force | Out-Null
     New-Item -ItemType Directory (Split-Path -Parent $out) -Force | Out-Null
     $chunk = [int64][math]::Floor($total / $parts)
     $curlPids = @()
     for ($i=0; $i -lt $parts; $i++) {
       $start = [int64]($i * $chunk)
       $end   = if ($i -eq $parts-1) { $total-1 } else { $start+$chunk-1 }
       $arg = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0',
                '-r',"$start-$end",'-o',(Join-Path $dir "p$i.bin"),'-m','1800',
                '-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}|t=%{time_total}') + $retry
       if ($proxy) { $arg += @('--proxy',$proxy) }
       $arg += $url
       $curlPids += (Start-Process curl.exe -ArgumentList $arg -NoNewWindow -PassThru `
         -RedirectStandardOutput (Join-Path $dir "p$i.log") `
         -RedirectStandardError  (Join-Path $dir "p$i.err")).Id
     }
     "parts=$parts chunk=$chunk pids=$($curlPids -join ',')"
   }
   ```

   记下 `$curlPids`：收尾和降档时只杀这些 pid，别 `Stop-Process -Name curl` 把用户自己的下载一起杀了。

8. **分段时后台跑 + 45 秒看一次增长；20–30s 还是 0 字节就自己降档重开。** 只停自己那批 `$curlPids`、清空分片、**降并发（16→8→4）或切到候选第二名路线**再开，不要靠再加并发救场。**单流分支（`$parts = 1`）跳过本步和第 9 步，直接到第 10 步。**

   ```powershell
   $before = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
   Start-Sleep -Seconds 45
   $after = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
   "delta=$([math]::Round(($after-$before)/1MB,1))MB/45s => $([math]::Round((($after-$before)/1KB)/45,0)) KB/s  total=$([math]::Round($after/1MB,1))MB"
   # 哪个段卡住：按大小排序，0 字节或明显偏小的就是它
   Get-ChildItem $dir -Filter 'p*.bin' | Sort-Object Length |
     ForEach-Object { '{0,-8} {1,12} {2,7:N1} MB' -f $_.Name,$_.Length,($_.Length/1MB) }
   # 诊断为 0 时才执行：$curlPids | Stop-Process -Force; 清分片; 改 $parts; 重跑第 7 步
   ```

9. **拼装前逐段核对字节数，再按 p0→pN 顺序拼。** 总和对不上就是有段被截断，只重跑那段；大小对内容错是最难发现的失败，所以拼完还要看第 10 步的 digest。

   ```powershell
   $sum = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
   "parts=$sum total=$total sumOk=$($sum -eq $total)"
   Get-ChildItem $dir -Filter 'p*.log' | ForEach-Object { "  $($_.Name): $((Get-Content $_.FullName -Raw).Trim())" }
   if ($sum -ne $total) { throw "PARTS_MISMATCH: sum=$sum total=$total，先修分片再拼" }
   New-Item -ItemType Directory (Split-Path -Parent $out) -Force | Out-Null   # $out 的父目录可能不存在
   $fs = [IO.File]::Create($out)
   for ($i=0; $i -lt $parts; $i++) {
     $p = Join-Path $dir "p$i.bin"
     if (-not (Test-Path $p)) { $fs.Dispose(); throw "PARTS_MISSING: $p" }
     $in = [IO.File]::OpenRead($p); $in.CopyTo($fs); $in.Dispose()
   }
   $fs.Dispose(); (Get-Item $out).Length
   ```

10. **用 release digest 做「字节数 + SHA256」闭环，不通过就别说完成。** digest 形如 `sha256:<hex>`；老 release 没有 `digest` 字段时如实说明缺少基准，不要伪造校验，也不要用 Authenticode 兜底（此前实测该安装包是 `NotSigned`）。单流分支同样必须过这一关。

    ```powershell
    $size = (Get-Item $out).Length
    $sizeOk = ($size -eq $total)
    "size=$size expect=$total sizeOk=$sizeOk"
    if ($want) {
      $got   = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower()
      "sha256=$got expect=$want shaOk=$($got -eq $want)"
      if ($sizeOk -and $got -eq $want) { 'DOWNLOAD_VERIFIED_OK' } else { 'DOWNLOAD_VERIFY_FAILED' }
    } else {
      'NO_DIGEST: 该 release 未提供 sha256，只能保证字节数一致'
      if ($sizeOk) { 'DOWNLOAD_SIZE_OK_NO_DIGEST' } else { 'DOWNLOAD_VERIFY_FAILED' }
    }
    ```

11. **收尾只还原自己动过的东西，然后一句话报结果。** 停掉第 5 步自己起的 pid（用户原本就在跑的代理不要动），删分片和临时目录，确认 7897 不再监听、`ProxyEnable` 与开始时一致。

    ```powershell
    if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }   # 只停自己起的
    if ($curlPids) { $curlPids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue               # 只删自己建的
    # 注意 Get-ChildItem 的 -Filter 只收单个字符串；清理也用 -like 链，别用带 () 的 -match 正则（少个右括号就抛 ArgumentException）
    Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'single_*' -or $_.Name -like 'range_*' -or $_.Name -like 'ghdl_*' } |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    "7897=$([bool](Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue))"
    (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
    ```

    报告模板（小白只看这三行，不要贴探测过程）：

    ```powershell
    "路线=本机 Mihomo 内核 127.0.0.1:7897（<单流/16 段>，单连接探针 X KB/s；<跳过阶梯：小包 / 已够快> 或 阶梯中位数 1/16 = X/Y KB/s）"
    "已下载并校验通过：<MB>，平均 <MB/s>，SHA256 与 release digest 一致"
    "文件=<绝对路径>"
    ```

    并发数写第 6 步的 `$winN`（跳过阶梯时写「单流（没测并发：<100MB 或单连接已 ≥3MB/s）」），别写死「16 段」。错误路径的报告同样只需一行，但必须带判定词：`ASSET_NOT_FOUND` + 候选清单、`RELEASE_NOT_FOUND`、`API_RATE_LIMITED`、`NO_ROUTE` 或 `DOWNLOAD_VERIFY_FAILED`。

## 技能自身的维护与加载验证（改 SKILL.md 后必跑）

三个**非模型文件**随文档同步维护（DSH 只读 SKILL.md 的 frontmatter，其余为跨宿主与自检）：

- `agents/openai.yaml`：Codex/OpenAI 宿主展示元数据，顶层 `interface:` 里 `display_name`、`short_description`（25–64 字符）、`default_prompt`（必须含 `$github-release-download-acceleration`）。
- `README.md`：给人看的说明（能力、限制、示例、门槛与跳过阶梯的时机）。
- `scripts/validate.ps1`：可复跑自检，检查 frontmatter（含 `metadata` 两个门槛值与代码一致）、围栏代码块、`openai.yaml` 字段长度与 `$skill` 引用、禁用写法（`(if …)`、`$x += 管道`、`& curl … 2>&1`）；**退出码非 0 就是文档有问题**。

**两个门槛的唯一改动点是 frontmatter 的 `metadata`**（`min_size_for_ladder_mb` / `single_conn_fast_kbps`）。PS 5.1 没有 YAML 解析器，代码不能在运行时读 frontmatter，所以第 6/7 步的 `$ladderMinMB`/`$fastKB` 各存一份，**改阈值要两处同步**；只改一边时 `validate.ps1` 报 `[FAIL] metadata… 与代码 $ladderMinMB 不一致：改阈值要两处同步` 并以 exit=1 收尾。

```powershell
$root = '<技能目录>'
# validate.ps1 必须是 UTF-8 with BOM：5.1 会把无 BOM 的 UTF-8 当 GBK 读，中文字符串里的引号被吞掉（实测 exit=1）
$b = [IO.File]::ReadAllBytes((Join-Path $root 'scripts\validate.ps1'))
"BOM=$($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)"
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\validate.ps1')
"exit=$LASTEXITCODE"
```

改阈值后必须做**反向测试**才算验证完成：只改 metadata（100→80）应 FAIL/exit=1，还原后 exit=0。写回 SKILL.md 用 `UTF8Encoding($false)`，别用 `Out-File`/`Set-Content`（5.1 会加 BOM，而验收要求 SKILL.md BOM=False）：

```powershell
$sk = Join-Path '<技能目录>' 'SKILL.md'; $v = Join-Path '<技能目录>' 'scripts\validate.ps1'
$enc = New-Object System.Text.UTF8Encoding($false)
$bak = [IO.File]::ReadAllText($sk,[Text.Encoding]::UTF8)
powershell -NoProfile -ExecutionPolicy Bypass -File $v | Select-String 'VALIDATE'; "exit=$LASTEXITCODE"
[IO.File]::WriteAllText($sk, ($bak -replace 'min_size_for_ladder_mb: "100"','min_size_for_ladder_mb: "80"'), $enc)
'--- 只改 metadata ---'; powershell -NoProfile -ExecutionPolicy Bypass -File $v | Select-String 'VALIDATE|不一致'; "exit=$LASTEXITCODE"
[IO.File]::WriteAllText($sk, $bak, $enc)
'--- 还原 ---'; powershell -NoProfile -ExecutionPolicy Bypass -File $v | Select-String 'VALIDATE'; "exit=$LASTEXITCODE"
```

DSH 是否能发现这个技能要单独验证——技能目录必须落在技能发现根里：

```powershell
$src = '<项目目录>\.dsh\skills\github-release-download-acceleration'
$dst = "$env:USERPROFILE\.dsh\skills\github-release-download-acceleration"
if (-not (Test-Path $dst)) { cmd /c mklink /J "$dst" "$src" }
```

建好 junction 后**必须用 `skill` 工具真正加载一次**（实测：junction 之前 `skill` 报 `unknown or no longer available`，建好后加载成功）；只看 `Test-Path` 为真不能证明 DSH 能加载。

### 网络全断时的离线夹具（不产生真实下载流量）

直连与 127.0.0.1:7897 都 `code=000` 时不要假装实测：用正则抽出围栏块、只验证门槛分支的语义。**完全不起 curl**（跳过分支不会调用 `Test-Ladder`，所以零流量），把断言结果如实报成「离线夹具 PASS」，不要说成「下载实测通过」。

```powershell
$skill = Join-Path '<技能目录>' 'SKILL.md'
$t  = [IO.File]::ReadAllText($skill,[Text.Encoding]::UTF8)
$ms = [regex]::Matches($t,'(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```')
"blocks=$($ms.Count)"; for ($i=0;$i -lt $ms.Count;$i++){ "{0,2}: L{1}" -f $i, (($t.Substring(0,$ms[$i].Index) -split "`n").Count) }
$b6 = @($ms | Where-Object { $_.Groups['code'].Value -match 'SKIP_LADDER' })[0].Groups['code'].Value
function Check([bool]$c,[string]$m){ if($c){"[PASS] $m"}else{"[FAIL] $m"} }
# 1) 小资产（32MB、探针 0）：必须跳过阶梯并判 winN=1
$o = & ([scriptblock]::Create('$total=32MB;$singleKB=0;' + $b6)) | Out-String
Check ($o -match 'SKIP_LADDER') '块6 小资产打印 SKIP_LADDER'
Check ($o -match 'winN=1')      '块6 小资产 winN=1'
# 2) 大资产但单连接 4200KB/s（≥3072）：同样跳过
$o2 = & ([scriptblock]::Create('$total=200MB;$singleKB=4200;' + $b6)) | Out-String
Check ($o2 -match 'SKIP_LADDER') '块6 大资产但单连接够快也跳过'
# 3) 第 7 步同一个门槛表达式（只算语义，不下载）
Check (((& ([scriptblock]::Create('$ladderMinMB=100;$total=99MB;$total -lt ($ladderMinMB * 1MB)')))) -eq $true)  '99MB 判为小资产'
Check (((& ([scriptblock]::Create('$ladderMinMB=100;$total=200MB;$total -lt ($ladderMinMB * 1MB)')))) -eq $false) '200MB 判为非小资产'
```

夹具脚本自己也必须 UTF-8 with BOM 再执行；用 `edit` 改夹具时若报 `file changed since it was read`，先 `read` 再重试。

**改完后的回归闭环**：抽全部 `powershell`/`pwsh`/`ps1` 围栏块按顺序点源执行（只替换占位行），第 2 步应打印实际命中的 `core`/`cfg`，输出不得出现 `FormatEntryData`/`out-lineoutput` 报错；再跑 `scripts\validate.ps1`，必须 `VALIDATE_OK: 0 个错误 / 0 个告警` 且退出码 0；能联网时最后对真实小资产跑一次 e2e，直到 `DOWNLOAD_VERIFIED_OK` 才收工。

## Pitfalls

- **不要假设环境。** 裸机上没有 Clash Verge、没有 aria2c/7z（实测 `Get-Command aria2c,7z` 全空），也不一定有已启动的代理；缺了就换路线，绝不 `exit` 报错或要求用户去装东西。全程只用 `curl.exe` + PowerShell。
- **不要向用户要参数。** 端口、内核路径、配置目录、仓库名都自己查；仓库名尤其不能凭产品名猜（实测按产品名猜的 `rakanki911/DLSS5-Swapper` 直接 404，真实仓库在 `app-update.yml`/`app.asar` 里），但这属于拿到 URL 前的上游工作。
- **资产名对不上必须 `ASSET_NOT_FOUND` + 候选清单，禁止静默换名。** 实测过的坏姿势：发现 `fzf-0.65.2-windows-x64.zip` 不存在后只打印 name/size 就改用 `fzf-0.65.2-windows_amd64.zip` 继续下，答案里连 `ASSET_NOT_FOUND` 都没有——用户以为下的是自己要的文件。
- **API 200 ≠ 资产名对，也 ≠ 资产可下**；**API 403 限流不是 NO_ROUTE**（有 total/digest 就继续，缺 total 用 `-r 0-0` 的 `Content-Range` 反推，digest 缺失只做字节数校验）。
- **并发不是越多越快，最优值会漂移。** 实测代理 16 段 7.7 MB/s 最优、24 段 6.0、32 段 6.3 回落；更早一次「8 段 20s 全 0 字节、4 段 1148 KB/s」。每轮现测，别背历史数字；完整率掉了或吞吐回落就退回上一档。
- **`Port open: False` 不等于代理已启用，`ProxyServer` 残留值也不等于。** 只有端口真的 Listen 且 range GET 实测有速度才算；实测 `ProxyEnable: 0` 却留着 `127.0.0.1:7897`。**测任何基线前先确认端口在监听**：只有 `TIME_WAIT`、`core_listening=False` 时跑基线得到 `bytes=0 code=000`——那不是「直连很慢」，是根本没有代理。
- **忘 `-L` 就只剩 302 和 0 字节**（资产会跳到 `release-assets.githubusercontent.com`）。**别用 `-I`/HEAD 判断资产可下**，用 `-r 0-1023` 的 GET 探测。
- **镜像必须实测，全灭很正常**（6 个里 5 个 TLS 握手超时，只剩 gh-proxy 206/119 KB/s）；探测超时给 8s、并行跑，别恋战试十几个。**镜像「快」可能是回了错误页**：排序先看 `Bytes ≥ 512KB` 再看 KB/s。
- **启动内核要显式 `-d`/`-f` 且只绑本机**：用 `clash-verge.yaml` 运行配置，`config.yaml` 只确认 `mixed-port: 7897`；不开 GUI、不写注册表、不打开 `allow-lan`。配置目录缺失或无可用节点就跳过 B，拉起空内核只会白等 15 秒。
- **旧内核配新配置会读不懂字段。** 多份安装时按 `verge-mihomo.exe` 的 `LastWriteTime` 取最新，别用候选数组第一个。候选为空是正常降级：做 FakeSort 副本（两假目录各放新旧 exe）验证应选中新的（实测 `SORT_PICK_NEWEST=True`），全空则跳过 B。
- **每段独立日志、重开前清空分片**，否则分片全 0 时无法定位卡住的段，旧文件还会混进拼装；**拼装前必须核对分片总字节数**，大小对而内容错的失败最难发现；**digest 为空时不要伪造校验**，如实说明只有字节数基准。
- **只杀自己的进程。** `Stop-Process -Name curl` 会把用户自己正在跑的下载一起杀掉；收尾和降档只能用记下的 `$curlPids`，内核只用 `$corePid`。
- **`curl` 的 `-w` 串里不要有空格**（5.1 的 `Start-Process -ArgumentList` 不加引号，含空格的参数被拆开 → `-o` 失效、响应体进 stdout、分片 0 字节）。用 `|` 分隔、`-A dsh`，或整条命令串自己加引号。
- **围栏代码块里不要混用 `Format-Table`/`Format-List`**：抽块连续执行时上一个 `format-*` 的 `FormatEntryData` 会污染下一条输出（`out-lineoutput : “...FormatEntryData”类型的对象无效`），统一用 `'{0,-28} ...' -f`。
- **别写 `$x =(if …)`**（5.1 里 `if` 是语句，报 `The term 'if' is not recognized`）：用 `$x =$(if (…) {…} else {…})`。**`$array += 管道` 要用 `@()` 包住右边**，否则优先级会吞掉结果。
- **别用 `& curl … 2>&1` 收结果**：5.1 会把原生 stderr 变成 ErrorRecord，撞上 `$ErrorActionPreference='Stop'` 就是终止错误（实测 `curl: (35) schannel: failed to receive handshake` 直接中断）。统一 `Start-Process -RedirectStandardOutput/-RedirectStandardError` 两个文件再 `Get-Content -Raw`；单流分支用 `& curl.exe @arg`（不加 `2>&1`）。
- **`--retry-all-errors` 要 7.71+**，Win10 自带 7.55 会报 `unknown option`；第 7 步先 `curl.exe -V` 取版本，低于 7.71 只保留 `--retry 3 --retry-delay 2`。
- **同一条路线在不同时刻能差两个数量级**：同日同一节点、同样 1MB 段 `14.2s = 72KB/s` 与 `0.5s = 2245KB/s` 并存，整包 16 段也从 `1355` 波动到 `6318 KB/s`。只跟同一时刻的另一条路线/另一档并发比；单次异常慢先重测一次再下结论。
- **PowerShell 变量名大小写不敏感。** 写包装/测试脚本时 `$b = $raw -split '\|'` 会盖掉 `$B`（本轮实测报 `STRIP_MISS: url`，因为 `$BLK` 被 Step 5 的 `$b` 顶掉）；中间变量加前缀区分。
- **`<100MB 单流` 与「跳过阶梯」必须是代码，不是文字。** 只在决策表写「小资产不分段」而代码仍写死 `$parts = 16`，30MB 资产就会被切成 16 份；第 7 步必须 `if ($total -lt ($ladderMinMB * 1MB) -or $parts -le 1)` 走单流，`$parts` 只能来自第 6 步的 `$winN`；「不测并发」也要真跳过，别只打印一行。
- **两个门槛写在 `metadata` 里，代码里也要有一份。** `min_size_for_ladder_mb`/`single_conn_fast_kbps` 是「测量成本 vs 收益」的取舍点，用户改头部即可；`$ladderMinMB`/`$fastKB` 必须一致，`validate.ps1` 比对两处数字，改一边忘另一边直接 FAIL（有意的冗余：5.1 没有 YAML 解析器）。
- **别为小包付出测量成本。** 阶梯 ≈ 26 秒，节点快时每遍还要下载 20+MB 采样（5.8MB/s × 4s × 6 ≈ 140MB），对 30–60MB 的包比省下的时间还贵。判据用第 5 步的 8MB 探针 `$singleKB`：≥3MB/s 或资产小于 `$ladderMinMB` 直接单流；要老行为就 `$ForceLadder = $true`。
- **阶梯结果必须喂给第 7 步。** 本轮修掉的真缺陷：`Test-Ladder` 只打印不返回、第 7 步硬编码 `$parts = 16`，于是「测了阶梯但完全没用上」，节点不限速时反而比单流慢（整包 5.8 vs 4.2 MB/s，0.72×）。函数要返回 `N/Full/KBps`，调用侧汇总出 `$winN`。
- **小段测速会把单流测冤枉。** 固定 1MB/8MB 段被建连 + 慢启动吃掉（同一节点 1MB 段 742 KB/s vs 整包单流 5829 KB/s，差 8 倍）。正确做法：每档 n 条连接同时从各自起点 open-range 读到文件尾，限同一时间窗（`-m $sec`）再比聚合 KB/s；curl 到点 exit 28 属正常。
- **单次采样噪声极大**：同一 1MB 段 72 与 2245 KB/s 并存，整包 16 段 1355–6318 波动。阶梯至少三遍取中位数并报 min–max，波动 >2× 的档位不作胜出档；多段必须快 1.25 倍，两档中位数差 10% 内选低并发。
- **Step 5 的 B 路线阈值要按资产大小算**：range `0-8388607` 对小于 8MB 的资产返回 `200` + 整个文件（实测 `got=1863156`），拿 4MB 硬阈值判断会把刚拉起来的内核误杀成「B 不可用」。
- **下载前先查盘**（分片+成品约 2 倍资产），空间不够直接换盘；**报告写实测平均速度，不要写峰值**（`speed_download` 瞬时值会被前段缓存拉高）。
- **`web_fetch` 抓 GitHub 页面可能直接 fetch failed**，别反复重试，直接用 `curl.exe` + API。
- **若用户原本就开着系统代理/已有代理进程，收尾不要关它**；只停自己拉起的内核，只删自己建的目录。
- **写技能自己的 .ps1 必须带 BOM**：`[IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))`；无 BOM 时 5.1 按 GBK 解码，中文引号被吞，`validate.ps1` 首跑就 exit=1。反向测试写回 SKILL.md 时相反：用 `UTF8Encoding($false)` 保持 BOM=False。
- **`param()` 默认值里 `$PSScriptRoot` 是空的**：不能写 `param([string]$SkillRoot = $PSScriptRoot)`，要在脚本体里 `if (-not $SkillRoot) { $SkillRoot = $PSScriptRoot }`，再用 `(Get-Location).Path` 兜底。
- **`Get-ChildItem -Filter` 只接受单个字符串**（传数组报「无法将“System.Object[]”转换为…“System.String”」）；多模式过滤用 `Where-Object Name -like`。**清理残留时别用带括号的 `-match` 正则**：本轮实测 `-match '^(ladder_|probe_...'` 少个右括号直接抛 `ArgumentException`，改用显式 `-like` 链才过。
- **`skill` 工具报 `unknown or no longer available` 是发现路径问题**，不是文件坏了：先确认技能目录在发现根内（必要时建 junction），再用 `skill` 工具实加载验证。
- TODO：若宿主已装 aria2c，可用 `aria2c -x16 -s16 --all-proxy=...` 替代手写分段，但本技能未实测该路线，暂不纳入默认流程。

## Verification

- 自检输出能一句话说清选了哪条路线、为什么，且第 3 步打印过 `asset=… total=… digest=…`（API 限流时是 `API_RATE_LIMITED` + 已知 total/digest 或 `range_probe` 反推的 total）。
- **错误路径演练**：拿真实 release 的不存在资产名（例：`fzf-0.65.2-windows-x64.zip`，真实是 `..._amd64.zip`）跑一遍，输出必须含 `ASSET_NOT_FOUND`、列出全部候选（名字 + MB）并指出最接近的一条，且**没有生成下载文件、没有进入第 4 步探测**。
- **API 限流演练**：模拟 403 + `rate limit` 时输出 `API_RATE_LIMITED`，用已知 total/digest 继续，最终仍能 `DOWNLOAD_VERIFIED_OK` 或 `DOWNLOAD_SIZE_OK_NO_DIGEST`，不得报 `NO_ROUTE`。
- 并行探测表里胜出路线 KB/s 明显高于其它（2026-10：代理 16 段 7.7 MB/s ≫ 直连 1.2 ≫ 镜像 119 KB/s），<100 KB/s 的已淘汰或明确降级说明；日志里能看到 `PORT_7897_NOT_LISTENING`（若未监听）或 `A_usable≥1`，任何 `bytes=0 code=000` 都被标成「无代理」，没拿来当单流对照。
- **门槛可配**：`SKILL.md` frontmatter 的 `metadata.min_size_for_ladder_mb` 是 `"100"`、`metadata.single_conn_fast_kbps` 是 `"3072"`，与第 6/7 步的 `$ladderMinMB=100`/`$fastKB=3072` 一致；决策表、第 6 步判定、第 7 步单流分支、Pitfalls、README 的措辞同步，全仓 grep 无残留 `60MB`/`20MB`/`1/4/16` 旧门槛。
- **改一半会被拦住**：只把 metadata 改成 80 时 `validate.ps1` 输出 `[FAIL] … 不一致：改阈值要两处同步` 且 `exit=1`；两处同步后 `VALIDATE_OK: 0 个错误 / 0 个告警`、`exit=0`；测试后 SKILL.md 已还原且 `BOM=False`。
- **小资产/快节点分支**：`$total < 100MB` 或 `$singleKB ≥ 3072` 时走单流，日志里有 `SKIP_LADDER: …`（跳过阶梯才算过）与 `SINGLE exit=0 code=200|got=<total>`，没有 `parts=` 分段行，`Get-FileHash` 与 digest 一致并输出 `DOWNLOAD_VERIFIED_OK`。
- **限速节点分支**：1/16 两档各三遍、同一时间窗，输出 `完成 n/n`、中位数、min–max 波动与 `winN=…`（无 4 段档）；限速时应判成 16，且 `$parts` 与 `winN` 一致、没有写死 16。
- **离线夹具（网络全断时）**：正则抽出全部 `powershell`/`pwsh`/`ps1` 围栏块并报出块数与起始行号；夹具在零真实下载流量下全 PASS——含 `SKIP_LADDER`（32MB）与 `winN=1`、单连接 4200KB/s 也跳过、以及 99MB→小资产 / 200MB→非小资产两档门槛断言；结束时 `validate.ps1 exit=0` 且 `%TEMP%` 下无 `ghdl_*`/`ladder_*`/`probe_*`/`meta_*` 残留。夹具 PASS 只能报成离线验证，不能当成下载实测。
- **第 2 步围栏块**：真实机器打印 `core=<实际路径> cfg=<实际路径> candidates=<n>`；未安装时 `candidates=0`、`core=` 为空属正常；FakeSort 副本验证「两份安装选最新」输出 `SORT_PICK_NEWEST=True`；非系统盘安装（如 `E:\Apps\Clash Verge`、`E:\Tools\Clash Verge`）也能命中；全仓检索可执行围栏块中写死的 `D:\Clash Verge` 命中数应为 0（说明文字示例可保留）。
- **围栏可执行性**：抽全部围栏块按顺序执行（只替换占位行），输出不含 `FormatEntryData`/`out-lineoutput` 报错；`validate.ps1` 退出码 0、`VALIDATE_OK: 0 个错误 / 0 个告警`、`SKILL.md` BOM=False。
- 若走了 B 路线：内核起来后 7897 在 `127.0.0.1` 上监听，`HKCU` 的 `ProxyEnable` 全程未被改写；若走代理路线：`curl -L --proxy http://127.0.0.1:7897 -r 0-8388607` 返回 `206` 且速度远高于直连，分片全部落在增长。
- **整包验收参考（2026-10，rclone 31,634,900 B）**：16 段 `31,634,900 B / 8.0s = 3,862 KB/s`，16 个分片全部 `206`、`MATCH_TOTAL=True`。干净对照（单流 vs 多段）要分别整包跑一次，报告耗时、平均 KB/s、相对倍数并各自做 digest 校验，不能只拿 4 秒阶梯窗口当结论。
- `p*.bin` 总字节数等于 `$total`（实测 223737114 / 31634900），拼装文件 `Length` 等于 release asset 的 `size`；`Get-FileHash -Algorithm SHA256` 与 digest hex 完全一致输出 `DOWNLOAD_VERIFIED_OK`，无 digest 时 `DOWNLOAD_SIZE_OK_NO_DIGEST` 并说明缺基准。
- `scripts\validate.ps1` 自带 BOM 且 `exit=0`、全项 `[ OK ]`；`agents/openai.yaml` 的 `short_description` 在 25–64 字符内、`default_prompt` 含 `$github-release-download-acceleration`；`README.md` 存在且门槛措辞与 SKILL.md 一致。
- `skill` 工具能真正加载 `github-release-download-acceleration`（不是只看目录存在）；收尾后 7897 不再监听、`Get-Process verge-mihomo` 无本次残留、`ProxyEnable` 与开始时相同、临时目录已删、用户的其它 curl 进程没被波及（只按 `$corePid`/`$curlPids` 停）。
