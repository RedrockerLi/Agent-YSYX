#include <am.h>

bool vme_init(void* (*pgalloc_f)(int), void (*pgfree_f)(void*)) {
  return false;
}

void protect(AddrSpace *as) {
}

void unprotect(AddrSpace *as) {
}

void map(AddrSpace *as, void *va, void *pa, int prot) {
}

Context *ucontext(AddrSpace *as, Area kstack, void *entry) {
  Context *c = (Context *)((uint8_t *)kstack.end - sizeof(Context));
  for (int i = 0; i < sizeof(Context); i++) {
    ((char *)c)[i] = 0;
  }
  c->mepc = (uintptr_t)entry;
  c->mstatus = 0x1800; // MPP = 3
  c->pdir = (as != (void *)0) ? as->ptr : (void *)0;
  c->gpr[2] = (uintptr_t)c;
  return c;
}
