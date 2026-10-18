# Agent-YSYX: 基于“一生一芯”的 AI Agent 芯片设计能力评测

<p align="center">
  <a href="README.md"><b>English</b></a> | <a href="README_zh.md"><b>简体中文</b></a>
</p>

---

## 📌 项目概述

**Agent-YSYX** 依托 **“一生一芯”（One Student One Chip, [ysyx.oscc.cc](https://ysyx.oscc.cc/docs/)）** 工程体系，致力于评测大模型与自主 AI Agent 的芯片设计全流程能力。

本项目重点聚焦于以下核心环节：
- **Verilog RTL 代码生成**：从基础数字逻辑到完整处理器核的可综合 RTL 设计。
- **功能验证**：自动构建并运行测试平台（Testbench）、断言及软硬件协同仿真。
- **自动化调试与诊断**：结合编译器报错、仿真日志与波形定位并闭环修复硬件缺陷。
- **端到端硬件设计**：增量式设计、集成并验证一颗能够运行真实软件与操作系统的 RISC-V 处理器。

---

## 🐳 Docker 实验环境

本项目提供自包含的 Docker 镜像，已预装全套开发与仿真工具（Verilator v5.008、RISC-V 交叉编译链、GTKWave、SDL2 等）。

### 1. 构建镜像

```bash
docker build -t ysyx .
```

> *(Apple Silicon / ARM64 用户推荐添加 `--platform linux/amd64`)*

### 2. 运行容器

```bash
docker run --rm -it --net=host -v "$PWD":/workspace ysyx
```
