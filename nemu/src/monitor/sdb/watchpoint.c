/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include "sdb.h"

#define NR_WP 32

static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool() {
  int i;
  for (i = 0; i < NR_WP; i ++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
    wp_pool[i].expr_str[0] = '\0';
    wp_pool[i].old_val = 0;
  }

  head = NULL;
  free_ = wp_pool;
}

WP* new_wp(char *expr_str, bool *success) {
  if (free_ == NULL) {
    printf("Error: no free watchpoint available in pool (max %d)\n", NR_WP);
    *success = false;
    return NULL;
  }

  word_t val = expr(expr_str, success);
  if (!(*success)) {
    printf("Error: expression evaluation failed for '%s'\n", expr_str);
    return NULL;
  }

  WP *wp = free_;
  free_ = free_->next;

  wp->next = head;
  head = wp;

  strncpy(wp->expr_str, expr_str, sizeof(wp->expr_str) - 1);
  wp->expr_str[sizeof(wp->expr_str) - 1] = '\0';
  wp->old_val = val;

  *success = true;
  return wp;
}

bool free_wp(int no) {
  WP *prev = NULL;
  WP *curr = head;

  while (curr != NULL) {
    if (curr->NO == no) {
      if (prev == NULL) {
        head = curr->next;
      } else {
        prev->next = curr->next;
      }

      curr->next = free_;
      free_ = curr;
      curr->expr_str[0] = '\0';
      curr->old_val = 0;
      return true;
    }
    prev = curr;
    curr = curr->next;
  }

  return false;
}

void print_wp() {
  if (head == NULL) {
    printf("No active watchpoints.\n");
    return;
  }

  printf("%-8s %-32s %-16s %-16s\n", "Num", "Expression", "Value (Hex)", "Value (Dec)");
  WP *wp = head;
  while (wp != NULL) {
    printf("%-8d %-32s 0x%-14x %-16u\n", wp->NO, wp->expr_str, wp->old_val, wp->old_val);
    wp = wp->next;
  }
}

bool check_wp() {
  bool triggered = false;
  WP *wp = head;

  while (wp != NULL) {
    bool success = false;
    word_t new_val = expr(wp->expr_str, &success);
    if (!success) {
      printf("Warning: failed to re-evaluate watchpoint %d ('%s')\n", wp->NO, wp->expr_str);
    } else if (new_val != wp->old_val) {
      printf("\nWatchpoint %d triggered: %s\n", wp->NO, wp->expr_str);
      printf("  Old value = 0x%08x (%u)\n", wp->old_val, wp->old_val);
      printf("  New value = 0x%08x (%u)\n", new_val, new_val);
      wp->old_val = new_val;
      triggered = true;
    }
    wp = wp->next;
  }

  return triggered;
}
