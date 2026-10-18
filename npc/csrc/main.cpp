#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <dlfcn.h>
#include <getopt.h>
#include <sys/time.h>

#include "Vysyx_261018.h"
#include "verilated.h"
#include "svdpi.h"

#define PMEM_BASE 0x80000000u
#define PMEM_SIZE (128 * 1024 * 1024) // 128 MB

static uint8_t pmem[PMEM_SIZE];
static Vysyx_261018 *top = NULL;
static uint64_t g_cycle_cnt = 0;
static uint64_t g_inst_cnt = 0;

enum { NPC_RUNNING, NPC_STOP, NPC_END, NPC_ABORT };
static int npc_state = NPC_RUNNING;
static int halt_ret = 0;
static uint32_t halt_pc = 0;

// Exported from Verilog DPI-C
extern "C" int get_pc();
extern "C" int get_gpr(int idx);

static inline void set_dpi_scope() {
  static svScope scope = NULL;
  if (!scope) {
    scope = svGetScopeFromName("TOP.ysyx_261018");
  }
  if (scope) {
    svSetScope(scope);
  }
}

// DiffTest types and pointers
enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };
typedef void (*difftest_memcpy_t)(uint32_t addr, void *buf, size_t n, bool direction);
typedef void (*difftest_regcpy_t)(void *dut, bool direction);
typedef void (*difftest_exec_t)(uint64_t n);
typedef void (*difftest_init_t)(int port);

static difftest_memcpy_t ref_difftest_memcpy = NULL;
static difftest_regcpy_t ref_difftest_regcpy = NULL;
static difftest_exec_t   ref_difftest_exec = NULL;
static difftest_init_t   ref_difftest_init = NULL;
static bool difftest_enabled = false;

static const char *reg_names[32] = {
  "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
  "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
};

static uint64_t get_time_us() {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

static bool g_skip_difftest = false;

static inline bool is_mmio(uint32_t addr) {
  return (addr >= 0xa0000000u && addr < 0xa2000000u);
}

// DPI-C: pmem_read
extern "C" int pmem_read(int raddr, char rlen) {
  uint32_t addr = (uint32_t)raddr;
  if (addr >= PMEM_BASE && addr < PMEM_BASE + PMEM_SIZE) {
    uint32_t offset = addr - PMEM_BASE;
    uint32_t val = 0;
    memcpy(&val, &pmem[offset], (rlen > 4) ? 4 : rlen);
    return (int)val;
  }
  if (is_mmio(addr)) {
    g_skip_difftest = true;
    if (addr == 0xa0000048u) {
      uint64_t us = get_time_us();
      return (int)(us & 0xffffffff);
    } else if (addr == 0xa000004cu) {
      uint64_t us = get_time_us();
      return (int)(us >> 32);
    }
  }
  return 0;
}

// DPI-C: pmem_write
extern "C" void pmem_write(int waddr, int wdata, char wmask) {
  uint32_t addr = (uint32_t)waddr;
  uint32_t data = (uint32_t)wdata;
  uint8_t mask = (uint8_t)wmask;

  if (addr >= PMEM_BASE && addr < PMEM_BASE + PMEM_SIZE) {
    uint32_t offset = addr - PMEM_BASE;
    for (int i = 0; i < 4; i++) {
      if ((mask >> i) & 1) {
        pmem[offset + i] = (data >> (i * 8)) & 0xff;
      }
    }
    return;
  }

  if (is_mmio(addr)) {
    g_skip_difftest = true;
    if (addr == 0xa00003f8u) {
      putchar(data & 0xff);
      fflush(stdout);
    }
    return;
  }
}

// DPI-C: npc_ebreak
extern "C" void npc_ebreak(int pc, int a0) {
  halt_pc = (uint32_t)pc;
  halt_ret = a0;
  if (halt_ret == 0) {
    printf("\033[1;32mnpc: HIT GOOD TRAP at pc = 0x%08x\033[0m\n", halt_pc);
    npc_state = NPC_END;
  } else {
    printf("\033[1;31mnpc: HIT BAD TRAP at pc = 0x%08x (a0 = %d)\033[0m\n", halt_pc, halt_ret);
    npc_state = NPC_ABORT;
  }
}

static void dump_regs() {
  set_dpi_scope();
  printf("------- NPC Register State -------\n");
  for (int i = 0; i < 32; i++) {
    printf("%-4s: 0x%08x  ", reg_names[i], get_gpr(i));
    if ((i + 1) % 4 == 0) printf("\n");
  }
  printf("pc  : 0x%08x\n", (uint32_t)get_pc());
  printf("----------------------------------\n");
}

static bool check_difftest() {
  if (!difftest_enabled) return true;

  set_dpi_scope();

  if (g_skip_difftest) {
    g_skip_difftest = false;
    uint32_t dut_regs[33] = {0};
    for (int i = 0; i < 32; i++) {
      dut_regs[i] = (uint32_t)get_gpr(i);
    }
    dut_regs[32] = (uint32_t)get_pc();
    ref_difftest_regcpy(dut_regs, DIFFTEST_TO_REF);
    return true;
  }

  ref_difftest_exec(1);

  uint32_t ref_regs[33] = {0};
  ref_difftest_regcpy(ref_regs, DIFFTEST_TO_DUT);

  uint32_t dut_pc = (uint32_t)get_pc();
  uint32_t ref_pc = ref_regs[32];

  bool mismatch = false;
  // Compare GPRs (check first 16 for RV32E, or 32 for RV32I)
  for (int i = 0; i < 32; i++) {
    uint32_t dut_val = (uint32_t)get_gpr(i);
    uint32_t ref_val = ref_regs[i];
    if (dut_val != ref_val) {
      printf("\033[1;31mDiffTest Mismatch at PC = 0x%08x!\033[0m\n", dut_pc);
      printf("Register %s (x%d): DUT = 0x%08x, REF = 0x%08x\n", reg_names[i], i, dut_val, ref_val);
      mismatch = true;
    }
  }

  if (mismatch) {
    printf("--- DUT State ---\n");
    dump_regs();
    printf("--- REF State ---\n");
    for (int i = 0; i < 32; i++) {
      printf("%-4s: 0x%08x  ", reg_names[i], ref_regs[i]);
      if ((i + 1) % 4 == 0) printf("\n");
    }
    printf("pc  : 0x%08x\n", ref_pc);
    npc_state = NPC_ABORT;
    return false;
  }
  return true;
}

static void single_cycle() {
  top->clock = 0;
  top->eval();
  top->clock = 1;
  top->eval();
  g_cycle_cnt++;
}

static void step_inst() {
  single_cycle();
  g_inst_cnt++;
  if (npc_state == NPC_RUNNING) {
    check_difftest();
  }
}

static void reset_npc(int cycles) {
  top->reset = 1;
  for (int i = 0; i < cycles; i++) {
    single_cycle();
  }
  top->reset = 0;
  top->eval();
}

static long load_img(const char *img_file) {
  if (!img_file) {
    printf("Error: No image file specified.\n");
    exit(1);
  }
  FILE *fp = fopen(img_file, "rb");
  if (!fp) {
    printf("Error: Cannot open image file '%s'\n", img_file);
    exit(1);
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  assert(size <= (long)PMEM_SIZE);
  int ret = fread(pmem, size, 1, fp);
  assert(ret == 1);
  fclose(fp);
  printf("[npc] Loaded image '%s', size = %ld bytes\n", img_file, size);
  return size;
}

static void init_difftest(const char *ref_so, long img_size) {
  if (!ref_so) return;

  void *handle = dlopen(ref_so, RTLD_LAZY);
  if (!handle) {
    printf("Error loading DiffTest reference '%s': %s\n", ref_so, dlerror());
    exit(1);
  }

  ref_difftest_memcpy = (difftest_memcpy_t)dlsym(handle, "difftest_memcpy");
  ref_difftest_regcpy = (difftest_regcpy_t)dlsym(handle, "difftest_regcpy");
  ref_difftest_exec   = (difftest_exec_t)dlsym(handle, "difftest_exec");
  ref_difftest_init   = (difftest_init_t)dlsym(handle, "difftest_init");

  assert(ref_difftest_memcpy && ref_difftest_regcpy && ref_difftest_exec && ref_difftest_init);

  ref_difftest_init(1234);
  ref_difftest_memcpy(PMEM_BASE, pmem, img_size, DIFFTEST_TO_REF);

  uint32_t init_regs[33] = {0};
  init_regs[32] = PMEM_BASE;
  ref_difftest_regcpy(init_regs, DIFFTEST_TO_REF);

  difftest_enabled = true;
  printf("[npc] DiffTest enabled with reference: %s\n", ref_so);
}

int main(int argc, char *argv[]) {
  Verilated::commandArgs(argc, argv);

  const char *img_file = NULL;
  const char *diff_so = NULL;
  bool batch_mode = false;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-b") == 0 || strcmp(argv[i], "--batch") == 0) {
      batch_mode = true;
    } else if (strncmp(argv[i], "-d=", 3) == 0) {
      diff_so = argv[i] + 3;
    } else if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--diff") == 0) {
      if (i + 1 < argc) diff_so = argv[++i];
    } else if (argv[i][0] != '-') {
      img_file = argv[i];
    }
  }

  top = new Vysyx_261018;

  long img_size = load_img(img_file);
  reset_npc(10);

  if (diff_so) {
    init_difftest(diff_so, img_size);
  }

  uint64_t start_time = get_time_us();

  if (batch_mode) {
    while (npc_state == NPC_RUNNING && g_cycle_cnt < 100000000ULL) {
      step_inst();
    }
  } else {
    // Interactive SDB
    char line[128];
    printf("Welcome to NPC SDB! Type 'c' to run, 'si [N]' to step, 'q' to quit.\n");
    while (npc_state == NPC_RUNNING) {
      printf("(npc) ");
      if (!fgets(line, sizeof(line), stdin)) break;
      char cmd[32];
      int n = 1;
      if (sscanf(line, "%31s %d", cmd, &n) >= 1) {
        if (strcmp(cmd, "q") == 0) {
          break;
        } else if (strcmp(cmd, "c") == 0) {
          while (npc_state == NPC_RUNNING) {
            step_inst();
          }
        } else if (strcmp(cmd, "si") == 0) {
          for (int i = 0; i < n && npc_state == NPC_RUNNING; i++) {
            step_inst();
            printf("pc: 0x%08x\n", (uint32_t)get_pc());
          }
        } else if (strcmp(cmd, "info") == 0) {
          dump_regs();
        }
      }
    }
  }

  uint64_t elapsed_us = get_time_us() - start_time;
  printf("[npc] Simulated %lu instructions in %lu cycles (%lu us)\n",
         g_inst_cnt, g_cycle_cnt, elapsed_us);

  delete top;
  return (npc_state == NPC_END && halt_ret == 0) ? 0 : 1;
}
