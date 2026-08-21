#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
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

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_publication_survives_an_unwritable_existing_record
test_failed_publication_refuses_to_report_success

echo "# all fm-spawn-worktree-settle tests passed"
