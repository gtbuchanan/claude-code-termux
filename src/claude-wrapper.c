/*
 * claude-wrapper — launcher for the Termux-patched Claude Code binary.
 *
 * A compiled ELF wrapper (not a shell script) is required: Claude's shell
 * snapshot re-execs its embedded tools via `exec -a ugrep $WRAPPER -G …`,
 * relying on argv[0]="ugrep" to dispatch to ripgrep/bfs/rg. The kernel drops
 * the original argv[0] when it reinterprets a script shebang, so a bash
 * wrapper would arrive as argv[0]="…/bash". execv() preserves argv verbatim.
 *
 * The wrapper is itself a bionic binary, so Termux's libtermux-exec loads into
 * it cleanly; it then clears LD_PRELOAD before exec'ing the glibc Claude binary
 * (whose ld.so would otherwise choke on termux-exec's unversioned libc.so).
 *
 * BINARY (the absolute path to the patched Claude Code binary) and TMPDIR_PATH
 * (the Termux prefix tmp dir) are baked in at compile time via -DBINARY="…" and
 * -DTMPDIR_PATH="…".
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef BINARY
#error "BINARY must be defined at compile time (-DBINARY=\"/path/to/claude\")"
#endif

#ifndef TMPDIR_PATH
#error "TMPDIR_PATH must be defined at compile time (-DTMPDIR_PATH=\"/…/tmp\")"
#endif

int main(int argc, char **argv) {
  (void)argc;
  /* Termux has no writable /tmp (it's shell:shell 0771), so Claude's temp
     paths must land in the Termux prefix. Two env vars cover the env-honoring
     sites (see anthropics/claude-code#15637):
       - TMPDIR drives os.tmpdir() (`env.TMPDIR||…||"/tmp"`) — the main resolver.
       - CLAUDE_CODE_TMPDIR drives the sandbox subprocess TMPDIR, which falls
         back to "/tmp/claude" and does NOT consult TMPDIR.
     overwrite=0 sets each only when unset, so Termux/user values still win.
     The MCP-browser-bridge dir is hardcoded to /tmp and unreachable this way;
     it's a documented limitation (the compiled binary can't be byte-patched to
     grow the literal). */
  (void)setenv("TMPDIR", TMPDIR_PATH, 0);
  (void)setenv("CLAUDE_CODE_TMPDIR", TMPDIR_PATH, 0);
  (void)unsetenv("LD_PRELOAD");
  execv(BINARY, argv);
  fprintf(stderr, "claude wrapper: execv %s failed: %s\n", BINARY, strerror(errno));
  return 127;
}
