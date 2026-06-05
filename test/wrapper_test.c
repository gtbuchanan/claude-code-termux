/*
 * Unit tests for the C launcher (src/claude-wrapper.c).
 *
 * The wrapper's entire job is environment shaping followed by a single exec
 * handoff, so the unit under test is claude_wrapper_run(): the env vars it
 * sets/clears and the exact (path, argv) it hands to exec. The wrapper takes
 * its exec function as a parameter (a seam), so the tests pass a recording stub
 * instead of the real execv — no process replacement, no linker tricks. The
 * wrapper is compiled with -DCLAUDE_WRAPPER_NO_MAIN so its main() doesn't
 * collide with greatest's here.
 *
 * BINARY and TMPDIR_PATH are the sentinel literals baked into the wrapper (see
 * scripts/test-wrapper.sh); they need not exist on disk because exec is faked.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "greatest.h"

/* The unit under test (src/claude-wrapper.c, built with CLAUDE_WRAPPER_NO_MAIN). */
int claude_wrapper_run(int argc, char **argv,
                       int (*exec)(const char *, char *const *));

/* --- Recording exec stub --------------------------------------------------- */

static int    exec_calls;
static char  *exec_path;
static char  *exec_argv[64];
static int    exec_argc;
static int    exec_retval;   /* what the stub returns (real exec only returns on failure) */

static int recording_exec(const char *path, char *const argv[]) {
  exec_calls++;
  free(exec_path);
  exec_path = strdup(path);
  exec_argc = 0;
  for (char *const *arg = argv; *arg != NULL && exec_argc < 63; ++arg) {
    exec_argv[exec_argc++] = strdup(*arg);
  }
  exec_argv[exec_argc] = NULL;
  return exec_retval;
}

/* Clear the stub + the three env vars the wrapper touches, for an isolated run. */
static void reset_fixture(void) {
  for (int i = 0; i < exec_argc; ++i) {
    free(exec_argv[i]);
    exec_argv[i] = NULL;
  }
  exec_calls = 0;
  exec_argc = 0;
  exec_retval = -1;   /* default: pretend exec failed so the wrapper returns */
  free(exec_path);
  exec_path = NULL;
  unsetenv("TMPDIR");
  unsetenv("CLAUDE_CODE_TMPDIR");
  unsetenv("LD_PRELOAD");
}

static const char *env_or_empty(const char *name) {
  const char *v = getenv(name);
  return v != NULL ? v : "";
}

/* --- Tests ----------------------------------------------------------------- */

/*
 * The core fix: exec must receive argv verbatim. Claude's shell snapshot
 * re-execs embedded tools via `exec -a ugrep <wrapper> -G …` and dispatches on
 * argv[0], so a dropped or rewritten argv[0] breaks ripgrep/bfs routing.
 */
TEST preserves_argv_and_execs_baked_in_binary(void) {
  reset_fixture();
  char *argv[] = {"ugrep", "-G", "needle", NULL};
  claude_wrapper_run(3, argv, recording_exec);

  ASSERT_EQ_FMT(1, exec_calls, "%d");
  ASSERT_STR_EQ(BINARY, exec_path);
  ASSERT_EQ_FMT(3, exec_argc, "%d");
  ASSERT_STR_EQ("ugrep", exec_argv[0]);    /* argv[0] preserved → tool dispatch */
  ASSERT_STR_EQ("-G", exec_argv[1]);
  ASSERT_STR_EQ("needle", exec_argv[2]);
  PASS();
}

/* Termux has no writable /tmp, so the wrapper points TMPDIR at the prefix. */
TEST sets_tmpdirs_when_unset(void) {
  reset_fixture();
  char *argv[] = {"claude", NULL};
  claude_wrapper_run(1, argv, recording_exec);

  ASSERT_STR_EQ(TMPDIR_PATH, env_or_empty("TMPDIR"));
  ASSERT_STR_EQ(TMPDIR_PATH, env_or_empty("CLAUDE_CODE_TMPDIR"));
  PASS();
}

/* overwrite=0: a TMPDIR the user/Termux already exported must win. */
TEST preserves_existing_tmpdirs(void) {
  reset_fixture();
  setenv("TMPDIR", "/keep", 1);
  setenv("CLAUDE_CODE_TMPDIR", "/keep-cc", 1);
  char *argv[] = {"claude", NULL};
  claude_wrapper_run(1, argv, recording_exec);

  ASSERT_STR_EQ("/keep", env_or_empty("TMPDIR"));
  ASSERT_STR_EQ("/keep-cc", env_or_empty("CLAUDE_CODE_TMPDIR"));
  PASS();
}

/*
 * termux-exec is preloaded into every Termux shell; its text-script libc.so
 * crashes the glibc binary's ld.so, so the wrapper must clear LD_PRELOAD before
 * the handoff.
 */
TEST clears_ld_preload(void) {
  reset_fixture();
  setenv("LD_PRELOAD", "/usr/lib/libtermux-exec-ld-preload.so", 1);
  char *argv[] = {"claude", NULL};
  claude_wrapper_run(1, argv, recording_exec);

  ASSERT(getenv("LD_PRELOAD") == NULL);
  PASS();
}

/* exec only returns on failure; when it does the wrapper reports it and exits 127. */
TEST exec_failure_returns_127(void) {
  reset_fixture();
  exec_retval = -1;
  char *argv[] = {"claude", NULL};
  /* The wrapper prints a diagnostic to stderr here; that output is expected. */
  int rc = claude_wrapper_run(1, argv, recording_exec);

  ASSERT_EQ_FMT(127, rc, "%d");
  PASS();
}

GREATEST_MAIN_DEFS();

int main(int argc, char **argv) {
  /* The wrapper writes an exec-failure diagnostic to stderr after every faked
     exec (any return models failure), so silence it — only the return codes and
     the captured handoff/env are under test, not the message text. */
#if defined(_WIN32)
  (void)freopen("NUL", "w", stderr);
#else
  (void)freopen("/dev/null", "w", stderr);
#endif

  GREATEST_MAIN_BEGIN();
  RUN_TEST(preserves_argv_and_execs_baked_in_binary);
  RUN_TEST(sets_tmpdirs_when_unset);
  RUN_TEST(preserves_existing_tmpdirs);
  RUN_TEST(clears_ld_preload);
  RUN_TEST(exec_failure_returns_127);
  GREATEST_MAIN_END();
}
