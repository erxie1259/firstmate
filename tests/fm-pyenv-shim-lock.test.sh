#!/usr/bin/env bash
# Behavior tests for bin/fm-pyenv-shim-lock-clear.sh and the holder identity in
# bin/fm-pyenv-rehash-lib.sh.
#
# The cleaner exists because an orphaned <pyenv-root>/shims/.pyenv-shim blocks
# every new interactive shell for the whole PYENV_REHASH_TIMEOUT, which stalls
# worker launches. It must clear a genuinely orphaned lock, refuse while a rehash
# is really running, and stay a quiet no-op when there is no lock at all.
#
# The case that carries the real risk is test_a_command_line_mention_is_not_a_holder:
# the naive holder check is `pgrep -f pyenv-rehash`, which matches the WHOLE
# command line of every process, and agent processes here carry launch briefs that
# quote these filenames. That test drives a decoy that a full-command-line match
# DOES hit, asserts the naive match hits it, and then asserts the cleaner is not
# fooled - so the case cannot go quietly vacuous if the decoy ever stops being a
# decoy.
#
# Every rehash-shaped process below is a REAL process running a REAL executable
# file named pyenv-rehash; nothing here fakes the identity being tested. The one
# thing stubbed out is host noise: this fleet's own shells start rehashes
# constantly, so FM_PYENV_PS_BIN points at a wrapper that runs the real `ps` and
# drops only rehash rows from OUTSIDE this suite's fixture root. Fixture
# processes, decoys, and every other real process pass through untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAR="$ROOT/bin/fm-pyenv-shim-lock-clear.sh"
TMP_ROOT=$(fm_test_tmproot fm-pyenv-shim-lock)

BG_PIDS=""
# Only the regression case below sets this, and only to prove that pyenv's own
# timeout has no say in who holds the lock. Empty everywhere else.
CASE_REHASH_TIMEOUT=""

stop_background() {
  local p
  for p in $BG_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  for p in $BG_PIDS; do
    wait "$p" 2>/dev/null || true
  done
  BG_PIDS=""
}

trap 'stop_background; fm_test_cleanup' EXIT
trap 'stop_background; fm_test_cleanup; exit 130' INT
trap 'stop_background; fm_test_cleanup; exit 143' TERM

# make_case <name> builds an isolated pyenv root with a real, executable
# pyenv-rehash script of its own, plus the host-noise-filtering ps wrapper.
# Echoes "<case-dir>|<pyenv-root>|<lock>|<rehash-script>|<ps-wrapper>".
make_case() {
  local name=$1 dir root lock rehash ps_wrapper
  dir="$TMP_ROOT/$name"
  root="$dir/.pyenv"
  lock="$root/shims/.pyenv-shim"
  rehash="$dir/libexec/pyenv-rehash"
  ps_wrapper="$dir/ps-wrapper"
  mkdir -p "$root/shims" "$dir/libexec"
  # shellcheck disable=SC2016 # The sleep argument must reach the script, not expand here.
  printf '#!/usr/bin/env bash\nsleep "${1:-120}"\n' > "$rehash"
  chmod +x "$rehash"
  cat > "$ps_wrapper" <<'SH'
#!/usr/bin/env bash
set -u
/bin/ps "$@" | awk -v root="$FM_TEST_FIXTURE_ROOT" '
  {
    n = split($5, parts, "/")
    if (parts[n] == "pyenv-rehash" && index($5, root) != 1) next
    print
  }
'
SH
  chmod +x "$ps_wrapper"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$root" "$lock" "$rehash" "$ps_wrapper"
}

read_case() {
  IFS='|' read -r CASE_DIR PYROOT LOCK REHASH PS_WRAPPER <<EOF
$1
EOF
}

run_clear() {
  PYENV_ROOT="$PYROOT" FM_PYENV_PS_BIN="$PS_WRAPPER" \
    PYENV_REHASH_TIMEOUT="$CASE_REHASH_TIMEOUT" \
    FM_TEST_FIXTURE_ROOT="$TMP_ROOT" "$CLEAR" "$@" 2>&1
}

# start_rehash starts a real process running this case's real pyenv-rehash file
# and records its pid in REHASH_PID. Not a command substitution: the started
# process must be registered for cleanup in THIS shell, and its output is sent to
# /dev/null so it never holds a caller's capture pipe open.
REHASH_PID=""
start_rehash() {
  "$REHASH" 120 >/dev/null 2>&1 &
  REHASH_PID=$!
  BG_PIDS="$BG_PIDS $REHASH_PID"
  wait_for_pid "$REHASH_PID"
}

wait_for_pid() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    if ps -p "$pid" -o pid= >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  fail "background process $pid never appeared in the process table"
}

aside_count() {
  local n
  n=$(find "$PYROOT/shims" -maxdepth 1 -name '.pyenv-shim.fm-orphaned-*' 2>/dev/null | wc -l)
  printf '%s\n' "$(printf '%s' "$n" | tr -d '[:space:]')"
}

write_lock() {  # <content> [old]
  printf '%s' "$1" > "$LOCK"
  if [ "${2:-}" = old ]; then
    touch -t 202001010000 "$LOCK"
  fi
}

# An absent lock is the ordinary state, and callers run this unconditionally, so
# it must cost nothing and say nothing.
test_absent_lock_is_a_silent_no_op() {
  local out status
  read_case "$(make_case absent)"
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "an absent lock must be reported as success"
  [ -z "$out" ] || fail "an absent lock printed output: $out"
  [ "$(aside_count)" = 0 ] || fail "an absent lock still produced a moved-aside file"
  pass "an absent pyenv rehash lock is a silent, successful no-op"
}

# The whole point of moving instead of deleting: the operator can put it back and
# can see that it happened.
test_orphaned_lock_is_moved_aside_not_deleted() {
  local out status aside
  read_case "$(make_case orphaned)"
  write_lock 'prototype-shim-body' old
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "clearing an orphaned lock must succeed"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "the cleaner did not say it cleared the lock"
  assert_absent "$LOCK" "the orphaned lock is still in place"
  [ "$(aside_count)" = 1 ] || fail "expected exactly one moved-aside copy, found $(aside_count)"
  aside=$(find "$PYROOT/shims" -maxdepth 1 -name '.pyenv-shim.fm-orphaned-*')
  [ "$(cat "$aside")" = 'prototype-shim-body' ] \
    || fail "the moved-aside copy did not preserve the lock's contents"
  pass "an orphaned lock is moved aside with its contents intact, not deleted"
}

# Automation runs this unconditionally, so a second run against an already-clean
# shim directory must be indistinguishable from the absent case.
test_a_second_run_is_a_silent_no_op() {
  local out status
  read_case "$(make_case idempotent)"
  write_lock 'body' old
  run_clear >/dev/null
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "a repeat run must succeed"
  [ -z "$out" ] || fail "a repeat run printed output: $out"
  [ "$(aside_count)" = 1 ] || fail "a repeat run produced a second moved-aside copy"
  pass "running the cleaner twice clears once and then says nothing"
}

# A rehash that was already running when the lock appeared is the process that
# could have created it; taking the lock away would let a second rehash write
# shims underneath the first.
test_a_live_rehash_is_refused() {
  local out status
  read_case "$(make_case live)"
  start_rehash
  write_lock 'body'
  out=$(run_clear)
  status=$?
  expect_code 3 "$status" "a live rehash must be refused with its own exit status"
  assert_contains "$out" "refused: a pyenv rehash is in progress" \
    "the refusal did not name the reason"
  assert_contains "$out" "$REHASH_PID" "the refusal did not name the holder it found"
  assert_present "$LOCK" "the lock was moved even though a rehash was running"
  stop_background
  pass "a genuinely running rehash makes the cleaner refuse and leave the lock alone"
}

# THE TRAP. `pgrep -f` and any other full-command-line match reports a holder
# that does not exist as soon as some unrelated process merely quotes the path -
# which every agent launch brief on this fleet does. The decoy below is exactly
# that process, and both halves are asserted: that the naive match is fooled, and
# that this cleaner is not.
test_a_command_line_mention_is_not_a_holder() {
  local out status decoy naive
  read_case "$(make_case decoy)"
  write_lock 'body'
  # shellcheck disable=SC2016 # As above: the placeholder belongs in the written script.
  printf '#!/usr/bin/env bash\nsleep "${1:-120}"\n' > "$CASE_DIR/agent-sim.sh"
  chmod +x "$CASE_DIR/agent-sim.sh"
  "$CASE_DIR/agent-sim.sh" 120 "launch-brief: the fault is an orphaned lock left by $REHASH" \
    >/dev/null 2>&1 &
  decoy=$!
  BG_PIDS="$BG_PIDS $decoy"
  wait_for_pid "$decoy"

  # Divergence assertion: if this ever stops holding, the decoy has stopped being
  # a decoy and the case below would pass for the wrong reason.
  # shellcheck disable=SC2009 # Grepping full command lines IS the naive check under test.
  naive=$(ps -axo pid=,args= | grep -F 'pyenv-rehash' | awk '{print $1}')
  printf '%s\n' "$naive" | grep -qx -- "$decoy" \
    || fail "the decoy is no longer matched by a full-command-line search, so this case proves nothing"

  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "a process that merely mentions the path must not block clearing"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "the cleaner treated a command-line mention as a live rehash"
  assert_absent "$LOCK" "the lock survived even though no rehash was running"
  stop_background
  pass "a process that only mentions pyenv-rehash on its command line is not treated as the holder"
}

# The observed fault: the lock is long orphaned and every new shell is stuck
# WAITING on it, so live rehash processes exist and none of them created this
# lock - each started long after the file was already there. The lock is also
# older than the staleness threshold, so it is clearable on either ground.
test_a_stale_lock_is_cleared_even_while_waiters_run() {
  local out status
  read_case "$(make_case waiters)"
  write_lock 'body' old
  start_rehash
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "a long-orphaned lock must be cleared even while shells wait on it"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "the cleaner mistook a waiting shell for the lock's holder"
  assert_absent "$LOCK" "the long-orphaned lock survived"
  stop_background
  pass "a long-orphaned lock is cleared even while blocked shells are still waiting on it"
}

# The routine window: the lock was orphaned moments ago, so it is far younger
# than the staleness threshold, and the only rehash alive started AFTER the lock
# already existed. A process that was not running when the file appeared cannot
# be the process that created it, so it is queued behind the lock, not holding
# it, and the lock is clearable.
test_a_young_lock_with_a_waiting_rehash_is_cleared() {
  local out status
  read_case "$(make_case young-waiter)"
  # No backdating: this lock is young, so only the start-time rule can clear it.
  write_lock 'body'
  # Enough separation that the rehash provably starts after the lock's mtime,
  # beyond the whole-second granularity `ps` reports.
  sleep 4
  start_rehash
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "a young lock whose only rehash started after it must be cleared"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "a rehash that only started after the lock existed was treated as its holder"
  assert_absent "$LOCK" "the young orphaned lock survived"
  stop_background
  pass "a young lock is cleared when its only rehash started after the lock already existed"
}

# The regression that matters: a rehash which was running before the lock
# appeared is a candidate holder no matter how long its body has been going.
# pyenv's own acquire loop ends at PYENV_REHASH_TIMEOUT and the waiter exits,
# so a still-running rehash past that point has ACQUIRED the lock and is writing
# shims - the one process that must never be cleared out from under. The timeout
# is set to one second here precisely to prove it has no say: the cleaner sees it
# in its own environment, the shell that owns the lock never did.
test_a_rehash_older_than_its_lock_is_refused_however_long_it_runs() {
  local out status
  read_case "$(make_case long-holder)"
  start_rehash
  sleep 4
  write_lock 'body'
  CASE_REHASH_TIMEOUT=1
  out=$(run_clear)
  status=$?
  CASE_REHASH_TIMEOUT=""
  expect_code 3 "$status" "a rehash predating its lock must be refused whatever its run length"
  assert_contains "$out" "refused: a pyenv rehash is in progress" \
    "the refusal did not name the reason"
  assert_present "$LOCK" "a running rehash's own lock was moved aside"
  stop_background
  pass "a rehash that predates its lock keeps holding it however long it has been running"
}

# An unreadable process table must not cost the tool its primary path. A lock
# well past the staleness threshold is decided by its age alone, so it is still
# cleared when `ps` cannot be consulted; a young lock, whose verdict genuinely
# needs the process table, must still refuse to guess.
test_an_unreadable_process_table_still_clears_a_stale_lock() {
  local out status
  read_case "$(make_case ps-unreadable)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_DIR/ps-broken"
  chmod +x "$CASE_DIR/ps-broken"
  PS_WRAPPER="$CASE_DIR/ps-broken"
  write_lock 'body' old
  out=$(run_clear)
  status=$?
  expect_code 0 "$status" "a long-orphaned lock must still be cleared when the process table cannot be read"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "an unreadable process table blocked the fault this tool exists for"
  assert_absent "$LOCK" "the long-orphaned lock survived an unreadable process table"

  write_lock 'body'
  out=$(run_clear)
  status=$?
  expect_code 1 "$status" "a young lock with no readable process table must refuse to guess"
  assert_contains "$out" "cannot tell whether a pyenv rehash is running" \
    "the refusal did not name the reason"
  assert_present "$LOCK" "a young lock was cleared without any evidence about running rehashes"
  pass "an unreadable process table still clears a stale lock but never a young one"
}

# The narrow surface is the reason this command can be allowlisted at all: it
# must never become a general file mover.
test_arguments_are_refused() {
  local out status
  read_case "$(make_case args)"
  write_lock 'body' old
  out=$(run_clear "$CASE_DIR/somewhere-else")
  status=$?
  expect_code 2 "$status" "an argument must be refused"
  assert_contains "$out" "takes no arguments" "the refusal did not explain itself"
  assert_present "$LOCK" "the lock was touched by an invocation that should have been refused"
  pass "the cleaner refuses arguments so it cannot be aimed at another path"
}

# Anything other than pyenv's own regular file at that path is unexplained, and
# moving it would be acting on a guess.
test_an_unexpected_file_type_is_refused() {
  local out status
  read_case "$(make_case symlink)"
  printf 'elsewhere\n' > "$CASE_DIR/elsewhere"
  ln -s "$CASE_DIR/elsewhere" "$LOCK"
  out=$(run_clear)
  status=$?
  expect_code 1 "$status" "a symlink at the lock path must be refused"
  assert_contains "$out" "is not a regular file" "the refusal did not name the reason"
  assert_present "$CASE_DIR/elsewhere" "the symlink's target was disturbed"
  [ -L "$LOCK" ] || fail "the symlink at the lock path was moved"
  pass "a symlink at the lock path is refused rather than moved"
}

test_absent_lock_is_a_silent_no_op
test_orphaned_lock_is_moved_aside_not_deleted
test_a_second_run_is_a_silent_no_op
test_a_live_rehash_is_refused
test_a_command_line_mention_is_not_a_holder
test_a_stale_lock_is_cleared_even_while_waiters_run
test_a_young_lock_with_a_waiting_rehash_is_cleared
test_a_rehash_older_than_its_lock_is_refused_however_long_it_runs
test_an_unreadable_process_table_still_clears_a_stale_lock
test_arguments_are_refused
test_an_unexpected_file_type_is_refused

echo "# all fm-pyenv-shim-lock tests passed"
