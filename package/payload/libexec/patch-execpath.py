#!/usr/bin/env python3
"""Null out Claude Code's subprocess CLAUDE_CODE_EXECPATH assignment.

Claude sets CLAUDE_CODE_EXECPATH=process.execPath (the bare binary) in the
environment of every subprocess, bypassing the launcher wrapper. Combined with
the LD_PRELOAD re-export in settings.json, that re-exec inherits LD_PRELOAD and
ld.so crashes. We can't intercept at process.execPath (the binary's execPath
always resolves to itself, never the wrapper), so instead we blank the
assignment: subprocesses see CLAUDE_CODE_EXECPATH="", and the snapshot's
`[[ -x $_cc_bin ]] || _cc_bin=$WRAPPER` fallback routes the re-exec through the
wrapper, which clears LD_PRELOAD.

The assignment is replaced in place with `""` + padding so byte offsets are
preserved. Bun's minifier rotates identifiers across releases, so the match is
anchored on the trailing `…).TMUX=` and uses backreferences to stay unique.
Fails loudly if the anchor isn't found exactly once, surfacing binary
refactors on the next version bump instead of silently mis-patching.
"""
import re
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

ident = rb"[A-Za-z_$][A-Za-z0-9_$]*"
anchor = re.compile(
    rb"((" + ident + rb")\[" + ident + rb"\]=)process\.execPath(,(" + ident + rb")\)\2\.TMUX=\4)"
)

matches = anchor.findall(data)
if len(matches) != 1:
    # The anchor is keyed on bun's minified output, which shifts between
    # releases. When it stops matching exactly once, dump a byte window around
    # each `process.execPath` so the new surrounding shape is visible from CI
    # logs alone — no local repro needed to update the anchor.
    needle = b"process.execPath"
    windows = []
    start = 0
    while (i := data.find(needle, start)) != -1:
        windows.append(data[max(0, i - 40):i + len(needle) + 40])
        start = i + len(needle)
    ctx = "\n  ".join(w.decode("latin-1") for w in windows[:5])
    sys.exit(
        f"CLAUDE_CODE_EXECPATH patch: expected exactly 1 anchor match, got "
        f"{len(matches)}.\n  process.execPath context "
        f"({len(windows)} occurrence(s)):\n  {ctx}"
    )

replacement = b'""' + b" " * 14
assert len(replacement) == 16

with open(path, "wb") as f:
    f.write(anchor.sub(lambda m: m.group(1) + replacement + m.group(3), data))
