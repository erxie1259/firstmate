#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-pointers.
#
# The pointer index is the one migration step that writes at fleet scale, so
# what it must never do is accumulate: a second run has to leave the store the
# size the first one did. Every test drives the real script, and every write
# goes through a real bin/fm-memory-mcp against a scratch data dir under this
# test's own temp root. fm_pointers_assert_scratch enforces that on every
# invocation: nothing here ever names or opens the operator's live store.
#
# Deriving the pointer set needs only the standard library, so the plan and
# routing tests always run. The write tests need the mnemosyne library and skip
# cleanly where it is absent, which is every CI runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-pointers)
POINTERS="$ROOT/bin/fm-memory-pointers"
MCP="$ROOT/bin/fm-memory-mcp"

# --- helpers -----------------------------------------------------------------

fm_pointers_assert_scratch() {
  case "$1" in
    "$TMP_ROOT"/*) ;;
    *) fail "refusing to run against a path outside the test temp root: $1" ;;
  esac
}

# A firstmate home with the three canonical files the index reads.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  fm_pointers_assert_scratch "$home"
  mkdir -p "$home/data"
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

## Standing decisions

- **Autonomy**: every registered project is +yolo. Set 2026-07-29.

## Chat is for outcomes only (2026-08-13, captain-decided)

Never send routine acknowledgements. Batch non-urgent updates into the next reply.
MD
  cat > "$home/data/learnings.md" <<'MD'
# Learnings

## 2026-07-30 - never recover an opencode crewmate with `--continue`

It replays the whole transcript and the worker starts over.

## 2026-08-06 - a stale pyenv rehash lock makes every new shell hang

Sixty seconds per shell, which breaks spawns.
MD
  cat > "$home/data/projects.md" <<'MD'
# Projects

- flags [no-mistakes +yolo lane:products] - Flutter flags app (added 2026-07-29)
- firstmate [no-mistakes +yolo lane:fleet-infra] - the fleet orchestrator itself (added 2026-08-18)
MD
  printf '%s' "$home"
}

# A data dir with every lane the fixture home routes to, provisioned for real.
make_lanes() {  # <name> <lane>...
  local dir="$TMP_ROOT/$1" lane
  shift
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir"
  for lane in "$@"; do
    FM_HOME="$TMP_ROOT/no-such-home" "$MCP" provision --lane "$lane" --data-dir "$dir" >/dev/null \
      || fail "could not provision lane $lane for the fixture"
  done
  printf '%s' "$dir"
}

fm_pointers() {  # <home> <data-dir> <args>...
  local home=$1 data_dir=$2
  shift 2
  fm_pointers_assert_scratch "$home"
  fm_pointers_assert_scratch "$data_dir"
  "$POINTERS" "$@" --home "$home" --data-dir "$data_dir" 2>&1
}

json_field() {  # <json> <python-expression over `d`>
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

# Every working memory in a lane bank, read directly, so a test can prove what
# the run actually left behind rather than what it reported.
lane_rows() {  # <data-dir> <lane>
  fm_pointers_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM working_memory").fetchone()[0])
PY
}

live_pointer_rows() {  # <data-dir> <lane>
  fm_pointers_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
rows = conn.execute(
    "SELECT count(*) FROM working_memory WHERE superseded_by IS NULL"
    " AND source = 'firstmate-pointers'").fetchone()[0]
print(rows)
PY
}

library_available() {
  python3 - <<'PY' >/dev/null 2>&1
import importlib.util, sys
sys.exit(0 if importlib.util.find_spec("mnemosyne") else 1)
PY
}

skip_without_library() {  # <what>
  if library_available; then
    return 1
  fi
  echo "note: mnemosyne not importable under $(command -v python3); skipping $1" >&2
  pass "fm-memory-pointers: mnemosyne not installed, skipping $1"
  return 0
}

# --- deriving the pointer set ------------------------------------------------

test_plan_routes_every_source_to_its_lane() {
  local home out
  home=$(make_home plan-home)
  out=$("$POINTERS" plan --home "$home") || fail "planning failed: $out"
  [ "$(json_field "$out" "d['total']")" = "6" ] || fail "the plan did not derive one pointer per section: $out"
  [ "$(json_field "$out" "d['problems']")" = "[]" ] || fail "a complete home still reported problems: $out"

  # captain.md is fleet-wide preference, so it lands in shared on the lane-wide
  # channel; learnings are fleet machinery; a project rides its own lane and is
  # scoped to itself by channel.
  [ "$(json_field "$out" "d['lanes']")" \
    = "{'fleet-infra': 3, 'products': 1, 'shared': 2}" ] || fail "pointers were not routed by lane: $out"
  [ "$(json_field "$out" "sorted({p['channel_id'] for p in d['pointers'] if p['lane']=='shared'})")" \
    = "['_lane']" ] || fail "captain pointers were not written lane-wide: $out"
  [ "$(json_field "$out" "next(p['channel_id'] for p in d['pointers'] if p['lane']=='products')")" \
    = "flags" ] || fail "a project pointer was not scoped to its own project: $out"

  # A pointer references its canonical file; it never becomes a second copy of it.
  [ "$(json_field "$out" "all(p['metadata']['pointer'] for p in d['pointers'])")" = "True" ] \
    || fail "a derived memory was not marked a pointer: $out"
  [ "$(json_field "$out" "all(p['metadata']['canonical_file'] in p['content'] for p in d['pointers'])")" = "True" ] \
    || fail "a pointer does not name the file that owns its fact: $out"
  [ "$(json_field "$out" "all(p['metadata']['canonical_line'] > 0 for p in d['pointers'])")" = "True" ] \
    || fail "a pointer does not name the line it came from: $out"
  pass "fm-memory-pointers: every canonical section becomes one pointer, routed to its own lane"
}

test_plan_classifies_decisions_apart_from_preferences_and_learnings() {
  local home out
  home=$(make_home classify-home)
  out=$("$POINTERS" plan --home "$home") || fail "planning failed: $out"
  # Recall ranks on importance and veracity, so the classes have to differ.
  [ "$(json_field "$out" "next(p['memory_type'] for p in d['pointers'] if 'captain-decided' in p['metadata']['canonical_anchor'])")" \
    = "decision" ] || fail "a captain-decided section was not classified a decision: $out"
  [ "$(json_field "$out" "next(p['importance'] for p in d['pointers'] if 'captain-decided' in p['metadata']['canonical_anchor'])")" \
    = "0.9" ] || fail "a captain decision did not carry decision importance: $out"
  [ "$(json_field "$out" "next(p['memory_type'] for p in d['pointers'] if p['metadata']['canonical_anchor']=='Standing decisions')")" \
    = "preference" ] || fail "an unmarked captain section was not classified a preference: $out"
  [ "$(json_field "$out" "sorted({p['memory_type'] for p in d['pointers'] if p['lane']=='fleet-infra'})")" \
    = "['context', 'learning']" ] || fail "fleet-infra pointers were not classified: $out"
  # Project pointers sit at the cross-lane awareness floor on purpose: every
  # lane should see which projects exist elsewhere, by title alone.
  [ "$(json_field "$out" "next(p['importance'] for p in d['pointers'] if p['channel_id']=='flags')")" \
    = "0.7" ] || fail "a project pointer is not at the awareness threshold: $out"
  pass "fm-memory-pointers: pointers carry the importance, veracity, and type their class calls for"
}

test_plan_refuses_to_guess_a_lane_for_an_unrouted_project() {
  local home out status
  home=$(make_home unrouted-home)
  cat >> "$home/data/projects.md" <<'MD'
- strayproj [no-mistakes] - registered but never assigned a lane (added 2026-08-20)
MD
  status=0
  out=$("$POINTERS" plan --home "$home") || status=$?
  [ "$status" -eq 1 ] || fail "an unrouted project did not make the plan fail: exit $status"
  assert_contains "$out" "strayproj carries no lane" "the unrouted project was not named: $out"
  [ "$(json_field "$out" "sum(1 for p in d['pointers'] if p['channel_id']=='strayproj')")" = "0" ] \
    || fail "an unrouted project was written to a guessed lane: $out"
  # The projects that ARE routed still plan, so one gap does not stall the index.
  [ "$(json_field "$out" "sum(1 for p in d['pointers'] if p['channel_id']=='flags')")" = "1" ] \
    || fail "one unrouted project suppressed the routed ones: $out"
  pass "fm-memory-pointers: an unrouted project is reported and skipped, never guessed into a lane"
}

test_plan_reports_an_absent_canonical_file_rather_than_inventing_one() {
  local home out status
  home=$(make_home absent-home)
  rm "$home/data/learnings.md"
  status=0
  out=$("$POINTERS" plan --home "$home") || status=$?
  [ "$status" -eq 1 ] || fail "an absent canonical file did not make the plan fail: exit $status"
  assert_contains "$out" "data/learnings.md is absent" "the absent file was not named: $out"
  pass "fm-memory-pointers: an absent canonical file is reported, not silently indexed as empty"
}

# --- writing through the bridge ----------------------------------------------

test_write_is_idempotent_across_runs() {
  local home dir first second rows_after_first rows_after_second
  skip_without_library "the pointer write test" && return
  home=$(make_home write-home)
  dir=$(make_lanes write-dir shared fleet-infra products)

  first=$(fm_pointers "$home" "$dir" write) || fail "the first pointer run failed: $first"
  [ "$(json_field "$first" "d['counts']['written']")" = "6" ] \
    || fail "the first run did not write every pointer: $first"
  [ "$(json_field "$first" "d['counts']['skipped_duplicate']")" = "0" ] \
    || fail "the first run skipped a pointer that was not there: $first"
  [ "$(json_field "$first" "d['counts']['refused']")" = "0" ] || fail "the first run was refused: $first"
  rows_after_first="$(lane_rows "$dir" shared)|$(lane_rows "$dir" fleet-infra)|$(lane_rows "$dir" products)"

  second=$(fm_pointers "$home" "$dir" write) || fail "the second pointer run failed: $second"
  [ "$(json_field "$second" "d['counts']['written']")" = "0" ] \
    || fail "re-running wrote pointers that were already there: $second"
  [ "$(json_field "$second" "d['counts']['skipped_duplicate']")" = "6" ] \
    || fail "re-running did not recognize every pointer as already written: $second"
  [ "$(json_field "$second" "d['counts']['refused']")" = "0" ] || fail "the second run was refused: $second"
  rows_after_second="$(lane_rows "$dir" shared)|$(lane_rows "$dir" fleet-infra)|$(lane_rows "$dir" products)"
  # The counts are a claim; the row counts are the fact.
  [ "$rows_after_first" = "$rows_after_second" ] \
    || fail "a second run changed the store: $rows_after_first -> $rows_after_second"
  pass "fm-memory-pointers: running the index twice leaves the store exactly as the first run did"
}

test_write_lands_pointers_in_their_own_lane_and_project() {
  local home dir out row
  skip_without_library "the pointer routing test" && return
  home=$(make_home routing-home)
  dir=$(make_lanes routing-dir shared fleet-infra products)
  out=$(fm_pointers "$home" "$dir" write) || fail "the pointer run failed: $out"

  # A project pointer is scoped to its own project inside its own lane, and
  # every pointer is durable: global scope and pinned against the 24h trim.
  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute(
    "SELECT channel_id, scope, veracity, memory_type, consolidated_at IS NOT NULL"
    " FROM working_memory WHERE source = 'firstmate-pointers'").fetchone()
print("|".join(str(x) for x in r))
PY
)
  [ "$row" = "flags|global|stated|context|1" ] || fail "a project pointer did not land as written: $row"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] || fail "the captain pointers did not land in shared"
  [ "$(live_pointer_rows "$dir" fleet-infra)" = "3" ] \
    || fail "the learnings and fleet project pointers did not land in fleet-infra"
  # Physical isolation: a captain preference is not readable from another lane's bank.
  [ "$(live_pointer_rows "$dir" products)" = "1" ] \
    || fail "a pointer leaked into the products bank: $(live_pointer_rows "$dir" products)"
  pass "fm-memory-pointers: each pointer lands in its own lane bank, scoped, global, and pinned"
}

test_an_edited_section_supersedes_its_pointer_instead_of_adding_a_second() {
  local home dir out live superseded
  skip_without_library "the pointer drift test" && return
  home=$(make_home drift-home)
  dir=$(make_lanes drift-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # The canonical file is the source of truth, so editing it must not leave two
  # live pointers claiming different things about the same section.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().replace(
    "Never send routine acknowledgements.",
    "Never send routine acknowledgements, and never say shipshape.")
open(p, "w").write(text)
PY
  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the edit failed: $out"
  [ "$(json_field "$out" "d['counts']['updated']")" = "1" ] \
    || fail "the edited section was not written as a supersession: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "0" ] \
    || fail "the edited section was written as a second pointer: $out"

  live=$(python3 - "$dir/banks/lane-shared/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT count(*) FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NULL AND content LIKE '%Chat is for outcomes only%'").fetchone()[0])
PY
)
  [ "$live" = "1" ] || fail "an edited section left $live live pointers, not one"
  superseded=$(python3 - "$dir/banks/lane-shared/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT count(*) FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NOT NULL").fetchone()[0])
PY
)
  [ "$superseded" = "1" ] || fail "the stale pointer was not kept as superseded history: $superseded"
  # And the live one carries the new text, not the old.
  assert_contains "$(python3 - "$dir/banks/lane-shared/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT content FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NULL AND content LIKE '%Chat is for outcomes only%'").fetchone()[0])
PY
)" "never say shipshape" "the surviving pointer does not carry the edited text"
  pass "fm-memory-pointers: an edited canonical section supersedes its pointer rather than duplicating it"
}

test_a_shifted_section_supersedes_its_pointer_instead_of_adding_a_second() {
  local home dir out live superseded
  skip_without_library "the shifted-section drift test" && return
  home=$(make_home shift-home)
  dir=$(make_lanes shift-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # A pointer names the line its fact lives on, so inserting a section above it
  # changes what the pointer says even though the section itself is untouched.
  # That has to supersede exactly as an edit does: otherwise every section below
  # any insertion accumulates a second live pointer on every run.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
head, rest = text.split("## Standing decisions", 1)
open(p, "w").write(
    head + "## Ship on green only (2026-08-19, captain-decided)\n\n"
    "Never merge on a red pipeline.\n\n## Standing decisions" + rest)
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the insertion failed: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "1" ] \
    || fail "the insertion wrote more than the one genuinely new pointer: $out"
  [ "$(json_field "$out" "d['counts']['updated']")" = "2" ] \
    || fail "the shifted sections were not written as supersessions: $out"
  live=$(live_pointer_rows "$dir" shared)
  [ "$live" = "3" ] || fail "an insertion left $live live captain pointers, not three"
  superseded=$(python3 - "$dir/banks/lane-shared/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT count(*) FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NOT NULL").fetchone()[0])
PY
)
  [ "$superseded" = "2" ] || fail "the shifted pointers were not retired as history: $superseded"
  pass "fm-memory-pointers: a section moved by an insertion supersedes its pointer, never duplicates it"
}

test_a_lost_ledger_costs_a_duplicate_pointer_not_a_wrong_answer() {
  local home dir out live
  skip_without_library "the lost-ledger test" && return
  home=$(make_home ledger-home)
  dir=$(make_lanes ledger-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # The ledger is derived state, never authoritative. Losing it must degrade to
  # the store's own dedupe, not to a wrong or refused answer.
  rm "$dir/banks/lane-shared/fm-memory-pointers.json"
  out=$(fm_pointers "$home" "$dir" write) || fail "the run after losing the ledger failed: $out"
  [ "$(json_field "$out" "d['counts']['refused']")" = "0" ] \
    || fail "losing the ledger caused a refusal: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "0" ] \
    || fail "losing the ledger wrote duplicate pointers: $out"
  live=$(live_pointer_rows "$dir" shared)
  [ "$live" = "2" ] || fail "losing the ledger changed the shared lane: $live live pointers"
  pass "fm-memory-pointers: a lost ledger falls back to the store's own dedupe, changing nothing"
}

test_write_refuses_an_unprovisioned_lane_rather_than_creating_one() {
  local home dir out status
  skip_without_library "the unprovisioned-lane test" && return
  home=$(make_home unprovisioned-home)
  # products is deliberately missing: an auto-created empty bank is exactly the
  # silent-empty-store failure the bridge's preflight exists to prevent.
  dir=$(make_lanes unprovisioned-dir shared fleet-infra)
  status=0
  out=$(fm_pointers "$home" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "writing into an unprovisioned lane exited $status, not 1"
  assert_contains "$out" "bank_missing" "the unprovisioned lane was not named as the blocker: $out"
  [ ! -f "$dir/banks/lane-products/mnemosyne.db" ] \
    || fail "the run created a bank for an unprovisioned lane"
  # The lanes that WERE provisioned still landed, so one missing bank does not
  # cost the whole index.
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] || fail "a missing lane suppressed the healthy ones"
  pass "fm-memory-pointers: an unprovisioned lane is refused and reported, never auto-created"
}

test_plan_routes_every_source_to_its_lane
test_plan_classifies_decisions_apart_from_preferences_and_learnings
test_plan_refuses_to_guess_a_lane_for_an_unrouted_project
test_plan_reports_an_absent_canonical_file_rather_than_inventing_one
test_write_is_idempotent_across_runs
test_write_lands_pointers_in_their_own_lane_and_project
test_an_edited_section_supersedes_its_pointer_instead_of_adding_a_second
test_a_shifted_section_supersedes_its_pointer_instead_of_adding_a_second
test_a_lost_ledger_costs_a_duplicate_pointer_not_a_wrong_answer
test_write_refuses_an_unprovisioned_lane_rather_than_creating_one
echo "# all fm-memory-pointers tests passed"
