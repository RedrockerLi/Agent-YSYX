TOPNAME = ElaborateTop
BUILD_DIR = ./build
BIN = $(BUILD_DIR)/$(TOPNAME)

VERILATOR = verilator
VERILATOR_FLAGS = --build -cc --exe -O3 --no-timing \
	-DPDK_BEHAV \
	-Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PINMISSING -Wno-WIDTH \
	-Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-SELRANGE -Wno-MULTITOP \
	-Wno-PINCONNECTEMPTY -Wno-VARHIDDEN \
	-I../perip/spi/rtl -I../perip/uart16550/rtl \
	--top-module $(TOPNAME) \
	--Mdir $(BUILD_DIR)/obj_dir -o $(abspath $(BIN))

SRCS = ../ready-to-run/minirv/ElaborateTop.v \
       ../perip/flash/flash.v \
       ../perip/tc_io.v \
       $(wildcard ../perip/psram/*.sv) \
       $(wildcard ../perip/gpio/*.v) \
       $(wildcard ../perip/spi/rtl/*.v) \
       $(wildcard ../perip/uart16550/rtl/*.v) \
       $(wildcard ../../npc/vsrc/*.v) \
       $(abspath sim_main.cpp)

all: $(BIN)

$(BIN): $(SRCS)
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)

run: $(BIN)
	$(BIN) ../ready-to-run/minirv/hello-minirv-ysyxsoc.bin

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run clean
