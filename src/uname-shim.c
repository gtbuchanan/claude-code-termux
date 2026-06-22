/*
 * uname-shim — LD_PRELOAD interposer that reports kernel release "5.10.0".
 *
 * Claude Code 2.1.181 bumped its bundled Bun to 1.4.0, whose HTTP event loop
 * calls epoll_pwait2 with no fallback and null-derefs at startup on every
 * kernel >= 5.11 (bun#32489 — "Segmentation fault at address 0x0"). Bun selects
 * that path from the kernel version it reads via glibc uname(), and uname() is
 * an undefined dynamic import in the Claude binary, so interposing it here makes
 * Bun see a < 5.11 kernel and take the working epoll_pwait path instead. 5.10 is
 * the highest pre-5.11 release (an LTS), so it keeps every other kernel feature.
 *
 * The launcher points LD_PRELOAD at this object (replacing termux-exec's, which
 * its glibc ld.so can't load anyway). It is built freestanding (-nostdlib): with
 * no libc dependency of its own it loads under glibc's ld.so regardless of the
 * toolchain that compiled it, and the raw uname syscall avoids recursing into
 * the very symbol it interposes. The fix is harmless once Anthropic ships a
 * fixed Bun (epoll_pwait works on 5.10 too), so it needs no later removal.
 *
 * aarch64 Termux only — __NR_uname and the svc calling convention are baked in.
 * See anthropics/claude-code#50270.
 */

/* glibc struct utsname: six _UTSNAME_LENGTH (65) char fields. */
#define UTS_LEN 65
struct utsname {
  char sysname[UTS_LEN];
  char nodename[UTS_LEN];
  char release[UTS_LEN];
  char version[UTS_LEN];
  char machine[UTS_LEN];
  char domainname[UTS_LEN];
};

static long raw_uname(struct utsname *buf) {
  register long x8 __asm__("x8") = 160; /* __NR_uname on aarch64 */
  register long x0 __asm__("x0") = (long)buf;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
  return x0;
}

int uname(struct utsname *buf) {
  long rc = raw_uname(buf);
  if (rc == 0) {
    static const char release[] = "5.10.0";
    for (unsigned i = 0; i < sizeof(release); i++) {
      buf->release[i] = release[i];
    }
  }
  return (int)rc;
}
