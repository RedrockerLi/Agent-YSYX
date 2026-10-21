#include "trap.h"

/*
 * Directed RV32M test.
 *
 * The default AM target is compiled with -march=rv32e_zicsr (no M), so the
 * regular mul/div tests only exercise the software libgcc routines.  The
 * inline .insn forms below force real M instructions and are also accepted
 * by the rv32e assembler via ".option arch, +m".
 */

#define M_ASM(funct3) \
  ".option push\n" \
  ".option arch, +m\n" \
  ".insn r 0x33, " #funct3 ", 0x01, %0, %1, %2\n" \
  ".option pop\n"

static inline int m_mul(int a, int b) {
  int r;
  asm volatile(M_ASM(0) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_mulh(int a, int b) {
  int r;
  asm volatile(M_ASM(1) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_mulhsu(int a, int b) {
  int r;
  asm volatile(M_ASM(2) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_mulhu(int a, int b) {
  int r;
  asm volatile(M_ASM(3) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_div(int a, int b) {
  int r;
  asm volatile(M_ASM(4) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_divu(int a, int b) {
  int r;
  asm volatile(M_ASM(5) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_rem(int a, int b) {
  int r;
  asm volatile(M_ASM(6) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static inline int m_remu(int a, int b) {
  int r;
  asm volatile(M_ASM(7) : "=r"(r) : "r"(a), "r"(b));
  return r;
}

#define INT_MIN32 ((int)0x80000000)
#define INT_MAX32 ((int)0x7fffffff)

static const int test_data[] = {
  0, 1, -1, 2, 3, 7, 15, 16,
  INT_MAX32, INT_MIN32,
  0x12345678, (int)0x87654321,
  (int)0xfffffffe, (int)0xffffffff,
  31, 32,
};

#define NR_DATA ((int)(sizeof(test_data) / sizeof(test_data[0])))

int main() {
  int i, j;
  for (i = 0; i < NR_DATA; i ++) {
    for (j = 0; j < NR_DATA; j ++) {
      int a = test_data[i];
      int b = test_data[j];
      unsigned int ua = (unsigned int)a;
      unsigned int ub = (unsigned int)b;
      unsigned long long uprod = (unsigned long long)ua * (unsigned long long)ub;
      long long sprod = (long long)a * (long long)b;
      long long sprou = (long long)a * (long long)ub;

      check(m_mul(a, b) == (int)uprod);
      check(m_mulh(a, b) == (int)((unsigned long long)sprod >> 32));
      check(m_mulhsu(a, b) == (int)((unsigned long long)sprou >> 32));
      check(m_mulhu(a, b) == (int)(uprod >> 32));

      if (b == 0) {
        check(m_div(a, b) == -1);
        check(m_rem(a, b) == a);
        check(m_divu(a, b) == (int)0xffffffff);
        check(m_remu(a, b) == a);
      } else if (a == INT_MIN32 && b == -1) {
        check(m_div(a, b) == INT_MIN32);
        check(m_rem(a, b) == 0);
        check(m_divu(a, b) == (int)(ua / ub));
        check(m_remu(a, b) == (int)(ua % ub));
      } else {
        check(m_div(a, b) == (int)((long long)a / (long long)b));
        check(m_rem(a, b) == (int)((long long)a % (long long)b));
        check(m_divu(a, b) == (int)(ua / ub));
        check(m_remu(a, b) == (int)(ua % ub));
      }
    }
  }

  return 0;
}
