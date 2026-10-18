#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>

#include "VElaborateTop.h"
#include "VElaborateTop___024root.h"
#include "verilated.h"

static uint8_t *flash_mem = NULL;
static size_t flash_size = 0;

extern "C" void flash_read(int addr, int *data) {
  uint32_t a = (uint32_t)addr;
  if (flash_mem && a < flash_size) {
    uint32_t val = 0;
    size_t rem = flash_size - a;
    if (rem >= 4) {
      memcpy(&val, flash_mem + a, 4);
    } else {
      memcpy(&val, flash_mem + a, rem);
    }
    *data = (int)val;
  } else {
    *data = 0;
  }
}

// DPI-C hooks from core
extern "C" int pmem_read(int raddr, char rlen) {
  uint32_t a = (uint32_t)raddr;
  // If flash read in XIP space (0x30000000 - 0x3fffffff)
  if (a >= 0x30000000u && a < 0x40000000u) {
    int val = 0;
    flash_read(a - 0x30000000u, &val);
    return val;
  }
  return 0;
}

extern "C" void pmem_write(int waddr, int wdata, char wmask) {
}

extern "C" void npc_ebreak(int pc, int a0) {
  printf("\n[ysyxSoC] EBREAK reached at pc=0x%08x (a0=%d)\n", (uint32_t)pc, a0);
  exit(a0 == 0 ? 0 : 1);
}

int main(int argc, char *argv[]) {
  Verilated::commandArgs(argc, argv);

  const char *img_file = "ready-to-run/minirv/hello-minirv-ysyxsoc.bin";
  if (argc > 1) {
    img_file = argv[1];
  }

  FILE *fp = fopen(img_file, "rb");
  if (!fp) {
    printf("Cannot open flash image: %s\n", img_file);
    return 1;
  }
  fseek(fp, 0, SEEK_END);
  flash_size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  flash_mem = (uint8_t *)malloc(flash_size);
  assert(fread(flash_mem, flash_size, 1, fp) == 1);
  fclose(fp);
  printf("[ysyxSoC] Loaded flash image '%s', size = %zu bytes\n", img_file, flash_size);

  VElaborateTop *top = new VElaborateTop;

  // Reset sequence
  top->reset = 1;
  for (int i = 0; i < 30; i++) {
    top->clock = 0; top->eval();
    top->clock = 1; top->eval();
  }
  top->reset = 0;

  printf("[ysyxSoC] Starting SoC simulation...\n");
  for (uint64_t cycle = 0; cycle < 200000000; cycle++) {
    top->clock = 0; top->eval();
    top->clock = 1; top->eval();
    if (cycle % 20000000 == 0 && cycle > 0) {
      printf("[ysyxSoC] Simulated %luM cycles...\n", cycle / 1000000);
      fflush(stdout);
    }
  }

  uint32_t end_pc = top->rootp->ElaborateTop__DOT__dut__DOT__asic__DOT__soc__DOT__cpu__DOT__core0__DOT__u_core__DOT__pc;
  printf("\n[ysyxSoC] Simulation completed. End PC = 0x%08x\n", end_pc);
  delete top;
  free(flash_mem);
  return 0;
}
