#ifndef __PMEM_H__
#define __PMEM_H__

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define PMEM_BASE 0x80000000u
#define PMEM_SIZE (128 * 1024 * 1024) // 128 MB

#ifdef __cplusplus
extern "C" {
#endif

extern bool g_skip_difftest;

void init_pmem(const char *img_file);
int  pmem_read(int raddr, char rlen);
void pmem_write(int waddr, int wdata, char wmask);
uint8_t *get_pmem(void);
uint64_t get_time_us(void);

#ifdef __cplusplus
}
#endif

#endif // __PMEM_H__
