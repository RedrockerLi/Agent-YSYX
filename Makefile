# ==============================================================================
# Agent-YSYX: Top-Level Evaluation & Benchmark Orchestrator
# ==============================================================================

ARCH       ?= riscv32e-npc
TOPNAME    ?= cpu_top
YSYX_HOME  ?= $(if $(NEMU_HOME),$(NEMU_HOME)/..,$(shell pwd))

# Only define orchestrator targets when run from the top-level repository
# (Prevents recipe override warnings when included by subprojects like NEMU)
ifeq ($(CURDIR),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))))

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# 0. Help / Usage
# ------------------------------------------------------------------------------
help:
	@echo "======================================================================"
	@echo "  Agent-YSYX: AI Agent Benchmark Suite for IC Design"
	@echo "======================================================================"
	@echo "  Target Architecture : $(ARCH)"
	@echo "  Core Top Module     : $(TOPNAME)"
	@echo ""
	@echo "  [Functional Verification]"
	@echo "    make test          : Run all 35 cpu-tests (Verilator + DiffTest)"
	@echo "    make test-single   : Run single test (e.g., make test-single ALL=add)"
	@echo "    make test-4state   : Run 4-state simulation (Icarus Verilog + VPI)"
	@echo "    make test-os       : Run OS workloads (Nanos-lite & Thread-OS)"
	@echo ""
	@echo "  [Performance Benchmarks]"
	@echo "    make bench         : Run full standard benchmarks (CoreMark + Dhrystone)"
	@echo "    make bench-coremark: Run CoreMark (10 iterations)"
	@echo "    make bench-dhrystone: Run Dhrystone (5000 runs)"
	@echo "    make bench-micro   : Run MicroBench algorithm suite"
	@echo ""
	@echo "  [Physical Design & ASIC Signoff]"
	@echo "    make synth / pnr-synth: Run logic synthesis and PPA report (SMIC 55nm)"
	@echo "    make pnr           : Run full backend P&R flow (RTL-to-GDSII)"
	@echo "    make pnr-<step>    : Run step (floorplan, place, cts, legalize, opt, route, filler, rcx, sta, lvs, drc, harden)"
	@echo "    make pnr-status    : Refresh physical-design step states every 5s (WORKSPACE=<ws>)"
	@echo "    make test-netlist  : Run gate-level netlist simulation"
	@echo "    make signoff       : Export signoff package (GDSII, DEF, SDF, reports)"
	@echo ""
	@echo "  [Maintenance]"
	@echo "    make clean         : Clean build artifacts in npc and benchmarks"
	@echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Functional Verification
# ------------------------------------------------------------------------------
sim:
	$(MAKE) -C npc sim TOPNAME=$(TOPNAME)

test:
	@echo ">>> Running 35 cpu-tests with DiffTest ($(ARCH))..."
	$(MAKE) -C am-kernels/tests/cpu-tests run ARCH=$(ARCH)

test-single:
	@if [ -z "$(ALL)" ]; then \
		echo "Usage: make test-single ALL=<testcase_name> (e.g., make test-single ALL=add)"; \
		exit 1; \
	fi
	$(MAKE) -C am-kernels/tests/cpu-tests run ARCH=$(ARCH) ALL=$(ALL)

test-4state:
	@echo ">>> Running Icarus Verilog 4-state simulation (dummy)..."
	$(MAKE) -C npc run-iverilog IMG=../am-kernels/tests/cpu-tests/build/dummy-$(ARCH).bin

test-4state-all:
	@echo ">>> Running Icarus Verilog 4-state simulation on all cpu-tests..."
	@for bin in am-kernels/tests/cpu-tests/build/*-$(ARCH).bin; do \
		echo "=== Testing $$bin ==="; \
		$(MAKE) -C npc run-iverilog IMG=../$$bin || exit 1; \
	done

test-os:
	@echo ">>> Running Thread-OS context switches..."
	$(MAKE) -C am-kernels/kernels/thread-os run ARCH=$(ARCH)
	@echo ">>> Running Nanos-lite (/bin/hello)..."
	$(MAKE) -C nanos-lite run ARCH=$(ARCH)

# ------------------------------------------------------------------------------
# 2. Performance Benchmarks
# ------------------------------------------------------------------------------
bench: bench-coremark bench-dhrystone

bench-coremark:
	@echo ">>> Running CoreMark benchmark (10 iterations)..."
	$(MAKE) -C am-kernels/benchmarks/coremark run ARCH=$(ARCH) ITERATIONS=10

bench-dhrystone:
	@echo ">>> Running Dhrystone benchmark (5000 runs)..."
	$(MAKE) -C am-kernels/benchmarks/dhrystone run ARCH=$(ARCH) NUMBER_OF_RUNS=5000

bench-micro:
	@echo ">>> Running MicroBench test suite..."
	$(MAKE) -C am-kernels/benchmarks/microbench run ARCH=$(ARCH) mainargs=test

# ------------------------------------------------------------------------------
# 3. Physical Design & ASIC Backend (SMIC 55nm)
# ------------------------------------------------------------------------------
synth pnr-synth:
	$(MAKE) -C npc pnr-synth

BACKEND_FREQ_MHZ ?= 100.0
WORKSPACE ?= default

pnr:
	$(MAKE) -C npc pnr

pnr-status:
	$(MAKE) -C npc pnr-status WORKSPACE=$(WORKSPACE)

pnr-floorplan:
	$(MAKE) -C npc pnr-floorplan

pnr-place:
	$(MAKE) -C npc pnr-place

pnr-cts:
	$(MAKE) -C npc pnr-cts

pnr-legalize:
	$(MAKE) -C npc pnr-legalize

pnr-opt:
	$(MAKE) -C npc pnr-opt

pnr-route:
	$(MAKE) -C npc pnr-route

pnr-filler:
	$(MAKE) -C npc pnr-filler

pnr-rcx:
	$(MAKE) -C npc pnr-rcx

pnr-sta:
	$(MAKE) -C npc pnr-sta

pnr-lvs:
	$(MAKE) -C npc pnr-lvs

pnr-drc:
	$(MAKE) -C npc pnr-drc

pnr-harden:
	$(MAKE) -C npc pnr-harden

signoff:
	$(MAKE) -C npc signoff

test-netlist:
	@echo ">>> Running gate-level netlist simulation..."
	$(MAKE) -C npc run-netlist-iv IMG=../am-kernels/tests/cpu-tests/build/dummy-$(ARCH).bin

# ------------------------------------------------------------------------------
# 4. Clean
# ------------------------------------------------------------------------------
clean:
	$(MAKE) -C npc clean
	-$(MAKE) -C am-kernels/tests/cpu-tests clean
	-$(MAKE) -C am-kernels/benchmarks/coremark clean
	-$(MAKE) -C am-kernels/benchmarks/dhrystone clean
	-$(MAKE) -C am-kernels/benchmarks/microbench clean
	-$(MAKE) -C nanos-lite clean

.PHONY: help sim test test-single test-4state test-4state-all test-os \
        bench bench-coremark bench-dhrystone bench-micro \
        synth pnr-synth pnr-floorplan pnr-place pnr-cts pnr-legalize \
        pnr-opt pnr-route pnr-filler pnr-rcx pnr-sta pnr-lvs pnr-drc \
        pnr-harden pnr pnr-status signoff test-netlist clean

# ------------------------------------------------------------------------------
# 5. Fast STA (additive; existing physical-design targets are unchanged)
# ------------------------------------------------------------------------------
FREQ_MHZ ?= 100.0
YOSYS_SYNTH_STRATEGY ?= DELAY 4

sta-fast:
	$(MAKE) -C npc sta-fast FREQ_MHZ=$(FREQ_MHZ) YOSYS_SYNTH_STRATEGY="$(YOSYS_SYNTH_STRATEGY)"

sta-fast-clean:
	$(MAKE) -C npc sta-fast-clean

.PHONY: sta-fast sta-fast-clean

endif

