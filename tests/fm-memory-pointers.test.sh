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
    " AND valid_until IS NULL AND source = 'firstmate-pointers'").fetchone()[0]
print(rows)
PY
}

live_rows_claiming() {  # <data-dir> <lane> <text>
  fm_pointers_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" "$3" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT count(*) FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NULL AND valid_until IS NULL AND content LIKE ?",
    ("%" + sys.argv[2] + "%",)).fetchone()[0])
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

test_a_moved_section_is_absorbed_and_reverting_the_move_round_trips() {
  local home dir out live
  skip_without_library "the moved-section round-trip test" && return
  home=$(make_home shift-home)
  dir=$(make_lanes shift-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # A section that only MOVED still says the same thing, so its pointer must be
  # left exactly as it is. Rewriting it would retire the row, and the store
  # refuses to write text a retired row already holds - so undoing the edit
  # that moved it could never be indexed again.
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
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a section that merely moved was rewritten: $out"
  [ "$(json_field "$out" "d['counts']['refused']")" = "0" ] || fail "the insertion was refused: $out"
  live=$(live_pointer_rows "$dir" shared)
  [ "$live" = "3" ] || fail "an insertion left $live live captain pointers, not three"

  # Now undo it. The derived text returns to what run one stored, which is the
  # case that used to be refused forever once the row had been retired.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace(
    "## Ship on green only (2026-08-19, captain-decided)\n\n"
    "Never merge on a red pipeline.\n\n", ""))
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after reverting the insertion failed: $out"
  [ "$(json_field "$out" "d['counts']['refused']")" = "0" ] \
    || fail "reverting the insertion was refused: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "0" ] \
    || fail "reverting the insertion wrote a duplicate pointer: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the pointer to the section that went away was not retired: $out"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "reverting left $(live_pointer_rows "$dir" shared) live captain pointers, not two"
  [ "$(live_rows_claiming "$dir" shared "Ship on green only")" = "0" ] \
    || fail "a pointer still claims a section that was removed"
  pass "fm-memory-pointers: a moved section is left alone, and undoing the move round-trips"
}

test_a_renamed_section_retires_the_pointer_that_named_the_old_heading() {
  local home dir out
  skip_without_library "the renamed-section test" && return
  home=$(make_home rename-home)
  dir=$(make_lanes rename-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # The heading is what a pointer tells the reader to look for, so a renamed
  # section must not leave a live pointer sending them to a heading the file no
  # longer has.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace(
    "## Chat is for outcomes only (2026-08-13, captain-decided)",
    "## Chat carries outcomes only (2026-08-13, captain-decided)"))
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the rename failed: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "1" ] \
    || fail "the renamed section did not get its own pointer: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the pointer naming the old heading was not retired: $out"
  [ "$(json_field "$out" "d['counts']['refused'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "the rename was refused: $out"
  [ "$(live_rows_claiming "$dir" shared "Chat is for outcomes only")" = "0" ] \
    || fail "a live pointer still names the heading the rename removed"
  [ "$(live_rows_claiming "$dir" shared "Chat carries outcomes only")" = "1" ] \
    || fail "the renamed section does not have exactly one live pointer"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "the rename changed how many captain pointers are live"
  pass "fm-memory-pointers: a renamed section retires the pointer that named the old heading"
}

test_a_deleted_section_leaves_no_live_pointer_claiming_it() {
  local home dir out
  skip_without_library "the deleted-section test" && return
  home=$(make_home delete-home)
  dir=$(make_lanes delete-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # A withdrawn captain decision that recall still returns is the exact failure
  # this index exists to prevent, so a deleted section has to take its pointer
  # with it.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
head, _ = text.split("## Chat is for outcomes only", 1)
open(p, "w").write(head)
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the deletion failed: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the deleted section's pointer was not retired: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "0" ] \
    || fail "the deletion wrote a new pointer: $out"
  [ "$(json_field "$out" "d['counts']['refused'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "the deletion was refused: $out"
  [ "$(live_rows_claiming "$dir" shared "Chat is for outcomes only")" = "0" ] \
    || fail "a live pointer still claims a captain section that was deleted"
  [ "$(live_pointer_rows "$dir" shared)" = "1" ] \
    || fail "the surviving captain section lost its pointer too"
  pass "fm-memory-pointers: a deleted section leaves nothing live still claiming it"
}

test_deleting_the_first_of_two_same_heading_sections_keeps_the_survivor() {
  local home dir out rows
  skip_without_library "the renumbered-repeat test" && return
  home=$(make_home renumber-home)
  dir=$(make_lanes renumber-dir shared fleet-infra products)
  cat >> "$home/data/captain.md" <<'MD'

## Standing decisions

- **Reviews**: never merge on a red pipeline. Set 2026-08-19.
MD
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # Removing the first of two same-heading sections renumbers the survivor onto
  # the key the deleted one held. The survivor must keep a live pointer: the
  # ledger key moving is bookkeeping, not a withdrawal.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
kept, dropping, dropped = [], False, False
for line in open(p).read().splitlines(keepends=True):
    if line.startswith("## "):
        dropping = not dropped and line.strip() == "## Standing decisions"
        dropped = dropped or dropping
    if not dropping:
        kept.append(line)
open(p, "w").write("".join(kept))
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the deletion failed: $out"
  [ "$(json_field "$out" "d['counts']['refused'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "the renumbered repeat was refused: $out"
  [ "$(live_rows_claiming "$dir" shared "never merge on a red pipeline")" = "1" ] \
    || fail "the surviving same-heading section lost its live pointer"
  [ "$(live_rows_claiming "$dir" shared "every registered project is +yolo")" = "0" ] \
    || fail "a live pointer still claims the same-heading section that was deleted"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "the shared lane holds $(live_pointer_rows "$dir" shared) live pointers, not two"

  # And it settles: a further run neither writes, retires, nor refuses anything.
  rows=$(lane_rows "$dir" shared)
  out=$(fm_pointers "$home" "$dir" write) || fail "the settling run failed: $out"
  [ "$(json_field "$out" "d['counts']['written'] + d['counts']['updated'] + d['counts']['expired'] + d['counts']['refused']")" = "0" ] \
    || fail "the renumbered repeat never settles: $out"
  [ "$(lane_rows "$dir" shared)" = "$rows" ] || fail "a settled run still grew the store"
  pass "fm-memory-pointers: deleting the first of two same-heading sections keeps the survivor live"
}

test_re_laning_a_project_retires_the_pointer_in_the_lane_it_left() {
  local home dir out
  skip_without_library "the re-laned project test" && return
  home=$(make_home relane-home)
  dir=$(make_lanes relane-dir shared fleet-infra products personal)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"
  [ "$(live_pointer_rows "$dir" products)" = "1" ] || fail "the project pointer did not land in products"

  # Moving a project to another lane empties its old lane of derived pointers
  # entirely. The old lane must still be reconciled, or its bank keeps
  # answering recalls with a project that now lives somewhere else.
  python3 - "$home/data/projects.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace("lane:products", "lane:personal"))
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the re-lane failed: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the pointer in the lane the project left was not retired: $out"
  [ "$(json_field "$out" "d['counts']['refused'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "the re-lane was refused: $out"
  [ "$(live_pointer_rows "$dir" products)" = "0" ] \
    || fail "the lane the project left still holds a live pointer to it"
  [ "$(live_pointer_rows "$dir" personal)" = "1" ] \
    || fail "the lane the project moved to does not hold exactly one live pointer"
  pass "fm-memory-pointers: re-laning a project retires the pointer in the lane it left"
}

test_removing_a_lanes_last_project_retires_its_pointer() {
  local home dir out
  skip_without_library "the emptied-lane test" && return
  home=$(make_home empty-lane-home)
  dir=$(make_lanes empty-lane-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # Dropping the registry line leaves products deriving nothing at all, which
  # is the case a walk over only the derived lanes never visits again.
  python3 - "$home/data/projects.md" <<'PY'
import sys
p = sys.argv[1]
kept = [line for line in open(p).read().splitlines(keepends=True) if not line.startswith("- flags ")]
open(p, "w").write("".join(kept))
PY

  out=$(fm_pointers "$home" "$dir" write) || fail "the run after the removal failed: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the emptied lane's last pointer was not retired: $out"
  [ "$(json_field "$out" "d['counts']['refused'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "the removal was refused: $out"
  [ "$(live_pointer_rows "$dir" products)" = "0" ] \
    || fail "a live pointer still claims a project that left the registry"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "emptying one lane cost another lane its pointers"
  pass "fm-memory-pointers: removing a lane's last project retires the pointer it left behind"
}

test_an_unreadable_source_spares_only_its_own_keys() {
  local home dir out status
  skip_without_library "the scoped-derivation guard test" && return
  home=$(make_home guard-home)
  dir=$(make_lanes guard-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # data/learnings.md cannot be read, so nothing it owns can be called deleted.
  # data/projects.md reads fine, so dropping a project from it IS a deletion
  # and must still be reconciled: one source coming up short cannot freeze the
  # lanes the other sources feed.
  rm "$home/data/learnings.md"
  python3 - "$home/data/projects.md" <<'PY'
import sys
p = sys.argv[1]
kept = [line for line in open(p).read().splitlines(keepends=True) if not line.startswith("- flags ")]
open(p, "w").write("".join(kept))
PY

  status=0
  out=$(fm_pointers "$home" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "a run with an unreadable canonical file exited $status, not 1"
  [ "$(live_pointer_rows "$dir" fleet-infra)" = "3" ] \
    || fail "the learnings pointers were retired because their file could not be read"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the genuinely deregistered project was not retired: $out"
  [ "$(live_pointer_rows "$dir" products)" = "0" ] \
    || fail "a project dropped from a readable registry kept its live pointer"
  [ "$(json_field "$out" "sorted(l['lane'] for l in d['skipped_reconciliation'])")" \
    = "['fleet-infra']" ] || fail "the run did not report exactly what it left alone: $out"
  [ "$(json_field "$out" "sorted({s.split('#')[0] for l in d['skipped_reconciliation'] for s in l['keys']})")" \
    = "['data/learnings.md']" ] || fail "keys from a healthy source were left alone too: $out"
  pass "fm-memory-pointers: a source that came up short spares its own keys and no others"
}

test_a_lazily_absent_learnings_file_is_not_a_problem() {
  local home dir out
  skip_without_library "the lazy-learnings test" && return
  home=$(make_home lazy-home)
  dir=$(make_lanes lazy-dir shared fleet-infra products)
  # AGENTS.md creates data/learnings.md lazily, so a home that has recorded no
  # learning yet is an ordinary state, not a derivation that came up short.
  : > "$home/data/learnings.md"

  out=$(fm_pointers "$home" "$dir" write) || fail "a home with no learnings yet failed: $out"
  [ "$(json_field "$out" "d['problems']")" = "[]" ] \
    || fail "an empty learnings file with nothing indexed was reported as a problem: $out"
  [ "$(json_field "$out" "d['counts']['expired'] + d['counts']['refused']")" = "0" ] \
    || fail "a home with no learnings retired or refused something: $out"
  [ "$(live_pointer_rows "$dir" fleet-infra)" = "1" ] \
    || fail "the fleet-infra project pointer did not land"
  pass "fm-memory-pointers: a home that has recorded no learning yet runs normally"
}

test_an_emptied_learnings_file_with_pointers_indexed_refuses() {
  local home dir out status
  skip_without_library "the emptied-learnings test" && return
  home=$(make_home emptied-learnings-home)
  dir=$(make_lanes emptied-learnings-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # Once the ledger holds its keys, the same empty file has everything to lose:
  # retiring on it is unrecoverable, so the run refuses instead.
  : > "$home/data/learnings.md"

  status=0
  out=$(fm_pointers "$home" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "an emptied learnings file with pointers indexed exited $status, not 1"
  [ "$(json_field "$out" "d['counts']['expired']")" = "0" ] \
    || fail "an emptied learnings file retired its pointers: $out"
  [ "$(live_pointer_rows "$dir" fleet-infra)" = "3" ] \
    || fail "the learnings pointers were retired on the strength of an empty file"
  [ "$(json_field "$out" "any('learnings.md' in p for p in d['problems'])")" = "True" ] \
    || fail "the emptied learnings file was not reported as a problem: $out"
  pass "fm-memory-pointers: an emptied source whose pointers are indexed is refused"
}

test_an_emptied_canonical_file_retires_nothing_and_refuses() {
  local home dir out status
  skip_without_library "the emptied-canonical-file test" && return
  home=$(make_home emptied-home)
  dir=$(make_lanes emptied-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # Truncated mid-write, emptied by accident, restored from an empty backup:
  # a readable file with nothing in it is indistinguishable from every section
  # having been deleted. Retiring on that reading cannot be undone, because the
  # bridge will not write text a retired row already holds, so the run refuses.
  : > "$home/data/captain.md"

  status=0
  out=$(fm_pointers "$home" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "an emptied canonical file exited $status, not 1"
  [ "$(json_field "$out" "d['counts']['expired']")" = "0" ] \
    || fail "an emptied canonical file retired pointers: $out"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "the shared lane was emptied on the strength of an empty file"
  [ "$(json_field "$out" "any('captain.md' in p for p in d['problems'])")" = "True" ] \
    || fail "the emptied file was not reported as a problem: $out"
  pass "fm-memory-pointers: a canonical file emptied to nothing is refused, never obeyed"
}

test_a_canonical_file_with_no_sections_retires_nothing_and_refuses() {
  local home dir out status
  skip_without_library "the sectionless-canonical-file test" && return
  home=$(make_home sectionless-home)
  dir=$(make_lanes sectionless-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # Present, readable, and full of prose, but restructured out of `## `
  # headings: the derivation is empty for the same reason and costs the same.
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

Everything here was reorganised and no longer uses second-level headings.
MD

  status=0
  out=$(fm_pointers "$home" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "a canonical file with no sections exited $status, not 1"
  [ "$(json_field "$out" "d['counts']['expired']")" = "0" ] \
    || fail "a file with no sections retired pointers: $out"
  [ "$(live_pointer_rows "$dir" shared)" = "2" ] \
    || fail "the shared lane was emptied by a file that merely lost its headings"
  pass "fm-memory-pointers: a canonical file that derives no sections is refused, never obeyed"
}

test_a_ledger_from_another_home_neither_retires_nor_supersedes() {
  local home other dir out status
  skip_without_library "the mismatched-home test" && return
  home=$(make_home ledger-home-a)
  dir=$(make_lanes ledger-home-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"

  # A second checkout carries the SAME headings with different text, so every
  # ledger key matches and only the digest differs. Chaining onto the first
  # home's rows would retire them exactly as irreversibly as expiring them, so
  # a foreign ledger is written past, never through.
  other=$(make_home ledger-home-b)
  python3 - "$other/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace(
    "Never send routine acknowledgements.",
    "This second checkout says something else entirely about chat."))
PY

  status=0
  out=$(fm_pointers "$other" "$dir" write) || status=$?
  [ "$status" -eq 1 ] || fail "a run that skipped reconciliation reported success: exit $status"
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a run from another home superseded this home's rows: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "0" ] \
    || fail "a run from another home retired this home's pointers: $out"
  [ "$(live_rows_claiming "$dir" shared "Never send routine acknowledgements")" = "1" ] \
    || fail "the first home's pointer was retired by a run from another tree"
  [ "$(json_field "$out" "all('ledger-home-a' in l['reason'] for l in d['skipped_reconciliation'])")" \
    = "True" ] || fail "the report does not name the home the ledger belongs to: $out"

  # And the first home still reconciles normally, so the binding is not a
  # one-way lock on the ledger.
  out=$(fm_pointers "$home" "$dir" write) || fail "the run from the original home failed: $out"
  [ "$(json_field "$out" "'skipped_reconciliation' in d")" = "False" ] \
    || fail "the original home was locked out of its own ledger: $out"
  [ "$(live_rows_claiming "$dir" shared "Never send routine acknowledgements")" = "1" ] \
    || fail "the original home no longer holds exactly one live pointer for its section"

  # The foreign run wrote a row of its own for the same key. If it had also
  # recorded that row in the ledger it does not own, the owning home's next
  # reconciliation would aim at the OTHER home's row: deleting the section here
  # would retire a pointer this run never wrote and leave its own row live,
  # claiming a section that is gone.
  python3 - "$home/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.split("## Chat is for outcomes only")[0])
PY
  out=$(fm_pointers "$home" "$dir" write) || fail "the reconciling run from the original home failed: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "1" ] \
    || fail "the original home did not retire its own deleted section: $out"
  [ "$(live_rows_claiming "$dir" shared "Never send routine acknowledgements")" = "0" ] \
    || fail "the original home's pointer for a deleted section is still live: $out"
  [ "$(live_rows_claiming "$dir" shared "This second checkout says something else entirely")" = "1" ] \
    || fail "the other home's row was retired by a run that does not own its ledger: $out"
  pass "fm-memory-pointers: a ledger from another home is neither retired from nor superseded through"
}

test_a_run_from_another_home_records_nothing_in_the_ledger_it_does_not_own() {
  local home other dir before after
  skip_without_library "the foreign-ledger record test" && return
  home=$(make_home foreign-record-home-a)
  dir=$(make_lanes foreign-record-dir shared fleet-infra products)
  fm_pointers "$home" "$dir" write >/dev/null || fail "the first pointer run failed"
  before=$(cat "$dir/banks/lane-shared/fm-memory-pointers.json")

  other=$(make_home foreign-record-home-b)
  python3 - "$other/data/captain.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace(
    "Never send routine acknowledgements.",
    "A foreign checkout with its own text for the same heading."))
PY
  fm_pointers "$other" "$dir" write >/dev/null

  after=$(cat "$dir/banks/lane-shared/fm-memory-pointers.json")
  [ "$before" = "$after" ] \
    || fail "a run from another tree rewrote a ledger it does not own"
  pass "fm-memory-pointers: a run from another tree leaves the ledger it does not own byte-identical"
}

test_a_bridge_that_will_not_start_at_all_costs_its_lanes_not_the_run() {
  local home dir out
  home=$(make_home no-bridge-home)
  dir="$TMP_ROOT/no-bridge-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir"

  # An interpreter that is not there fails in the spawn itself, which raises an
  # OSError rather than the tool's own typed error. That still costs the lanes
  # their pointers and nothing more: a run that lets it escape loses the counts
  # for every pointer, so nothing can say how much of the fleet landed.
  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$TMP_ROOT/no-such-python" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, interpreter, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sys.executable = interpreter

pointers = mod.derive(Path(home)).pointers
result = mod.write_pointers(Path(home), Path(data_dir), pointers)
print(json.dumps({"total": len(pointers), **result}))
PY
) || fail "a bridge that could not be spawned crashed the run: $out"

  [ "$(json_field "$out" "d['counts']['refused'] == d['total']")" = "True" ] \
    || fail "the pointers of a lane whose bridge never started were not counted: $out"
  [ "$(json_field "$out" "sorted({r['lane'] for r in d['refusals']})")" \
    = "['fleet-infra', 'products', 'shared']" ] \
    || fail "not every lane was walked and reported: $out"
  [ "$(json_field "$out" "sorted({r['error']['code'] for r in d['refusals']})")" = "['lane_failed']" ] \
    || fail "a spawn failure was not reported as a lane failure: $out"
  pass "fm-memory-pointers: a bridge that cannot even be spawned costs its lanes, never the run"
}

test_a_tool_result_that_is_not_an_object_is_refused_not_crashed() {
  local home dir stub out
  home=$(make_home nonobject-home)
  dir="$TMP_ROOT/nonobject-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir"

  # Valid JSON that is not an object cannot answer "which row did this land
  # on". Reading it as one would raise past the guards that keep a lane's
  # failure from costing the run, so it is refused at the bridge boundary.
  stub="$TMP_ROOT/nonobject-bridge.py"
  cat > "$stub" <<'PY'
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + "\n")
    else:
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "id": request["id"],
            "result": {"content": [{"type": "text", "text": "[\"not\", \"an\", \"object\"]"}]}}) + "\n")
    sys.stdout.flush()
PY

  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$stub" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, stub, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.BRIDGE = Path(stub)

pointers = mod.derive(Path(home)).pointers
result = mod.write_pointers(Path(home), Path(data_dir), pointers)
ledger, _ = mod.read_ledger(Path(data_dir), "shared")
print(json.dumps({"total": len(pointers), "ledger": ledger, **result}))
PY
) || fail "a non-object tool result crashed the run: $out"

  [ "$(json_field "$out" "d['counts']['refused'] == d['total']")" = "True" ] \
    || fail "a non-object tool result did not account for every pointer: $out"
  [ "$(json_field "$out" "d['counts']['written'] + d['counts']['skipped_duplicate']")" = "0" ] \
    || fail "a non-object tool result was counted as a stored row: $out"
  [ "$(json_field "$out" "d['ledger']")" = "{}" ] \
    || fail "a non-object tool result was recorded in the ledger: $out"
  pass "fm-memory-pointers: a tool result that is not an object is refused at the bridge boundary"
}

test_a_ledger_record_that_is_not_an_object_degrades_to_plain_dedupe() {
  local home dir stub out
  home=$(make_home corrupt-record-home)
  dir="$TMP_ROOT/corrupt-record-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir/banks/lane-shared"

  # The ledger beside a bank is this tool's own persisted state, so a test may
  # write one. A record that is not an object remembers nothing readable about
  # the row it claims - neither a memory id to supersede nor one to retire - so
  # it must cost a duplicate pointer at worst. Reading it as a record instead
  # loses every lane's counts, and every rerun fails the same way until the
  # file is repaired by hand.
  cat > "$dir/banks/lane-shared/fm-memory-pointers.json" <<JSON
{
  "home": "$(cd "$home" && pwd -P)",
  "pointers": {
    "data/captain.md#Standing decisions": "not-an-object",
    "data/captain.md#Long gone": ["also", "not", "an", "object"]
  }
}
JSON

  stub="$TMP_ROOT/corrupt-record-bridge.py"
  cat > "$stub" <<'PY'
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + "\n")
    else:
        payload = json.dumps({"id": "row-%s" % request["id"], "created": True})
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "id": request["id"],
            "result": {"content": [{"type": "text", "text": payload}]}}) + "\n")
    sys.stdout.flush()
PY

  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$stub" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, stub, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.BRIDGE = Path(stub)

pointers = mod.derive(Path(home)).pointers
result = mod.write_pointers(Path(home), Path(data_dir), pointers)
ledger, recorded = mod.read_ledger(Path(data_dir), "shared")
print(json.dumps({"total": len(pointers), "ledger": ledger, "home": recorded, **result}))
PY
) || fail "a malformed ledger record crashed the whole run: $out"

  [ "$(json_field "$out" "d['counts']['written'] == d['total']")" = "True" ] \
    || fail "a malformed ledger record cost the run its pointers: $out"
  [ "$(json_field "$out" "d['counts']['expired'] + d['counts']['expiry_refused']")" = "0" ] \
    || fail "a record naming no readable row was treated as retirable: $out"
  [ "$(json_field "$out" "all(isinstance(r, dict) for r in d['ledger'].values())")" = "True" ] \
    || fail "the rewritten ledger still carries a record that is not an object: $out"
  [ "$(json_field "$out" "'data/captain.md#Long gone' in d['ledger']")" = "False" ] \
    || fail "an unreadable record for a section that is gone was kept: $out"
  [ "$(json_field "$out" "'data/captain.md#Standing decisions' in d['ledger']")" = "True" ] \
    || fail "the run did not re-record the section it just wrote: $out"
  pass "fm-memory-pointers: a ledger record that is not an object degrades to plain dedupe"
}

test_two_sections_sharing_a_heading_keep_one_live_pointer_each() {
  local home dir first second rows_first rows_second live superseded
  skip_without_library "the repeated-heading test" && return
  home=$(make_home repeat-home)
  dir=$(make_lanes repeat-dir shared fleet-infra products)
  # Two `## ` sections may carry the same heading. They are two different
  # facts, so each has to own its pointer: sharing a ledger entry makes the
  # second retire the first on every run, and the store grows while one fact
  # is never live.
  cat >> "$home/data/captain.md" <<'MD'

## Standing decisions

- **Reviews**: never merge on a red pipeline. Set 2026-08-19.
MD

  first=$(fm_pointers "$home" "$dir" write) || fail "the first pointer run failed: $first"
  [ "$(json_field "$first" "d['counts']['written']")" = "7" ] \
    || fail "the repeated heading was not written as its own pointer: $first"
  [ "$(json_field "$first" "d['counts']['updated']")" = "0" ] \
    || fail "the repeated heading superseded the section it merely shares a title with: $first"
  live=$(live_pointer_rows "$dir" shared)
  [ "$live" = "3" ] || fail "the shared lane holds $live live pointers, not three"
  rows_first=$(lane_rows "$dir" shared)

  second=$(fm_pointers "$home" "$dir" write) || fail "the second pointer run failed: $second"
  [ "$(json_field "$second" "d['counts']['updated']")" = "0" ] \
    || fail "re-running flipped the repeated headings against each other: $second"
  [ "$(json_field "$second" "d['counts']['written']")" = "0" ] \
    || fail "re-running wrote pointers that were already there: $second"
  rows_second=$(lane_rows "$dir" shared)
  [ "$rows_first" = "$rows_second" ] \
    || fail "a repeated heading grew the store on re-run: $rows_first -> $rows_second"
  [ "$(live_pointer_rows "$dir" shared)" = "3" ] \
    || fail "a re-run retired one of two sections sharing a heading"
  superseded=$(python3 - "$dir/banks/lane-shared/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute(
    "SELECT count(*) FROM working_memory WHERE source='firstmate-pointers'"
    " AND superseded_by IS NOT NULL").fetchone()[0])
PY
)
  [ "$superseded" = "0" ] || fail "sections sharing a heading retired $superseded pointers between them"
  pass "fm-memory-pointers: two sections sharing a heading each keep their own live pointer"
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

test_a_bridge_that_dies_midlane_still_reports_every_lane() {
  local home dir stub out
  home=$(make_home midlane-home)
  dir="$TMP_ROOT/midlane-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir"

  # A stub bridge that answers `initialize`, serves exactly one tool call, and
  # then dies mid-lane. A real bridge can go the same way - killed, out of
  # disk, crashed after startup - and the run has to survive it: the pointers
  # that already landed stay counted, the stranded ones are named, and the
  # remaining lanes are still walked.
  # A pointer written by an earlier run whose section is gone: the expiry half
  # of this lane dies with the same bridge, and it has to be reported rather
  # than left neither retired nor counted.
  mkdir -p "$dir/banks/lane-shared"
  cat > "$dir/banks/lane-shared/fm-memory-pointers.json" <<JSON
{
  "home": "$(cd "$home" && pwd -P)",
  "pointers": {
    "data/captain.md#Withdrawn": {"memory_id": "zzz", "canonical_sha": "9", "canonical_line": 2}
  }
}
JSON

  stub="$TMP_ROOT/midlane-bridge.py"
  cat > "$stub" <<'PY'
import json, sys
served = False
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + "\n")
        sys.stdout.flush()
        continue
    if served:
        sys.exit(0)
    served = True
    payload = json.dumps({"id": "row-%s" % request["id"], "created": True})
    sys.stdout.write(json.dumps({
        "jsonrpc": "2.0", "id": request["id"],
        "result": {"content": [{"type": "text", "text": payload}]}}) + "\n")
    sys.stdout.flush()
PY

  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$stub" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, stub, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.BRIDGE = Path(stub)

derived = mod.derive(Path(home))
pointers, problems = derived.pointers, list(derived.problems)
result = mod.write_pointers(Path(home), Path(data_dir), pointers, derived.troubled, derived.empty)
ledger, _ = mod.read_ledger(Path(data_dir), "shared")
print(json.dumps({"total": len(pointers), "problems": problems, "ledger": ledger, **result}))
PY
) || fail "a bridge dying mid-lane crashed the run: $out"

  # One pointer per lane landed before its bridge died, and all three lanes
  # were walked: a crash on the first lane would report none of this.
  [ "$(json_field "$out" "d['counts']['written']")" = "3" ] \
    || fail "the pointers that landed before the bridge died were not counted: $out"
  [ "$(json_field "$out" "d['counts']['refused']")" = "3" ] \
    || fail "the stranded pointers were not counted as refused: $out"
  [ "$(json_field "$out" "d['counts']['written'] + d['counts']['refused'] == d['total']")" = "True" ] \
    || fail "the run lost track of some pointers entirely: $out"
  [ "$(json_field "$out" "sorted({r['lane'] for r in d['refusals']})")" \
    = "['fleet-infra', 'shared']" ] || fail "the lanes that lost pointers were not named: $out"
  [ "$(json_field "$out" "all(r['keys'] for r in d['refusals'])")" = "True" ] \
    || fail "a refusal did not name the pointers that did not land: $out"
  # The ledger for a lane that failed mid-way still records what DID land, so
  # the next run supersedes those rows rather than duplicating them.
  [ -f "$dir/banks/lane-shared/fm-memory-pointers.json" ] \
    || fail "a lane that failed mid-way lost the ledger for the pointer that landed"
  # The stale pointer it could not retire is counted and named as an expiry
  # refusal, apart from the writes that did not land.
  [ "$(json_field "$out" "d['counts']['expiry_refused']")" = "1" ] \
    || fail "the stale pointer the dead bridge could not retire was not counted: $out"
  [ "$(json_field "$out" "sorted(k for r in d['refusals'] if r['kind'] == 'expiry' for k in r['keys'])")" \
    = "['data/captain.md#Withdrawn']" ] \
    || fail "the stale pointer was not reported apart from the write refusals: $out"
  [ "$(json_field "$out" "'data/captain.md#Withdrawn' in d['ledger']")" = "True" ] \
    || fail "the id needed to retire the stale pointer later was dropped: $out"
  pass "fm-memory-pointers: a bridge dying mid-lane costs its lane, never the run's counts"
}

test_a_success_with_no_memory_id_is_refused_not_recorded() {
  local home dir stub out
  home=$(make_home payload-home)
  dir="$TMP_ROOT/payload-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir"

  # A bridge that calls a write successful but names no row leaves nothing to
  # record: a ledger entry pointing at no memory would send the next run's
  # supersession at a row that does not exist. It has to be a refusal, and it
  # must not cost the run its counts.
  stub="$TMP_ROOT/payload-bridge.py"
  cat > "$stub" <<'PY'
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + "\n")
    else:
        payload = json.dumps({"status": "ok", "store_verified": True, "created": True})
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0", "id": request["id"],
            "result": {"content": [{"type": "text", "text": payload}]}}) + "\n")
    sys.stdout.flush()
PY

  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$stub" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, stub, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.BRIDGE = Path(stub)

pointers = mod.derive(Path(home)).pointers
result = mod.write_pointers(Path(home), Path(data_dir), pointers)
ledger, _ = mod.read_ledger(Path(data_dir), "shared")
print(json.dumps({"total": len(pointers), "ledger": ledger, **result}))
PY
) || fail "a success carrying no memory id crashed the run: $out"

  [ "$(json_field "$out" "d['counts']['refused'] == d['total']")" = "True" ] \
    || fail "a success with no memory id was counted as a write: $out"
  [ "$(json_field "$out" "d['counts']['written'] + d['counts']['skipped_duplicate']")" = "0" ] \
    || fail "a row that was never named was recorded as stored: $out"
  [ "$(json_field "$out" "d['ledger']")" = "{}" ] \
    || fail "the ledger recorded a pointer the bridge never named: $out"
  [ "$(json_field "$out" "sorted({(r.get('error') or {}).get('code') for r in d['refusals']})")" \
    = "['malformed_result']" ] || fail "the refusal did not name the malformed result: $out"
  pass "fm-memory-pointers: a write reported successful with no memory id is refused, not recorded"
}

test_a_bridge_dying_during_reconciliation_counts_each_key_once() {
  local home dir stub out
  home=$(make_home reconcile-fail-home)
  dir="$TMP_ROOT/reconcile-fail-dir"
  fm_pointers_assert_scratch "$dir"
  mkdir -p "$dir/banks/lane-shared"

  # The ledger beside a bank is this tool's own persisted state, so a test can
  # seed one: two pointers written by an earlier run whose sections are gone.
  cat > "$dir/banks/lane-shared/fm-memory-pointers.json" <<JSON
{
  "home": "$(cd "$home" && pwd -P)",
  "pointers": {
    "data/captain.md#Gone one": {"memory_id": "aaa", "canonical_sha": "1", "canonical_line": 3},
    "data/captain.md#Gone two": {"memory_id": "bbb", "canonical_sha": "2", "canonical_line": 9}
  }
}
JSON

  # A bridge that refuses the first expiry and then dies on the second. The
  # refused key is already accounted for, so counting it again as stranded
  # would report more pointers left stale than there are.
  stub="$TMP_ROOT/reconcile-fail-bridge.py"
  cat > "$stub" <<'PY'
import json, sys
seen = 0
for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}) + "\n")
        sys.stdout.flush()
        continue
    seen += 1
    if seen > 1:
        sys.exit(0)
    payload = json.dumps({"status": "error", "error": {"code": "expire_failed", "message": "no"}})
    sys.stdout.write(json.dumps({
        "jsonrpc": "2.0", "id": request["id"],
        "result": {"content": [{"type": "text", "text": payload}], "isError": True}}) + "\n")
    sys.stdout.flush()
PY

  out=$(python3 - "$ROOT/bin/fm-memory-pointers" "$stub" "$home" "$dir" <<'PY'
import importlib.machinery, importlib.util, json, sys
from pathlib import Path

module_path, stub, home, data_dir = sys.argv[1:5]
loader = importlib.machinery.SourceFileLoader("fm_memory_pointers", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.BRIDGE = Path(stub)

result = mod.write_pointers(Path(home), Path(data_dir), [], [])
ledger, _ = mod.read_ledger(Path(data_dir), "shared")
print(json.dumps({"ledger": sorted(ledger), **result}))
PY
) || fail "a bridge dying during reconciliation crashed the run: $out"

  [ "$(json_field "$out" "d['counts']['expiry_refused']")" = "2" ] \
    || fail "the keys left stale were not counted once each: $out"
  [ "$(json_field "$out" "d['counts']['expired']")" = "0" ] \
    || fail "a key that was never retired was counted as expired: $out"
  [ "$(json_field "$out" "len({k for r in d['refusals'] for k in ([r['key']] if 'key' in r else r['keys'])})")" = "2" ] \
    || fail "the refusals do not name exactly the two keys left stale: $out"
  [ "$(json_field "$out" "sum(1 for r in d['refusals'] for k in ([r['key']] if 'key' in r else r['keys']))")" = "2" ] \
    || fail "a key left stale was reported twice: $out"
  # Both ids stay in the ledger: they are the only way to retire those rows later.
  [ "$(json_field "$out" "len(d['ledger'])")" = "2" ] \
    || fail "a key that could not be retired was dropped from the ledger: $out"
  pass "fm-memory-pointers: a bridge dying during reconciliation counts each stale key exactly once"
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
test_a_moved_section_is_absorbed_and_reverting_the_move_round_trips
test_a_renamed_section_retires_the_pointer_that_named_the_old_heading
test_a_deleted_section_leaves_no_live_pointer_claiming_it
test_deleting_the_first_of_two_same_heading_sections_keeps_the_survivor
test_re_laning_a_project_retires_the_pointer_in_the_lane_it_left
test_removing_a_lanes_last_project_retires_its_pointer
test_an_unreadable_source_spares_only_its_own_keys
test_a_lazily_absent_learnings_file_is_not_a_problem
test_an_emptied_learnings_file_with_pointers_indexed_refuses
test_an_emptied_canonical_file_retires_nothing_and_refuses
test_a_canonical_file_with_no_sections_retires_nothing_and_refuses
test_a_ledger_from_another_home_neither_retires_nor_supersedes
test_a_run_from_another_home_records_nothing_in_the_ledger_it_does_not_own
test_a_bridge_that_will_not_start_at_all_costs_its_lanes_not_the_run
test_a_tool_result_that_is_not_an_object_is_refused_not_crashed
test_a_ledger_record_that_is_not_an_object_degrades_to_plain_dedupe
test_two_sections_sharing_a_heading_keep_one_live_pointer_each
test_a_lost_ledger_costs_a_duplicate_pointer_not_a_wrong_answer
test_a_bridge_that_dies_midlane_still_reports_every_lane
test_a_success_with_no_memory_id_is_refused_not_recorded
test_a_bridge_dying_during_reconciliation_counts_each_key_once
test_write_refuses_an_unprovisioned_lane_rather_than_creating_one
echo "# all fm-memory-pointers tests passed"
