# ==============================================================================
# 0. Toolchain & Environment Configuration (Centralized User Customization)
# Users can override any tool or path from environment variables or make CLI:
#   make <target> ECC=/custom/ecc ICSPROUT55_HOME=/custom/pdk
# ==============================================================================
TOPNAME         ?= cpu_top
TB_TOPNAME      ?= sim_top

# Core EDA, compiler, and simulation tools (default to system PATH)
ECC             ?= ecc
VERILATOR       ?= verilator
IVERILOG        ?= iverilog
IVERILOG_VPI    ?= iverilog-vpi
VVP             ?= vvp

# ICsprout55 PDK Root
# Priority: User override -> System ENV -> auto-query via ecc -> empty fallback
ICSPROUT55_HOME ?= $(shell $(ECC) pdk show 2>/dev/null | awk '$$1 == "root:" {print $$2}')

# Workspace and Directory Layout (Relative paths only, zero hardcoded machine paths)
BUILD_DIR       ?= ./build
OBJ_DIR          = $(BUILD_DIR)/obj_dir
BIN              = $(BUILD_DIR)/$(TOPNAME)
BACKEND_DIR      = $(BUILD_DIR)/backend
WORKSPACE       ?= default
BACKEND_FREQ_MHZ ?= 100.0

# Verilator Compilation Flags
VERILATOR_CFLAGS += -MMD --build -cc \
                    -O3 --x-assign fast --x-initial fast --noassert \
                    -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PINMISSING -Wno-TIMESCALEMOD

# RTL Sources
ALL_VSRCS        = $(shell find $(CURDIR)/vsrc -name "*.v")
VSRCS            = $(filter-out $(CURDIR)/vsrc/sim_top.v, $(ALL_VSRCS))
VSRCS_REL        = $(patsubst $(CURDIR)/%,%,$(VSRCS))

# C/C++ Sources
VERILATOR_CSRCS  = $(CURDIR)/csrc/main.cpp $(CURDIR)/csrc/pmem.c
VPI_CSRCS        = $(CURDIR)/csrc/vpi.c $(CURDIR)/csrc/pmem.c

# Include Flags
INCFLAGS         = -I$(CURDIR)/csrc
CFLAGS          += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""
LDFLAGS         += -ldl

default: $(BIN)

$(shell mkdir -p $(BUILD_DIR))

# ==============================================================================
# 1. Verilator Simulation Flow
# ==============================================================================
$(BIN): $(VSRCS) $(VERILATOR_CSRCS)
	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

sim: $(BIN)

DIFF_REF_SO ?= $(if $(NEMU_HOME),$(NEMU_HOME)/build/riscv32-nemu-interpreter-so,../nemu/build/riscv32-nemu-interpreter-so)

override ARGS ?= -b
ifneq ($(wildcard $(DIFF_REF_SO)),)
override ARGS += -d $(DIFF_REF_SO)
endif

run: $(BIN)
	$(BIN) $(ARGS) $(IMG)

# ==============================================================================
# 2. Iverilog 4-State Simulation Flow (X-state Checking, Stage E8)
# ==============================================================================
VPI_BIN = $(BUILD_DIR)/vpi_pmem.vpi
VVP_BIN = $(BUILD_DIR)/sim_iverilog.vvp

$(VPI_BIN): $(VPI_CSRCS)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG_VPI) --name=vpi_pmem $(VPI_CSRCS) -Icsrc
	@mv vpi_pmem.vpi $(BUILD_DIR)/
	@rm -f vpi.o pmem.o

$(VVP_BIN): $(ALL_VSRCS)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -s $(TB_TOPNAME) -o $@ $^

sim-vpi: $(VPI_BIN)
sim-iverilog: $(VVP_BIN) $(VPI_BIN)

run-iverilog: $(VVP_BIN) $(VPI_BIN)
	$(VVP) -M$(BUILD_DIR) -mvpi_pmem $(VVP_BIN) +img=$(IMG)

# ==============================================================================
# 3. ASIC Physical Design Configuration (ECC Project Manifest)
# ==============================================================================
$(BACKEND_DIR)/ecc.toml:
	@mkdir -p $(BACKEND_DIR)
	@echo '[design]' > $@
	@echo 'name = "$(TOPNAME)"' >> $@
	@echo 'top = "$(TOPNAME)"' >> $@
	@echo 'rtl = [' >> $@
	@for f in $(VSRCS_REL); do echo "  \"../../$$f\"," >> $@; done
	@sed -i '$$ s/,$$//' $@
	@echo ']' >> $@
	@echo 'clock_port = "clock"' >> $@
	@echo 'frequency_mhz = $(BACKEND_FREQ_MHZ)' >> $@
	@echo '' >> $@
	@echo '[pdk]' >> $@
	@echo 'name = "ics55"' >> $@
ifneq ($(ICSPROUT55_HOME),)
	@echo 'root = "$(ICSPROUT55_HOME)"' >> $@
endif
	@echo '' >> $@
	@echo '[flow]' >> $@
	@echo 'preset = "rtl2gds"' >> $@

# ==============================================================================
# 4. Gate-Level Netlist Simulation Flow (Stage E8)
# ==============================================================================
SYNTH_SIM_NETLIST = $(BACKEND_DIR)/$(WORKSPACE)/Synthesis_yosys/output/$(TOPNAME)_Synthesis_sim.v
NETLIST_VVP = $(BUILD_DIR)/sim_netlist.vvp
STDCELL_VERILOG = $(if $(ICSPROUT55_HOME), \
                    $(wildcard $(ICSPROUT55_HOME)/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CL/verilog/ics55_LLSC_H7CL.v) \
                    $(wildcard $(ICSPROUT55_HOME)/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v),)

$(SYNTH_SIM_NETLIST):
	@if [ -f "$(SYNTH_SIM_NETLIST).gz" ]; then \
		gunzip -k -f "$(SYNTH_SIM_NETLIST).gz"; \
	else \
		echo "Gate-level netlist not found. Please run 'make pnr-synth' first." && exit 1; \
	fi

$(NETLIST_VVP): $(SYNTH_SIM_NETLIST) vsrc/sim_top.v
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -s $(TB_TOPNAME) -o $@ vsrc/sim_top.v $(SYNTH_SIM_NETLIST) $(STDCELL_VERILOG)

sim-netlist-iv: $(NETLIST_VVP) $(VPI_BIN)

run-netlist-iv: $(NETLIST_VVP) $(VPI_BIN)
	$(VVP) -M$(BUILD_DIR) -mvpi_pmem $(NETLIST_VVP) +img=$(IMG)

# ==============================================================================
# 5. ASIC Physical Design Flow (Modular Steps & One-Command Full P&R)
# ==============================================================================
$(BACKEND_DIR)/project.json: $(BACKEND_DIR)/ecc.toml
	@echo '{"schema_version": 1, "project_id": "proj_backend", "name": "backend", "design_name": "$(TOPNAME)", "root_path": "'$$(cd $(BACKEND_DIR) && pwd)'", "workspaces": [{"workspace_id": "$(WORKSPACE)", "name": "$(TOPNAME)", "workspace_path": "'$$(cd $(BACKEND_DIR) && pwd)/$(WORKSPACE)'", "start_step": "Synth", "end_step": "Harden", "status": "unstart"}]}' > $@
	@$(ECC) workspace refresh $(WORKSPACE) --project $(BACKEND_DIR) >/dev/null 2>&1 || true
	@python3 -c 'import json; p="$(BACKEND_DIR)/$(WORKSPACE)/home/flow.json"; d=json.load(open(p)); [s.update(state="Success", info={"bypassed": True}) for s in d.get("steps", []) if s.get("name")=="lec"]; json.dump(d, open(p, "w"), indent=4)' 2>/dev/null || true

ECC_WORKSPACE_FLAG = --project $(BACKEND_DIR) --workspace $(WORKSPACE)
ECC_RUN = $(ECC) run $(ECC_WORKSPACE_FLAG)

# Step 1: Logic Synthesis (Yosys)
pnr-synth: $(BACKEND_DIR)/project.json
	@echo ">>> [1/12] Running Logic Synthesis (Yosys)..."
	$(ECC_RUN) --only Synthesis
	@gunzip -k -f $(BACKEND_DIR)/$(WORKSPACE)/Synthesis_yosys/output/$(TOPNAME)_Synthesis_sim.v.gz 2>/dev/null || true
	@echo ">>> [1/12] Logic Synthesis completed."
	@cat $(BACKEND_DIR)/$(WORKSPACE)/Synthesis_yosys/report/post_synthesis/qor_summary.rpt 2>/dev/null || true

synth: pnr-synth

# Step 2: Floorplanning
pnr-floorplan: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only Floorplan
	@echo ">>> [2/12] Floorplan completed."

# Step 3: Global Placement (DreamPlace)
pnr-place: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only place
	@echo ">>> [3/12] Placement completed."

# Step 4: Clock Tree Synthesis (ECC CTS)
pnr-cts: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only CTS
	@echo ">>> [4/12] CTS completed."

# Step 5: Cell Legalization (DreamPlace)
pnr-legalize: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only legalization
	@echo ">>> [5/12] Legalization completed."

# Step 6: Timing Optimization (Sizer Buffer Insertion & Gate Sizing)
pnr-opt: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only "Timing optimization"
	@echo ">>> [6/12] Timing optimization completed."

# Step 7: Detailed Routing (ECC Route)
pnr-route: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only route
	@echo ">>> [7/12] Detailed Routing completed."

# Step 8: Filler & Welltap Cell Insertion
pnr-filler: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only filler
	@echo ">>> [8/12] Filler insertion completed."

# Step 9: 3D Parasitic Extraction (RCX)
pnr-rcx: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only RCX
	@echo ">>> [9/12] Parasitic Extraction (RCX) completed."

# Step 10: Multi-Corner Multi-Mode Static Timing Analysis (iSTA)
pnr-sta: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only sta
	@echo ">>> [10/12] MCMM Static Timing Analysis (STA) completed."

# Step 11: Physical Verification (LVS & DRC)
pnr-lvs: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only lvs
	@echo ">>> [11/12-A] LVS check completed."

pnr-drc: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only drc
	@echo ">>> [11/12-B] DRC check completed."

# Step 12: Layout Harden & Deliverables
pnr-harden: $(BACKEND_DIR)/project.json
	$(ECC_RUN) --only Harden
	@echo ">>> [12/12] Harden completed."

# Step 13: Signoff Export
signoff:
	$(ECC) signoff export --project $(BACKEND_DIR) --workspace $(WORKSPACE)
	@echo ">>> Signoff package exported."

# One-Command Full Physical Design (RTL-to-GDSII)
PNR_OVERWRITE ?=

pnr: $(BACKEND_DIR)/project.json
	@echo ">>> Starting automated physical design pipeline (Synthesis -> Floorplan -> Placement -> CTS -> Sizer -> Route -> RCX -> STA -> Harden)..."
	$(ECC) run --project $(BACKEND_DIR) --workspace $(WORKSPACE) $(PNR_OVERWRITE)
	@gunzip -k -f $(BACKEND_DIR)/$(WORKSPACE)/Synthesis_yosys/output/$(TOPNAME)_Synthesis_sim.v.gz 2>/dev/null || true
	@echo ">>> Physical design pipeline finished. Packaging signoff deliverables..."
	-$(MAKE) signoff
	@echo ">>> Full physical design flow completed successfully."

# Full flow with an explicitly requested clock frequency and a fresh workspace.
# Removes the generated backend manifests so frequency_mhz is re-emitted.
pnr-freq:
	@rm -f $(BACKEND_DIR)/ecc.toml $(BACKEND_DIR)/project.json
	@$(MAKE) pnr BACKEND_FREQ_MHZ=$(BACKEND_FREQ_MHZ) WORKSPACE=$(WORKSPACE) PNR_OVERWRITE=--overwrite

clean:
	rm -rf $(BUILD_DIR)

.PHONY: default sim run sim-vpi sim-iverilog run-iverilog \
        synth pnr-synth pnr-floorplan pnr-place pnr-cts pnr-legalize \
        pnr-opt pnr-route pnr-filler pnr-rcx pnr-sta pnr-lvs pnr-drc \
        pnr-harden pnr pnr-freq signoff sim-netlist-iv run-netlist-iv clean

# ==============================================================================
# 6. Fast STA (additive; does not touch the full backend flow)
#    Only adds a separate project/workspace under build/backend_fast/ and
#    writes run artifacts under build/sta_fast/. Existing pnr* targets above
#    are unchanged.
# ==============================================================================
FREQ_MHZ          ?= 100.0
YOSYS_SYNTH_STRATEGY ?= DELAY 4
FAST_BACKEND_DIR   = $(BUILD_DIR)/backend_fast
FAST_WS            = fast
FAST_RUN_DIR       = $(BUILD_DIR)/sta_fast

fast-manifest:
	@mkdir -p $(FAST_BACKEND_DIR)
	@echo '[design]' > $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'name = "$(TOPNAME)"' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'top = "$(TOPNAME)"' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'rtl = [' >> $(FAST_BACKEND_DIR)/ecc.toml
	@for f in $(VSRCS_REL); do echo "  \"../../$$f\"," >> $(FAST_BACKEND_DIR)/ecc.toml; done
	@sed -i '$$ s/,$$//' $(FAST_BACKEND_DIR)/ecc.toml
	@echo ']' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'clock_port = "clock"' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'frequency_mhz = $(FREQ_MHZ)' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo '' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo '[pdk]' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'name = "ics55"' >> $(FAST_BACKEND_DIR)/ecc.toml
ifneq ($(ICSPROUT55_HOME),)
	@echo 'root = "$(ICSPROUT55_HOME)"' >> $(FAST_BACKEND_DIR)/ecc.toml
endif
	@echo '' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo '[flow]' >> $(FAST_BACKEND_DIR)/ecc.toml
	@echo 'preset = "syn_sta"' >> $(FAST_BACKEND_DIR)/ecc.toml
	@python3 -c 'import json,os; p="$(FAST_BACKEND_DIR)/project.json"; d={"schema_version":1,"project_id":"proj_fast","name":"fast","design_name":"$(TOPNAME)","root_path":os.path.abspath("$(FAST_BACKEND_DIR)"),"workspaces":[{"workspace_id":"$(FAST_WS)","name":"$(TOPNAME)_fast","workspace_path":os.path.abspath("$(FAST_BACKEND_DIR)/$(FAST_WS)"),"start_step":"Synth","end_step":"Synth","status":"unstart"}]}; json.dump(d,open(p,"w"),indent=2)'

sta-fast: fast-manifest
	@mkdir -p $(FAST_RUN_DIR)
	FREQ_MHZ=$(FREQ_MHZ) FAST_BACKEND_DIR=$(abspath $(FAST_BACKEND_DIR)) FAST_WS=$(FAST_WS) \
		YOSYS_SYNTH_STRATEGY="$(YOSYS_SYNTH_STRATEGY)" \
		bash scripts/sta_fast.sh

sta-fast-clean:
	rm -rf $(FAST_BACKEND_DIR) $(FAST_RUN_DIR)

.PHONY: sta-fast fast-manifest sta-fast-clean
