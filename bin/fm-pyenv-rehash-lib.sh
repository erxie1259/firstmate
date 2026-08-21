#!/usr/bin/env bash
# fm-pyenv-rehash-lib.sh - the single owner of what pyenv's rehash lock is and
# how a genuine rehash process is recognized.
#
# pyenv-rehash serializes itself with one file, <pyenv-root>/shims/.pyenv-shim,
# created under `set -o noclobber` and removed by an EXIT trap (verified against
# pyenv 2.6.31's libexec/pyenv-rehash). Kill the holder between those two points
# and the file survives with nothing behind it. Every later shell that runs
# `pyenv rehash` during startup then spins in the acquire loop for the whole
# PYENV_REHASH_TIMEOUT (60s by default), which is what turns one orphaned file
# into minutes of blocked terminals.
#
# The lock carries no owner: it is an empty file at acquire time and the shim
# script body afterwards, never a pid. So "is a rehash really in progress?" has
# to be answered from the process table plus the lock's own age, which is what
# the functions below do.
#
# WHY NOT `pgrep -f pyenv-rehash`, and please do not reintroduce it:
# `pgrep -f` matches the WHOLE command line of every process. Agent processes on
# this fleet carry their launch brief on their command line, and those briefs
# quote these very filenames, so a bare pattern match reports a rehash holder
# that does not exist - or matches the caller itself and waits on its own tail.
# That exact class of mistake wedged a worker for 25 minutes on 2026-08-20 when
# it polled `pgrep -f fm-test-run.sh` and matched its own agent process. The
# identity used here instead is structural and cannot be produced by prose: the
# process's argv0 must be a recognized shell, and its argv1 must be a path that
# resolves on disk to an existing executable regular file named pyenv-rehash.
# A brief that merely mentions the path fails both halves. Observed live shape,
# for reference: `bash /opt/homebrew/Cellar/pyenv/<v>/libexec/pyenv-rehash`.
#
# Consumers: bin/fm-pyenv-shim-lock-clear.sh (the guarded mover) and
# bin/fm-spawn.sh (stalled-terminal diagnosis). Both source this file; neither
# restates the rules above.

# Seconds after which a still-present lock is treated as abandoned regardless of
# which rehash processes are alive. The default sits above pyenv's own
# PYENV_REHASH_TIMEOUT (60s), which is how long a rehash queues for the lock
# before giving up and exiting, so an ordinary rehash cycle is long finished by
# then and is never mistaken for a stale one. Overridable for tests only.
FM_PYENV_REHASH_STALE_SECS=${FM_PYENV_REHASH_STALE_SECS:-90}

# Slack, in seconds, allowed when comparing a rehash process's start time against
# the lock's mtime. `ps` reports elapsed time in whole seconds and the two values
# are read a moment apart, so a difference inside this window proves nothing and
# the process is KEPT in the holder set. Every ambiguity here resolves toward
# refusing to clear.
FM_PYENV_REHASH_START_SLACK_SECS=${FM_PYENV_REHASH_START_SLACK_SECS:-2}

# fm_pyenv_shim_lock_path: the one path this fleet's cleaner is allowed to touch,
# derived from pyenv's own root convention (PYENV_ROOT, else ~/.pyenv - the same
# default `pyenv root` prints) plus the fixed relative path shims/.pyenv-shim.
# It is never assembled from caller input.
fm_pyenv_shim_lock_path() {
  local root=${PYENV_ROOT:-}
  if [ -z "$root" ]; then
    [ -n "${HOME:-}" ] || return 1
    root=$HOME/.pyenv
  fi
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${root%/}/shims/.pyenv-shim"
}

# fm_pyenv_mtime: seconds since epoch of <path>, BSD stat first then GNU.
fm_pyenv_mtime() {  # <path>
  local m
  m=$(stat -f %m -- "$1" 2>/dev/null) || m=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  case "$m" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$m"
}

# fm_pyenv_shim_lock_age_seconds: age of <path> in whole seconds, clamped at 0 so
# a skewed clock cannot report a lock as younger than new.
fm_pyenv_shim_lock_age_seconds() {  # <path>
  local mtime now age
  mtime=$(fm_pyenv_mtime "$1") || return 1
  now=$(date +%s) || return 1
  age=$((now - mtime))
  [ "$age" -ge 0 ] || age=0
  printf '%s\n' "$age"
}

# fm_pyenv_process_rows: one `pid<TAB>ppid<TAB>etime<TAB>argv0<TAB>argv1` row per
# process. Taken once per classification so every question below is answered from
# the same snapshot rather than racing separate `ps` calls against each other -
# including how long each process has been running, which is why the elapsed-time
# column is part of this one read rather than a per-pid `ps` of its own.
# A shell path containing a space would split wrong and simply fail to match,
# which loses a detection rather than inventing one.
fm_pyenv_process_rows() {
  local ps_bin=${FM_PYENV_PS_BIN:-ps} raw
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  # Captured before awk sees it: a pipeline would report awk's status and turn an
  # unreadable process table into a confident empty answer.
  raw=$("$ps_bin" -axo pid=,ppid=,etime=,args= 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | awk '{ printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5 }'
}

# fm_pyenv_etime_seconds: <etime> in whole seconds, parsing the [[dd-]hh:]mm:ss
# form both BSD and GNU `ps` print. Status 1 means the value could not be read at
# all, which callers must treat as "cannot prove anything about this process"
# rather than as an age of zero.
fm_pyenv_etime_seconds() {  # <etime>
  local e=$1 days=0 rest h=0 m=0 s part
  case "$e" in
    ''|*[!0-9:-]*) return 1 ;;
  esac
  case "$e" in
    *-*) days=${e%%-*}; rest=${e#*-} ;;
    *) rest=$e ;;
  esac
  case "$rest" in
    *:*:*)
      h=${rest%%:*}
      m=${rest#*:}; m=${m%%:*}
      s=${rest##*:}
      ;;
    *:*)
      m=${rest%%:*}
      s=${rest#*:}
      ;;
    *) s=$rest ;;
  esac
  for part in "$days" "$h" "$m" "$s"; do
    case "$part" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
  printf '%s\n' "$(( ((10#$days * 24 + 10#$h) * 60 + 10#$m) * 60 + 10#$s ))"
}

# fm_pyenv_is_shell_argv0: <argv0> names a recognized interactive-or-script shell.
# BSD ps reports argv0, so a login shell arrives as "-zsh"; strip that dash the
# same way bin/backends/herdr.sh's idle-shell proof does.
fm_pyenv_is_shell_argv0() {  # <argv0>
  local a=$1
  a=${a#-}
  a=${a##*/}
  case "$a" in
    sh|bash|zsh|dash|ksh|fish) return 0 ;;
  esac
  return 1
}

# fm_pyenv_ppid_of: the parent pid of <pid> within <rows>, or nothing.
fm_pyenv_ppid_of() {  # <pid> <rows>
  printf '%s\n' "$2" | awk -F '\t' -v p="$1" '$1 == p { print $2; exit }'
}

# fm_pyenv_ancestry: <pid> and every ancestor of it, one per line, bounded so a
# corrupt or cyclic table cannot spin. Used to keep the caller and everything
# that launched it out of the holder set.
fm_pyenv_ancestry() {  # <pid> <rows>
  local pid=$1 rows=$2 depth=0
  while [ "$depth" -lt 64 ]; do
    case "$pid" in
      ''|*[!0-9]*) return 0 ;;
    esac
    [ "$pid" -gt 1 ] || return 0
    printf '%s\n' "$pid"
    pid=$(fm_pyenv_ppid_of "$pid" "$rows")
    depth=$((depth + 1))
  done
}

# fm_pyenv_rehash_scan: one `pid<TAB>elapsed-seconds` row for every genuine live
# pyenv-rehash process, holder or waiter, excluding this process and its
# ancestors. Elapsed time is carried so a caller can derive when each process
# started; it is empty when `ps` gave no readable time for that process.
# Status 1 means the process table could not be read at all, which is a refusal
# to guess rather than an answer of "none".
fm_pyenv_rehash_scan() {
  local rows exclude pid etime argv0 argv1 elapsed
  rows=$(fm_pyenv_process_rows) || return 1
  exclude=$(fm_pyenv_ancestry "$$" "$rows")
  # Field 2 is the parent pid, needed by the ancestry walks that share these
  # rows but not here, so it is read into the throwaway and left unnamed.
  while IFS=$'\t' read -r pid _ etime argv0 argv1; do
    [ -n "${argv1:-}" ] || continue
    [ "${argv1##*/}" = pyenv-rehash ] || continue
    fm_pyenv_is_shell_argv0 "$argv0" || continue
    # The file-system half of the identity: prose on a command line can name the
    # path, but only a real invocation has argv1 pointing at the executable file.
    [ -f "$argv1" ] && [ -x "$argv1" ] || continue
    printf '%s\n' "$exclude" | grep -qx -- "$pid" && continue
    elapsed=$(fm_pyenv_etime_seconds "${etime:-}") || elapsed=""
    printf '%s\t%s\n' "$pid" "$elapsed"
  done <<EOF
$rows
EOF
}

# fm_pyenv_rehash_pids: pids of every genuine live pyenv-rehash process, whether
# it holds the lock or is only waiting for it. This is the raw "a real rehash is
# running here" question, which is what a blocked terminal's diagnosis asks.
fm_pyenv_rehash_pids() {
  local scanned
  scanned=$(fm_pyenv_rehash_scan) || return 1
  printf '%s' "$scanned" | awk -F '\t' 'NF { print $1 }'
}

# fm_pyenv_rehash_live_pids: pids of every genuine live pyenv-rehash process that
# could still be HOLDING <lock-path>. This is the holder set, and it is the only
# place that knows how a holder is told from a mere waiter; every consumer
# inherits that rule by calling here.
#
# The rule is start time against the lock's own mtime, not run length. pyenv's
# holder is the process that created the lock in acquire_lock and then rewrote it
# in create_prototype_shim, so the lock's mtime is always at or after the holder's
# own start. A rehash that started AFTER the lock already existed therefore cannot
# be the process that made it: it is queued behind the lock, and dropping it is
# what lets a freshly orphaned lock be cleared while a blocked shell waits on it.
#
# Deliberately NOT run length: pyenv's acquire loop runs only until
# start + PYENV_REHASH_TIMEOUT and the waiter then exits, so a rehash still alive
# past that timeout has already acquired the lock and is inside the shim-writing
# body, which on a cold cache legitimately takes tens of seconds. Excluding
# long-running processes would drop exactly the real holders. That is also why
# nothing here reads PYENV_REHASH_TIMEOUT: this process's own environment says
# nothing about the shell that actually holds the lock.
#
# Every unprovable case keeps the process in the set so the caller refuses: an
# unreadable elapsed time, an unreadable lock mtime, and any difference inside
# FM_PYENV_REHASH_START_SLACK_SECS.
fm_pyenv_rehash_live_pids() {  # <lock-path>
  local scanned mtime now
  scanned=$(fm_pyenv_rehash_scan) || return 1
  mtime=$(fm_pyenv_mtime "${1:-}") || mtime=""
  now=$(date +%s) || now=""
  if [ -z "$mtime" ] || [ -z "$now" ]; then
    printf '%s' "$scanned" | awk -F '\t' 'NF { print $1 }'
    return 0
  fi
  printf '%s' "$scanned" \
    | awk -F '\t' -v mtime="$mtime" -v now="$now" -v slack="$FM_PYENV_REHASH_START_SLACK_SECS" '
    NF {
      if ($2 != "" && now - $2 > mtime + slack) next
      print $1
    }
  '
}

# fm_pyenv_pid_has_ancestor: <pid> is <ancestor> or descends from it, bounded the
# same way as fm_pyenv_ancestry.
fm_pyenv_pid_has_ancestor() {  # <pid> <ancestor> [rows]
  local pid=$1 ancestor=$2 rows=${3:-} depth=0
  [ -n "$rows" ] || rows=$(fm_pyenv_process_rows) || return 1
  while [ "$depth" -lt 64 ]; do
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$pid" -gt 1 ] || return 1
    [ "$pid" != "$ancestor" ] || return 0
    pid=$(fm_pyenv_ppid_of "$pid" "$rows")
    depth=$((depth + 1))
  done
  return 1
}

# fm_pyenv_shim_lock_state: classify <lock-path> as one of
#   absent   - no lock, nothing to do
#   orphaned - the lock is present and no rehash can still be holding it
#   live     - a rehash is genuinely in progress and the lock is its own
#   unknown  - the process table could not be read, so nothing may be concluded
# On `live` it also prints the deciding holder pid as a second field.
#
# The rule, in one place: a lock older than FM_PYENV_REHASH_STALE_SECS is
# orphaned no matter which rehash processes are alive, since an ordinary rehash
# cycle finishes far inside that. A younger lock is live only while a process
# that could actually be its holder exists, which fm_pyenv_rehash_live_pids
# decides from the lock's own mtime; when none does, the young lock is re-sampled
# once after a short settle before being called orphaned, so a rehash that
# started between the two reads is not stepped on.
fm_pyenv_shim_lock_state() {  # <lock-path>
  local lock=$1 age pids
  [ -e "$lock" ] || { printf 'absent\n'; return 0; }
  age=$(fm_pyenv_shim_lock_age_seconds "$lock") || { printf 'unknown\n'; return 0; }
  pids=$(fm_pyenv_rehash_live_pids "$lock") || { printf 'unknown\n'; return 0; }
  if [ "$age" -ge "$FM_PYENV_REHASH_STALE_SECS" ]; then
    printf 'orphaned\n'
    return 0
  fi
  if [ -n "$pids" ]; then
    printf 'live %s\n' "$(printf '%s\n' "$pids" | head -1)"
    return 0
  fi
  sleep 0.5
  [ -e "$lock" ] || { printf 'absent\n'; return 0; }
  pids=$(fm_pyenv_rehash_live_pids "$lock") || { printf 'unknown\n'; return 0; }
  if [ -n "$pids" ]; then
    printf 'live %s\n' "$(printf '%s\n' "$pids" | head -1)"
    return 0
  fi
  printf 'orphaned\n'
}
