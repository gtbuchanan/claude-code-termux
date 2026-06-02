#!/usr/bin/env bash
#
# Print the package version — CalVer YYYY.M.<counter>, where <counter> is the
# CI run number (monotonic + unique) or 0 for local builds. Single source of the
# version format; build-deb.sh and test.sh default to it.
#
set -euo pipefail
# Unpadded month: leading zeros read oddly in versions and some parsers reject
# them. 10# forces base 10 so "08"/"09" aren't parsed as invalid octal.
printf '%s.%s.%s\n' "$(date -u +%Y)" "$((10#$(date -u +%m)))" "${GITHUB_RUN_NUMBER:-0}"
