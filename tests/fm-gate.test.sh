#!/usr/bin/env bash
# Tests for bin/fm-gate.sh: mechanical post-run gates that check a finished
# task's own claims against what actually happened.
#
# The load-bearing property is that a FALSE claim is caught and an UNRUNNABLE
# check never looks like a pass. So the matrix pins, in both directions:
#   - an honest exhaustive claim record passes
#   - a claim naming a file the branch never touched fails and names it
#   - an exhaustive record that hides a real touch fails; a non-exhaustive one
#     reports the same touch as a note and still passes
#   - claims derived from status prose catch a false claim, ignore obstacle
#     lines, and ignore prose tokens that are not anchored in the repository
#   - no claims, no metadata, and a returned (detached) worktree are all
#     reported as inconclusive rather than as a pass
#   - scout and ship deliverables, and the opt-in tests_pass gate
#   - a typed terminal envelope is a declared exhaustive claim source, so an
#     undeclared touch fails where status prose would only have noted it
#   - an ABSENT envelope is not applicable and leaves every other verdict, the
#     claim source, and the exit status exactly as they were without it, while a
#     PRESENT but invalid one is reported and refused as a claim source
#   - self-reported test counts are checked for consistency and never mistaken
#     for having run anything
#   - the whole run leaves the repository byte-identical
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-tests)
TASK_ID=task-g1

# A project clone with an origin, plus a worktree on the task's own branch.
# The baseline carries bin/ and docs/ so a claimed-but-absent path under either
# is still anchored to a real directory, the way a real repo behaves.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  mkdir -p "$case_dir/_seed/bin" "$case_dir/_seed/docs"
  printf 'baseline\n' > "$case_dir/_seed/bin/real.sh"
  printf 'baseline\n' > "$case_dir/_seed/docs/guide.md"
  printf 'baseline\n' > "$case_dir/_seed/README.md"
  git -C "$case_dir/_seed" add .
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$TASK_ID" "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 kind=${2:-ship}
  fm_write_meta "$case_dir/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=direct-PR"
}

# One committed change to bin/real.sh and one new docs file: the "reality" every
# claim record in this suite is judged against.
commit_real_work() {
  local case_dir=$1
  printf 'changed\n' > "$case_dir/wt/bin/real.sh"
  printf 'new\n' > "$case_dir/wt/docs/added.md"
  git -C "$case_dir/wt" add bin/real.sh docs/added.md
  git -C "$case_dir/wt" commit -qm "task work"
}

write_claims() {
  local path=$1
  shift
  : > "$path"
  printf '%s\n' "$@" >> "$path"
}

write_status() {
  local case_dir=$1
  shift
  : > "$case_dir/state/$TASK_ID.status"
  printf '%s\n' "$@" >> "$case_dir/state/$TASK_ID.status"
}

# The typed terminal envelope a crewmate writes at data/<id>/envelope.json.
# Written as raw JSON text so a test can hand the gate a malformed or
# contract-violating document, which is half of what needs covering.
write_envelope() {
  local case_dir=$1 body=$2
  mkdir -p "$case_dir/data/$TASK_ID"
  printf '%s\n' "$body" > "$case_dir/data/$TASK_ID/envelope.json"
}

# A well-formed envelope with the two really-changed files and no test claims,
# so each test can vary exactly the one thing it is about.
envelope_json() {  # <files-json-array> [tests_run] [tests_passed]
  printf '{"files_changed":%s,"tests_run":%s,"tests_passed":%s,"claims":["did the work"],"acceptance_criteria_met":["ac1"],"open_questions":[]}' \
    "$1" "${2:-0}" "${3:-0}"
}

# Sets OUT to the gate's combined output and RC to its exit status. Deliberately
# not a command substitution: the exit status is half of what is under test, and
# a subshell would swallow it.
RC=0
OUT=
run_gate() {
  local case_dir=$1
  shift
  RC=0
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$GATE" "$@" > "$case_dir/gate.out" 2>&1 || RC=$?
  OUT=$(cat "$case_dir/gate.out")
}

repo_fingerprint() {
  local case_dir=$1
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)'
  git -C "$case_dir/wt" rev-parse HEAD
  git -C "$case_dir/wt" status --porcelain
  git -C "$case_dir/wt" stash list
}

test_honest_exhaustive_claims_pass() {
  local case_dir
  case_dir=$(make_case honest)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 0 "$RC" "honest"
  assert_contains "$OUT" 'GATE diff_matches_claims: PASS' "honest: the diff must match the claims"
  assert_contains "$OUT" 'GATE artifacts_exist: PASS' "honest: the branch carries a commit"
  assert_contains "$OUT" 'verdict: PASS' "honest: overall verdict"
  pass "fm-gate passes an honest exhaustive claim record"
}

test_false_claim_is_caught() {
  local case_dir
  case_dir=$(make_case false-claim)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  # The load-bearing case: the worker says it changed a file it never touched.
  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md" \
    "files_changed=bin/never-written.sh"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 1 "$RC" "false-claim"
  assert_contains "$OUT" 'GATE diff_matches_claims: FAIL' "false-claim: the gate must fail"
  assert_contains "$OUT" 'claimed but untouched:' "false-claim: the mismatch class must be named"
  assert_contains "$OUT" 'bin/never-written.sh' "false-claim: the specific file must be named"
  assert_contains "$OUT" 'verdict: FAIL' "false-claim: overall verdict"
  pass "fm-gate catches a claim for work that was never done"
}

test_exhaustive_source_fails_on_unclaimed_touch() {
  local case_dir
  case_dir=$(make_case hidden-touch)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 1 "$RC" "hidden-touch"
  assert_contains "$OUT" 'GATE diff_matches_claims: FAIL' "hidden-touch: an exhaustive record must account for every file"
  assert_contains "$OUT" 'touched but unclaimed:' "hidden-touch: the mismatch class must be named"
  assert_contains "$OUT" 'docs/added.md' "hidden-touch: the specific file must be named"
  pass "fm-gate fails an exhaustive claim record that hides a real change"
}

test_non_exhaustive_source_notes_unclaimed_touch() {
  local case_dir
  case_dir=$(make_case note-only)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_claims "$case_dir/claims" \
    "claim_source=prose-stub" \
    "claim_confidence=derived" \
    "files_changed_exhaustive=0" \
    "files_changed=bin/real.sh"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 0 "$RC" "note-only"
  assert_contains "$OUT" 'GATE diff_matches_claims: PASS' "note-only: a partial record must not fail on an extra touch"
  assert_contains "$OUT" 'touched but unclaimed (note only' "note-only: the extra touch must still be reported"
  assert_contains "$OUT" 'docs/added.md' "note-only: the extra touch must be named"
  pass "fm-gate reports an unclaimed touch as a note for a non-exhaustive claim source"
}

test_status_prose_claims_catch_a_false_claim() {
  local case_dir
  case_dir=$(make_case status-false)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_status "$case_dir" \
    "working: setup complete" \
    "done: rewrote bin/real.sh and added bin/never-written.sh"

  run_gate "$case_dir" "$TASK_ID"

  expect_code 1 "$RC" "status-false"
  # Both prose paths must be derived, or "caught the false one" would be an
  # accident of an empty claim set rather than a real comparison.
  assert_contains "$OUT" 'source=status confidence=derived files=2' \
    "status-false: both prose paths must be derived as claims"
  assert_contains "$OUT" 'GATE diff_matches_claims: FAIL' "status-false: the false claim must fail the gate"
  assert_contains "$OUT" 'claimed but untouched:
    bin/never-written.sh' "status-false: only the false claim belongs in the untouched block"
  pass "fm-gate derives claims from status prose and catches a false one"
}

test_status_prose_ignores_obstacle_lines_and_unanchored_tokens() {
  local case_dir
  case_dir=$(make_case status-noise)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_status "$case_dir" \
    "done: pushed refs/pull/9/head and bumped the pin to 0.11.0" \
    "blocked: compile fails on missing bin/absent-dependency.sh"

  run_gate "$case_dir" "$TASK_ID"

  # Every token is either unanchored prose or lives on an obstacle line, so the
  # status source yields no claims at all - and that is reported, not passed.
  expect_code 3 "$RC" "status-noise"
  assert_contains "$OUT" 'source=status confidence=derived files=0' "status-noise: no claim should survive"
  assert_not_contains "$OUT" 'refs/pull/9/head' "status-noise: an unanchored ref name is not a claimed path"
  assert_not_contains "$OUT" '0.11.0' "status-noise: a version string is not a claimed path"
  assert_not_contains "$OUT" 'bin/absent-dependency.sh' "status-noise: a blocked: line is not a claim of work done"
  pass "fm-gate keeps obstacle lines and unanchored prose tokens out of derived claims"
}

test_status_keyed_verbs_are_read() {
  local case_dir
  case_dir=$(make_case status-keyed)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  # bin/fm-classify-lib.sh allows an optional [key=<slug>] token between the
  # verb and the colon. A resolver that matched "^done:" literally would read
  # nothing here and go quietly claimless.
  write_status "$case_dir" \
    "working [key=phase]: reworked bin/real.sh" \
    "done [key=phase]: also added bin/never-written.sh"

  run_gate "$case_dir" "$TASK_ID"

  expect_code 1 "$RC" "status-keyed"
  assert_contains "$OUT" 'source=status confidence=derived files=2' \
    "status-keyed: keyed done/working lines must still yield their claims"
  assert_contains "$OUT" 'claimed but untouched:
    bin/never-written.sh' "status-keyed: the false claim must still be caught"
  pass "fm-gate reads keyed done/working status lines through the classify contract"
}

test_status_root_token_needs_a_real_anchor() {
  local case_dir
  case_dir=$(make_case status-root)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  # CHANGELOG.md is neither tracked nor changed: at the repo root there is
  # nothing to tell it apart from prose about a file this task never owned, so
  # it must not become a claim. README.md IS tracked and was not changed, so a
  # claim on it is still real evidence and must still fail.
  write_status "$case_dir" "done: regenerated CHANGELOG.md and rewrote README.md"

  run_gate "$case_dir" "$TASK_ID"

  expect_code 1 "$RC" "status-root"
  assert_contains "$OUT" 'source=status confidence=derived files=1' \
    "status-root: only the anchored root token may become a claim"
  assert_not_contains "$OUT" 'CHANGELOG.md' \
    "status-root: an unanchored root token must not become a claimed path"
  assert_contains "$OUT" 'claimed but untouched:
    README.md' "status-root: a tracked root file claimed but untouched is still caught"
  pass "fm-gate anchors repo-root prose tokens on being tracked or changed"
}

test_no_claims_reports_inconclusive_not_pass() {
  local case_dir
  case_dir=$(make_case no-claims)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  # No status log and no --claims: there is nothing to check.

  run_gate "$case_dir" "$TASK_ID"

  expect_code 3 "$RC" "no-claims"
  assert_contains "$OUT" 'claims: none resolved' "no-claims: the absence must be stated"
  assert_contains "$OUT" 'GATE diff_matches_claims: CANNOT-RUN' "no-claims: the gate must say it could not run"
  assert_contains "$OUT" 'verdict: INCONCLUSIVE' "no-claims: must not read as a pass"
  assert_not_contains "$OUT" 'verdict: PASS' "no-claims: a vacuous pass is the failure mode this exists to prevent"
  pass "fm-gate reports a task with no claims as inconclusive rather than passing vacuously"
}

test_missing_metadata_cannot_run() {
  local case_dir
  case_dir=$(make_case no-meta)
  commit_real_work "$case_dir"

  run_gate "$case_dir" "$TASK_ID"

  expect_code 3 "$RC" "no-meta"
  assert_contains "$OUT" 'CANNOT RUN: no recorded metadata' "no-meta: the missing record must be named"
  assert_contains "$OUT" 'verdict: INCONCLUSIVE' "no-meta: must not read as a pass"
  pass "fm-gate reports missing task metadata as inconclusive"
}

test_returned_worktree_cannot_run() {
  local case_dir
  case_dir=$(make_case returned-wt)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  # A returned and re-leased worktree sits detached on the default branch: the
  # task's work is not there to judge, which is not the same as absent work.
  git -C "$case_dir/wt" checkout -q --detach main

  run_gate "$case_dir" "$TASK_ID"

  expect_code 3 "$RC" "returned-wt"
  assert_contains "$OUT" 'GATE artifacts_exist: CANNOT-RUN' "returned-wt: must not fabricate a missing-work failure"
  assert_contains "$OUT" "no longer holds this task's branch" "returned-wt: the reason must be legible"
  assert_not_contains "$OUT" 'verdict: FAIL' "returned-wt: an unjudgeable branch is not a failed one"
  pass "fm-gate reports a returned worktree as inconclusive, not as missing work"
}

test_scout_report_artifacts() {
  local case_dir
  case_dir=$(make_case scout-missing)
  write_meta "$case_dir" scout

  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "scout-missing"
  assert_contains "$OUT" 'GATE artifacts_exist: FAIL' "scout-missing: a scout without a report has no deliverable"
  assert_contains "$OUT" 'scout deliverable is missing' "scout-missing: the reason must be legible"

  mkdir -p "$case_dir/data/$TASK_ID"
  printf '   \n\n' > "$case_dir/data/$TASK_ID/report.md"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "scout-empty"
  assert_contains "$OUT" 'scout deliverable exists but is empty' "scout-empty: whitespace is not a deliverable"

  printf '# Findings\n\nThe cause is X.\n' > "$case_dir/data/$TASK_ID/report.md"
  run_gate "$case_dir" "$TASK_ID"
  assert_contains "$OUT" 'GATE artifacts_exist: PASS' "scout-report: a real report satisfies the gate"
  pass "fm-gate requires a non-empty scout report as the scout deliverable"
}

test_ship_without_commits_fails_artifacts() {
  local case_dir
  case_dir=$(make_case no-commits)
  write_meta "$case_dir"
  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 1 "$RC" "no-commits"
  assert_contains "$OUT" 'GATE artifacts_exist: FAIL' "no-commits: a ship with no commits has no deliverable"
  assert_contains "$OUT" 'has no commits of its own' "no-commits: the reason must be legible"
  pass "fm-gate fails a ship task whose branch carries no commits"
}

test_secondmate_artifacts_not_applicable() {
  local case_dir
  case_dir=$(make_case secondmate)
  write_meta "$case_dir" secondmate

  run_gate "$case_dir" "$TASK_ID"

  assert_contains "$OUT" 'GATE artifacts_exist: N/A' "secondmate: a persistent home is not a work deliverable"
  pass "fm-gate treats a secondmate home as having no work deliverable"
}

test_tests_pass_is_opt_in_twice() {
  local case_dir
  case_dir=$(make_case tests-optin)
  write_meta "$case_dir"
  commit_real_work "$case_dir"

  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"
  assert_contains "$OUT" 'GATE tests_pass: SKIP' "tests-optin: no declared command means skip"
  assert_contains "$OUT" 'never guesses one' "tests-optin: the gate must not invent a command"

  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md" \
    "tests_command=test -f bin/real.sh"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"
  expect_code 0 "$RC" "tests-declared-not-run"
  assert_contains "$OUT" 'GATE tests_pass: SKIP' "tests-declared: a declared command is not run by default"
  assert_contains "$OUT" 'pass --run-tests to execute it' "tests-declared: the opt-in must be stated"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims" --run-tests
  expect_code 0 "$RC" "tests-run-pass"
  assert_contains "$OUT" 'GATE tests_pass: PASS' "tests-run: a passing declared command passes the gate"

  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md" \
    "tests_command=printf 'boom\\n'; exit 7"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims" --run-tests
  expect_code 1 "$RC" "tests-run-fail"
  assert_contains "$OUT" 'GATE tests_pass: FAIL' "tests-run-fail: a failing declared command fails the gate"
  assert_contains "$OUT" 'exited 7' "tests-run-fail: the exit status must be reported"
  assert_contains "$OUT" 'boom' "tests-run-fail: the command output must be shown"
  pass "fm-gate runs a declared test command only under --run-tests and reports its real result"
}

test_malformed_claim_record_is_refused() {
  local case_dir
  case_dir=$(make_case bad-claims)
  write_meta "$case_dir"
  commit_real_work "$case_dir"

  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_touched=bin/real.sh"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"
  expect_code 2 "$RC" "bad-key"
  assert_contains "$OUT" 'unknown claim record key: files_touched' "bad-key: an unhonored field must be refused, not ignored"

  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=maybe" \
    "files_changed_exhaustive=1"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"
  expect_code 2 "$RC" "bad-confidence"
  assert_contains "$OUT" 'claim_confidence must be declared or derived' "bad-confidence: the contract must be stated"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/absent-file"
  expect_code 2 "$RC" "missing-claims-file"
  assert_contains "$OUT" 'claims file not found' "missing-claims-file: must refuse rather than fall back silently"
  pass "fm-gate refuses a malformed or missing claim record instead of guessing"
}

test_envelope_is_an_exhaustive_declared_claim_source() {
  local case_dir
  case_dir=$(make_case envelope-honest)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md"]' 4 4)"

  run_gate "$case_dir" "$TASK_ID"

  expect_code 0 "$RC" "envelope-honest"
  assert_contains "$OUT" 'GATE envelope_valid: PASS' "envelope-honest: a contract-satisfying envelope passes"
  assert_contains "$OUT" 'claims: source=envelope confidence=declared files=2 exhaustive=yes' \
    "envelope-honest: the envelope is a declared, exhaustive claim source"
  assert_contains "$OUT" 'GATE diff_matches_claims: PASS' "envelope-honest: the diff matches"
  assert_contains "$OUT" 'verdict: PASS' "envelope-honest: overall verdict"
  pass "fm-gate reads the typed envelope as a declared exhaustive claim source"
}

# The load-bearing case: exhaustive means an omission is a lie, not a rounding
# error. A worker that quietly touched a file it did not declare must be caught.
test_envelope_catches_undeclared_and_false_changes() {
  local case_dir
  case_dir=$(make_case envelope-dishonest)
  write_meta "$case_dir"
  commit_real_work "$case_dir"

  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh"]')"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-hides-a-touch"
  assert_contains "$OUT" 'GATE diff_matches_claims: FAIL' "envelope-hides-a-touch: an undeclared change must fail"
  assert_contains "$OUT" 'touched but unclaimed:' "envelope-hides-a-touch: the omission must be named"
  assert_contains "$OUT" 'docs/added.md' "envelope-hides-a-touch: the exact file must be named"
  assert_not_contains "$OUT" 'note only' "envelope-hides-a-touch: an exhaustive source must not downgrade this to a note"

  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md","bin/never-written.sh"]')"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-claims-work-never-done"
  assert_contains "$OUT" 'claimed but untouched:' "envelope-claims-work-never-done: the false claim must fail"
  assert_contains "$OUT" 'bin/never-written.sh' "envelope-claims-work-never-done: the exact file must be named"

  write_envelope "$case_dir" "$(envelope_json '[]')"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-empty-with-changes"
  assert_contains "$OUT" 'GATE diff_matches_claims: FAIL' "envelope-empty-with-changes: empty exhaustive claims must fail on a non-empty diff"
  assert_contains "$OUT" 'touched but unclaimed:' "envelope-empty-with-changes: the omission must be named"
  assert_contains "$OUT" 'bin/real.sh' "envelope-empty-with-changes: the changed file must be named"
  pass "fm-gate catches an envelope that hides a change or claims work never done"
}

# Back-compat is the whole reason the envelope is optional: a task that never
# writes one must produce the same verdict, exit status, and claim source it did
# before envelopes existed.
test_absent_envelope_changes_nothing() {
  local case_dir out_without out_with
  case_dir=$(make_case envelope-absent)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_status "$case_dir" "done: rewrote bin/real.sh"

  run_gate "$case_dir" "$TASK_ID"
  expect_code 0 "$RC" "envelope-absent"
  out_without=$OUT
  assert_contains "$OUT" 'GATE envelope_valid: N/A' "envelope-absent: an absent envelope is not applicable"
  assert_contains "$OUT" 'the typed terminal envelope is optional' "envelope-absent: the reason must say so"
  assert_contains "$OUT" 'claims: source=status confidence=derived' \
    "envelope-absent: claim resolution must fall through to status prose exactly as before"
  assert_contains "$OUT" 'verdict: PASS' "envelope-absent: the verdict must be unaffected"

  # Everything except the envelope_valid line must be byte-identical to a run
  # made with the gate's envelope handling given nothing to do.
  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md"]')"
  run_gate "$case_dir" "$TASK_ID"
  out_with=$OUT
  [ "$out_without" != "$out_with" ] \
    || fail "envelope-absent: writing an envelope changed nothing, so this test proves nothing"
  pass "fm-gate treats an absent envelope as not applicable and behaves exactly as before"
}

# A present envelope that does not parse is a different thing from an absent
# one. It is reported, it does not become a claim source, and resolution still
# falls through so the rest of the report stays useful.
test_broken_envelope_fails_and_falls_through() {
  local case_dir
  case_dir=$(make_case envelope-broken)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_status "$case_dir" "done: rewrote bin/real.sh"

  write_envelope "$case_dir" '{"files_changed": ['
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-unparseable"
  assert_contains "$OUT" 'GATE envelope_valid: FAIL' "envelope-unparseable: broken JSON must fail the gate"
  assert_contains "$OUT" 'not valid JSON' "envelope-unparseable: the reason must name the parse failure"
  assert_contains "$OUT" 'claims: source=status confidence=derived' \
    "envelope-unparseable: a broken envelope must not be used as a claim source"
  assert_contains "$OUT" 'GATE diff_matches_claims: PASS' \
    "envelope-unparseable: resolution must fall through so the rest of the report survives"

  write_envelope "$case_dir" '{"files_changed":[],"tests_run":0,"tests_passed":0,"claims":[],"acceptance_criteria_met":[],"open_questions":[],"notes":"extra"}'
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-unknown-key"
  assert_contains "$OUT" 'unknown key(s): notes' \
    "envelope-unknown-key: a field no consumer honors must be refused, not silently dropped"

  write_envelope "$case_dir" '{"files_changed":[],"tests_run":0,"tests_passed":0,"claims":[]}'
  run_gate "$case_dir" "$TASK_ID"
  assert_contains "$OUT" 'missing required key(s): acceptance_criteria_met, open_questions' \
    "envelope-missing-keys: every missing key must be named"

  write_envelope "$case_dir" '{"files_changed":["/etc/passwd"],"tests_run":0,"tests_passed":0,"claims":[],"acceptance_criteria_met":[],"open_questions":[]}'
  run_gate "$case_dir" "$TASK_ID"
  assert_contains "$OUT" 'files_changed must hold plain repo-relative paths' \
    "envelope-absolute-path: an absolute path is not a repo-relative claim"

  chmod 000 "$case_dir/data/$TASK_ID/envelope.json"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 3 "$RC" "envelope-unreadable"
  assert_contains "$OUT" 'GATE envelope_valid: CANNOT-RUN' "envelope-unreadable: an unreadable envelope cannot be checked"
  assert_contains "$OUT" 'not a readable file' "envelope-unreadable: the reason must identify the read failure"
  pass "fm-gate reports a present-but-invalid envelope instead of ignoring or trusting it"
}

# Self-reported counts cannot substitute for running anything, so a consistent
# pair is explicitly UNVERIFIED rather than a pass. A pair that contradicts
# itself is still a claim, and it fails.
test_envelope_test_counts_are_checked_not_trusted() {
  local case_dir
  case_dir=$(make_case envelope-counts)
  write_meta "$case_dir"
  commit_real_work "$case_dir"

  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md"]' 12 12)"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 0 "$RC" "envelope-counts-consistent"
  assert_contains "$OUT" 'GATE tests_pass: SKIP' "envelope-counts-consistent: counts alone never pass the gate"
  assert_contains "$OUT" 'reports 12 of 12 tests passing' "envelope-counts-consistent: the claim must be shown"
  assert_contains "$OUT" 'unverified' "envelope-counts-consistent: an unverified claim must say so"

  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md"]' 9 7)"
  run_gate "$case_dir" "$TASK_ID"
  expect_code 1 "$RC" "envelope-counts-shortfall"
  assert_contains "$OUT" 'GATE tests_pass: FAIL' "envelope-counts-shortfall: a declared shortfall must fail"
  assert_contains "$OUT" 'only 7 of 9 tests passing' "envelope-counts-shortfall: the shortfall must be quantified"

  write_envelope "$case_dir" "$(envelope_json '["bin/real.sh","docs/added.md"]' 2 5)"
  run_gate "$case_dir" "$TASK_ID"
  assert_contains "$OUT" 'GATE envelope_valid: FAIL' "envelope-counts-impossible: passing more than were run is malformed"
  assert_contains "$OUT" 'exceeds tests_run' "envelope-counts-impossible: the contradiction must be named"
  pass "fm-gate checks self-reported test counts for consistency and never treats them as verification"
}

# Precedence: an explicit --claims record is the caller speaking directly and
# outranks whatever the worker left behind.
test_explicit_claims_outrank_the_envelope() {
  local case_dir
  case_dir=$(make_case envelope-precedence)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_envelope "$case_dir" "$(envelope_json '["bin/never-written.sh"]')"
  write_claims "$case_dir/claims" \
    "claim_source=explicit" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md"

  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims"

  expect_code 0 "$RC" "envelope-precedence"
  assert_contains "$OUT" 'claims: source=explicit' "envelope-precedence: --claims must win over the envelope"
  assert_contains "$OUT" 'GATE envelope_valid: PASS' "envelope-precedence: the envelope is still reported on"
  pass "fm-gate lets an explicit claim record outrank the envelope while still reporting it"
}

test_gate_run_mutates_nothing() {
  local case_dir before after
  case_dir=$(make_case read-only)
  write_meta "$case_dir"
  commit_real_work "$case_dir"
  write_status "$case_dir" "done: rewrote bin/real.sh and added bin/never-written.sh"
  write_claims "$case_dir/claims" \
    "claim_source=envelope-stub" \
    "claim_confidence=declared" \
    "files_changed_exhaustive=1" \
    "files_changed=bin/real.sh" \
    "files_changed=docs/added.md" \
    "tests_command=printf 'ran\\n'"

  before=$(repo_fingerprint "$case_dir")
  run_gate "$case_dir" "$TASK_ID"
  run_gate "$case_dir" "$TASK_ID" --claims "$case_dir/claims" --run-tests
  after=$(repo_fingerprint "$case_dir")

  [ "$before" = "$after" ] || fail "read-only: fm-gate changed repository state"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  pass "fm-gate leaves refs, HEAD, and the working tree untouched"
}

test_honest_exhaustive_claims_pass
test_false_claim_is_caught
test_exhaustive_source_fails_on_unclaimed_touch
test_non_exhaustive_source_notes_unclaimed_touch
test_status_prose_claims_catch_a_false_claim
test_status_prose_ignores_obstacle_lines_and_unanchored_tokens
test_status_keyed_verbs_are_read
test_status_root_token_needs_a_real_anchor
test_no_claims_reports_inconclusive_not_pass
test_missing_metadata_cannot_run
test_returned_worktree_cannot_run
test_scout_report_artifacts
test_ship_without_commits_fails_artifacts
test_secondmate_artifacts_not_applicable
test_tests_pass_is_opt_in_twice
test_malformed_claim_record_is_refused
test_envelope_is_an_exhaustive_declared_claim_source
test_envelope_catches_undeclared_and_false_changes
test_absent_envelope_changes_nothing
test_broken_envelope_fails_and_falls_through
test_envelope_test_counts_are_checked_not_trusted
test_explicit_claims_outrank_the_envelope
test_gate_run_mutates_nothing
