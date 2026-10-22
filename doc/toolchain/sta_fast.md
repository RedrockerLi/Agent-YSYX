# 快速 STA 使用说明 (Fast STA)

`make sta-fast` 是面向 RTL 迭代的轻量时报流程：只做 Yosys 综合 + 后综合 iSTA，不进入布局、布线、RCX 或多工艺角签核。它用于判断关键路径方向和相对改善，不是签核结果。

## 命令

```bash
# 默认 100MHz
make sta-fast

# 指定目标频率（会重新综合）
make sta-fast FREQ_MHZ=150

# 清理快速 STA 的项目和运行记录（不影响 build/backend/ 的完整流程）
make sta-fast-clean
```

`make sta-fast` 在 Docker 容器内运行（遵循 `AGENTS.md`）：

```bash
docker run --rm -it --net=host -v "$PWD":/workspace ysyx
cd /workspace
make sta-fast FREQ_MHZ=100
```

## 它做什么

1. 生成独立的快速项目：`npc/build/backend_fast/ecc.toml` 和 `project.json`。
2. 使用 ECC 的 `syn_sta` preset：只包含 `Synthesis` 一步，综合后自动跑一次 iSTA。
3. 分析角固定为 SS、1.08V、125C、RCworst（H7CL + H7CR Liberty），不读 SPEF。
4. 不创建 `Floorplan_ecc`、`place_dreamplace`、`CTS_ecc`、`route_ecc`、`RCX_ecc` 等目录。
5. 每次运行用 `--overwrite` 重建 `fast` workspace，避免 `origin/` 中的旧 RTL/SDC。

完整的物理设计流程（`pnr`、`pnr-synth`、`pnr-<step>`、`signoff`）不受影响，仍使用原来的 `npc/build/backend/` 和 `default` workspace。

## 输出

每次运行写到：

```
npc/build/sta_fast/<run_id>/
├── run.log          # ECC 完整日志
├── time.txt         # elapsed_s（镜像无 /usr/bin/time 时无 maxrss）
├── summary.txt      # 解析后的 WNS/TNS/top path 摘要
└── manifest.json    # WNS/TNS/top paths、哈希、耗时
```

后综合 STA 报告：

```
npc/build/backend_fast/fast/Synthesis_yosys/report/post_synthesis/qor_summary.rpt
npc/build/backend_fast/fast/Synthesis_yosys/feature/post_synthesis/timing_paths.json
```

`manifest.json` 的关键字段：

| 字段 | 含义 |
|---|---|
| `wns_ns` / `tns_ns` | 报告中的 WNS/TNS（解析失败时为 null） |
| `top_paths` | 按 slack 升序的前 10 条路径（start/end/slack/delay/logic_levels） |
| `rtl_sha256` | `npc/vsrc/*.v` 的哈希（不含 `sim_top.v`） |
| `origin_rtl_sha256` | ECC workspace `origin/` 中实际 RTL 的哈希 |
| `origin_mismatch` | 两者不一致时为 true，表示可能测了旧 RTL |
| `frequency_mhz` | 本次综合/STA 使用的目标频率 |
| `elapsed_s` | 本次运行总耗时（含综合） |
| `report` / `feature` | 报告路径，优先写相对仓库根目录的路径 |

## 实测（本机 Docker，100MHz）

- 总耗时约 25min（本机实测 `elapsed_s=1461–1502`，含综合；STA 本身远小于此）。
- STA 阶段实测 ECC 进程 RSS 约 20GB（`flow.json` 记录的 Synthesis peak memory 约 1.6GB）；建议在 30GB 内存的机器上单独运行，避免与其他大内存任务并发。
- 综合后 SS 角：WNS **-24.255ns**、TNS **-2180.2ns**、Fmax 估计 **29MHz**、hold WNS **+0.213ns**、NVP 509。
- 最差路径：`ex_mem_is_jal_jalr_reg_p:Q -> io_lsu_addr[30]_reg_p:D`，slack -24.255ns，259 个组合单元级。
- 这些数值与 [CPU 基线报告 5.2 节](../cpu/baseline.md#52-icsprout55-逻辑综合与-ppa-评估-asic-synthesis--ppa-metrics)中记录的综合后 SS 角数据一致。

## 限制

- **不是签核**：没有布局/布线 RC、没有 SPEF、没有 13 角、没有 hold 签核。绝对 WNS 偏乐观。
- **综合时间另计**：RTL 改动后要重新综合，按当前设计约 30–60min；只看 STA 部分是分钟级。`elapsed_s` 记录的是含综合的总时间。
- **只有 SS 角**：TT/FF 角需要完整后布线 STA。
- **不适合判断收敛**：后综合到后布线的偏移会随关键路径类型变化；是否收敛用完整 13 角结果判断。

## 快速验收

```bash
# 1) 成功完成
make sta-fast FREQ_MHZ=100
cat npc/build/sta_fast/<run_id>/manifest.json

# 2) 没有进入 P&R/RCX
find npc/build/backend_fast/fast -maxdepth 1 -type d | sort
# 期望只有 Synthesis_yosys 以及 ECC 管理目录，没有 Floorplan_ecc/place_dreamplace/route_ecc/RCX_ecc

# 3) 频率约束生效
grep -n "create_clock\|clk_period" npc/build/backend_fast/fast/origin/cpu_top.sdc
```

同 RTL/PDK/ECC 版本、100MHz 约束下，后综合 SS 角的 WNS 应接近 `-24.255ns`、TNS 接近 `-2180.2ns`；偏差大时先检查 `origin_mismatch`、`frequency_mhz` 和 ECC/PDK 版本。
