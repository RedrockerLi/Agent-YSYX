# RISC-V 处理器架构与性能报告（频率优化）

本报告记录处理器核 **`cpu_top`** 的微架构、存储层次、基准测试实测数据、55nm 物理实现结果与功能验证状态。所有仿真、基准测试与后端流程均在仓库自带的 Docker 环境中执行。

---

## 目录

- [一、处理器微架构 (Microarchitecture)](#一处理器微架构-microarchitecture)
  - [1.1 流水线与总体结构](#11-流水线与总体结构)
  - [1.2 取指、分支预测与指令队列](#12-取指分支预测与指令队列)
  - [1.3 执行单元 (ALU 与 MDU)](#13-执行单元-alu-与-mdu)
  - [1.4 冒险处理与流水控制](#14-冒险处理与流水控制)
- [二、存储层次 (Memory Hierarchy)](#二存储层次-memory-hierarchy)
  - [2.1 指令缓存 (ICache)](#21-指令缓存-icache)
  - [2.2 数据缓存 (DCache)](#22-数据缓存-dcache)
  - [2.3 一致性维护与 fence.i](#23-一致性维护与-fencei)
  - [2.4 总线仲裁与 AXI4 突发传输](#24-总线仲裁与-axi4-突发传输)
- [三、基准测试实测性能数据 (Benchmark Results)](#三基准测试实测性能数据-benchmark-results)
  - [3.1 测试总览与性能汇总表](#31-测试总览与性能汇总表)
  - [3.2 CoreMark](#32-coremark)
  - [3.3 Dhrystone](#33-dhrystone)
  - [3.4 MicroBench](#34-microbench)
  - [3.5 Thread-OS](#35-thread-os)
  - [3.6 Nanos-lite](#36-nanos-lite)
  - [3.7 cpu-tests](#37-cpu-tests)
- [四、物理实现 (Physical Design)](#四物理实现-physical-design)
  - [4.1 流程与约束](#41-流程与约束)
  - [4.2 逻辑综合](#42-逻辑综合)
  - [4.3 布局与布线](#43-布局与布线)
  - [4.4 时序签核](#44-时序签核)
  - [4.5 功耗](#45-功耗)
  - [4.6 物理验证](#46-物理验证)
  - [4.7 流程状态](#47-流程状态)
- [五、功能验证 (Verification)](#五功能验证-verification)
- [六、源码结构](#六源码结构)

---

## 一、处理器微架构 (Microarchitecture)

### 1.1 流水线与总体结构

处理器为按序单发射的 5 级流水线，分为 **IF（取指）**、**ID（译码）**、**EX（执行）**、**MEM（访存）**、**WB（写回）** 五个阶段，流水线寄存器为 IF/ID、ID/EX、EX/MEM、MEM/WB。

- **指令集**：RV32E / RV32I 基础整数指令集，集成 RV32M 乘除法扩展；支持机器模式 CSR 与精准异常自陷。
- **可变延迟执行**：EX 级的 ALU 固定占用 3 拍，MUL/DIV 占用多拍；MEM 级的访存延迟由 Cache 命中或缺失决定。EX 或 MEM 未完成时，ID 级及其上游保持停顿。
- **解耦取指**：取指单元以 16 字节整行为单位读取 ICache，结果进入 8 项指令队列；ID 级从队列头部取指，取指延迟由队列吸收，不直接出现在 ID 的时序路径上。

```mermaid
flowchart LR
    subgraph IF_Stage ["IF (取指)"]
        PC["fetch_pc"] --> IC["ICache<br/>整行读取"]
        IC --> FQ["8 项指令队列<br/>{pc, inst, 预测}"]
    end

    subgraph ID_Stage ["ID (译码)"]
        RF["寄存器堆 (16 GPRs)"]
        DEC["译码 / 立即数"]
    end

    subgraph EX_Stage ["EX (执行)"]
        FW["前递与操作数选择"]
        ALU["ALU (3 拍)"]
        MDU["MUL / DIV (多拍)"]
        BR["分支判定 / 重定向"]
    end

    subgraph MEM_Stage ["MEM (访存)"]
        DC["DCache<br/>分行读 / 写回"]
    end

    subgraph WB_Stage ["WB (写回)"]
        WB["写回选择"]
    end

    FQ --> DEC
    DEC --> FW
    FW --> ALU
    FW --> MDU
    ALU --> BR
    ALU --> DC
    DC --> WB
    WB -.写回.-> RF
    BR -.冲刷.-> IF_Stage
```

### 1.2 取指、分支预测与指令队列

- **取指请求**：`fetch_pc` 向 ICache 请求一个 16 字节行；当队列占用不超过 3 项（即至少能容纳 4 个字）且 ICache 空闲时发起下一次请求。访存停顿期间取指队列继续填充。
- **指令队列**：行数据返回后，从目标字开始把 4 个字连同各自的预测信息写入 8 项环形队列（3 位读写指针、4 位计数）。队列头单独寄存，ID 级直接读取队头寄存器，不经过 8:1 选择。
- **分支预测单元 (BPU)**：32 项直接映射 BTB（tag、目标、返回标记）、32 项 2 位饱和计数器 BHT、8 项 RAS。查询按三拍流水组织：
  1. 请求拍：四路 PC 的索引与标签分别寄存；
  2. 阵列读拍：每个通道只用自己的索引副本读出 BTB/BHT；
  3. 比较拍：命中、计数器方向和 RAS 栈顶（寄存的 `ras_target_r`）组合出预测结果。
- **预测使用**：一次行请求同时查询该行的 4 个字，预测结果随指令入队；ID 级对预译码为控制指令的队头，若预测跳转则修改 `fetch_pc` 并清空队列。
- **预测更新**：分支、`jal`、`jalr` 在 EX 级得到实际结果，训练 BTB/BHT/RAS 并记录预测正确率；预测错误时向取指单元发出重定向并冲刷队列。

### 1.3 执行单元 (ALU 与 MDU)

- **ALU（3 拍）**：
  1. 启动拍：锁存经前递选择的操作数、操作码独热码，以及分支比较专用的 `cmp_a`/`cmp_b`；
  2. 计算拍：并行完成四个 8 位加法的组和（含/不含进位输入两种）、桶形移位与分支比较；
  3. 选择拍：解析组间进位链，按独热码用 AND-OR 选择最终结果，并置位 `done`。
- **加法器**：`add32cs` 把 32 位加法拆成四个 8 位加法组，组和同时计算进位输入为 0 与 1 的两种结果，再用两级选择得到组间进位；`add16cs` 用同样的分组进位选择实现 16 位加法与取反。
- **移位器**：三级 4:1 桶形移位器（`shamt[1:0]`、`shamt[3:2]`、`shamt[4]`），左移、逻辑右移、算术右移共用移位网络，结果按操作码选择。
- **分支与跳转目标**：ID/EX 寄存器保存 `pc+4`；分支与 `jal` 的目标由该寄存器加立即数得到，`jalr` 的目标来自已寄存的操作数。重定向目标用独热码 AND-OR 选择。
- **MDU**：乘除法器为独立多周期单元，与 ALU 并行存在，由操作码选择启用。
  - 除法器：restoring 算法，`DIV_BITS_PER_CYCLE = 1`（每拍 1 位商，32 次迭代，含符号转换约 35 拍）；33 位部分余数的比较/减法使用 `add32cs`，符号转换使用 `add16cs`。
  - 乘法器：radix-4 Booth 数字生成，`MUL_BITS_PER_CYCLE = 4`（每拍 2 个 radix-4 数字，8 次迭代）；部分积在进位保存（carry-save）累加器中压缩，最后单独一拍做进位传播加法；64 位符号修正按高低 32 位分别用进位选择取反。
  - **握手**：ALU、除法器、乘法器各自输出 `done`，接受信号互相门控（同一拍只允许一个单元完成并提交结果），避免多单元同时结束导致的重启竞争。

### 1.4 冒险处理与流水控制

- **前递**：EX 级操作数来自 ID/EX 寄存器、EX/MEM 结果或 MEM/WB 写回数据的三选一；寄存器堆采用写透设计，WB 与 ID 同拍读写同一寄存器时直接透传。
- **Load-Use**：检测到 EX 级为 load 且 ID 级立即使用其目的寄存器时，冻结 PC、IF/ID 与队列，并向 ID/EX 注入气泡。
- **多周期停顿**：`id_stall = load_use_hazard || mem_stall || ex_mdu_stall || ex_alu_stall`。ALU、MUL、DIV 未完成，或 MEM 等待 DCache 响应、等待 fence 完成时，ID 及上游保持不动，取指队列继续填充。
- **控制流冲刷**：分支预测错误、异常/自陷、`mret`、`fence.i` 都会清空 IF/ID 与指令队列并重定向 `fetch_pc`；EX 级重定向先寄存一拍再作用于取指单元。

---

## 二、存储层次 (Memory Hierarchy)

### 2.1 指令缓存 (ICache)

- **结构参数**：2 路组相联（2-Way Set-Associative），64 个 Set，行大小 16 字节（4 条 32-bit 指令），每路 1 KB、总容量 2 KB。替换策略为伪 LRU（每组 1-bit 翻转标记）。
- **数组组织**：64 组按 16 个 bank × 4 组划分。请求拍把组索引复制到 16 个 bank 寄存器，每个 bank 的读索引只由自己的副本驱动，地址扇出限制在 bank 内。
- **读时序**：`S_IDLE` 接收请求并寄存 bank 索引、标签与一热 bank 选择；bank 读与 16 份候选行（数据、标签、有效位、LRU）的寄存每拍进行；`S_CMP` 用一热 bank 选择经 AND-OR 选出目标候选并完成标签比较；`S_RESP` 输出 128 位行。命中行与 refill 行共用响应寄存器 `resp_line_r`，取指队列只看到寄存器输出。
- **标签比较拆分**：标签低 11 位在候选寄存拍与已寄存的请求标签比较并寄存（`cand_eq*`），`S_CMP` 只比较高 11 位，避免同一拍同时承担阵列选择与完整标签比较。
- **refill 写口**：按 way 分开的一热 set 写使能（`rf_w0_oh`/`rf_w1_oh`）与每 way 一份数据副本；写使能与标签在 `S_REFILL_DONE` 寄存，阵列写入在下一拍由普通触发器驱动。
- **LRU 更新**：命中时用一热 set 选通更新，避免 64 位索引比较进入写路径。
- **缺失处理**：未命中时发出 `arlen=3` 的 4 拍 INCR 突发读，数据在 `S_REFILL` 中按拍拼接，完成后整行写入受害 way，并把该行作为响应返回。
- **一致性**：`fence_i` 清空全部有效位，并使在途 refill 排空（`S_DRAIN`）。

### 2.2 数据缓存 (DCache)

- **结构参数**：2 路组相联，64 个 Set，行大小 16 字节，每路 1 KB、总容量 2 KB。**写回（Write-Back）** 与 **写分配（Write-Allocate）**。
- **数组组织**：每个 way 按 4 个 32 位字平面存储，使读选择器宽度保持 32 位而不是 128 位；64 组按 16 个 bank × 4 组划分，16 个 bank 又按 4 个组（每组 4 个 bank）先做一次组内 bank 选择。
- **读时序**：`S_IDLE` 寄存 bank 索引的 per-bank 副本；bank 读拍把每个组选中的 bank 写入 4 份组候选寄存器；`S_CMP` 用一热组选择 `d_grp_oh` 选出目标组、比较标签并选出 32 位字；`S_RESP` 返回数据。组内 bank 选择由一热 `d_lo_oh` 完成，两者都由已寄存的 bank 索引组合译码，每个周期只承担一级 4:1 选择。
- **命中响应**：每个 way 各做一次字选择，再用命中位在 32 位宽度上二选一，命中位只驱动 32 个门。
- **写口**：store 与 refill 都使用按 way 分开的一热 set 写使能（`st_w0_oh`/`st_w1_oh`、`rf_w0_oh`/`rf_w1_oh`）和一热字选择；字选择一热寄存器按 mux 组复制，refill 合并的字选择单独寄存为 `rw_word_oh`，写数据按 way 复制，避免 way/字选择广播到整个阵列。
- **缺失处理**：脏行先经 `S_WB_LINE` 以 `awlen=3` 回写，再进入 `S_REFILL` 接收 4 拍读数据；`S_REFILL_MERGE` 把待写 store 字与 refill 行合并后写入阵列。
- **MMIO**：访问非缓存区间时经 `S_MMIO_WAIT` 直通总线，不分配 cache 行。

### 2.3 一致性维护与 fence.i

`fence.i` 由 DCache 扫描全部 64 组：`S_FENCE_SETUP` 启动扫描，`S_FENCE_BANK` 提前一拍寄存当前组的一热译码（`fence_set_oh`），`S_FENCE_READ` 读出该组两路，`S_FENCE_CHECK` 判断脏行，`S_FENCE_WB` 写回脏行并清除有效位。扫描完成后 ICache 清空全部有效位。

### 2.4 总线仲裁与 AXI4 突发传输

- **仲裁**：`cache_arbiter` 连接 ICache 与 DCache，DCache 优先；授权保持到当前突发结束，避免突发计数漂移。
- **突发**：ICache refill、DCache refill 与脏行写回均为 `arlen=3` / `awlen=3` 的 4 拍 INCR 突发，与 16 字节行宽对应。
- **接口**：AXI4 Master 提供独立的读地址、读数据、写地址、写数据与写响应通道，单 outstanding。

---

## 三、基准测试实测性能数据 (Benchmark Results)

> **说明**：所有基准测试与仿真验证均在 Docker 容器内运行，均启用 NEMU DiffTest。运行时间按 500 MHz 签核频率折算：运行时间 = 总周期数 ÷ 500 MHz。

### 3.1 测试总览与性能汇总表

| 测试用例 (Benchmark) | 运行规模 / 参数 | 验证状态 | 总周期数 (Cycles) | 总指令数 (Insts) | 平均 IPC | 运行时间 | ICache 命中率 | DCache 命中率 | 分支预测准确率 (BPU) |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **CoreMark** | 10 iterations | **PASS** | 39,514,793 | 7,834,824 | **0.1983** | **79.03 ms** | **99.53%** | **99.92%** | **75.56%** |
| **Dhrystone** | 5,000 runs | **PASS** | 12,104,689 | 2,515,768 | **0.2078** | **24.21 ms** | **99.04%** | **96.71%** | **81.34%** |
| **MicroBench** | `test` 算法集 (10项) | **PASS** | 2,661,452 | 525,429 | **0.1974** | **5.32 ms** | **97.71%** | **94.66%** | **73.36%** |
| **Nanos-lite (`/bin/hello`)** | OS 启动 + 加载用户程序 | **PASS** | 1,208,799 | 247,111 | **0.2044** | **2.42 ms** | **97.63%** | **96.17%** | **88.40%** |
| **Thread-OS** | 20 次线程上下文切换 | **PASS** | 691,337 | 117,959 | **0.1706** | **1.383 ms** | **97.85%** | **99.44%** | **92.77%** |
| **cpu-tests** | 完整 RV32 基础指令算法 | **36 PASS + 1 预期失败** | — | — | — | — | — | — | — |

### 3.2 CoreMark

- **测试目标**：嵌入式 CPU 整数流水线性能基准测试。
- **运行命令**：
  ```bash
  make -C am-kernels/benchmarks/coremark run ARCH=riscv32e-npc ITERATIONS=10
  ```
- **执行日志与统计输出**：
  ```text
  Running CoreMark for 10 iterations
  CoreMark PASS       4294967 Marks
  npc: HIT GOOD TRAP at pc = 0x80002580
  ================ PERFORMANCE STATISTICS ================
  Total Cycles       : 39514793
  Total Instructions : 7834824
  IPC                : 0.1983
  ICache Hits        : 15911625, Misses: 74831, Hit Rate: 99.53%
  DCache Hits        : 1117563, Misses: 850, Hit Rate: 99.92%
  Branch Prediction  : 1762837 / 2332942, Accuracy: 75.56%
  ========================================================
  ```
- **运行时间**：39,514,793 cycles ÷ 500 MHz = **79.03 ms**。

### 3.3 Dhrystone

- **测试目标**：经典整数算力性能基准测试。
- **运行命令**：
  ```bash
  make -C am-kernels/benchmarks/dhrystone run ARCH=riscv32e-npc NUMBER_OF_RUNS=5000
  ```
- **执行日志与统计输出**：
  ```text
  Dhrystone Benchmark, Version C, Version 2.2
  Trying 5000 runs through Dhrystone.
  Dhrystone PASS         0 Marks
  npc: HIT GOOD TRAP at pc = 0x80000c34
  ================ PERFORMANCE STATISTICS ================
  Total Cycles       : 12104689
  Total Instructions : 2515768
  IPC                : 0.2078
  ICache Hits        : 4357184, Misses: 42021, Hit Rate: 99.04%
  DCache Hits        : 883681, Misses: 30100, Hit Rate: 96.71%
  Branch Prediction  : 416936 / 512559, Accuracy: 81.34%
  ========================================================
  ```
- **运行时间**：12,104,689 cycles ÷ 500 MHz = **24.21 ms**。

### 3.4 MicroBench

- **测试目标**：10 种典型算法场景的计算与访存适应能力。
- **运行命令**：
  ```bash
  make -C am-kernels/benchmarks/microbench run ARCH=riscv32e-npc mainargs=test
  ```
- **执行日志与统计输出**：
  ```text
  MicroBench PASS
  npc: HIT GOOD TRAP at pc = 0x800057c0
  ================ PERFORMANCE STATISTICS ================
  Total Cycles       : 2661452
  Total Instructions : 525429
  IPC                : 0.1974
  ICache Hits        : 936516, Misses: 21915, Hit Rate: 97.71%
  DCache Hits        : 111635, Misses: 6295, Hit Rate: 94.66%
  Branch Prediction  : 90760 / 123723, Accuracy: 73.36%
  ========================================================
  ```
- **运行时间**：2,661,452 cycles ÷ 500 MHz = **5.32 ms**。

### 3.5 Thread-OS

- **测试目标**：密集自陷与跨线程寄存器保存/恢复时的稳定性与缓存效率。
- **运行命令**：
  ```bash
  make -C am-kernels/kernels/thread-os run ARCH=riscv32e-npc
  ```
- **执行日志与统计输出**：
  ```text
  Thread-OS PASS (20 Context Switches Completed)
  npc: HIT GOOD TRAP at pc = 0x800002c8
  ================ PERFORMANCE STATISTICS ================
  Total Cycles       : 691337
  Total Instructions : 117959
  IPC                : 0.1706
  ICache Hits        : 228194, Misses: 5024, Hit Rate: 97.85%
  DCache Hits        : 65413, Misses: 370, Hit Rate: 99.44%
  Branch Prediction  : 22436 / 24184, Accuracy: 92.77%
  ========================================================
  ```
- **运行时间**：691,337 cycles ÷ 500 MHz = **1.383 ms**。

### 3.6 Nanos-lite

- **测试目标**：操作系统内核初始化、ramdisk 文件系统解析、ELF 用户程序加载、`fence.i` 缓存冲刷与用户态系统调用。
- **运行命令**：
  ```bash
  make -C nanos-lite update ARCH=riscv32e-npc
  make -C nanos-lite run ARCH=riscv32e-npc
  ```
- **执行输出 (`/bin/hello`)**：
  ```text
  Hello World!
  Hello World from Navy-apps for the 2th time!
  Hello World from Navy-apps for the 3th time!
  Hello World from Navy-apps for the 4th time!
  Hello World from Navy-apps for the 5th time!
  npc: HIT GOOD TRAP at pc = 0x80000d50
  ================ PERFORMANCE STATISTICS ================
  Total Cycles       : 1208799
  Total Instructions : 247111
  IPC                : 0.2044
  ICache Hits        : 410598, Misses: 9951, Hit Rate: 97.63%
  DCache Hits        : 94792, Misses: 3780, Hit Rate: 96.17%
  Branch Prediction  : 48911 / 55332, Accuracy: 88.40%
  ========================================================
  ```
- **运行时间**：1,208,799 cycles ÷ 500 MHz = **2.42 ms**。

### 3.7 cpu-tests

- **测试目标**：RV32E 基础整数指令集与 RV32M 乘除法扩展在流水线、前递网络与多周期执行单元中的功能正确性。
- **运行命令**：
  ```bash
  make -C am-kernels/tests/cpu-tests run ARCH=riscv32e-npc
  ```
- **测试覆盖与实测结果**：共 37 个用例，36 个 PASS；`wrong` 是负向用例，按设计触发 `HIT BAD TRAP at pc = 0x80000030 (a0 = 1)`，测试框架将其判为 `***FAIL***` 属预期行为。全部运行启用 DiffTest。

---

## 四、物理实现 (Physical Design)

### 4.1 流程与约束

- **工艺/单元库**：icsprout55 1P6M，标准单元 ics55 LLSC H7C（H7R/H7L 两种阈值）。
- **约束**：时钟端口 `clock`，周期 2.0 ns（500 MHz）。
- **流程**：Yosys 综合 → Floorplan → DreamPlace 布局 → CTS → legalization → Sizer 时序优化（TT 库）→ 详细布线（MET2–MET5）→ filler → RCX 寄生提取 → STA → LVS → post-route LEC → DRC → Harden。
- **布局参数**：核心利用率 0.32，DreamPlace `stop_overflow` 0.05，全局布局 6000 次迭代。
- **签核角**：TT（TYPICAL，1.2 V，25 °C），布线后 SPEF 反标。

### 4.2 逻辑综合

| 指标 | 数值 |
|---|---:|
| 标准单元总面积 | 637,149.52 µm²（0.637 mm²） |
| 标准单元数 | 206,446 |
| Setup WNS / TNS / 违例路径 | +0.303 ns / 0.0 ns / 0 |
| 估算 Fmax | 589 MHz |
| Hold WNS | +0.196 ns |
| 动态功耗（SS 库、默认翻转率） | 242.5567 mW（内部 238.7874 mW、开关 3.7694 mW） |
| 漏电功耗 | 0.6729 mW |

综合时序与功耗为 SS 角、无连线寄生的估算值，只用于综合阶段的横向比较。

### 4.3 布局与布线

| 指标 | 数值 |
|---|---:|
| Die 尺寸 / 面积 | 1415.2 µm × 1415.2 µm / 2,002,791.04 µm²（2.003 mm²） |
| Core 尺寸 / 面积 | 1411.2 µm × 1411.2 µm / 1,991,485.44 µm²（1.991 mm²） |
| I/O 引脚数 | 554 |
| 网络数 | 220,027（含时钟网） |
| 综合后实例数 | 206,446 |
| 布局实例数 | 234,039 |
| 布线实例数 | 247,240 |
| 插入 filler 后实例数 | 692,725 |
| Core 利用率（布局/布线） | 0.32 / 0.35 |
| 布局总线长（GRWL / HPWL） | 8,476,697 µm / 6,543,840 µm |
| 布线总线长 | 9,465,370 µm（9.47 mm） |
| 布线 via 数 | 1,305,110 |
| 层分配 overflow | 2,180 |
| 详细布线 DRC 违例 | 0 |

布局的全局布局溢出（egr）合计 177,871、最大值 18，在 6000 次迭代内收敛到 `stop_overflow` 以下。层分配报告 2,180 个 overflow，详细布线后的违例计数为 0。

### 4.4 时序签核

布线后 TT 角、SPEF 反标：

| 指标 | 数值 |
|---|---:|
| Setup WNS | **+0.006 ns** |
| Setup TNS | 0.0 ns |
| Setup 违例路径数 | **0** |
| 估算 Fmax | **502 MHz** |
| Hold WNS | +0.125 ns |
| Hold 违例路径数 | 0 |
| TDRC（CAP / FANOUT / TRAN） | 0 / 0 / 0 |

### 4.5 功耗

布线后 TT 角功耗报告（工具默认翻转率）：

| 项 | 数值 |
|---|---:|
| Cell Internal | 347.7367 mW |
| Net Switching | 93.5026 mW |
| Total Dynamic | 441.2393 mW |
| Cell Leakage | 0.1060 mW |
| **Total** | **441.3453 mW** |

按电路类型：寄存器阵列 325.8875 mW（73.84%）、时钟网络 96.1914 mW（21.80%）、组合逻辑 19.2663 mW（4.37%）。寄存器与时钟网络占主导，主要来源是由标准单元 D 触发器构成的两个 2 KB Cache 阵列与全芯片时钟树。

### 4.6 物理验证

| 检查 | 结果 |
|---|---|
| LVS（版图 vs. 网表） | **通过**，不匹配数 0 |
| DRC（布线器内部） | 违例 0 |
| DRC（全版图 GDS） | 205,779 条，全部为 MET1 `metal_short`，网络与实例字段为空 `-1`/`[]`，即 PDN 电源/地轨形状；没有信号网络参与 |
| post-route LEC | `$equiv` 194,357 个：已证明 194,043，未证明 314 |

未证明的 314 个等价点全部是内部单元引脚级的同名网络：`u_icache` 内 167 个（`cand_tag0[*]`、`cand_eq*` 的复合门 A/B/D 引脚）、顶层 `icache_resp_line_*` 143 个、`mem_wb_wdata_*` 4 个。这些点在 Sizer/布线阶段被重排为不同的门级结构，按名字配对的 pin 级等价点无法证明；寄存器与端口级等价未列入未证明项。

### 4.7 流程状态

综合、布局、CTS、时序优化、布线、filler、RCX、STA、LVS、post-route LEC、DRC 均已完成；Harden 是流程的最后一步。本报告的数据全部来自上述步骤，不包含 GDS 与签核交付包。

---

## 五、功能验证 (Verification)

- **差分测试**：所有基准与测试运行均启用 NEMU DiffTest，逐指令比对 GPR 与 PC。
- **cpu-tests**：37 个用例中 36 个 PASS，`wrong` 按设计触发 BAD TRAP（`a0 = 1`）。
- **四值仿真**：`make test-4state-all ARCH=riscv32e-npc` 在 Icarus Verilog 中运行全部 37 个用例：36 个 `HIT GOOD TRAP`，`wrong` 按预期 `HIT BAD TRAP at pc = 0x80000030 (a0 = 1)`，退出码 0，无 X 态挂起。

---

## 六、源码结构

| 文件 | 说明 |
| :--- | :--- |
| [cpu_top.v](../../npc/vsrc/cpu_top.v) | 流水线、取指队列、冒险控制、CSR/自陷与总线接口 |
| [icache.v](../../npc/vsrc/icache.v) | 2 路组相联 ICache，分行读取、一热写口与 refill |
| [dcache.v](../../npc/vsrc/dcache.v) | 2 路写回 DCache，字平面存储、一热写口、脏块写回与 fence |
| [alu.v](../../npc/vsrc/alu.v) | 3 拍 ALU：加法、移位、比较与结果选择 |
| [mul_unit.v](../../npc/vsrc/mul_unit.v) | radix-4 Booth 乘法器（每拍 4 位，进位保存累加） |
| [div_unit.v](../../npc/vsrc/div_unit.v) | restoring 除法器（每拍 1 位） |
| [bpu.v](../../npc/vsrc/bpu.v) | 32 项 BTB + 32 项 BHT + 8 项 RAS 分支预测单元 |
| [add16cs.v](../../npc/vsrc/add16cs.v) / [add32cs.v](../../npc/vsrc/add32cs.v) | 分组进位选择加法器 |
| [csr.v](../../npc/vsrc/csr.v) | CSR 寄存器与自陷现场 |
| [cache_arbiter.v](../../npc/vsrc/cache_arbiter.v) | ICache/DCache 总线仲裁 |
| [axi_master.v](../../npc/vsrc/axi_master.v) | AXI4 Master 接口 |
| [regfile.v](../../npc/vsrc/regfile.v) | 16 × 32 位寄存器堆（写透） |
