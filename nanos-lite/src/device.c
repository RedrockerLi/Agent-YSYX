#include <common.h>

#if defined(MULTIPROGRAM) && !defined(TIME_SHARING)
# define MULTIPROGRAM_YIELD() yield()
#else
# define MULTIPROGRAM_YIELD()
#endif

#define NAME(key) \
  [AM_KEY_##key] = #key,

static const char *keyname[256] __attribute__((used)) = {
  [AM_KEY_NONE] = "NONE",
  AM_KEYS(NAME)
};

size_t serial_write(const void *buf, size_t offset, size_t len) {
  const char *str = (const char *)buf;
  for (size_t i = 0; i < len; i++) {
    putch(str[i]);
  }
  return len;
}

size_t events_read(void *buf, size_t offset, size_t len) {
  AM_INPUT_KEYBRD_T ev = io_read(AM_INPUT_KEYBRD);
  if (ev.keycode == AM_KEY_NONE) return 0;
  int ret = snprintf(buf, len, "%s %s\n", ev.keydown ? "kd" : "ku", keyname[ev.keycode]);
  return ret > 0 ? ret : 0;
}

size_t dispinfo_read(void *buf, size_t offset, size_t len) {
  AM_GPU_CONFIG_T cfg = io_read(AM_GPU_CONFIG);
  int ret = snprintf(buf, len, "WIDTH : %d\nHEIGHT : %d\n", cfg.width, cfg.height);
  return ret > 0 ? ret : 0;
}

size_t fb_write(const void *buf, size_t offset, size_t len) {
  AM_GPU_CONFIG_T cfg = io_read(AM_GPU_CONFIG);
  int w = cfg.width;
  int pixel_offset = offset / 4;
  int num_pixels = len / 4;
  if (num_pixels == 0) return 0;

  int pixels_written = 0;
  while (pixels_written < num_pixels) {
    int cur_x = (pixel_offset + pixels_written) % w;
    int cur_y = (pixel_offset + pixels_written) / w;
    int cur_len = w - cur_x;
    if (cur_len > num_pixels - pixels_written) {
      cur_len = num_pixels - pixels_written;
    }
    io_write(AM_GPU_FBDRAW, cur_x, cur_y, (void *)((uint32_t *)buf + pixels_written), cur_len, 1, true);
    pixels_written += cur_len;
  }
  return len;
}

void init_device() {
  Log("Initializing devices...");
  ioe_init();
}
