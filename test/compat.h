/*
 * Test-only POSIX shims for hosts whose libc lacks them.
 *
 * The unit tests build src/claude-wrapper.c natively on the dev host (see
 * scripts/test-wrapper.sh), but Windows/mingw libc has no POSIX setenv/unsetenv
 * — only _putenv_s. This header is force-included (-include) into the test
 * build to supply them; it is NEVER part of the shipped Termux build, so
 * production code stays free of host-portability cruft. On POSIX hosts the
 * block compiles to nothing and the real libc functions are used.
 */
#ifndef CLAUDE_WRAPPER_TEST_COMPAT_H
#define CLAUDE_WRAPPER_TEST_COMPAT_H

#if defined(_WIN32)
#include <stdlib.h>

static int setenv(const char *name, const char *value, int overwrite) {
  if (!overwrite && getenv(name) != NULL) {
    return 0;
  }
  return _putenv_s(name, value);
}

/* _putenv_s(name, "") removes the variable on Windows (getenv → NULL). */
static int unsetenv(const char *name) {
  return _putenv_s(name, "");
}
#endif /* _WIN32 */

#endif /* CLAUDE_WRAPPER_TEST_COMPAT_H */
