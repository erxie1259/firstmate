#!/usr/bin/env bash
# fm-pyenv-shim-lock-clear.sh - move pyenv's orphaned rehash lock aside, or
# refuse. Takes no arguments and touches exactly one path.
#
# Why this exists as its own script: an orphaned <pyenv-root>/shims/.pyenv-shim
# blocks every new interactive shell for the full PYENV_REHASH_TIMEOUT, which
# stalls worker launches and the captain's own terminals. Clearing it needs to be
# something automation may run, and this narrow command is what gets allowlisted
# instead of a general `mv` or `rm`. Its whole value is that it cannot be aimed:
# the target is derived from pyenv's own root convention plus a fixed relative
# path (bin/fm-pyenv-rehash-lib.sh owns that derivation), never from a parameter,
# so allowlisting it grants exactly one file's worth of authority.
#
# It MOVES rather than deletes, to a dot-prefixed sibling carrying a UTC stamp.
# Dot-prefixed because pyenv's own `remove_outdated_shims` / `remove_stale_shims`
# iterate "$SHIM_PATH"/* , which never matches a leading dot, so the kept-aside
# copy is invisible to pyenv and reversible by hand.
#
# Usage: fm-pyenv-shim-lock-clear.sh
#
# Outcomes:
#   exit 0, one line on stdout   - the orphaned lock was moved aside
#   exit 0, silent               - there was no lock; nothing to do
#   exit 3, one line on stderr   - refused: a rehash is genuinely in progress
#   exit 2, one line on stderr   - refused: this command takes no arguments
#   exit 1, one line on stderr   - could not act (unreadable table, odd file type,
#                                  or the move itself failed)
# The two no-error outcomes deliberately share exit 0 so a caller may run this
# unconditionally under `set -e`; the printed line is what distinguishes "cleared"
# from "nothing to do", and callers key on that.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pyenv-rehash-lib.sh
. "$SCRIPT_DIR/fm-pyenv-rehash-lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ "$#" -ne 0 ]; then
  echo "error: fm-pyenv-shim-lock-clear.sh takes no arguments; its target is fixed" >&2
  exit 2
fi

LOCK=$(fm_pyenv_shim_lock_path) || {
  echo "error: pyenv's shim directory cannot be resolved from PYENV_ROOT or HOME" >&2
  exit 1
}

[ -e "$LOCK" ] || [ -L "$LOCK" ] || exit 0

if [ -L "$LOCK" ] || [ ! -f "$LOCK" ]; then
  echo "error: $LOCK is not a regular file; refusing to move it" >&2
  exit 1
fi

STATE=$(fm_pyenv_shim_lock_state "$LOCK")
case "$STATE" in
  absent)
    exit 0
    ;;
  unknown)
    echo "error: cannot tell whether a pyenv rehash is running; leaving $LOCK alone" >&2
    exit 1
    ;;
  live*)
    echo "refused: a pyenv rehash is in progress (holder pid ${STATE#live }); leaving $LOCK alone" >&2
    exit 3
    ;;
  orphaned)
    ;;
  *)
    echo "error: unrecognized lock state '$STATE'; leaving $LOCK alone" >&2
    exit 1
    ;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ) || {
  echo "error: cannot stamp the moved-aside lock; leaving $LOCK alone" >&2
  exit 1
}
DEST="$LOCK.fm-orphaned-$STAMP"
N=0
while [ -e "$DEST" ] || [ -L "$DEST" ]; do
  N=$((N + 1))
  if [ "$N" -gt 9 ]; then
    echo "error: no free name to move $LOCK aside to; leaving it alone" >&2
    exit 1
  fi
  DEST="$LOCK.fm-orphaned-$STAMP-$N"
done

mv -- "$LOCK" "$DEST" || {
  echo "error: could not move $LOCK aside" >&2
  exit 1
}
printf 'cleared orphaned pyenv rehash lock: %s moved to %s\n' "$LOCK" "$DEST"
