/*
 * execpath-shim — LD_PRELOAD interposer that points the processes Claude spawns
 * at LAUNCHER_PATH instead of the bare patched binary: it rewrites
 * CLAUDE_CODE_EXECPATH in every child's environment, and it redirects a spawn
 * of the binary itself.
 *
 * Claude's shell snapshot re-execs its embedded tools through that variable:
 *
 *     local _cc_bin="${CLAUDE_CODE_EXECPATH:-}"
 *     [[ -x $_cc_bin ]] || _cc_bin=$HOME/.local/bin/claude
 *     (exec -a ugrep "$_cc_bin" -G …)
 *
 * Claude sets it to process.execPath — the bare patched binary, not the
 * launcher — so the fallback never fires. That re-exec then inherits the bionic
 * LD_PRELOAD settings.json re-exports for subprocesses, and the glibc ld.so
 * resolves its DT_NEEDED libc.so to Termux's linker script, aborting with
 * "invalid ELF header". Every grep/find inside the Bash tool dies there; on a
 * native build those are the only search primitives Claude has. See issue #61.
 *
 * Rewriting the child's envp routes the re-exec back through the launcher,
 * which replaces LD_PRELOAD (src/claude-wrapper.c) before handing off to the
 * binary. This supersedes the byte patch that used to blank the assignment in
 * the binary: as of Claude Code 2.1.246 bun compiles the shell module to
 * bytecode, so patching the embedded JS source text applied cleanly and did
 * nothing at run time. Interposing libc's spawn calls depends on the platform
 * ABI rather than on Anthropic's minifier output, so it does not rot per
 * release.
 *
 * The rewrite REPLACES an existing entry and never appends one. Claude always
 * sets the variable, so that is enough to fix the re-exec; when it is absent
 * the snapshot's own $HOME/.local/bin/claude fallback already reaches the
 * launcher, and staying out of unrelated children's environments keeps the
 * blast radius to the case that is actually broken.
 *
 * Claude also spawns process.execPath directly: `claude remote-control` starts
 * each session that way. The child inherits the same bionic LD_PRELOAD and
 * dies the same way, so a spawn whose path lies under BINARY_DIR goes to the
 * launcher instead, argv untouched so argv[0] dispatch still works. The
 * directory holds only the patched binaries and the `current` symlink, so the
 * prefix match names exactly the spawns that need it. The redirect is skipped
 * inside the launcher itself: a launcher that inherits Claude's own LD_PRELOAD
 * loads this shim, and on a bionic whose execv reaches the interposed execve,
 * redirecting its exec of the binary would start the launcher again, forever.
 *
 * Freestanding, like the package's other shims: no libc of its own, dlsym left
 * undefined and resolved from libc.so.6 at load — deliberately NO -ldl, so the
 * object carries no DT_NEEDED (a libdl.so dep would break the glibc ld.so
 * load; that was the failure mode in #25).
 *
 * aarch64 Termux only. LAUNCHER_PATH and BINARY_DIR are baked in
 * (build-wrapper.sh); the launcher preloads this alongside its other shims.
 */

#ifndef LAUNCHER_PATH
#error                                                                         \
    "LAUNCHER_PATH must be defined at compile time (-DLAUNCHER_PATH=\"/…/bin/claude\")"
#endif

#ifndef BINARY_DIR
#error                                                                         \
    "BINARY_DIR must be defined at compile time (-DBINARY_DIR=\"/…/opt/claude-code-termux/\")"
#endif

#define RTLD_NEXT ((void *)-1L)
extern void *dlsym(void *handle, const char *symbol);

static const char kKey[] = "CLAUDE_CODE_EXECPATH=";
static const char kEntry[] = "CLAUDE_CODE_EXECPATH=" LAUNCHER_PATH;
static const char kBinaryDir[] = BINARY_DIR;

/*
 * Upper bound on the environment we will rewrite. The copy lives on the
 * caller's stack, so it must be bounded — posix_spawn runs on whichever thread
 * Bun spawns from, and those stacks are not the main thread's. A real
 * environment is a few dozen entries; anything past this is forwarded
 * untouched rather than truncated, since a wrong environment is worse than an
 * unfixed one.
 */
#define MAX_ENV_ENTRIES 1024

/* Freestanding prefix test — no libc. Returns 1 iff s starts with prefix. */
static int has_prefix(const char *s, const char *prefix) {
  if (s == 0) {
    return 0;
  }
  for (const char *p = prefix; *p != '\0'; p++, s++) {
    if (*s != *p) {
      return 0;
    }
  }
  return 1;
}

static int is_execpath_entry(const char *s) { return has_prefix(s, kKey); }

static long raw_readlinkat(const char *path, char *buf, unsigned long size) {
  register long x8 __asm__("x8") = 78;   /* __NR_readlinkat on aarch64 */
  register long x0 __asm__("x0") = -100; /* AT_FDCWD */
  register long x1 __asm__("x1") = (long)path;
  register long x2 __asm__("x2") = (long)buf;
  register long x3 __asm__("x3") = (long)size;
  __asm__ volatile("svc #0"
                   : "+r"(x0)
                   : "r"(x8), "r"(x1), "r"(x2), "r"(x3)
                   : "memory");
  return x0;
}

/* 1 iff this process is the launcher. readlinkat does not NUL-terminate, and
   the buffer holds one byte past LAUNCHER_PATH so a longer target is told
   apart from an exact match. */
static int in_launcher(void) {
  static const char kLauncher[] = LAUNCHER_PATH;
  char self[sizeof(kLauncher)];
  long n = raw_readlinkat("/proc/self/exe", self, sizeof(self));
  if (n != (long)sizeof(kLauncher) - 1) {
    return 0;
  }
  for (long i = 0; i < n; i++) {
    if (self[i] != kLauncher[i]) {
      return 0;
    }
  }
  return 1;
}

/* The path to exec: the launcher for the bare binary, else path unchanged. A
   bare file name for execvpe/posix_spawnp has no slash, so it never matches. */
static const char *redirect_path(const char *path) {
  return has_prefix(path, kBinaryDir) && !in_launcher() ? LAUNCHER_PATH : path;
}

static int env_len(char *const *envp) {
  int n = 0;
  if (envp != 0) {
    while (envp[n] != 0) {
      n++;
    }
  }
  return n;
}

/*
 * Copy envp into `out` with any CLAUDE_CODE_EXECPATH entry replaced. Returns 1
 * when `out` holds the rewritten environment and 0 when the caller should
 * forward the original (nothing to replace, or too large to copy). The copy
 * loop carries a branch per entry, so no memcpy libcall is emitted for it —
 * which matters under -nostdlib, where one would be an unresolvable symbol.
 */
static int rewrite_env(char *const *envp, const char **out, int cap) {
  int n = env_len(envp);
  if (n >= cap) {
    return 0;
  }
  int found = 0;
  for (int i = 0; i < n; i++) {
    if (is_execpath_entry(envp[i])) {
      out[i] = kEntry;
      found = 1;
    } else {
      out[i] = envp[i];
    }
  }
  out[n] = 0;
  return found;
}

typedef int (*execve_fn)(const char *, char *const *, char *const *);
/* file_actions/attrp are opaque here: they are forwarded untouched, so the shim
   avoids depending on the spawn.h types matching between the bionic toolchain
   that builds it and the glibc runtime that loads it. pid_t is int on aarch64. */
typedef int (*spawn_fn)(int *, const char *, const void *, const void *,
                        char *const *, char *const *);

/* Each interposer resolves the real libc symbol once (RTLD_NEXT skips this
   preload) and forwards with the path redirected and the environment rewritten;
   if it cannot be resolved it fails closed (-1) rather than dereferencing a
   NULL pointer. */
int execve(const char *path, char *const argv[], char *const envp[]) {
  static execve_fn real = 0;
  if (real == 0) {
    real = (execve_fn)dlsym(RTLD_NEXT, "execve");
  }
  if (real == 0) {
    return -1;
  }
  const char *buf[MAX_ENV_ENTRIES + 1];
  if (!rewrite_env(envp, buf, MAX_ENV_ENTRIES)) {
    return real(redirect_path(path), argv, envp);
  }
  return real(redirect_path(path), argv, (char *const *)buf);
}

int execvpe(const char *file, char *const argv[], char *const envp[]) {
  static execve_fn real = 0;
  if (real == 0) {
    real = (execve_fn)dlsym(RTLD_NEXT, "execvpe");
  }
  if (real == 0) {
    return -1;
  }
  const char *buf[MAX_ENV_ENTRIES + 1];
  if (!rewrite_env(envp, buf, MAX_ENV_ENTRIES)) {
    return real(redirect_path(file), argv, envp);
  }
  return real(redirect_path(file), argv, (char *const *)buf);
}

int posix_spawn(int *pid, const char *path, const void *file_actions,
                const void *attrp, char *const argv[], char *const envp[]) {
  static spawn_fn real = 0;
  if (real == 0) {
    real = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawn");
  }
  if (real == 0) {
    return -1;
  }
  const char *buf[MAX_ENV_ENTRIES + 1];
  if (!rewrite_env(envp, buf, MAX_ENV_ENTRIES)) {
    return real(pid, redirect_path(path), file_actions, attrp, argv, envp);
  }
  return real(pid, redirect_path(path), file_actions, attrp, argv,
              (char *const *)buf);
}

int posix_spawnp(int *pid, const char *file, const void *file_actions,
                 const void *attrp, char *const argv[], char *const envp[]) {
  static spawn_fn real = 0;
  if (real == 0) {
    real = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawnp");
  }
  if (real == 0) {
    return -1;
  }
  const char *buf[MAX_ENV_ENTRIES + 1];
  if (!rewrite_env(envp, buf, MAX_ENV_ENTRIES)) {
    return real(pid, redirect_path(file), file_actions, attrp, argv, envp);
  }
  return real(pid, redirect_path(file), file_actions, attrp, argv,
              (char *const *)buf);
}
