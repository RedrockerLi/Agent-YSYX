#include <vpi_user.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "pmem.h"

static uint64_t cycle_count = 0;

// $pmem_init_task(string image_file)
static PLI_INT32 pmem_init_calltf(char *user_data) {
  (void)user_data;
  vpiHandle callh = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle arg_iter = vpi_iterate(vpiArgument, callh);
  if (!arg_iter) return 0;

  vpiHandle img_arg = vpi_scan(arg_iter);
  s_vpi_value val;
  val.format = vpiStringVal;
  vpi_get_value(img_arg, &val);

  init_pmem(val.value.str);
  return 0;
}

// $pmem_read_func(addr, len) -> 32-bit word
static PLI_INT32 pmem_read_calltf(char *user_data) {
  (void)user_data;
  vpiHandle callh = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle arg_iter = vpi_iterate(vpiArgument, callh);
  if (!arg_iter) return 0;

  vpiHandle addr_arg = vpi_scan(arg_iter);
  vpiHandle len_arg = vpi_scan(arg_iter);

  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(addr_arg, &val);
  uint32_t addr = (uint32_t)val.value.integer;

  int rlen = 4;
  if (len_arg) {
    vpi_get_value(len_arg, &val);
    rlen = val.value.integer;
  }

  uint32_t rdata = (uint32_t)pmem_read((int)addr, (char)rlen);

  val.format = vpiIntVal;
  val.value.integer = (int)rdata;
  vpi_put_value(callh, &val, NULL, vpiNoDelay);
  return 0;
}

static PLI_INT32 pmem_read_sizetf(char *user_data) {
  (void)user_data;
  return 32;
}

// $pmem_write_task(addr, data, mask)
static PLI_INT32 pmem_write_calltf(char *user_data) {
  (void)user_data;
  vpiHandle callh = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle arg_iter = vpi_iterate(vpiArgument, callh);
  if (!arg_iter) return 0;

  vpiHandle addr_arg = vpi_scan(arg_iter);
  vpiHandle data_arg = vpi_scan(arg_iter);
  vpiHandle mask_arg = vpi_scan(arg_iter);

  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(addr_arg, &val);
  uint32_t addr = (uint32_t)val.value.integer;

  vpi_get_value(data_arg, &val);
  uint32_t data = (uint32_t)val.value.integer;

  vpi_get_value(mask_arg, &val);
  uint8_t mask = (uint8_t)val.value.integer;

  pmem_write((int)addr, (int)data, (char)mask);
  return 0;
}

// $npc_ebreak_task(pc, a0)
static PLI_INT32 npc_ebreak_calltf(char *user_data) {
  (void)user_data;
  vpiHandle callh = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle arg_iter = vpi_iterate(vpiArgument, callh);
  if (!arg_iter) return 0;

  vpiHandle pc_arg = vpi_scan(arg_iter);
  vpiHandle a0_arg = vpi_scan(arg_iter);

  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(pc_arg, &val);
  uint32_t pc = (uint32_t)val.value.integer;

  vpi_get_value(a0_arg, &val);
  int a0 = val.value.integer;

  if (a0 == 0) {
    vpi_printf("\033[1;32mnpc [4-state/iverilog]: HIT GOOD TRAP at pc = 0x%08x (cycles = %lu)\033[0m\n", pc, cycle_count);
  } else {
    vpi_printf("\033[1;31mnpc [4-state/iverilog]: HIT BAD TRAP at pc = 0x%08x (a0 = %d, cycles = %lu)\033[0m\n", pc, a0, cycle_count);
  }

  vpi_control(vpiFinish, a0 == 0 ? 0 : 1);
  return 0;
}

// $sim_tick_task()
static PLI_INT32 sim_tick_calltf(char *user_data) {
  (void)user_data;
  cycle_count++;
  if (cycle_count >= 50000000ULL) {
    vpi_printf("\033[1;31mnpc [4-state/iverilog]: Simulation TIMEOUT after %lu cycles!\033[0m\n", cycle_count);
    vpi_control(vpiFinish, 1);
  }
  return 0;
}

void register_vpi_pmem_tasks(void) {
  s_vpi_systf_data tf_data;

  // 1. $pmem_init_task
  memset(&tf_data, 0, sizeof(tf_data));
  tf_data.type      = vpiSysTask;
  tf_data.tfname    = "$pmem_init_task";
  tf_data.calltf    = pmem_init_calltf;
  tf_data.compiletf = NULL;
  tf_data.sizetf    = NULL;
  vpi_register_systf(&tf_data);

  // 2. $pmem_read_func
  memset(&tf_data, 0, sizeof(tf_data));
  tf_data.type      = vpiSysFunc;
  tf_data.sysfunctype = vpiIntFunc;
  tf_data.tfname    = "$pmem_read_func";
  tf_data.calltf    = pmem_read_calltf;
  tf_data.compiletf = NULL;
  tf_data.sizetf    = pmem_read_sizetf;
  vpi_register_systf(&tf_data);

  // 3. $pmem_write_task
  memset(&tf_data, 0, sizeof(tf_data));
  tf_data.type      = vpiSysTask;
  tf_data.tfname    = "$pmem_write_task";
  tf_data.calltf    = pmem_write_calltf;
  tf_data.compiletf = NULL;
  tf_data.sizetf    = NULL;
  vpi_register_systf(&tf_data);

  // 4. $npc_ebreak_task
  memset(&tf_data, 0, sizeof(tf_data));
  tf_data.type      = vpiSysTask;
  tf_data.tfname    = "$npc_ebreak_task";
  tf_data.calltf    = npc_ebreak_calltf;
  tf_data.compiletf = NULL;
  tf_data.sizetf    = NULL;
  vpi_register_systf(&tf_data);

  // 5. $sim_tick_task
  memset(&tf_data, 0, sizeof(tf_data));
  tf_data.type      = vpiSysTask;
  tf_data.tfname    = "$sim_tick_task";
  tf_data.calltf    = sim_tick_calltf;
  tf_data.compiletf = NULL;
  tf_data.sizetf    = NULL;
  vpi_register_systf(&tf_data);
}

void (*vlog_startup_routines[])(void) = {
  register_vpi_pmem_tasks,
  0
};
