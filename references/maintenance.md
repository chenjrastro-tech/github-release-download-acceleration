# 维护施工法与发布自查

> 本文件是 `SKILL.md` 的维护附录；运行时代码仍以 `references/runner-steps.md` 为准。

### 施工法 A：SKILL.md 逼近 65,536 字节时怎么拆（逐字可复跑）

以 2026-10 这次拆分为样本：65,383 → 35,980 字节，11 个 `powershell` 块搬到 `references/runner-steps.md`，`ghdl.ps1` 只有头部注释变化。

1. **先量字节与行数，再按体积排序**，确认唯一超标的是 SKILL.md：

    ```powershell
    (Get-Item SKILL.md).Length
    # 不要用裸 Get-Content：PS 5.1 读无 BOM 的 UTF-8 会按 ANSI 解码，行数会算错
    [IO.File]::ReadAllLines((Resolve-Path SKILL.md)).Count
    Get-ChildItem -Recurse -File |
      Where-Object { $_.Extension -in '.md','.ps1','.sh','.json','.yml','.py' } |
      Sort-Object Length -Descending |
      Select-Object -First 12 Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}
    ```

    实测拆前 65,383 字节 / 862 行，余量 153 字节；另一次 65,482 → 65,522 只剩 14 字节。**余量小于 2 KB 就先拆再加字**，不要靠删校验步骤腾地方。

2. **数围栏块再动手**：用多行正则（`(?ms)`，捕获语言与代码组）逐块打印「语言 / 字节 / 所在小节」。实测 SKILL.md 里 0–10 步是 11 个 `powershell` 块（31,591 字节），`sh` 最小版 1 块（3,386 字节）留在正文。**只搬 powershell 运行时代码，步骤说明、判定和错误表留在原位。**

3. **搬进 references/ 并在原位留指针**：每块前加 `## 块 N · <小节标题>`；SKILL.md 原位留一行 `（运行时代码：references/runner-steps.md 块 N。要执行直接用 scripts\ghdl.ps1，不必手工复制这段脚本。）`。搬移脚本的坑：Python 命名组写 `(?P<code>...)`，照抄 .NET 的 `(?<code>...)` 会直接 `re.error`。
    - 搬完 `git diff SKILL.md` 只核两件事：删掉的是代码块、保留的是说明与指针；指针行数 = 搬走块数（实测 11 行）。

4. **生成器跟着新真源走，GENERATE_MISS 不能丢**：`scripts/build-runner.ps1` 的输入改为 `references/runner-steps.md`，三处替换点匹配不到就 `throw "GENERATE_MISS: …"`。改完先用旧结构试一次，必须看到 `GENERATE_MISS`——本窗口正是靠它发现切片写成 `blocks[1:12]`（应为 `blocks[0:11]`）。
    - 正确生成时日志是 `GENERATED: …ghdl.ps1 (31,899 bytes, 514 lines, 12 blocks)`；后来加功能变 33,163 bytes / 535 lines，但块数恒为 12。与提交版比只有头部两行注释（「从 SKILL.md 生成」→「从 references/runner-steps.md 生成」）不同，`git diff scripts/ghdl.ps1` 里没有逻辑行。

5. **validate 双处扫 + 同步断言**：围栏的语法与 5.1 兼容检查同时遍历 `SKILL.md` 与 `references/runner-steps.md`；新增 `build-runner.ps1 -Check`（非 0 就 FAIL）、`references/runner-steps.md` 块数 ≥ 11、SKILL.md 体积余量。期望输出里有「ghdl.ps1 与 references/runner-steps.md 同步」「references/runner-steps.md 有 11 个 powershell 块」；末尾当前是 `VALIDATE_OK: 0 个错误 / 0 个告警`（frontmatter 只留 name/description/metadata；维护触发已并入 description；SKILL.md 拆出维护附录后约 42KB，已低于 48KB，再涨过线才会多一条体积告警）。

6. **全仓扫旧引用再改文案**：

    ```powershell
    Select-String -Path SKILL.md,README.md,scripts\*.ps1 -Pattern 'build-runner|references/|65,536|65536|64 ?KB'
    ```

    「从本文件的围栏块生成」、README 目录树缺 `references/`、「18 条」这类旧话要一起改；断言条数以实测为准（sh 26 条 / ps1 84 条）。

7. **收尾闸（缺一不算完）**：

    ```powershell
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-runner.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    bash tests/run-tests-sh.sh        # Windows 上先设 PYTHON=<真实 python3>
    node --test tests/index.test.mjs   # 技能 provider 单测，6/6
    ```

    期望顺序：`GENERATED` → `VALIDATE_OK` → `TESTS_OK: 84 项通过` → `TESTS_SH_OK: 26 项通过` → Node `pass 6 / fail 0`；再跑 `build-runner.ps1 -Check` 拿 `GENERATE_OK: runner 与 references/runner-steps.md 同步`。拆分不改下载逻辑，套件失败先查环境（`PYTHON` 未设、`bash` 不在 PATH），别急着改代码——本窗口 sh 套件唯一一次失败就是没设 `PYTHON`。

8. **BOM 与 LF 是两条独立红线**：`scripts/*.ps1`、`tests/*.ps1` 必须带 BOM；`SKILL.md`、`references/*.md`、`*.sh` 不能带 BOM 且全文 LF。用字节回读验证（前 3 字节是否 `EF BB BF`、`\r\n` 计数是否为 0），不要只看编辑器显示。

### 施工法 B：ghdl.sh 与 ghdl.ps1 对齐验收（逐项可复跑）

对齐不是把 ps1 逐行翻译成 sh，而是下面五项在两侧日志里都能被看见：

| 能力 | 验收判据（两侧都要有日志证据） |
| --- | --- |
| 阶梯 | 1/16 两档各 3 遍、**交错**执行取中位数；必须 `16/16` 完成且 16 段 ≥ 1.25× 单段才分段，否则单流 |
| 并发 | 单连接被限速直接拉满；否则 4→8→16，打印 `RAMP_UP: workers=…`，出现 2 段卡住打印 `BACKOFF` |
| 进度 | 每 3–4 秒一行 `progress=…MB/…MB (…%) running=… rate=…KB/s`（ps1 3 秒、sh 4 秒）；sh 静默 >15 秒视为卡死 |
| 端口 | 20 个候选端口并行发起、最多等 3 秒再按优先级挑；串行每口约 2 秒（xtrace 实测 20 口 48.4s → 并行 9.4s） |
| 自愈/校验 | 坏段只重下该段；`SEGMENT_SIZE_MISMATCH` 保留分片；SHA256 降级链输出纯 hex；按后缀冒烟 |

改 `ghdl.sh` 的施工方式（sh 没有安全的手工编辑余量）：

1. **一律用 Python 锚点补丁脚本，不手改**：`io.open(p, encoding='utf-8', newline='')` 读入，先 `assert '\r\n' not in s`；每处替换写 `old = '''…'''`，`if old not in s: print('MISS <名字>'); sys.exit(1)`；写回后再回读断言新片段存在。MISS 就是「代码没改」，不是「也许改了」。
2. **MISS 后先停套件再重切片**：补丁 MISS 时正在跑的套件用的还是旧代码——先 kill 后台任务，再按前后两个稳定标记重新切片（不要按行号）。本窗口 `MISS ramp block` 后白跑 10 分钟才被发现；示例切片：从 `started=0\n  limit=4` 到 `# 进度：每 3 秒一行`。
3. **每次改完先 `bash -n scripts/ghdl.sh`**（`syntax_exit=0` 才继续）；Windows 上 `bash` 不在 PATH，要写全路径（如 `D:\...\Git\bin\bash.exe`），别直接调 `bash`。
4. **裸 `wait` 必须改成只等 worker pid**：分段 worker 之外还有进度报告器，裸 `wait` 等全部子进程 → 报告器等 busy 文件消失、主流程等 wait，实测挂死 >10 分钟被 kill。改成 `for p in $wpids; do wait "$p"; done`（只在 `$wpids` 非空时执行）。
5. **进度采样用一次 `du`，不要 16 次 `wc -c`**：逐个 `wc` 会被正在写的分片拖住（Windows 共享冲突时还能让进度线程被 `set -e` 杀掉），短下载（<5 秒）几乎采不到点；改成 `du -sk "$TMPD"` 一次遍历。
6. **curl 部分成功（rc=28）先取第一行再解析六列**：`out=$(curl … || echo '000|0|0')` 在「收到一部分后超时」会追加第二行，六列错位（实测选错路线、代理字段变 `0.0.0.0`）。正确写法 `out=$(curl …) || true`，再取第一行解析。
7. **测试夹具 TcpListener 要设 SendTimeout/ReceiveTimeout**：`tests/serve.ps1` 只设 `ReceiveTimeout` 不够，半开连接会卡死串行夹具，表现为「同一 OutDir 并发两个资产」两项都没有 exit code；给每个连接补 `SendTimeout` 后 ps1 套件 46/46。
8. **收尾判据**：日志里要有 `RAMP_UP`/`BACKOFF`/`progress=` 行、`engine_done=… elapsed=…`、`TESTS_SH_OK: 26 项通过`、`TESTS_OK: 84 项通过`；光 exit=0 不算对齐。sh 套件有时序，改完连跑 5 次都绿再收工。

### 发布自查：一个版本「发全」要四份证据

1. **tag 在远端**：`git ls-remote --tags origin` 与本地 `git tag --list` 对比 commit；或 `curl.exe -sS -H 'Accept: application/vnd.github+json' https://api.github.com/repos/<owner>/<repo>/git/refs/tags/<tag>`，确认指向 HEAD 同一提交。
2. **GitHub Release 本体**：`…/releases/tags/<tag>` 里 `draft=false`、`prerelease=false`、`published_at` 非空；「发布页能打开」不算证据。
3. **npm（若该版本也发布到 npm）**：从仓库 `package.json` 读 `name`，再 `npm view <name> dist-tags --json` 核 `latest`、`npm view <name> time --json` 核发布时间；命令与包名以仓库实际为准，别拿技能名硬套。
4. **CI 可追溯**：`gh run list --limit 3 --json databaseId,headSha,status,conclusion` 找到 `headSha` 等于该 tag 提交的 run，`conclusion=success`；插件市场目录（awesome-dsh-plugin / dsh-market）滞后一天属正常，不作为未发布证据。
