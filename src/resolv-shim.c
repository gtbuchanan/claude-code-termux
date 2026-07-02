/*
 * resolv-shim — LD_PRELOAD interposer that redirects opens of the absolute
 * path RESOLV_SRC ("/etc/resolv.conf") to RESOLV_DST ($PREFIX/etc/resolv.conf).
 *
 * Bun bundles its own c-ares resolver for its node:http / axios path (Claude
 * Code's WebFetch domain-safety preflight, the claude.ai MCP connector, and
 * OTEL export all ride it). c-ares reads the ABSOLUTE path /etc/resolv.conf; on
 * Android /etc -> /system/etc, which has no resolv.conf, so c-ares gets zero
 * nameservers and every lookup hangs until the caller's timeout (getaddrinfo
 * ETIMEOUT). Everything else resolves because it uses a different path: Termux's
 * glibc is patched to read $PREFIX/glibc/etc/resolv.conf, and Bun's native fetch
 * uses its own working DNS. Only c-ares is left pointing at the missing file.
 * Pointing it at $PREFIX/etc/resolv.conf (present, reachable 8.8.8.8/8.8.4.4)
 * fixes it. See anthropics/claude-code#50270 and this repo's issue #25.
 *
 * c-ares 1.21 (bundled) reads the config via fopen(); the fopen family returns
 * an opaque glibc FILE* that cannot be reimplemented freestanding, so — unlike
 * uname-shim's pure raw syscall — the real function must be called through
 * dlsym(RTLD_NEXT, …). dlsym lives in libc.so.6 (merged since glibc 2.34), so it
 * is declared extern and left UNDEFINED: with no -ldl, the object records no
 * DT_NEEDED, and the glibc ld.so that loads this preload resolves the symbol
 * from the already-loaded libc. Linking -ldl instead would record a
 * DT_NEEDED libdl.so that Termux's glibc can't satisfy — the failure mode in
 * issue #25's comments. The open family is interposed too (cheap insurance
 * should a future c-ares switch to open()); each rewrites ONLY the exact
 * RESOLV_SRC path and passes everything else through untouched.
 *
 * Built freestanding (-nostdlib -ffreestanding): the only external reference is
 * dlsym, so it loads under glibc's ld.so regardless of the bionic toolchain that
 * compiled it. RESOLV_SRC / RESOLV_DST are baked in at compile time via
 * -DRESOLV_SRC="…" / -DRESOLV_DST="…" (see scripts/build-wrapper.sh).
 *
 * aarch64 Termux only. See src/claude-wrapper.c for how the launcher preloads it
 * alongside uname-spoof.so.
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

/* glibc's opaque stdio handle; matching the tag keeps the fopen prototypes
   type-compatible with libc's so -Werror doesn't flag a library redeclaration. */
typedef struct _IO_FILE FILE;

/* dlsym from libc.so.6 (see file header): undefined, no -ldl, no DT_NEEDED. */
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

/*
 * Each interposer resolves the real libc function once (RTLD_NEXT = the next
 * definition after this preload = libc's) and forwards with the path rewritten.
 * The open family is variadic to match libc exactly; the optional mode arg is
 * present only for creating opens, so — like glibc's own open() — the va_arg is
 * read ONLY then (needs_mode), never unconditionally (a va_arg the caller didn't
 * pass is undefined behavior), and the mode is likewise forwarded only then.
 *
 * The *64 (LFS) variants are ABI-identical to their bases on aarch64 (off_t is
 * already 64-bit), so they are aliased onto the base interposers — the same way
 * glibc defines them — rather than duplicated. They must still be exported so a
 * caller that binds fopen64/open64/openat64 is intercepted (see the aliases
 * after the definitions).
 */
typedef FILE *(*fopen_fn)(const char *, const char *);
typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);

/* Mirror glibc's __OPEN_NEEDS_MODE: a mode arg accompanies O_CREAT or O_TMPFILE
   (the latter carries O_DIRECTORY too, so match the full bit pattern). */
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

/* LFS aliases (see the interposer comment above): fopen64/open64/openat64 are
   the base interposers under their 64-bit-off_t names, exported for callers
   that bind those symbols. */
FILE *fopen64(const char *, const char *) __attribute__((alias("fopen")));
int open64(const char *, int, ...) __attribute__((alias("open")));
int openat64(int, const char *, int, ...) __attribute__((alias("openat")));
