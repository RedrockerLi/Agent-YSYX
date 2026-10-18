#include <klib.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

struct str_ctx {
  char *buf;
  size_t size;
  size_t count;
};

static void str_putc(char c, void *ctx) {
  struct str_ctx *s = (struct str_ctx *)ctx;
  if (s->size > 0 && s->count + 1 < s->size) {
    s->buf[s->count] = c;
  }
  s->count++;
}

static void console_putc(char c, void *ctx) {
  int *count = (int *)ctx;
  putch(c);
  (*count)++;
}

static int format_engine(void (*putc_fn)(char, void *), void *ctx, const char *fmt, va_list ap) {
  int written = 0;
  while (*fmt) {
    if (*fmt != '%') {
      putc_fn(*fmt++, ctx);
      written++;
      continue;
    }
    fmt++; // skip '%'
    if (*fmt == '%') {
      putc_fn('%', ctx);
      written++;
      fmt++;
      continue;
    }

    // Flags
    bool zero_pad = false;
    bool left_align = false;
    while (*fmt == '0' || *fmt == '-') {
      if (*fmt == '0') zero_pad = true;
      if (*fmt == '-') left_align = true;
      fmt++;
    }

    // Width
    int width = 0;
    while (isdigit(*fmt)) {
      width = width * 10 + (*fmt - '0');
      fmt++;
    }

    // Specifiers
    char spec = *fmt++;
    char num_buf[64];
    int num_len = 0;
    const char *str_val = NULL;
    char char_val = 0;

    switch (spec) {
      case 'c': {
        char_val = (char)va_arg(ap, int);
        str_val = &char_val;
        num_len = 1;
        break;
      }
      case 's': {
        str_val = va_arg(ap, const char *);
        if (!str_val) str_val = "(null)";
        num_len = strlen(str_val);
        break;
      }
      case 'd':
      case 'i': {
        long long val = va_arg(ap, int);
        bool neg = false;
        if (val < 0) {
          neg = true;
          val = -val;
        }
        int idx = 0;
        if (val == 0) {
          num_buf[idx++] = '0';
        } else {
          while (val > 0) {
            num_buf[idx++] = '0' + (val % 10);
            val /= 10;
          }
        }
        if (neg) {
          num_buf[idx++] = '-';
        }
        for (int i = 0; i < idx / 2; i++) {
          char tmp = num_buf[i];
          num_buf[i] = num_buf[idx - 1 - i];
          num_buf[idx - 1 - i] = tmp;
        }
        num_buf[idx] = '\0';
        str_val = num_buf;
        num_len = idx;
        break;
      }
      case 'u': {
        unsigned int val = va_arg(ap, unsigned int);
        int idx = 0;
        if (val == 0) {
          num_buf[idx++] = '0';
        } else {
          while (val > 0) {
            num_buf[idx++] = '0' + (val % 10);
            val /= 10;
          }
        }
        for (int i = 0; i < idx / 2; i++) {
          char tmp = num_buf[i];
          num_buf[i] = num_buf[idx - 1 - i];
          num_buf[idx - 1 - i] = tmp;
        }
        num_buf[idx] = '\0';
        str_val = num_buf;
        num_len = idx;
        break;
      }
      case 'x':
      case 'X':
      case 'p': {
        unsigned long val;
        if (spec == 'p') {
          val = (uintptr_t)va_arg(ap, void *);
        } else {
          val = va_arg(ap, unsigned int);
        }
        int idx = 0;
        const char *digits = (spec == 'X') ? "0123456789ABCDEF" : "0123456789abcdef";
        if (val == 0) {
          num_buf[idx++] = '0';
        } else {
          while (val > 0) {
            num_buf[idx++] = digits[val & 0xf];
            val >>= 4;
          }
        }
        for (int i = 0; i < idx / 2; i++) {
          char tmp = num_buf[i];
          num_buf[i] = num_buf[idx - 1 - i];
          num_buf[idx - 1 - i] = tmp;
        }
        num_buf[idx] = '\0';
        str_val = num_buf;
        num_len = idx;
        break;
      }
      default:
        putc_fn(spec, ctx);
        written++;
        continue;
    }

    int pad = (width > num_len) ? width - num_len : 0;
    char pad_char = zero_pad ? '0' : ' ';

    if (zero_pad && str_val[0] == '-') {
      putc_fn('-', ctx);
      written++;
      str_val++;
      num_len--;
    }

    if (!left_align) {
      for (int i = 0; i < pad; i++) {
        putc_fn(pad_char, ctx);
        written++;
      }
    }
    for (int i = 0; i < num_len; i++) {
      putc_fn(str_val[i], ctx);
      written++;
    }
    if (left_align) {
      for (int i = 0; i < pad; i++) {
        putc_fn(' ', ctx);
        written++;
      }
    }
  }
  return written;
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  struct str_ctx s = { .buf = out, .size = n, .count = 0 };
  format_engine(str_putc, &s, fmt, ap);
  if (n > 0) {
    if (s.count < n) {
      out[s.count] = '\0';
    } else {
      out[n - 1] = '\0';
    }
  }
  return s.count;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  return vsnprintf(out, (size_t)-1, fmt, ap);
}

int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int ret = vsprintf(out, fmt, ap);
  va_end(ap);
  return ret;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int ret = vsnprintf(out, n, fmt, ap);
  va_end(ap);
  return ret;
}

int vprintf(const char *fmt, va_list ap) {
  int count = 0;
  return format_engine(console_putc, &count, fmt, ap);
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int ret = vprintf(fmt, ap);
  va_end(ap);
  return ret;
}

int __am_vsscanf_internal(const char *str, const char **end_pstr, const char *fmt, va_list ap) {
  const char *pstr = str;
  const char *pfmt = fmt;
  int item = -1;
  while (*pfmt) {
    char ch = *pfmt ++;
    if (isspace(ch)) {
      for (ch = *pfmt; isspace(ch); ch = *(++ pfmt));
      for (ch = *pstr; isspace(ch); ch = *(++ pstr));
      item ++;
      continue;
    }
    switch (ch) {
      case '%': break;
      default:
        if (*pstr == ch) { // match
          pstr ++;
          item ++;
          continue;
        }
        goto end; // fail
    }

    char *p;
    ch = *pfmt ++;
    switch (ch) {
      // conversion specifier
      case 'd':
        *(va_arg(ap, int *)) = strtol(pstr, &p, 10);
        if (p == pstr) goto end; // fail
        pstr = p;
        item ++;
        break;

      case 'c':
        *(va_arg(ap, char *)) = *pstr ++;
        item ++;
        break;

      default:
        printf("Unsupported conversion specifier '%c'\n", ch);
        assert(0);
    }
  }

end:
  if (end_pstr) {
    *end_pstr = pstr;
  }
  return item;
}

int vsscanf(const char *str, const char *fmt, va_list ap) {
  return __am_vsscanf_internal(str, NULL, fmt, ap);
}

int sscanf(const char *str, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsscanf(str, fmt, ap);
  va_end(ap);
  return r;
}

int __isoc99_sscanf(const char *str, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsscanf(str, fmt, ap);
  va_end(ap);
  return r;
}

#endif
