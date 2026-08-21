#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `spawn_wait_for_worktree` poll loop run after
# `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same file also owns the ONE automatic recovery for a worktree-acquisition
# timeout: an orphaned pyenv rehash lock blocks the pane's shell in startup for
# the whole PYENV_REHASH_TIMEOUT, so `treehouse get` never runs and the wait
# expires. The cases at the bottom drive a real stalled spawn against a real
# rehash-shaped process and assert that the recovery fires only on that exact
# signature, reports itself, and leaves every other timeout cause behaving
# exactly as it does today.
#
# The same file also owns the publication that CONSUMES that settled worktree,
# because a worktree the spawn detected correctly is worth nothing if the task
# record naming it never reaches disk. Stock macOS Bash 3.2 does not treat a
# failed redirection on a compound command as a fatal errexit condition, so the
# original `{ ... } > "$STATE/<id>.meta"` block published an empty record and
# still printed its success line and exited 0 whenever that path could not be
# opened for writing. The cases below drive a complete spawn against exactly
# that path and assert the record either lands whole or the spawn refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# An existing task record that cannot be opened for writing is the failure the
# atomic publication was introduced for: the redirection that used to write the
# record in place silently produced nothing under Bash 3.2, leaving a live task
# whose worktree= a reader resolves as empty while the spawn claimed success.
# Publishing through a private temporary and renaming needs only directory
# write permission, so the settled worktree this file already asserts must now
# actually be readable back out of the published record.
test_publication_survives_an_unwritable_existing_record() {
  local rec id out status meta
  id=settle-unwritable-record-z3
  rec=$(make_settle_case settle-unwritable-record "$id" 0)
  read_settle_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  : > "$meta"
  chmod 000 "$meta"

  out=$(run_settle_spawn "$id")
  status=$?
  chmod 644 "$meta" 2>/dev/null || true
  expect_code 0 "$status" "spawn should succeed when the record path is only unwritable in place"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -s "$meta" ] || fail "the task record was published empty, so every reader resolves its worktree as nothing"
  assert_grep "worktree=$WT_DIR" "$meta" \
    "the published record did not carry the settled worktree"
  assert_grep "window=" "$meta" "the published record is missing its endpoint window"
  pass "an unwritable existing task record is replaced whole rather than published empty"
}

# The other half of the same contract: when publication genuinely cannot
# complete, the spawn must say so and exit non-zero instead of printing its
# success line over a backend terminal and worktree nothing will ever reclaim.
# The rename is faulted for this task's record only, standing in for the
# read-only filesystem, quota, and EIO cases that reach the same branch.
test_failed_publication_refuses_to_report_success() {
  local rec id out status
  id=settle-publish-fault-z4
  rec=$(make_settle_case settle-publish-fault "$id" 0)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/mv" <<SH
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
  case "\$arg" in
    *"/$id.meta") exit 1 ;;
  esac
done
exec /bin/mv "\$@"
SH
  chmod +x "$FAKEBIN_DIR/mv"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose task record could not be published exited 0: $out"
  assert_contains "$out" "cannot publish task metadata" \
    "the spawn did not say the task record could not be published"
  assert_not_contains "$out" "spawned $id" \
    "the spawn reported success even though its task record never landed"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "an unpublished spawn still left a task record behind"
  pass "a task record that cannot be published fails the spawn loudly instead of leaking a live endpoint"
}

# --- stalled-pane recovery --------------------------------------------------
#
# Fixture shape, shared by the four cases below:
#   - a pyenv root of the case's own, so nothing here can reach the real one
#   - a real, executable pyenv-rehash script of the case's own
#   - a "pane shell" process that starts one child and waits, standing in for the
#     terminal's shell; the fake tmux reports its pid as #{pane_pid}
#   - a ps wrapper that hides only rehash rows from OUTSIDE this fixture, because
#     this fleet's own shells start real rehashes constantly and a case about
#     "no rehash is running" must not be decided by host noise
# The fake tmux reports the project path (a stalled pane) for as long as a marker
# file exists and the worktree path once it is gone. For the pyenv cases that
# marker is the lock itself, which is what the real pane does: its blocked shell
# finishes startup the moment the lock goes away and then runs the `treehouse
# get` already sitting in its input.

STALL_BG_PIDS=""

stop_stall_background() {
  local p
  for p in $STALL_BG_PIDS; do
    kill "$p" 2>/dev/null || true
  done
  for p in $STALL_BG_PIDS; do
    wait "$p" 2>/dev/null || true
  done
  STALL_BG_PIDS=""
}

trap 'stop_stall_background; fm_test_cleanup' EXIT
trap 'stop_stall_background; fm_test_cleanup; exit 130' INT
trap 'stop_stall_background; fm_test_cleanup; exit 143' TERM

make_stall_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_pid}"*)
    cat "${FM_FAKE_PANE_PID_FILE:?FM_FAKE_PANE_PID_FILE unset}"
    exit 0
    ;;
  *"#{pane_current_path}"*)
    if [ -e "${FM_FAKE_STALL_MARKER:?FM_FAKE_STALL_MARKER unset}" ]; then
      printf '%s
' "${FM_FAKE_PROJ_PATH:-}"
    else
      printf '%s
' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate
'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s
' "$fakebin"
}

# make_stall_case <name> <id>: build the home, project, worktree, pyenv root,
# rehash script, pane-shell simulator and ps wrapper for one stall case.
make_stall_case() {
  local name=$1 id=$2 case_dir
  STALL_DIR="$TMP_ROOT/$name"
  case_dir=$STALL_DIR
  STALL_HOME="$case_dir/home"
  STALL_PROJ="$case_dir/project"
  STALL_WT="$case_dir/wt"
  STALL_PYROOT="$case_dir/.pyenv"
  STALL_LOCK="$STALL_PYROOT/shims/.pyenv-shim"
  STALL_REHASH="$case_dir/libexec/pyenv-rehash"
  STALL_PS="$case_dir/ps-wrapper"
  STALL_PIDFILE="$case_dir/pane-pid"
  # The fake pane reports the project path (still stalled) while this marker
  # exists and the worktree path once it is gone. For the pyenv cases it IS the
  # lock, so clearing the lock is what unblocks the pane, exactly as the real
  # shell's blocked startup does; a case about another cause points it elsewhere.
  STALL_MARKER="$STALL_LOCK"
  STALL_FAKEBIN=$(make_stall_fakebin "$case_dir/fake")
  mkdir -p "$STALL_HOME/data" "$STALL_HOME/projects" "$STALL_HOME/state" \
    "$STALL_HOME/config" "$STALL_PYROOT/shims" "$case_dir/libexec"
  printf 'codex\n' > "$STALL_HOME/config/crew-harness"
  fm_git_worktree "$STALL_PROJ" "$STALL_WT" "wt-$name"
  mkdir -p "$STALL_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$STALL_HOME/data/$id/brief.md"
  touch "$STALL_HOME/state/.last-watcher-beat"
  # shellcheck disable=SC2016 # The placeholder belongs in the written script.
  printf '#!/usr/bin/env bash\nsleep "${1:-300}"\n' > "$STALL_REHASH"
  chmod +x "$STALL_REHASH"
  cat > "$case_dir/pane-sim.sh" <<'SH'
#!/usr/bin/env bash
set -u
pidfile=$1
shift
"$@" >/dev/null 2>&1 &
child=$!
printf '%s
' "$$" > "$pidfile"
printf '%s
' "$child" > "$pidfile.child"
wait "$child"
SH
  chmod +x "$case_dir/pane-sim.sh"
  cat > "$STALL_PS" <<'SH'
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
  chmod +x "$STALL_PS"
}

# start_pane_shell <command> [args...]: run the pane-shell simulator with the
# given foreground child and wait until both pids are on the process table.
start_pane_shell() {
  local i=0
  "$STALL_DIR/pane-sim.sh" "$STALL_PIDFILE" "$@" >/dev/null 2>&1 &
  STALL_BG_PIDS="$STALL_BG_PIDS $!"
  while [ "$i" -lt 60 ]; do
    if [ -s "$STALL_PIDFILE" ] && [ -s "$STALL_PIDFILE.child" ]; then
      STALL_BG_PIDS="$STALL_BG_PIDS $(cat "$STALL_PIDFILE.child")"
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  fail "the simulated pane shell never published its pids"
}

run_stall_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$STALL_HOME" \
    FM_STATE_OVERRIDE="$STALL_HOME/state" FM_DATA_OVERRIDE="$STALL_HOME/data" \
    FM_PROJECTS_OVERRIDE="$STALL_HOME/projects" FM_CONFIG_OVERRIDE="$STALL_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_SPAWN_WORKTREE_POLLS=3 \
    FM_FAKE_PANE_PATH="$STALL_WT" FM_FAKE_PROJ_PATH="$STALL_PROJ" \
    FM_FAKE_STALL_MARKER="$STALL_MARKER" FM_FAKE_PANE_PID_FILE="$STALL_PIDFILE" \
    PYENV_ROOT="$STALL_PYROOT" FM_PYENV_PS_BIN="$STALL_PS" \
    FM_TEST_FIXTURE_ROOT="$TMP_ROOT" \
    PATH="$STALL_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$STALL_PROJ" --mode no-mistakes --yolo off 2>&1
}

# A timeout with no rehash lock in sight is every other cause of this failure -
# a broken treehouse, a wedged pane, a project that will not resolve. It must
# report exactly what it reports today and must not mention pyenv at all.
test_a_timeout_without_the_signature_is_unchanged() {
  local id out status
  id=stall-plain-timeout-z5
  make_stall_case stall-plain "$id"
  # Stalled for a reason that has nothing to do with pyenv, and nothing in this
  # run can ever clear it.
  STALL_MARKER="$STALL_DIR/unrelated-stall"
  : > "$STALL_MARKER"
  start_pane_shell sleep 300
  out=$(run_stall_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a genuine timeout exited 0: $out"
  assert_contains "$out" "treehouse get did not enter a worktree within" \
    "the ordinary timeout no longer reports itself"
  assert_not_contains "$out" "pyenv" \
    "a timeout with an unrelated cause was blamed on pyenv"
  stop_stall_background
  pass "a worktree timeout with any other cause behaves exactly as before"
}

# The fault this recovery exists for: the lock is long orphaned, the pane's shell
# is stuck in a rehash that will never get it, and the acquisition times out.
# One clear, one more wait, and a line saying so.
test_an_orphaned_lock_stall_recovers_and_says_so() {
  local id out status
  id=stall-recovered-z6
  make_stall_case stall-recovered "$id"
  printf 'body' > "$STALL_LOCK"
  touch -t 202001010000 "$STALL_LOCK"
  start_pane_shell "$STALL_REHASH" 300
  out=$(run_stall_spawn "$id")
  status=$?
  expect_code 0 "$status" "the stalled spawn did not recover: $out"
  assert_contains "$out" "stalled because a pyenv rehash" \
    "the recovery did not report what it diagnosed"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "the recovery did not report clearing the lock"
  assert_contains "$out" "recovered after clearing the orphaned pyenv rehash lock" \
    "the recovery healed silently instead of reporting itself"
  assert_absent "$STALL_LOCK" "the orphaned lock was left in place"
  assert_grep "worktree=$STALL_WT" "$STALL_HOME/state/$id.meta" \
    "the recovered spawn did not record the worktree it finally entered"
  stop_stall_background
  pass "a stall on an orphaned pyenv rehash lock is cleared once, retried once, and reported"
}

# A rehash that was already running when the lock appeared could be the process
# that created it, so the cleaner must refuse. That refusal is the real
# diagnosis; reporting a bare timeout here would send the operator hunting the
# wrong fault.
test_a_live_rehash_stall_surfaces_the_refusal() {
  local id out status
  id=stall-refused-z7
  make_stall_case stall-refused "$id"
  start_pane_shell "$STALL_REHASH" 300
  printf 'body' > "$STALL_LOCK"
  out=$(run_stall_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose lock could not be cleared exited 0: $out"
  assert_contains "$out" "could not be cleared" \
    "the spawn hid the fact that clearing was refused"
  assert_contains "$out" "a pyenv rehash is in progress" \
    "the spawn did not surface the refusal's own reason"
  assert_present "$STALL_LOCK" "the lock was moved despite a live rehash"
  stop_stall_background
  pass "a refused clear surfaces the real diagnosis instead of a generic timeout"
}

# The routine window the recovery exists to cover: the lock was orphaned only
# moments ago, so it is younger than the staleness threshold, and the pane's own
# rehash started AFTER the lock already existed - it is queued behind it, not
# holding it. The spawn must clear it and recover rather than refuse and hand the
# operator the unblock button.
test_a_young_orphan_with_a_waiting_rehash_recovers() {
  local id out status
  id=stall-young-orphan-z9
  make_stall_case stall-young-orphan "$id"
  # No backdating: this lock is young, so only the start-time rule can clear it.
  printf 'body' > "$STALL_LOCK"
  # Enough separation that the pane's rehash provably starts after the lock's
  # mtime, beyond the whole-second granularity `ps` reports.
  sleep 4
  start_pane_shell "$STALL_REHASH" 300
  out=$(run_stall_spawn "$id")
  status=$?
  expect_code 0 "$status" "a young orphaned lock with only a queued rehash did not recover: $out"
  assert_contains "$out" "stalled because a pyenv rehash" \
    "the recovery did not report what it diagnosed"
  assert_contains "$out" "cleared orphaned pyenv rehash lock" \
    "a rehash that only started after the lock existed was treated as its holder"
  assert_contains "$out" "recovered after clearing the orphaned pyenv rehash lock" \
    "the recovery healed silently instead of reporting itself"
  assert_absent "$STALL_LOCK" "the young orphaned lock was left in place"
  assert_grep "worktree=$STALL_WT" "$STALL_HOME/state/$id.meta" \
    "the recovered spawn did not record the worktree it finally entered"
  stop_stall_background
  pass "a young orphaned lock whose only rehash started after it is cleared and recovered"
}

# The trap, at the spawn's own level: a process on this pane that merely quotes
# the rehash path is not a rehash, so nothing must be cleared and the timeout
# must report itself normally. Without the structural identity check this case
# would clear a lock on the strength of an agent's launch brief.
test_a_command_line_mention_on_the_pane_does_not_trigger_recovery() {
  local id out status
  id=stall-decoy-z8
  make_stall_case stall-decoy "$id"
  printf 'body' > "$STALL_LOCK"
  touch -t 202001010000 "$STALL_LOCK"
  # shellcheck disable=SC2016 # The placeholder belongs in the written script.
  printf '#!/usr/bin/env bash\nsleep "${1:-300}"\n' > "$STALL_DIR/agent-sim.sh"
  chmod +x "$STALL_DIR/agent-sim.sh"
  start_pane_shell "$STALL_DIR/agent-sim.sh" 300 \
    "launch-brief: the fault is an orphaned lock left by $STALL_REHASH"
  out=$(run_stall_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a timeout with no real rehash exited 0: $out"
  assert_contains "$out" "treehouse get did not enter a worktree within" \
    "the ordinary timeout no longer reports itself"
  assert_not_contains "$out" "cleared orphaned pyenv rehash lock" \
    "a command-line mention was enough to make the spawn clear pyenv's lock"
  assert_present "$STALL_LOCK" "the lock was cleared on the strength of a command-line mention"
  stop_stall_background
  pass "a pane process that only mentions pyenv-rehash does not trigger the recovery"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_publication_survives_an_unwritable_existing_record
test_failed_publication_refuses_to_report_success
test_a_timeout_without_the_signature_is_unchanged
test_an_orphaned_lock_stall_recovers_and_says_so
test_a_live_rehash_stall_surfaces_the_refusal
test_a_young_orphan_with_a_waiting_rehash_recovers
test_a_command_line_mention_on_the_pane_does_not_trigger_recovery

echo "# all fm-spawn-worktree-settle tests passed"
