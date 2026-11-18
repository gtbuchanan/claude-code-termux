/*
 * launcher-shim — bionic LD_PRELOAD interposer that sends any exec of the bare
 * patched binary through the launcher instead, keeping argv (and so argv[0])
 * intact.
 *
 * With the tengu_playful_dusk gate on, Claude's shell snapshot stops reading
 * CLAUDE_CODE_EXECPATH and bakes process.execPath into its grep/find functions
 * as a literal:
 *
 *     if [[ -x …/opt/claude-code-termux/claude-2.1.325 ]]; then
 *       ( exec -a ugrep …/opt/claude-code-termux/claude-2.1.325 -G … )
 *
 * process.execPath comes from /proc/self/exe, so it always names the bare
 * binary, and no environment rewrite (src/execpath-shim.c) can reach a path
 * written into a function body. The bare binary then inherits the shell's
 * bionic LD_PRELOAD, and the glibc ld.so aborts with "invalid ELF header" on
 * termux-exec's libc.so dependency.
 *
 * Interposing execve in the shell catches the re-exec however Claude spells
 * the path. The launcher replaces LD_PRELOAD with its glibc-safe shims before
 * exec'ing the binary, and execv preserves argv[0], so ugrep/bfs dispatch keeps
 * working.
 *
 * Unlike the package's other shims, this one loads into bionic processes (the
 * shells Claude spawns, through env.LD_PRELOAD in settings.json), so it links
 * against bionic normally. postinst puts it ahead of termux-exec, so the
 * RTLD_NEXT lookup below forwards to termux-exec's execve and every exec keeps
 * termux-exec's handling.
 *
 * Only execve is interposed, because that is what bash and zsh call to run the
 * snapshot functions' `exec -a`. Bionic's posix_spawn reaches it too; its
 * execv family does not, so a program calling execv on the bare binary still
 * fails as before.
 *
 * aarch64 Termux only. LAUNCHER_PATH and BINARY_DIR are baked in
 * (build-wrapper.sh).
 */
#include <dlfcn.h>
#include <errno.h>
#include <string.h>

#ifndef LAUNCHER_PATH
#error                                                                         \
    "LAUNCHER_PATH must be defined at compile time (-DLAUNCHER_PATH=\"/…/bin/claude\")"
#endif

#ifndef BINARY_DIR
#error                                                                         \
    "BINARY_DIR must be defined at compile time (-DBINARY_DIR=\"/…/opt/claude-code-termux/\")"
#endif

typedef int (*execve_fn)(const char *, char *const *, char *const *);

/* The directory holds only the patched binaries and the `current` symlink to
   one of them, so a prefix match names exactly the execs that need the
   launcher. */
static int is_bare_binary(const char *path) {
  return path != NULL && strncmp(path, BINARY_DIR, sizeof(BINARY_DIR) - 1) == 0;
}

/*
 * The shim also loads into the launcher, a bionic process started from the
 * same shell, so the launcher's own exec of the binary is redirected once more.
 * That cannot loop: the launcher has already replaced LD_PRELOAD by then, so
 * the second launcher runs without this shim and execs the binary directly.
 * Skipping the redirect inside the launcher would save that one exec at the
 * cost of a /proc/self/exe check that nothing could verify.
 */
int execve(const char *path, char *const argv[], char *const envp[]) {
  static execve_fn real = NULL;
  if (real == NULL) {
    real = (execve_fn)dlsym(RTLD_NEXT, "execve");
  }
  if (real == NULL) {
    errno = ENOSYS;
    return -1;
  }
  if (is_bare_binary(path)) {
    return real(LAUNCHER_PATH, argv, envp);
  }
  return real(path, argv, envp);
}
