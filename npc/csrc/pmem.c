#include "pmem.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static uint8_t pmem[PMEM_SIZE];
bool g_skip_difftest = false;

uint8_t *get_pmem(void) {
  return pmem;
}

uint64_t get_time_us(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

static inline bool is_mmio(uint32_t addr) {
  return (addr >= 0xa0000000u && addr < 0xa2000000u);
}

void init_pmem(const char *img_file) {
  if (!img_file) return;
  FILE *fp = fopen(img_file, "rb");
  if (!fp) {
    fprintf(stderr, "[PMEM] Warning: Unable to open binary image: %s\n", img_file);
    return;
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);

  if (size > (long)PMEM_SIZE) size = PMEM_SIZE;
  size_t nread = fread(pmem, 1, size, fp);
  fclose(fp);
  printf("[PMEM] Loaded %zu bytes from '%s' into PMEM [0x%08x]\n", nread, img_file, PMEM_BASE);
}

int pmem_read(int raddr, char rlen) {
  uint32_t addr = (uint32_t)raddr;
  if (addr >= PMEM_BASE && addr < PMEM_BASE + PMEM_SIZE) {
    uint32_t offset = addr - PMEM_BASE;
    uint32_t val = 0;
    memcpy(&val, &pmem[offset], (rlen > 4 || rlen <= 0) ? 4 : rlen);
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

void pmem_write(int waddr, int wdata, char wmask) {
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
