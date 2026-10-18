/***************************************************************************************
* ftrace.c - Function Call/Return Tracer
***************************************************************************************/

#include <common.h>
#include <elf.h>

typedef struct {
  char name[64];
  vaddr_t addr;
  size_t size;
} FuncInfo;

static FuncInfo *func_table = NULL;
static int func_cnt = 0;
static int call_depth = 0;
static bool ftrace_enabled = false;

void init_ftrace(const char *elf_file) {
  if (elf_file == NULL) return;

  FILE *fp = NULL;
  char alt_path[512];
  const char *dot = strrchr(elf_file, '.');
  if (dot && strcmp(dot, ".bin") == 0) {
    int prefix_len = dot - elf_file;
    snprintf(alt_path, sizeof(alt_path), "%.*s.elf", prefix_len, elf_file);
    fp = fopen(alt_path, "rb");
  }
  if (!fp) {
    fp = fopen(elf_file, "rb");
  }
  if (!fp) {
    snprintf(alt_path, sizeof(alt_path), "%s.elf", elf_file);
    fp = fopen(alt_path, "rb");
  }

  if (!fp) return;

  Elf32_Ehdr ehdr;
  if (fread(&ehdr, sizeof(Elf32_Ehdr), 1, fp) != 1) {
    fclose(fp);
    return;
  }

  if (memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0 || ehdr.e_ident[EI_CLASS] != ELFCLASS32) {
    fclose(fp);
    return;
  }

  Elf32_Shdr *shdrs = malloc(sizeof(Elf32_Shdr) * ehdr.e_shnum);
  fseek(fp, ehdr.e_shoff, SEEK_SET);
  if (fread(shdrs, sizeof(Elf32_Shdr), ehdr.e_shnum, fp) != ehdr.e_shnum) {
    free(shdrs);
    fclose(fp);
    return;
  }

  Elf32_Shdr *symtab_hdr = NULL;
  Elf32_Shdr *strtab_hdr = NULL;

  for (int i = 0; i < ehdr.e_shnum; i++) {
    if (shdrs[i].sh_type == SHT_SYMTAB) {
      symtab_hdr = &shdrs[i];
      if (symtab_hdr->sh_link < ehdr.e_shnum) {
        strtab_hdr = &shdrs[symtab_hdr->sh_link];
      }
    }
  }

  if (!symtab_hdr || !strtab_hdr) {
    free(shdrs);
    fclose(fp);
    return;
  }

  int nr_sym = symtab_hdr->sh_size / sizeof(Elf32_Sym);
  Elf32_Sym *syms = malloc(symtab_hdr->sh_size);
  fseek(fp, symtab_hdr->sh_offset, SEEK_SET);
  if (fread(syms, symtab_hdr->sh_size, 1, fp) != 1) {
    free(syms);
    free(shdrs);
    fclose(fp);
    return;
  }

  char *strtab = malloc(strtab_hdr->sh_size);
  fseek(fp, strtab_hdr->sh_offset, SEEK_SET);
  if (fread(strtab, strtab_hdr->sh_size, 1, fp) != 1) {
    free(strtab);
    free(syms);
    free(shdrs);
    fclose(fp);
    return;
  }

  func_table = malloc(sizeof(FuncInfo) * nr_sym);
  func_cnt = 0;

  for (int i = 0; i < nr_sym; i++) {
    if (ELF32_ST_TYPE(syms[i].st_info) == STT_FUNC) {
      func_table[func_cnt].addr = syms[i].st_value;
      func_table[func_cnt].size = syms[i].st_size;
      strncpy(func_table[func_cnt].name, strtab + syms[i].st_name, sizeof(func_table[0].name) - 1);
      func_table[func_cnt].name[sizeof(func_table[0].name) - 1] = '\0';
      func_cnt++;
    }
  }

  free(strtab);
  free(syms);
  free(shdrs);
  fclose(fp);

  ftrace_enabled = (func_cnt > 0);
  Log("ftrace: successfully loaded %d function symbols", func_cnt);
}

static const char* find_func_name(vaddr_t addr) {
  for (int i = 0; i < func_cnt; i++) {
    if (addr >= func_table[i].addr && addr < func_table[i].addr + func_table[i].size) {
      return func_table[i].name;
    }
  }
  return "???";
}

void ftrace_call(vaddr_t pc, vaddr_t target) {
  if (!ftrace_enabled) return;
  const char *name = find_func_name(target);
  log_write(FMT_WORD ": %*scall [%s@" FMT_WORD "]\n", pc, call_depth * 2, "", name, target);
  call_depth++;
}

void ftrace_ret(vaddr_t pc) {
  if (!ftrace_enabled) return;
  if (call_depth > 0) call_depth--;
  const char *name = find_func_name(pc);
  log_write(FMT_WORD ": %*sret [%s]\n", pc, call_depth * 2, "", name);
}
