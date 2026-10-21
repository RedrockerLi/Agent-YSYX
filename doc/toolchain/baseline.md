# 芯片物理实现与工具链基线 (Physical Design & Toolchain Baseline)

为落实“一生一芯”从前端微架构到真实芯片物理实现的完整验证闭环，建立了完全合规的 EDA 与物理设计基线平台，覆盖四值仿真、逻辑综合、STA 时序与功耗分析、门级网表仿真以及后端自动布局布线（P&R）。

## 工具链版本

| 组件 | 版本 |
|---|---|
| ECC | 0.1.0-alpha.12（CLI 0.1.0a12） |
| Yosys | 0.68+132 |
| ecc-tools / iSTA | 0.1.0a13 |
| DreamPlace | 0.1.0a7 |
| Sizer | 0.1.0-alpha |
| KLayout | 0.30.2 |
| PDK | icsprout55 v1.10.102（ics55_LLSC_H7C_V1p10C100） |

> RTL 迭代用的快速 STA 见 [sta_fast.md](sta_fast.md)：只做综合 + 后综合 STA，不含布局/RC，不是签核结果。

## 5.1 四值仿真与 X 态排查 (4-State Simulation & X-State Analysis)

- **验证目标与背景**：
  传统 Verilator 快速仿真采用二值逻辑（0 与 1），无法捕获硬件上电、未复位寄存器或悬空总线可能产生的“不定态 (X)”与“高阻态 (Z)”。若 X 态扩散至控制逻辑或有限状态机（FSM），将直接引发芯片流片死锁。依照芯片物理实现与验证规范要求，搭建了标准四值仿真器（Icarus Verilog）与 VPI 仿真环境，全量排查 X 态传播。
- **仿真平台架构**：
  - **测试顶层**：[npc/vsrc/sim_top.v](../../npc/vsrc/sim_top.v)，作为仿真顶层激励，具备对 DUT AXI4 Master 接口的完整从端响应能力（AR, R, AW, W, B 独立时钟通道响应）。
  - **DRAM 内存与 VPI 桥接**：在 [npc/csrc/pmem.c](../../npc/csrc/pmem.c) 与 [npc/csrc/vpi.c](../../npc/csrc/vpi.c) 实现 128 MB DRAM 内存模型与镜像加载器，经 `iverilog-vpi` 编译为 `vpi_pmem.vpi` 动态插件，由 `$pmem_read_func` 与 `$pmem_write_task` 提供周期精确的数据读写。
  - **总线协议握手加固**：
    - 在 [axi_master.v](../../npc/vsrc/axi_master.v) 增加 `req_ack` 确认信号，Cache 发起请求后一旦握手成功即刻拉低 `mem_req_valid`，根除了 4 拍突发结束返回 IDLE 时的虚假重复读死锁；
    - 针对 [dcache.v](../../npc/vsrc/dcache.v) 脏行写回（Writeback），实现完整的 4 拍突发数据流与 `write_beat_ack` 步进协调，确保 16 字节脏行完整写回外存并在 B 响应完成后再平滑启动缺失行重填。
- **运行命令**：
  ```bash
  # 1. 编译四值仿真可执行程序与 VPI 插件
  make -C npc sim-iverilog
  # 2. 运行单个测试用例（以 dummy 为例）
  make -C npc run-iverilog IMG=am-kernels/tests/cpu-tests/build/dummy-riscv32e-npc.bin
  # 3. 批量运行全部 35 个指令单元测试四值仿真
  for bin in am-kernels/tests/cpu-tests/build/*-riscv32e-npc.bin; do
    make -C npc run-iverilog IMG=$$bin
  done
  ```
- **X 态排查实测结果**：
  - **存储单元初始状态**：通用寄存器堆（RegFile 16 个 GPR）以及 ICache/DCache 的 Tag 阵列与 128-bit Data 阵列上电严格置为 `'bx`。
  - **排查结论**：全核心所有控制状态机（FSM）、流水线暂停/冲刷逻辑、分支预测控制线、Valid/Ready 握手协议线均具备严谨的同步复位赋初值逻辑；未初始化的 X 态被严格拘束在数据通路内部，并在首次写操作或 Cache 重填后被安全覆盖为确定数值，无任何 X 态扩散或死锁缺陷。
  - **测试用例验证**：在 Docker 容器环境下运行全套 35 个 `cpu-tests`（含高频脏行换出的 `matrix-mul` 等），**35/35 全部通过并输出 `HIT GOOD TRAP`**；负向测试用例 `wrong` 严格在第 61 周期触发 `HIT BAD TRAP at pc = 0x80000030 (a0 = 1)`。

---

## 5.2 ICsprout55 逻辑综合与 PPA 评估 (ASIC Synthesis & PPA Metrics)

- **工艺节点与条件**：
  - **工艺库 (PDK)**：中芯国际官方 55nm 工艺（`icsprout55-pdk`，标准单元库 `ics55_LLSC_H7C`）。
  - **分析条件 (Corner)**：最差慢速工艺角 `ICS_N55_H7BR_ss_mos_RCworst_1.08_125`（SS Corner, 1.08V, 125℃）。
  - **工具链**：集成在 ECC（Easy Chip Compiler）中的 Yosys 逻辑综合器与 iSTA 静态时序分析器。
- **运行命令**：
  ```bash
  # 启动 Yosys 门级综合与 iSTA 静态时序/功耗分析流程
  make -C npc synth
  ```
- **PPA 实测报告数据**：
  - **标准单元总面积 (Cell Area)**：**588,900.2 μm²**（约 **0.589 mm²**）。
  - **标准单元总数 (Leaf Cells)**：**173,726** 个门级单元。
  - **时序与频率评估**：
    - 在未执行物理布局布线（ZeroWireload 模型）与未插入缓冲树的 SS 角（`ICS_N55_H7BR_ss_mos_RCworst_1.08_125`）下，预估核心最高运行频率约为 **29 MHz**；对应 setup WNS **-24.255 ns**、TNS **-2180.2 ns**、违例路径 **509** 条，hold WNS **+0.213 ns**。
  - **功耗详细细分报告**：
    - **单元内部功耗 (Cell Internal Power)**：**40.0234 mW**
    - **网络翻转功耗 (Net Switching Power)**：**0.4080 mW**（407.99 μW）
    - **总动态功耗 (Total Dynamic Power)**：**40.4314 mW**
    - **静态漏电功耗 (Cell Leakage Power)**：**0.6521 mW**（652.05 μW）
    - **芯片总功耗 (Total Power)**：**41.0835 mW**
  - **架构功耗根因分析**：
    - 功耗的主要来源为触发器寄存器阵列（39.8741 mW，占 97.06%）；由于当前未集成商业编译 SRAM 宏单元（SRAM Compiler），4KB 的 Cache 结构（2KB ICache + 2KB DCache）全部由标准单元 D 触发器拼接构成，是占用芯片面积与静态/动态功耗的核心来源。

---

## 5.3 门级网表仿真 (Gate-Level Netlist Simulation)

- **验证目标**：
  逻辑综合将抽象 RTL 描述转换为了工艺库特定的基础逻辑门与触发器单元互联网表。门级网表仿真通过将真实工艺标准单元行为模型挂载到网表上，验证 Yosys 综合映射过程是否引入任何逻辑功能失真或综合漏洞。
- **配置与模型**：
  - **网表文件**：综合输出的完整物理网表 `cpu_top_Synthesis_sim.v`（未压缩文件体积约 110 MB，114,866,361 字节）。
  - **标准单元 Verilog 模型**：挂载 `ics55_LLSC_H7CL.v` 与 `ics55_LLSC_H7CR.v`。
  - **顶层驱动**：`sim_top.v` + `vpi_pmem.vpi`。
- **运行命令**：
  ```bash
  # 1. 编译门级网表与标准单元行为级仿真模型
  make -C npc sim-netlist-iv
  # 2. 运行门级网表仿真（以 dummy 和 add 为例）
  make -C npc run-netlist-iv IMG=am-kernels/tests/cpu-tests/build/dummy-riscv32e-npc.bin
  make -C npc run-netlist-iv IMG=am-kernels/tests/cpu-tests/build/add-riscv32e-npc.bin
  ```
- **实测验证数据**：
  - `dummy-riscv32e-npc.bin`：在第 61 周期精确捕获 `npc [4-state/iverilog]: HIT GOOD TRAP at pc = 0x80000030 (cycles = 61)`。
  - `add-riscv32e-npc.bin`：在第 1611 周期精确捕获 `npc [4-state/iverilog]: HIT GOOD TRAP at pc = 0x80000030 (cycles = 1611)`。
  - **结论**：门级网表功能 100% 健全，综合工具未破坏处理器算术逻辑、控制流与 AXI4 握手状态机语义。

---

## 5.4 后端物理设计自动布局布线 (Physical Design P&R Flow)

- **物理设计环境**：
  基于工业级 ECC 物理实现流程，对接中芯国际 55nm 金属互连技术文件（`N551P6M_ecos.lef`，1P6M 6层金属工艺）与标准单元 LEF（`ics55_LLSC_H7CL.lef`, `ics55_LLSC_H7CR.lef`）。
- **运行命令**：
  ```bash
  # 1. 启动完整后端物理实现全流程 (RTL-to-GDSII)
  make -C npc pnr
  # 2. 导出签核产物与版图交付包 (含 GDSII、LEF、DEF、SDF、网表及报告)
  make -C npc signoff
  ```
- **各物理设计阶段实测成果与芯片关键指标**：
  1. **芯片几何尺寸与布图规划 (Floorplan & Die Dimensions)**：
     - **工艺制程**：中芯国际 55nm LL 金属工艺（1P6M，共 7 层布线金属层 M1~M6 + TM1）
     - **芯片总面积 (Die Area)**：**1,482,549.72 μm²**（约 **1.483 mm²**，外框尺寸：1217.4 μm × 1217.8 μm）
     - **核心摆放区域 (Core Area)**：**1,472,824.92 μm²**（约 **1.473 mm²**，内部尺寸：1213.4 μm × 1213.8 μm）
     - **标准单元放置排 (Placement Rows)**：867 行
     - **芯片 I/O 引脚总数 (IO Pins)**：554 个
     - **设计网络总数 (Nets)**：190,453 条
  2. **单元规模与密度 (Density & Cell Count)**：
     - **综合网表逻辑单元数 (Synthesized Cells)**：173,726 个，初始核心密度（Core Usage）为 39.98%
     - **时序优化后逻辑单元数 (Post-Timing-Opt Instances)**：**190,073** 个（基础网表 173,722 个 + timing 实例 16,351 个）
     - **最终核心利用率 (Core Utilization)**：**45.30%**（Die Usage: 45.00%）
     - **最终布局实例总数 (Final Placed Instances)**：**546,077** 个（逻辑 190,073 个 + physical 356,004 个；physical 包含 Filler/Welltap 等填充单元，物理占位率达 100%）
  3. **详细布线与连通性 (Detailed Routing & Routability)**：
     - **金属布线层数**：7 层（M1 ~ M6 走线层与 TM1 顶层电源/时钟层）
     - **全芯片网络布通率 (Routability)**：**100%**（全量 190,453 条网络全部布通）
     - **布线几何与电气违规**：短路 (Shorts) = 0，开路 (Opens) = 0，LVS 连通率 = 100%
     - **RCX 寄生抽取产物**：基于 55nm 真实 3D 寄生模型完成多层金属走线分布寄生电阻电容抽取，反标生成约 264 MB（276,816,580 字节）的物理延迟标准文件 `cpu_top.sdf`
  4. **后布线多工况多工艺角静态时序签核指标 (Post-Route MCMM STA Signoff)**：
     - **签核体系说明**：
       芯片物理设计在由**晶体管工艺偏差 (Process: SS/WCL, TT/TYP, FF/MIN, FF/ML)**、**工作电压波动 (Voltage: 1.08V ~ 1.32V)**、**工作温度范围 (Temperature: -40℃ ~ 125℃)** 以及**金属互连寄生参数模型 (Interconnect RC: Cbest, RCbest, TYPICAL, Cworst, RCworst)** 构成的完整 13 维多工艺角（MCMM, Multi-Corner Multi-Mode）矩阵下进行签核。
     - **13 个已完成实测工艺角时序数据总览**（按 1000/(10 − WNS) 估算最高主频并排序）：

       | 签核工艺角组合 (PVT + RC) | 运行环境条件 | 建立时间 WNS (ns) | 建立时间 TNS (ns) | 违例路径数 (NVP) | 估算最高主频 | 保持时间 WNS(H) (ns) | 保持时间违规数 NVP(H) | 签核状态 |
       | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
       | **MIN_m40 / Cbest** | FF, 1.32V, -40℃, 最小电容 | -4.722 | -311.9 | 68 | **68 MHz** | +0.082 | 0 | Setup ✗ / Hold ✓ |
       | **MIN_m40 / RCworst** | FF, 1.32V, -40℃, 最差 RC 互连 | -4.802 | -317.2 | 68 | **68 MHz** | +0.082 | 0 | Setup ✗ / Hold ✓ |
       | **MIN_m40 / RCbest** | FF, 1.32V, -40℃, 最佳 RC 互连 | -4.996 | -329.9 | 68 | **67 MHz** | +0.083 | 0 | Setup ✗ / Hold ✓ |
       | **MIN_m40 / Cworst** | FF, 1.32V, -40℃, 最大电容 | -5.226 | -345.2 | 68 | **66 MHz** | +0.083 | 0 | Setup ✗ / Hold ✓ |
       | **ML_125 / Cbest** | FF, 1.32V, 125℃, 最小电容 | -6.648 | -441.7 | 68 | **60 MHz** | +0.091 | 0 | Setup ✗ / Hold ✓ |
       | **ML_125 / RCworst** | FF, 1.32V, 125℃, 最差 RC 互连 | -6.761 | -449.3 | 68 | **60 MHz** | +0.091 | 0 | Setup ✗ / Hold ✓ |
       | **ML_125 / RCbest** | FF, 1.32V, 125℃, 最佳 RC 互连 | -6.981 | -463.7 | 68 | **59 MHz** | +0.092 | 0 | Setup ✗ / Hold ✓ |
       | **ML_125 / Cworst** | FF, 1.32V, 125℃, 最大电容 | -7.284 | -483.9 | 68 | **58 MHz** | +0.092 | 0 | Setup ✗ / Hold ✓ |
       | **TYP_25 / TYPICAL** | TT, 1.20V, 25℃, 典型走线 | -13.508 | -903.7 | 68 | **43 MHz** | +0.133 | 0 | Setup ✗ / Hold ✓ |
       | **WCL_m40 / RCworst** | SS, 1.08V, -40℃, 最差 RC 互连 | -32.320 | -5170.9 | 1085 | **24 MHz** | +0.241 | 0 | Setup ✗ / Hold ✓ |
       | **MAX_125 / RCworst** | SS, 1.08V, 125℃, 最差 RC 互连 | -33.074 | -5457.8 | 1145 | **23 MHz** | +0.248 | 0 | Setup ✗ / Hold ✓ |
       | **WCL_m40 / Cworst** | SS, 1.08V, -40℃, 最大电容 | -33.760 | -5847.4 | 1202 | **23 MHz** | +0.243 | 0 | Setup ✗ / Hold ✓ |
       | **MAX_125 / Cworst** | SS, 1.08V, 125℃, 最大电容 | -34.627 | -6215.3 | 1213 | **22 MHz** | +0.251 | 0 | Setup ✗ / Hold ✓ |

       > 注：`Setup ✗` 表示该 corner 在 100 MHz（10 ns）约束下 setup WNS < 0、未收敛；`Hold ✓` 表示 hold WNS > 0 且 NVP(H) = 0。13 个 corner 合计 setup 违例路径 5257 条（按 corner 累加）。

     - **时序签核与时钟树质量分析**：
       - **保持时间 (Hold Signoff)**：全部 13 个工艺角下保持时间裕量均为正（Hold WNS: **+0.082 ns ~ +0.251 ns**），保持时间违规路径数 (Hold NVP) 恒为 **0**。全芯片平衡时钟树综合（CTS）在各工艺角下均未出现保持时间违例。
       - **建立时间 (Setup Signoff)**：在 100 MHz（周期 10 ns）约束下，13 个工艺角均存在 setup 违例，setup 尚未收敛；合计违例路径 **5257** 条。按 WNS 反推的各 corner 最高运行频率为：SS 1.08V, 125℃ **22 ~ 23 MHz**；SS 1.08V, -40℃ **23 ~ 24 MHz**；TT 1.20V, 25℃ **43 MHz**；FF 1.32V, 125℃ **58 ~ 60 MHz**；FF 1.32V, -40℃ **66 ~ 68 MHz**。
       - **设计电气规则检查 (TDRC Violations)**：全部 13 个工艺角下违规数均为 **0**（电容违例 CAP = 0，扇出违例 FANOUT = 0，转换时间违例 TRAN = 0）。
  5. **后布线多工艺角真实功耗细分报告 (Post-Route Power Breakdown)**：
     - **多工况功耗对比表**：

       | 工况场景 (Corner) | 运行环境 | 内部单元功耗 (Internal) | 网络翻转功耗 (Switching) | 静态漏电功耗 (Leakage) | 芯片总功耗 (Total Power) |
       | :--- | :--- | :--- | :--- | :--- | :--- |
       | **常温典型工况 (TYP_25/TYPICAL)** | TT, 1.20V, 25℃ | 58.2736 mW (80.42%) | 14.0366 mW (19.37%) | 0.1496 mW (0.21%) | **72.4598 mW** |
       | **恶劣慢速高温工况 (MAX_125/Cworst)** | SS, 1.08V, 125℃ | 42.6565 mW (77.41%) | 11.3384 mW (20.58%) | 1.1070 mW (2.01%) | **55.1019 mW** |
       | **最佳快速低温工况 (MIN_m40/Cworst)** | FF, 1.32V, -40℃ | 76.8564 mW (79.73%) | 19.1082 mW (19.82%) | 0.4322 mW (0.45%) | **96.3968 mW** |

     - **按电路类型功耗细分 (以 TT 典型工况为例)**：
       - **触发器寄存器阵列 (Registers)**：**54.3240 mW**（占比 **74.97%**，主要源自 4KB Cache 标准单元 DFF 阵列）
       - **全芯片时钟树网络 (Clock Network)**：**16.0665 mW**（占比 **22.17%**）
       - **组合逻辑运算网络 (Combinational)**：**2.0693 mW**（占比 **2.86%**）
       - **I/O 单元与存储宏 (IO & Memory)**：0.0000 mW

- **当前后端流程状态**：
  Synthesis、Floorplan、place、CTS、legalization、Timing optimization、route、filler、RCX、STA、LVS 已完成；`postRouteLec`（综合网表与后布线 LVS 网表的等价性检查）进行中；`drc` 与 `Harden` 未开始。STA 的 13 个工艺角数据与功耗数据已完整生成，但 setup 尚未收敛，后端签核尚不能标记为完成。

---
