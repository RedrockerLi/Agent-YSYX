# EDA 工具链与物理设计环境 (EDA Toolchain & Physical Design Environment)

本仓库的 RTL 仿真、四值仿真、门级网表仿真、逻辑综合、静态时序分析与后端物理设计统一运行在自带的 Docker 镜像中。本文记录工具版本、各工具在流程中的职责、命令入口以及后端工程布局。针对具体设计 `cpu_top` 的综合 PPA、门级仿真与 P&R 实测结果记录在 [CPU 基线报告第五章](../cpu/baseline.md#五芯片物理实现与后端验证基线-physical-design--silicon-verification)，不在本文档中重复。

---

## 一、运行环境

- **镜像**：仓库根目录 `Dockerfile` 构建的 `ysyx` 镜像（Ubuntu 22.04），预装交叉编译链、Verilator、Icarus Verilog、Yosys 与 ECC 物理设计环境。
- **构建与启动**：

  ```bash
  docker build -t ysyx .
  docker run --rm -it --net=host -v "$PWD":/workspace ysyx
  ```

- 所有仿真、综合、STA 与 P&R 命令均在容器内的工程根目录执行（见 `AGENTS.md`）。宿主机只承担文件编辑与 Git 操作。
- 工具路径可通过环境变量或 make 参数覆盖，例如 `make <target> ECC=/custom/ecc ICSPROUT55_HOME=/custom/pdk`。

## 二、工具版本

| 组件 | 版本 | 用途 |
|---|---|---|
| ECC | 0.1.0-alpha.12（CLI 0.1.0a12） | 物理设计流程编排、workspace/step 管理、签核产物导出 |
| Yosys | 0.68+132 | 逻辑综合，RTL → 标准单元门级网表 |
| ecc-tools / iSTA | 0.1.0a13 | 静态时序分析与功耗分析 |
| DreamPlace | 0.1.0a7 | 全局布局与合法化 |
| Sizer | 0.1.0-alpha | 时序优化（缓冲器插入与门级 sizing） |
| KLayout | 0.30.2 | 版图与 GDSII 处理 |
| PDK | icsprout55 v1.10.102（`ics55_LLSC_H7C_V1p10C100`） | 55nm 标准单元库、LEF/Liberty、金属互连 RC 技术文件 |
| Verilator | v5.008 | 周期级 RTL 仿真与 DiffTest |
| Icarus Verilog | 镜像 apt 版本（未固定） | 四值仿真与门级网表仿真 |

## 三、流程工具链组成

物理设计流程由 ECC 统一调度，各步骤调用对应工具：

```text
RTL ──Yosys──> 门级网表 ──DreamPlace──> 布局/合法化 ──ECC CTS──> 时钟树
      │                                                      │
      ├──iSTA（后综合 STA）                                   ├──Sizer──> 时序优化
      │                                                      ├──ECC Route──> 详细布线
      │                                                      ├──RCX──> SPEF/寄生参数
      │                                                      └──iSTA（MCMM 后布线 STA）
      └──Icarus Verilog + VPI（四值 / 门级网表仿真）
```

- **ECC preset**：后端工程使用 `rtl2gds` 完整流程；快速迭代使用 `syn_sta` preset，只包含 `Synthesis` 一步并在综合后执行一次 iSTA。
- **PDK 根目录解析优先级**：`ICSPROUT55_HOME` 环境变量 → `ecc pdk show` 查询结果。两者都为空时，`ecc.toml` 不写入 PDK 根路径，由 ECC 按 `pdk.name = "ics55"` 解析。

## 四、命令入口

### 4.1 仿真

| 命令 | 作用 |
|---|---|
| `make sim` / `make -C npc sim` | Verilator 编译 RTL 仿真器 |
| `make -C npc run IMG=<bin>` | 运行 Verilator 仿真（DiffTest 参考模型存在时自动启用） |
| `make test` | 35 个 cpu-tests 批量运行（Verilator + DiffTest） |
| `make -C npc sim-iverilog` | 编译 Icarus Verilog 四值仿真程序与 `vpi_pmem.vpi` 插件 |
| `make -C npc run-iverilog IMG=<bin>` | 运行单个四值仿真用例 |
| `make test-4state-all` | 批量运行四值仿真 |
| `make -C npc sim-netlist-iv` | 编译门级网表与标准单元行为模型 |
| `make -C npc run-netlist-iv IMG=<bin>` | 运行门级网表仿真 |

### 4.2 综合、STA 与后端

| 命令 | 作用 | 是否签核 |
|---|---|---|
| `make synth`（等价 `make -C npc pnr-synth`） | Yosys 综合 + 后综合 iSTA，输出 QoR 报告 | 否 |
| `make pnr` | 一键执行 RTL-to-GDSII 全流程，结束后自动导出签核包 | 签核产物 |
| `make pnr-<step>` | 单步执行：`floorplan`、`place`、`cts`、`legalize`、`opt`、`route`、`filler`、`rcx`、`sta`、`lvs`、`drc`、`harden` | 视步骤而定 |
| `make signoff` | 导出 GDSII、LEF、DEF、SDF、网表与报告 | 签核产物 |
| `make sta-fast [FREQ_MHZ=<n>]` | 快速综合 + 后综合 STA，面向 RTL 迭代 | 否 |

快速 STA 的适用范围、产物与限制见 [快速 STA 使用说明](sta_fast.md)。

## 五、后端工程布局

`make pnr-synth` 首次运行时生成 `npc/build/backend/` 工程：

```text
npc/build/backend/
├── ecc.toml        # 设计、PDK 与流程配置
├── project.json    # ECC 工程清单
└── default/        # workspace：按步骤保存中间结果与报告
```

`ecc.toml` 的固定字段：

| 字段 | 值 |
|---|---|
| `design.name` / `top` | `cpu_top` |
| `clock_port` | `clock` |
| `frequency_mhz` | `100.0`（固定；快速 STA 使用独立的 `backend_fast/ecc.toml`，由 `FREQ_MHZ` 覆盖） |
| `pdk.name` | `ics55` |
| `flow.preset` | `rtl2gds` |

Workspace 内的步骤顺序由 ECC 流程定义：`Synthesis` → `lec` → `Floorplan` → `place` → `CTS` → `legalization` → `Timing optimization` → `route` → `filler` → `RCX` → `sta` → `lvs` → `postRouteLec` → `drc` → `Harden`。Makefile 在生成工程时把 `lec` 预置为 `Success`（bypass）；`postRouteLec` 检查综合网表与后布线网表的一致性。

主要产物：

- 综合网表：`default/Synthesis_yosys/output/<top>_Synthesis_sim.v`（同时保留 `.gz` 压缩副本）
- 综合报告：`default/Synthesis_yosys/report/post_synthesis/qor_summary.rpt`
- 后布线寄生参数与 SDF：由 `RCX`、`sta` 步骤生成
- 签核包：由 `make signoff` 导出，包含 GDSII、LEF、DEF、SDF、网表及各类报告

## 六、分析条件

- **后综合 STA**：单角分析，SS、1.08V、125℃、RCworst（`ICS_N55_H7BR_ss_mos_RCworst_1.08_125`），不读 SPEF，采用 ZeroWireload 模型。
- **后布线 MCMM STA**：在 Process（SS/WCL、TT/TYP、FF/MIN、FF/ML）× Voltage（1.08V ~ 1.32V）× Temperature（-40℃ ~ 125℃）× Interconnect RC（Cbest、RCbest、TYPICAL、Cworst、RCworst）组合成的 13 个工艺角上签核。具体角组合与实测数据见 CPU 基线报告的 5.4 节。
- **快速 STA**：固定 SS 单角，无布局、布线与 RC 抽取，只用于判断关键路径方向和相对改善。

## 七、使用注意

- 后综合 STA 使用 ZeroWireload、未插入缓冲树，绝对 WNS 偏乐观，不能作为签核结论；是否收敛以后布线 13 角结果为准。
- `make pnr` 与完整 STA 的内存和耗时远高于 RTL 仿真，建议单独运行，避免与其他大内存任务并发。
- `make signoff` 只负责导出，不改变流程状态；setup 未收敛时导出的仍是未收敛数据。
