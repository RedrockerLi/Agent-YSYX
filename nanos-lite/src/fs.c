#include <fs.h>

typedef size_t (*ReadFn) (void *buf, size_t offset, size_t len);
typedef size_t (*WriteFn) (const void *buf, size_t offset, size_t len);

typedef struct {
  char *name;
  size_t size;
  size_t disk_offset;
  ReadFn read;
  WriteFn write;
  size_t open_offset;
} Finfo;

enum {FD_STDIN, FD_STDOUT, FD_STDERR, FD_FB, FD_EVENTS, FD_DISPINFO};

size_t invalid_read(void *buf, size_t offset, size_t len) {
  panic("should not reach here");
  return 0;
}

size_t invalid_write(const void *buf, size_t offset, size_t len) {
  panic("should not reach here");
  return 0;
}

size_t ramdisk_read(void *buf, size_t offset, size_t len);
size_t ramdisk_write(const void *buf, size_t offset, size_t len);
size_t serial_write(const void *buf, size_t offset, size_t len);
size_t events_read(void *buf, size_t offset, size_t len);
size_t dispinfo_read(void *buf, size_t offset, size_t len);
size_t fb_write(const void *buf, size_t offset, size_t len);

/* This is the information about all files in disk. */
static Finfo file_table[] __attribute__((used)) = {
  [FD_STDIN]    = {"stdin", 0, 0, invalid_read, invalid_write, 0},
  [FD_STDOUT]   = {"stdout", 0, 0, invalid_read, serial_write, 0},
  [FD_STDERR]   = {"stderr", 0, 0, invalid_read, serial_write, 0},
  [FD_FB]       = {"/dev/fb", 0, 0, invalid_read, fb_write, 0},
  [FD_EVENTS]   = {"/dev/events", 0, 0, events_read, invalid_write, 0},
  [FD_DISPINFO] = {"/proc/dispinfo", 0, 0, dispinfo_read, invalid_write, 0},
#include "files.h"
};

#define NR_FILES (sizeof(file_table) / sizeof(file_table[0]))

void init_fs() {
  AM_GPU_CONFIG_T cfg = io_read(AM_GPU_CONFIG);
  file_table[FD_FB].size = cfg.width * cfg.height * 4;
}

int fs_open(const char *pathname, int flags, int mode) {
  for (int i = 0; i < NR_FILES; i++) {
    if (file_table[i].name && strcmp(file_table[i].name, pathname) == 0) {
      file_table[i].open_offset = 0;
      return i;
    }
  }
  Log("File not found: %s", pathname);
  return -1;
}

size_t fs_read(int fd, void *buf, size_t len) {
  if (fd < 0 || fd >= NR_FILES) return -1;
  Finfo *f = &file_table[fd];
  if (f->read != NULL) {
    return f->read(buf, f->open_offset, len);
  }

  if (f->open_offset >= f->size) return 0;
  if (f->open_offset + len > f->size) {
    len = f->size - f->open_offset;
  }
  ramdisk_read(buf, f->disk_offset + f->open_offset, len);
  f->open_offset += len;
  return len;
}

size_t fs_write(int fd, const void *buf, size_t len) {
  if (fd < 0 || fd >= NR_FILES) return -1;
  Finfo *f = &file_table[fd];
  if (f->write != NULL) {
    return f->write(buf, f->open_offset, len);
  }

  if (f->open_offset >= f->size) return 0;
  if (f->open_offset + len > f->size) {
    len = f->size - f->open_offset;
  }
  ramdisk_write(buf, f->disk_offset + f->open_offset, len);
  f->open_offset += len;
  return len;
}

size_t fs_lseek(int fd, size_t offset, int whence) {
  if (fd < 0 || fd >= NR_FILES) return -1;
  Finfo *f = &file_table[fd];
  switch (whence) {
    case SEEK_SET:
      f->open_offset = offset;
      break;
    case SEEK_CUR:
      f->open_offset += offset;
      break;
    case SEEK_END:
      f->open_offset = f->size + offset;
      break;
    default:
      return -1;
  }
  return f->open_offset;
}

int fs_close(int fd) {
  return 0;
}
