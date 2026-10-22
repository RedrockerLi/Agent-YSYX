# Agent-YSYX: Exploring AI Agents' Capability in IC Design

<p align="center">
  <a href="README.md"><b>English</b></a> | <a href="README_zh.md"><b>简体中文</b></a>
</p>

---

## 📌 Overview

**Agent-YSYX** provides large models and autonomous AI agents with a real chip design environment built on the **"One Student One Chip" (YSYX / 一生一芯)** project ([ysyx.oscc.cc](https://ysyx.oscc.cc/docs/)).

The project does not score a one-shot RTL generation result; it observes the agents' capability boundary across repeated iterations.

The project covers the hardware design lifecycle, with a focus on:
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

---

## 🔁 Iteration Path

The repository develops in iterations. The focus is not scoring an agent's one-shot RTL generation, but exploring the boundary of agent capability through iterative development.

Iterations alternate between one architecture optimization round and one frequency improvement round. The boundary is defined by what a change alters, not by its size.

- **Architecture optimization round** — changes the processor's organization or features: pipeline depth and organization, forwarding and hazard handling, cache hierarchy and replacement policy, branch-prediction structure, bus/interconnect, and ISA or privilege support. The goal is higher IPC/CPI, fewer cycles, or better area and power at the same clock constraint; the round may not buy gains by relaxing functional correctness or timing constraints.
- **Frequency improvement round** — keeps the architecture and ISA-visible behavior unchanged and only changes the timing implementation: retiming, register duplication, logic restructuring, fanout and logic-depth reduction, and replacing a long combinational operator with a multi-cycle implementation attached to the pipeline stall mechanism. The goal is a shorter critical path and a higher achievable clock; area and power deltas must be reported.

Architecture rounds are compared at the same clock constraint using IPC and area/power; frequency rounds raise the target clock and are judged by post-synthesis/post-route timing together with benchmark cycle counts.