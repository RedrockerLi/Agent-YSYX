# Agent-YSYX: Evaluating AI Agents for IC Design

<p align="center">
  <a href="README.md"><b>English</b></a> | <a href="README_zh.md"><b>简体中文</b></a>
</p>

---

## 📌 Overview

**Agent-YSYX** focuses on evaluating AI agents' IC design capabilities through the **"One Student One Chip" (YSYX / 一生一芯)** project ([ysyx.oscc.cc](https://ysyx.oscc.cc/docs/)).

The project benchmarks autonomous agents across the entire hardware design lifecycle, with a focus on:
- **Verilog RTL Generation**: Synthesizable RTL designs ranging from basic digital logic to complete processor cores.
- **Functional Verification**: Constructing and executing testbenches, assertions, and co-simulations.
- **Debugging & Self-Correction**: Diagnosing and resolving hardware bugs using compiler diagnostics, simulation logs, and waveforms.
- **End-to-End Hardware Design**: Progressively designing, integrating, and validating a complete RISC-V processor capable of running real-world software.

---

## 🐳 Docker Environment

A self-contained Docker image is provided with all necessary tools pre-installed (Verilator v5.008, RISC-V GCC cross-compiler toolchain, GTKWave, SDL2, etc.).

### 1. Build Image

```bash
docker build -t ysyx .
```

> *(For Apple Silicon / ARM64, specify `--platform linux/amd64`)*

### 2. Run Container

```bash
docker run --rm -it --net=host -v "$PWD":/workspace ysyx
```
