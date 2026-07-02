/*
 * resolv-shim — LD_PRELOAD interposer that redirects opens of RESOLV_SRC
 * ("/etc/resolv.conf") to RESOLV_DST ("$PREFIX/etc/resolv.conf").
 *
 * Bundled Bun's c-ares resolver (its node:http/axios path: WebFetch's domain
 * preflight, the claude.ai MCP connector, OTEL export) reads the absolute
 * /etc/resolv.conf. Android maps /etc -> /system/etc, which has none, so those
 * lookups hang until timeout — while Bun's native fetch (separate DNS) is fine.
 * Redirecting the open to $PREFIX/etc/resolv.conf (reachable) fixes it. See
 * anthropics/claude-code#50270 and issue #25.
 *
 * c-ares reads the file via fopen(), whose opaque FILE* can't be reimplemented
 * freestanding, so the real function is reached via dlsym(RTLD_NEXT, …). dlsym
 * is left undefined and resolved from libc.so.6 at load — crucially with NO
 * -ldl, so the object carries no DT_NEEDED (a libdl.so dep would break the glibc
 * ld.so load; that was the failure mode in #25's comments).
 *
 * aarch64 Termux only. RESOLV_SRC/RESOLV_DST are baked in (build-wrapper.sh);
 * the launcher preloads this alongside uname-spoof.so (src/claude-wrapper.c).
 */
#include <fcntl.h>
#include <stdarg.h>

#ifndef RESOLV_SRC
#error                                                                         \
    "RESOLV_SRC must be defined at compile time (-DRESOLV_SRC=\"/etc/resolv.conf\")"
#endif

#ifndef RESOLV_DST
#error                                                                         \
    "RESOLV_DST must be defined at compile time (-DRESOLV_DST=\"/…/etc/resolv.conf\")"
#endif

/* Match glibc's opaque FILE tag so the fopen prototype stays type-compatible. */
typedef struct _IO_FILE FILE;

#define RTLD_NEXT ((void *)-1L)
extern void *dlsym(void *handle, const char *symbol);

/* Freestanding string compare — no libc. Returns 1 iff a and b are equal. */
static int str_eq(const char *a, const char *b) {
  while (*a != '\0' && *a == *b) {
    a++;
    b++;
  }
  return *a == *b;
}

/* Rewrite exactly RESOLV_SRC; every other path passes through unchanged. */
static const char *redirect(const char *path) {
  if (path != 0 && str_eq(path, RESOLV_SRC)) {
    return RESOLV_DST;
  }
  return path;
}

/* Each interposer resolves the real libc symbol once (RTLD_NEXT skips this
   preload) and forwards with the path rewritten. */
typedef FILE *(*fopen_fn)(const char *, const char *);
typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);

/* The open family is variadic; like glibc's __OPEN_NEEDS_MODE, read the mode arg
   only for creating opens — a va_arg the caller didn't pass is UB. (O_TMPFILE
   carries O_DIRECTORY too, so match the full bit pattern.) */
static int needs_mode(int flags) {
  return (flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE;
}

FILE *fopen(const char *path, const char *mode) {
  static fopen_fn real = 0;
  if (real == 0) {
    real = (fopen_fn)dlsym(RTLD_NEXT, "fopen");
  }
  return real(redirect(path), mode);
}

int open(const char *path, int flags, ...) {
  static open_fn real = 0;
  if (real == 0) {
    real = (open_fn)dlsym(RTLD_NEXT, "open");
  }
  if (!needs_mode(flags)) {
    return real(redirect(path), flags);
  }
  va_list ap;
  va_start(ap, flags);
  int mode = va_arg(ap, int);
  va_end(ap);
  return real(redirect(path), flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
  static openat_fn real = 0;
  if (real == 0) {
    real = (openat_fn)dlsym(RTLD_NEXT, "openat");
  }
  if (!needs_mode(flags)) {
    return real(dirfd, redirect(path), flags);
  }
  va_list ap;
  va_start(ap, flags);
  int mode = va_arg(ap, int);
  va_end(ap);
  return real(dirfd, redirect(path), flags, mode);
}

/* The *64 (LFS) variants are ABI-identical on aarch64 (64-bit off_t), so alias
   them onto the bases — as glibc does — still exported to catch callers that
   bind them. */
FILE *fopen64(const char *, const char *) __attribute__((alias("fopen")));
int open64(const char *, int, ...) __attribute__((alias("open")));
int openat64(int, const char *, int, ...) __attribute__((alias("openat")));
