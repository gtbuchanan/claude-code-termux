/*
 * execpath-shim — LD_PRELOAD interposer that rewrites CLAUDE_CODE_EXECPATH in
 * the environment of every process Claude spawns, pointing it at LAUNCHER_PATH.
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
 * Freestanding, like the package's other shims: no libc of its own, dlsym left
 * undefined and resolved from libc.so.6 at load — deliberately NO -ldl, so the
 * object carries no DT_NEEDED (a libdl.so dep would break the glibc ld.so
 * load; that was the failure mode in #25).
 *
 * aarch64 Termux only. LAUNCHER_PATH is baked in (build-wrapper.sh); the
 * launcher preloads this alongside its other shims.
 */

#ifndef LAUNCHER_PATH
#error                                                                         \
    "LAUNCHER_PATH must be defined at compile time (-DLAUNCHER_PATH=\"/…/bin/claude\")"
#endif

#define RTLD_NEXT ((void *)-1L)
extern void *dlsym(void *handle, const char *symbol);

static const char kKey[] = "CLAUDE_CODE_EXECPATH=";
static const char kEntry[] = "CLAUDE_CODE_EXECPATH=" LAUNCHER_PATH;

/*
 * Upper bound on the environment we will rewrite. The copy lives on the
 * caller's stack, so it must be bounded — posix_spawn runs on whichever thread
 * Bun spawns from, and those stacks are not the main thread's. A real
 * environment is a few dozen entries; anything past this is forwarded
 * untouched rather than truncated, since a wrong environment is worse than an
 * unfixed one.
 */
#define MAX_ENV_ENTRIES 1024

/* Freestanding prefix test — no libc. Returns 1 iff s starts with kKey. */
static int is_execpath_entry(const char *s) {
  if (s == 0) {
    return 0;
  }
  for (const char *k = kKey; *k != '\0'; k++, s++) {
    if (*s != *k) {
      return 0;
    }
  }
  return 1;
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
   preload) and forwards with the environment rewritten; if it can't be resolved
   it fails closed (-1) rather than dereferencing a NULL pointer. */
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
    return real(path, argv, envp);
  }
  return real(path, argv, (char *const *)buf);
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
    return real(file, argv, envp);
  }
  return real(file, argv, (char *const *)buf);
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
    return real(pid, path, file_actions, attrp, argv, envp);
  }
  return real(pid, path, file_actions, attrp, argv, (char *const *)buf);
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
    return real(pid, file, file_actions, attrp, argv, envp);
  }
  return real(pid, file, file_actions, attrp, argv, (char *const *)buf);
}
