#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-migrate.
#
# This is the step that copies the captain's own memory files into the store,
# so the two things it must never do are lose one and publish one. Every test
# drives the real script; every write goes through a real bin/fm-memory-mcp
# against a scratch data dir under this test's own temp root, and every source
# directory is a fixture this test built. fm_migrate_assert_scratch enforces
# both on every invocation, so nothing here can reach the operator's live store
# or read a real ~/.claude memory directory.
#
# Deriving the plan needs only the standard library, so the parsing, routing,
# canonicalisation, and credential tests always run. The write and verify tests
# need the mnemosyne library and skip cleanly where it is absent, which is every
# CI runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-migrate)
MIGRATE="$ROOT/bin/fm-memory-migrate"
MCP="$ROOT/bin/fm-memory-mcp"

# The literal a credential test proves never reaches the store. It is a
# throwaway string invented here, not a real secret.
SECRET_LITERAL='4uhjodzUCr1OTb8FL3mBfc0uwwsWo+s7'

# --- helpers -----------------------------------------------------------------

fm_migrate_assert_scratch() {
  case "$1" in
    "$TMP_ROOT"/*) ;;
    *) fail "refusing to run against a path outside the test temp root: $1" ;;
  esac
}

# A firstmate home whose registry routes flags and firstmate, and nothing else.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  fm_migrate_assert_scratch "$home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- flags [no-mistakes +yolo lane:products] - Flutter flags app (added 2026-07-29)
- firstmate [no-mistakes +yolo lane:fleet-infra] - the fleet orchestrator (added 2026-08-18)
- jy-cards [local-only +yolo] - registered with no lane token (added 2026-08-18)
MD
  printf '%s' "$home"
}

# An auto-memory tree in the shape Claude Code actually writes one.
make_sources() {  # <name>
  local src="$TMP_ROOT/$1"
  fm_migrate_assert_scratch "$src"
  mkdir -p "$src/-Users-x-Coding-flags/memory" \
           "$src/-Users-x-live-Coding-flags/memory" \
           "$src/-Users-x-Coding-firstmate/memory" \
           "$src/-Users-x-Coding-jy-cards/memory" \
           "$src/-Users-x-Coding-nowhere/memory"

  # Older dialect: a top-level `type:`.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs fastlane beta from a clean checkout of origin/main.
MD

  # Newer dialect: `type` nested under `metadata:`.
  cat > "$src/-Users-x-Coding-firstmate/memory/newer-dialect.md" <<'MD'
---
name: newer-dialect-memory
description: a memory written in the newer frontmatter generation
metadata:
  node_type: memory
  type: feedback
  originSessionId: abc-123
  modified: 2026-08-18T06:24:31.498Z
---

Chat carries outcomes only, never routine acknowledgements. Related: [[chat-style]]
MD

  # The same fact hand-copied into a second checkout of one project.
  cat > "$src/-Users-x-Coding-flags/memory/shared_fact.md" <<'MD'
---
name: Shared build fact
description: a fact both flags checkouts wrote down
type: reference
---
Build numbers are wall-clock timestamps, so every upload is unique.
MD
  cp "$src/-Users-x-Coding-flags/memory/shared_fact.md" \
     "$src/-Users-x-live-Coding-flags/memory/shared_fact.md"

  # A file that writes a secret down.
  cat > "$src/-Users-x-Coding-flags/memory/signing_notes.md" <<MD
---
name: Release signing notes
description: where the signing material for this app lives
type: user
---
Match password: $SECRET_LITERAL and the key file is AuthKey_28SVFTGS58.
MD

  # A registered project carrying no lane token.
  cat > "$src/-Users-x-Coding-jy-cards/memory/card_layout.md" <<'MD'
---
name: Card layout
description: the coworker card generator layout
type: project
---
One self-contained HTML page, exported as PNG.
MD

  # A directory matching no registered project.
  cat > "$src/-Users-x-Coding-nowhere/memory/orphan.md" <<'MD'
---
name: orphan memory
description: belongs to no registered project
type: project
---
Nothing routes this anywhere.
MD

  # The index Claude Code renders, which is never a memory.
  cat > "$src/-Users-x-Coding-flags/memory/MEMORY.md" <<'MD'
# Memory index

- [Flags release lane](project_release.md) - how the app ships
MD
  printf '%s' "$src"
}

# A data dir with the lanes the fixture routes to, provisioned for real.
make_lanes() {  # <name> <lane>...
  local dir="$TMP_ROOT/$1" lane
  shift
  fm_migrate_assert_scratch "$dir"
  mkdir -p "$dir"
  for lane in "$@"; do
    FM_HOME="$TMP_ROOT/no-such-home" "$MCP" provision --lane "$lane" --data-dir "$dir" >/dev/null \
      || fail "could not provision lane $lane for the fixture"
  done
  printf '%s' "$dir"
}

fm_migrate() {  # <home> <source> <data-dir> <args>...
  local home=$1 src=$2 data_dir=$3
  shift 3
  fm_migrate_assert_scratch "$home"
  fm_migrate_assert_scratch "$src"
  fm_migrate_assert_scratch "$data_dir"
  "$MIGRATE" "$@" --home "$home" --source "$src" --data-dir "$data_dir" 2>&1
}

json_field() {  # <json> <python-expression over `d`>
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

bank_rows() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
      .execute("SELECT count(*) FROM working_memory").fetchone()[0])
PY
}

live_migrated_rows() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT count(*) FROM working_memory WHERE superseded_by IS NULL AND valid_until IS NULL"
    " AND source LIKE 'claude-automemory%'").fetchone()[0])
PY
}

bank_text_contains() {  # <data-dir> <lane> <needle>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" "$3" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
hits = 0
for content, metadata in conn.execute("SELECT content, metadata_json FROM working_memory"):
    if sys.argv[2] in (content or "") or sys.argv[2] in (metadata or ""):
        hits += 1
print(hits)
PY
}

tree_digest() {  # <dir> - every file's path and bytes, order-stable
  fm_migrate_assert_scratch "$1"
  python3 - "$1" <<'PY'
import hashlib, sys
from pathlib import Path
h = hashlib.sha256()
for path in sorted(Path(sys.argv[1]).rglob("*")):
    if path.is_file():
        h.update(str(path).encode())
        h.update(path.read_bytes())
print(h.hexdigest())
PY
}

# Write a memory into a lane bank through the real bridge, so the bank holds a
# memory this migration never wrote - which is what every lane bank actually
# looks like once phase 2's pointers live in it.
remember_into_lane() {  # <data-dir> <lane> <content> [project-channel]
  fm_migrate_assert_scratch "$1"
  python3 - "$MCP" "$1" "$2" "$3" "${4:-}" <<'RPC' >/dev/null
import json, subprocess, sys
mcp, data_dir, lane, content, project = sys.argv[1:6]
proc = subprocess.Popen([sys.executable, mcp, "serve", "--lane", lane, "--data-dir", data_dir],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True)
arguments = {"content": content, "memory_type": "context", "importance": 0.5}
if project:
    arguments["project"] = project
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "memory_remember", "arguments": arguments}},
]
out, _ = proc.communicate("\n".join(json.dumps(r) for r in requests) + "\n")
answer = json.loads(out.strip().splitlines()[-1])
sys.exit(0 if not answer["result"].get("isError") else 1)
RPC
}

# The text of one lane's migrated memory, read back from the bank it landed in.
migrated_content() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT content FROM working_memory WHERE source LIKE 'claude-automemory%'"
    " AND superseded_by IS NULL ORDER BY id LIMIT 1").fetchone()[0])
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
  pass "fm-memory-migrate: mnemosyne not installed, skipping $1"
  return 0
}

# --- deriving the plan -------------------------------------------------------

test_plan_parses_both_frontmatter_dialects() {
  local home src out
  home=$(make_home dialect-home)
  src=$(make_sources dialect-src)
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/dialect-data" plan --json) \
    || true
  [ "$(json_field "$out" "next(e['memory_type'] for e in d['entries'] if e['metadata']['source_name']=='Flags release lane')")" \
    = "instruction" ] || fail "the older top-level type: dialect did not map to instruction: $out"
  [ "$(json_field "$out" "next(e['memory_type'] for e in d['entries'] if e['metadata']['source_name']=='newer-dialect-memory')")" \
    = "preference" ] || fail "the newer metadata.type dialect did not map to preference: $out"
  [ "$(json_field "$out" "next(e['metadata']['source_modified'] for e in d['entries'] if e['metadata']['source_name']=='newer-dialect-memory')")" \
    = "2026-08-18T06:24:31.498Z" ] || fail "the newer dialect's modified time was not preserved: $out"
  [ "$(json_field "$out" "next(e['metadata']['links'][0] for e in d['entries'] if e['metadata']['source_name']=='newer-dialect-memory')")" \
    = "chat-style" ] || fail "a wikilink target was not preserved: $out"
  pass "fm-memory-migrate: both auto-memory frontmatter dialects are parsed and mapped"
}

test_plan_never_migrates_the_index() {
  local home src out
  home=$(make_home index-home)
  src=$(make_sources index-src)
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/index-data" plan --json) || true
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if 'MEMORY.md' in e['metadata']['source_path'])")" \
    = "0" ] || fail "the MEMORY.md index was migrated: $out"
  pass "fm-memory-migrate: the MEMORY.md index is never migrated"
}

test_plan_canonicalises_fragmented_directories() {
  local home src out
  home=$(make_home canon-home)
  src=$(make_sources canon-src)
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/canon-data" plan --json) || true
  # Two directories of one project become one project, and the fact both of
  # them wrote down becomes ONE memory carrying both source paths.
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if e['metadata']['source_name']=='Shared build fact')")" \
    = "1" ] || fail "the duplicated fact was not collapsed into one memory: $out"
  [ "$(json_field "$out" "len(next(e['metadata']['source_paths'] for e in d['entries'] if e['metadata']['source_name']=='Shared build fact'))")" \
    = "2" ] || fail "the collapsed memory did not keep both source paths: $out"
  [ "$(json_field "$out" "next(c['project'] for c in d['canonicalised_projects'])")" \
    = "flags" ] || fail "the fragmented project was not reported as canonicalised: $out"
  [ "$(json_field "$out" "len(set(e['channel_id'] for e in d['entries'] if e['lane']=='products'))")" \
    = "1" ] || fail "one project's memories landed under more than one channel: $out"
  pass "fm-memory-migrate: several directories of one project become one project"
}

test_plan_refuses_to_guess_a_lane() {
  local home src out
  home=$(make_home unrouted-home)
  src=$(make_sources unrouted-src)
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/unrouted-data" plan --json) || true
  [ "$(json_field "$out" "sum(1 for u in d['unrouted'] if u['dir']=='-Users-x-Coding-nowhere')")" \
    = "1" ] || fail "a directory matching no registered project was not reported unrouted: $out"
  [ "$(json_field "$out" "next(u['project'] for u in d['unrouted'] if u['dir']=='-Users-x-Coding-jy-cards')")" \
    = "jy-cards" ] || fail "a registered project with no lane token was not reported unrouted: $out"
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if e['channel_id'] in ('jy-cards','nowhere'))")" \
    = "0" ] || fail "an unrouted directory produced a memory: $out"
  pass "fm-memory-migrate: an unresolvable lane is reported, never guessed"
}

test_plan_exit_status_reports_unrouted_work() {
  local home src
  home=$(make_home exit-home)
  src=$(make_sources exit-src)
  fm_migrate "$home" "$src" "$TMP_ROOT/exit-data" plan >/dev/null \
    && fail "a plan leaving files unrouted exited 0"
  pass "fm-memory-migrate: a plan that leaves files unrouted exits nonzero"
}

test_plan_keeps_credentials_out_and_points_at_the_file() {
  local home src out content
  home=$(make_home cred-home)
  src=$(make_sources cred-src)
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/cred-data" plan --json) || true
  [ "$(json_field "$out" "sum(1 for e in d['credential_pointers'])")" \
    = "1" ] || fail "the secret-bearing file was not held back as a pointer: $out"
  content=$(json_field "$out" "next(e['content'] for e in d['credential_pointers'])")
  case "$content" in
    *"$SECRET_LITERAL"*) fail "the credential pointer carries the secret itself" ;;
    *signing_notes.md*) ;;
    *) fail "the credential pointer does not name the file to read: $content" ;;
  esac
  [ "$(printf '%s' "$out" | grep -c "$SECRET_LITERAL")" = "0" ] \
    || fail "the plan output reproduced the secret literal"
  pass "fm-memory-migrate: a secret-bearing file becomes a pointer that carries no secret"
}

test_plan_reports_split_directories_it_cannot_route() {
  local home src out
  home=$(make_home split-home)
  src=$(make_sources split-src)
  mkdir -p "$src/-Users-x-Coding-apps-tcg-ops/memory" "$src/-Users-x-Coding-tcg-ops/memory"
  for dir in apps-tcg-ops tcg-ops; do
    cat > "$src/-Users-x-Coding-$dir/memory/note.md" <<MD
---
name: note from $dir
description: one half of a split project
type: project
---
Body from $dir.
MD
  done
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/split-data" plan --json) || true
  [ "$(json_field "$out" "next(f['looks_like_project'] for f in d['unrouted_fragments'])")" \
    = "tcg-ops" ] || fail "two directories of one unregistered project were not reported together: $out"
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if 'tcg-ops' in e['metadata']['source_path'])")" \
    = "0" ] || fail "an unregistered split project was routed anyway: $out"
  pass "fm-memory-migrate: split directories of an unregistered project are reported, not routed"
}

test_plan_keeps_a_refused_body_out_of_the_pointer_metadata() {
  local home src out
  home=$(make_home links-home)
  src=$(make_sources links-src)
  # A wikilink target is body text, and the body of this file is exactly what
  # D2 refuses to publish; a safe target beside it must still survive.
  cat > "$src/-Users-x-Coding-flags/memory/vault_notes.md" <<MD
---
name: Vault notes
description: where the release vault lives
type: user
---
The unlock value is $SECRET_LITERAL, recorded as [[$SECRET_LITERAL]]. See [[release-vault]].
MD
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/links-data" plan --json) || true
  [ "$(printf '%s' "$out" | grep -c "$SECRET_LITERAL")" = "0" ] \
    || fail "a link target lifted out of a refused body reproduced the secret literal"
  [ "$(json_field "$out" "json.dumps(next(e['metadata'].get('links') for e in d['credential_pointers'] if e['metadata']['source_name']=='Vault notes'))")" \
    = '["release-vault"]' ] \
    || fail "the credential pointer did not keep exactly the safe link targets: $out"
  pass "fm-memory-migrate: no text from a refused body reaches the pointer's metadata"
}

test_plan_reports_a_partial_canonical_overlap() {
  local home src out
  home=$(make_home overlap-home)
  src=$(make_sources overlap-src)
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

## Chat is for outcomes only

Chat carries outcomes only, never routine acknowledgements, and never a status ping.
MD
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/overlap-data" plan --json) || true
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if e['metadata']['source_name']=='newer-dialect-memory')")" \
    = "1" ] || fail "a memory a canonical file only partly states was dropped: $out"
  [ "$(json_field "$out" "next(x['owner'] for x in d['partial_pointer_overlaps'])")" \
    = "data/captain.md § Chat is for outcomes only" ] \
    || fail "the partial overlap with a canonical section was not reported: $out"
  pass "fm-memory-migrate: a partial canonical overlap is reported, never dropped"
}

# --- writing through the bridge ----------------------------------------------

test_write_is_idempotent() {
  skip_without_library "the idempotence test" && return 0
  local home src data first second before after
  home=$(make_home idem-home)
  src=$(make_sources idem-src)
  data=$(make_lanes idem-data products fleet-infra)
  first=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$first" "d['counts']['written']")" = "4" ] \
    || fail "the first run did not write every routed memory: $first"
  before=$(bank_rows "$data" products)
  second=$(fm_migrate "$home" "$src" "$data" write --json) || true
  after=$(bank_rows "$data" products)
  [ "$(json_field "$second" "d['counts']['written']")" = "0" ] \
    || fail "a second run over unchanged sources wrote new memories: $second"
  [ "$before" = "$after" ] \
    || fail "a second run changed the bank row count: $before -> $after"
  pass "fm-memory-migrate: re-running over unchanged sources writes nothing new"
}

test_write_supersedes_a_changed_source() {
  skip_without_library "the supersession test" && return 0
  local home src data out live
  home=$(make_home super-home)
  src=$(make_sources super-src)
  data=$(make_lanes super-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane now runs fastlane beta from a dedicated worktree.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "1" ] \
    || fail "an edited source file did not supersede its memory: $out"
  live=$(live_migrated_rows "$data" products)
  [ "$live" = "3" ] \
    || fail "an edited source left $live live memories where 3 were expected"
  [ "$(bank_text_contains "$data" products 'dedicated worktree')" != "0" ] \
    || fail "the replacement memory is not in the store"
  pass "fm-memory-migrate: an edited source supersedes its memory instead of duplicating it"
}

test_write_never_touches_a_source_file() {
  skip_without_library "the mirror-mode test" && return 0
  local home src data before after out
  home=$(make_home mirror-home)
  src=$(make_sources mirror-src)
  data=$(make_lanes mirror-data products fleet-infra)
  before=$(tree_digest "$src")
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  after=$(tree_digest "$src")
  [ "$before" = "$after" ] || fail "the migration changed a source file"
  [ "$(json_field "$out" "len(d['source_drift'])")" = "0" ] \
    || fail "the run reported source drift it should not have: $out"
  pass "fm-memory-migrate: the source files are only ever read"
}

test_write_keeps_the_secret_out_of_the_store() {
  skip_without_library "the credential-containment test" && return 0
  local home src data
  home=$(make_home nocred-home)
  src=$(make_sources nocred-src)
  data=$(make_lanes nocred-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  [ "$(bank_text_contains "$data" products "$SECRET_LITERAL")" = "0" ] \
    || fail "the secret literal reached the lane bank"
  [ "$(bank_text_contains "$data" products 'signing_notes.md')" != "0" ] \
    || fail "no pointer to the withheld credential file reached the store"
  pass "fm-memory-migrate: no secret reaches the store, but the pointer to it does"
}

test_one_unavailable_lane_costs_only_its_own_memories() {
  skip_without_library "the failure-isolation test" && return 0
  local home src data out
  home=$(make_home isolate-home)
  src=$(make_sources isolate-src)
  # fleet-infra is deliberately never provisioned, so its bridge cannot start.
  data=$(make_lanes isolate-data products)
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['written']")" = "3" ] \
    || fail "the healthy lane did not receive its memories: $out"
  [ "$(json_field "$out" "d['counts']['refused']")" = "1" ] \
    || fail "the unavailable lane's memory was not reported refused: $out"
  [ "$(json_field "$out" "next(r['lane'] for r in d['refusals'])")" = "fleet-infra" ] \
    || fail "the refusal does not name the lane that failed: $out"
  pass "fm-memory-migrate: a lane that cannot be opened costs its own memories and no others"
}

test_write_supersedes_an_edit_the_normalizer_would_fold_away() {
  skip_without_library "the whitespace-only supersession test" && return 0
  local home src data out live
  home=$(make_home fold-home)
  src=$(make_sources fold-src)
  data=$(make_lanes fold-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The stored text changes but its normalized form does not, which is exactly
  # the edit a ledger keyed on normalized text would call unchanged.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs FASTLANE BETA from a clean   checkout of origin/main.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "1" ] \
    || fail "an edit the normalizer folds away did not supersede its memory: $out"
  live=$(live_migrated_rows "$data" products)
  [ "$live" = "3" ] \
    || fail "a case-only edit left $live live memories where 3 were expected"
  pass "fm-memory-migrate: an edit that only changes case or spacing supersedes rather than duplicates"
}

test_verify_does_not_call_a_lane_local_memory_a_leak() {
  skip_without_library "the lane-containment false-positive test" && return 0
  local home src data out
  home=$(make_home local-home)
  src=$(make_sources local-src)
  data=$(make_lanes local-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A memory this migration never wrote, in the products bank, using a word
  # that only the fleet-infra migration otherwise uses. It is this lane's own
  # memory, so returning it is not a cross-lane leak.
  remember_into_lane "$data" products \
    "Release notes skip routine acknowledgements from the flags build log." \
    || fail "could not seed a lane-local memory through the bridge"
  out=$(fm_migrate "$home" "$src" "$data" verify) || true
  case "$out" in
    *"FAIL  9 lane containment"*) fail "a lane's own non-migrated memory was reported as a cross-lane leak: $out" ;;
  esac
  case "$out" in
    *"PASS  9 lane containment"*) ;;
    *) fail "verification did not report lane containment: $out" ;;
  esac
  pass "fm-memory-migrate: a lane's own memory sharing a word with another lane is not a leak"
}

test_verify_accepts_a_memory_left_to_a_canonical_pointer() {
  skip_without_library "the canonical-drop verification test" && return 0
  local home src data out
  home=$(make_home dropverify-home)
  src=$(make_sources dropverify-src)
  data=$(make_lanes dropverify-data products fleet-infra)
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

## Chat is for outcomes only

Chat carries outcomes only, never routine acknowledgements. Related: [[chat-style]]
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed on a migration that left a fact to its canonical pointer: $out"
  case "$out" in
    *"FAIL  2 provenance completeness"*) fail "a file left to its canonical pointer was reported as missing provenance: $out" ;;
  esac
  case "$out" in
    *"left to a canonical pointer"*) ;;
    *) fail "provenance completeness did not account for the canonical drop: $out" ;;
  esac
  pass "fm-memory-migrate: a fact left to its canonical pointer does not fail verification"
}

test_verify_catches_a_leak_hiding_in_a_project_channel() {
  skip_without_library "the project-channel leak test" && return 0
  local home src data leaked out
  home=$(make_home chanleak-home)
  src=$(make_sources chanleak-src)
  data=$(make_lanes chanleak-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A fleet-infra memory copied into the products bank under its own project
  # channel is exactly the cross-lane leak the lane model exists to prevent,
  # and it never lands in the lane-wide channel a default recall searches.
  leaked=$(migrated_content "$data" fleet-infra)
  remember_into_lane "$data" products "$leaked" firstmate \
    || fail "could not seed the cross-lane leak through the bridge"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while another lane's memory sat in the products bank: $out"
  case "$out" in
    *"FAIL  9 lane containment"*) ;;
    *) fail "lane containment did not catch a leak living in a project channel: $out" ;;
  esac
  pass "fm-memory-migrate: a leak in a project channel fails lane containment"
}

test_verify_does_not_spot_check_a_redacted_description() {
  skip_without_library "the redacted-description spot-check test" && return 0
  local home src data out detail
  home=$(make_home redact-home)
  src=$(make_sources redact-src)
  data=$(make_lanes redact-data products fleet-infra)
  # A description that itself names a secret is replaced by a constant, which
  # is the same string on every such pointer and identifies no memory.
  cat > "$src/-Users-x-Coding-flags/memory/vault_notes.md" <<MD
---
name: TestFlight vault
description: the API key for TestFlight is in 1Password entry 4821
type: user
---
Match password: $SECRET_LITERAL lives in the vault.
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify --json) || true
  detail=$(json_field "$out" "next(c['detail'] for c in d['checks'] if c['check'].startswith('8 '))")
  case "$detail" in
    "4/4 memories"*) ;;
    *) fail "the spot-check did not skip the pointer whose description was redacted: $detail" ;;
  esac
  [ "$(json_field "$out" "next(c['pass'] for c in d['checks'] if c['check'].startswith('8 '))")" \
    = "True" ] || fail "the recall spot-check failed on a correct migration: $out"
  pass "fm-memory-migrate: a redacted description is never used as a recall spot-check query"
}

test_verify_passes_a_clean_migration() {
  skip_without_library "the verification test" && return 0
  local home src data out
  home=$(make_home verify-home)
  src=$(make_sources verify-src)
  data=$(make_lanes verify-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed on a clean migration: $out"
  case "$out" in
    *FAIL*) fail "verification reported a failing check on a clean migration: $out" ;;
  esac
  for expected in "1 count reconciliation" "2 provenance completeness" "3 no silent loss to trim" \
                  "4 scope correctness" "5 embedding parity" "6 FTS parity" \
                  "7 clean lifecycle slate" "8 recall spot-check" "9 lane containment" \
                  "10 cross-lane awareness" "11 no duplicate live rows" \
                  "13 Hermes bank untouched" "14 every source file"; do
    case "$out" in
      *"$expected"*) ;;
      *) fail "verification did not report check '$expected': $out" ;;
    esac
  done
  pass "fm-memory-migrate: every checklist item is reported and passes on a clean migration"
}

test_verify_catches_a_memory_that_never_landed() {
  skip_without_library "the missing-memory test" && return 0
  local home src data out
  home=$(make_home missing-home)
  src=$(make_sources missing-src)
  data=$(make_lanes missing-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A source file that appeared after the migration is a memory the store does
  # not hold; verification must say so rather than reporting a tidy pass.
  cat > "$src/-Users-x-Coding-flags/memory/late_arrival.md" <<'MD'
---
name: Late arrival
description: written after the migration ran
type: project
---
This memory was never migrated.
MD
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while a derived memory was missing from the store: $out"
  case "$out" in
    *"FAIL  1 count reconciliation"*) ;;
    *) fail "verification did not fail count reconciliation: $out" ;;
  esac
  case "$out" in
    *"FAIL  2 provenance completeness"*) ;;
    *) fail "verification did not fail provenance completeness: $out" ;;
  esac
  pass "fm-memory-migrate: a memory that never landed fails verification"
}

test_rollback_leaves_every_source_intact() {
  skip_without_library "the rollback test" && return 0
  local home src data before after
  home=$(make_home rollback-home)
  src=$(make_sources rollback-src)
  data=$(make_lanes rollback-data products fleet-infra)
  before=$(tree_digest "$src")
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  fm_migrate_assert_scratch "$data"
  rm -rf "$data/banks"
  after=$(tree_digest "$src")
  [ "$before" = "$after" ] \
    || fail "deleting the lane banks changed the source files"
  [ ! -d "$data/banks" ] || fail "the lane banks were not removed by the rollback"
  pass "fm-memory-migrate: deleting the lane banks leaves every source file intact"
}

test_plan_drops_what_a_canonical_file_already_states() {
  local home src out
  home=$(make_home collide-home)
  src=$(make_sources collide-src)
  cat > "$home/data/captain.md" <<'MD'
# Captain preferences

## Chat is for outcomes only

Chat carries outcomes only, never routine acknowledgements. Related: [[chat-style]]
MD
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/collide-data" plan --json) || true
  [ "$(json_field "$out" "sum(1 for e in d['entries'] if e['metadata']['source_name']=='newer-dialect-memory')")" \
    = "0" ] || fail "a memory the canonical file already states was migrated anyway: $out"
  [ "$(json_field "$out" "next(x['owner'] for x in d['dropped_for_pointer'])")" \
    = "data/captain.md § Chat is for outcomes only" ] \
    || fail "the drop did not name the canonical section that owns the fact: $out"
  pass "fm-memory-migrate: a fact a canonical file already states is left to its pointer"
}

test_plan_parses_an_untyped_file() {
  local home src out
  home=$(make_home untyped-home)
  src=$(make_sources untyped-src)
  cat > "$src/-Users-x-Coding-flags/memory/untyped.md" <<'MD'
No frontmatter at all, just a body that still has to survive.
MD
  out=$(fm_migrate "$home" "$src" "$TMP_ROOT/untyped-data" plan --json) || true
  [ "$(json_field "$out" "next(e['memory_type'] for e in d['entries'] if e['metadata']['source_name']=='untyped')")" \
    = "context" ] || fail "a file with no frontmatter was not migrated as context: $out"
  pass "fm-memory-migrate: a file with no frontmatter is migrated, not dropped"
}

test_plan_parses_both_frontmatter_dialects
test_plan_never_migrates_the_index
test_plan_canonicalises_fragmented_directories
test_plan_refuses_to_guess_a_lane
test_plan_exit_status_reports_unrouted_work
test_plan_keeps_credentials_out_and_points_at_the_file
test_plan_reports_split_directories_it_cannot_route
test_plan_drops_what_a_canonical_file_already_states
test_plan_parses_an_untyped_file
test_plan_keeps_a_refused_body_out_of_the_pointer_metadata
test_plan_reports_a_partial_canonical_overlap
test_write_is_idempotent
test_write_supersedes_an_edit_the_normalizer_would_fold_away
test_verify_does_not_call_a_lane_local_memory_a_leak
test_write_supersedes_a_changed_source
test_write_never_touches_a_source_file
test_write_keeps_the_secret_out_of_the_store
test_one_unavailable_lane_costs_only_its_own_memories
test_verify_passes_a_clean_migration
test_verify_accepts_a_memory_left_to_a_canonical_pointer
test_verify_catches_a_leak_hiding_in_a_project_channel
test_verify_does_not_spot_check_a_redacted_description
test_verify_catches_a_memory_that_never_landed
test_rollback_leaves_every_source_intact
