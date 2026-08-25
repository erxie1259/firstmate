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
- widgets [no-mistakes +yolo lane:products] - a second project of the products lane (added 2026-08-20)
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
  # Content the store rewrites to a blob is written to MNEMOSYNE_BLOB_DIR, so
  # it is pinned inside this test's temp root and never the operator's own.
  mkdir -p "$TMP_ROOT/blobs"
  MNEMOSYNE_BLOB_DIR="$TMP_ROOT/blobs" \
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
remember_into_lane() {  # <data-dir> <lane> <content> [project-channel] [source] [metadata-json]
  fm_migrate_assert_scratch "$1"
  python3 - "$MCP" "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" <<'RPC' >/dev/null
import json, subprocess, sys
mcp, data_dir, lane, content, project, source, metadata = sys.argv[1:8]
proc = subprocess.Popen([sys.executable, mcp, "serve", "--lane", lane, "--data-dir", data_dir],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True)
arguments = {"content": content, "memory_type": "context", "importance": 0.5}
if project:
    arguments["project"] = project
if source:
    arguments["source"] = source
if metadata:
    arguments["metadata"] = json.loads(metadata)
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

# Put a row nobody indexed into a lane bank, the way a bank can already hold
# rows this migration never wrote and never indexed.
plant_unindexed_row() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "INSERT INTO working_memory (id, content, source, scope, channel_id, consolidated_at)"
    " VALUES ('planted-unindexed-row', 'A row some other writer left unindexed.',"
    " 'some-other-writer', 'global', '_lane', '2026-08-24T00:00:00Z')")
conn.commit()
conn.close()
PY
}

# Verify a copy of a written data dir after breaking exactly one thing in it.
# The copy keeps each defect isolated from the next.
verify_with_defect() {  # <home> <src> <data> <tag> <lane> <sql>
  local copy="$3-$4"
  fm_migrate_assert_scratch "$3"
  fm_migrate_assert_scratch "$copy"
  cp -R "$3" "$copy"
  python3 - "$copy/banks/lane-$5/mnemosyne.db" "$6" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.executescript(sys.argv[2])
conn.commit()
conn.close()
PY
  fm_migrate "$1" "$2" "$copy" verify
}

# Give the scratch data dir a Hermes bank, copied from one of its lane banks so
# it carries a real schema. The bank it is copied from decides whether it holds
# memories this migration wrote.
make_hermes_bank() {  # <data-dir> <lane-to-copy>
  fm_migrate_assert_scratch "$1"
  mkdir -p "$1/banks/default"
  cp "$1/banks/lane-$2/mnemosyne.db" "$1/banks/default/mnemosyne.db"
}

# The source paths one lane's migrated memory records as its provenance.
migrated_source_paths() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import json, sqlite3, sys
row = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT metadata_json FROM working_memory WHERE source LIKE 'claude-automemory%'"
    " AND superseded_by IS NULL ORDER BY id LIMIT 1").fetchone()
print(json.dumps(json.loads(row[0])["source_paths"]))
PY
}

# Put a memory carrying this migration's provenance into the Hermes bank's
# episodic table, where a consolidated row lives.
plant_episodic_hermes_row() {  # <data-dir>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/default/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "INSERT INTO episodic_memory (id, content, source, scope, channel_id)"
    " VALUES ('planted-episodic-row', 'A migrated memory the store consolidated.',"
    " 'claude-automemory', 'global', '_lane')")
conn.commit()
conn.close()
PY
}

# Drop one migrated memory's embedding, the way a genuinely unindexed memory
# of ours would look.
drop_one_embedding() {  # <data-dir> <lane>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute(
    "SELECT id FROM working_memory WHERE source LIKE 'claude-automemory%' ORDER BY id LIMIT 1").fetchone()
conn.execute("DELETE FROM memory_embeddings WHERE memory_id = ?", (row[0],))
conn.commit()
conn.close()
PY
}

# How many memories in the Hermes bank carry this migration's own source.
hermes_migration_rows() {  # <data-dir>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/default/mnemosyne.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT count(*) FROM working_memory WHERE source LIKE 'claude-automemory%'").fetchone()[0])
PY
}

# The text a lane bank actually holds for the memory carrying this phrase.
stored_row_text() {  # <data-dir> <lane> <needle>
  fm_migrate_assert_scratch "$1"
  python3 - "$1/banks/lane-$2/mnemosyne.db" "$3" <<'PY'
import sqlite3, sys
row = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT content FROM working_memory WHERE source LIKE 'claude-automemory%'"
    " AND metadata_json LIKE ?", (f"%{sys.argv[2]}%",)).fetchone()
print(row[0] if row else "")
PY
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

test_verify_accounts_for_a_source_file_that_disappeared() {
  skip_without_library "the orphaned-source test" && return 0
  local home src data out
  home=$(make_home orphan-home)
  src=$(make_sources orphan-src)
  data=$(make_lanes orphan-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A source file that goes away is never retired from the store, so the bank
  # legitimately holds one more live memory than this run derives.
  rm "$src/-Users-x-Coding-flags/memory/project_release.md"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a source file disappeared: $out"
  case "$out" in
    *"FAIL  1 count reconciliation"*) fail "a deliberately kept orphan was reported as a count mismatch: $out" ;;
  esac
  case "$out" in
    *"kept whose source file is gone"*) ;;
    *) fail "the kept orphan was not named in the reconciliation: $out" ;;
  esac
  case "$out" in
    *"ORPHANED products/"*) ;;
    *) fail "verification did not report the orphaned ledger key: $out" ;;
  esac
  pass "fm-memory-migrate: a memory whose source file vanished reconciles as a kept orphan"
}

test_verify_ignores_hermes_activity_that_is_not_ours() {
  skip_without_library "the Hermes-activity test" && return 0
  local home src data out stop
  home=$(make_home hermes-home)
  src=$(make_sources hermes-src)
  data=$(make_lanes hermes-data products fleet-infra shared)
  make_hermes_bank "$data" shared
  # Hermes writes to its own bank constantly, including while a migration is
  # running. That says nothing about whether this tool touched it.
  stop="$data/keep-touching"
  : > "$stop"
  (while [ -f "$stop" ]; do touch "$data/banks/default/mnemosyne.db"; sleep 0.05; done) &
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  rm -f "$stop"
  wait
  [ "$(hermes_migration_rows "$data")" = "0" ] \
    || fail "the fixture put a migration row in the Hermes bank"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after Hermes wrote to its own bank during the run: $out"
  case "$out" in
    *"FAIL  13"*) fail "Hermes writing to its own bank was reported as this migration touching it: $out" ;;
  esac
  pass "fm-memory-migrate: Hermes writing to its own bank is not this migration touching it"
}

test_verify_catches_a_memory_of_ours_in_the_hermes_bank() {
  skip_without_library "the Hermes-intrusion test" && return 0
  local home src data out
  home=$(make_home hermesleak-home)
  src=$(make_sources hermesleak-src)
  data=$(make_lanes hermesleak-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A Hermes bank that holds memories carrying this migration's provenance is
  # the one thing check 13 exists to catch.
  make_hermes_bank "$data" products
  [ "$(hermes_migration_rows "$data")" != "0" ] \
    || fail "the fixture did not put a migration row in the Hermes bank"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while migrated memories sat in the Hermes bank: $out"
  case "$out" in
    *"FAIL  13"*) ;;
    *) fail "check 13 did not catch a migrated memory in the Hermes bank: $out" ;;
  esac
  pass "fm-memory-migrate: a memory of ours in the Hermes bank fails verification"
}

test_verify_accepts_a_cross_lane_duplicate() {
  skip_without_library "the cross-lane duplicate verification test" && return 0
  local home src data out
  home=$(make_home xlane-home)
  src=$(make_sources xlane-src)
  data=$(make_lanes xlane-data products fleet-infra)
  # One fact written down in two projects that live in different lanes is
  # deliberately written once in EACH lane, never merged, so each lane holds
  # text the other lane also holds.
  cat > "$src/-Users-x-Coding-flags/memory/build_containers.md" <<'MD'
---
name: Build containers
description: how release builds are containerised
type: reference
---
Release builds run inside disposable containers built from the pinned base image.
MD
  cp "$src/-Users-x-Coding-flags/memory/build_containers.md" \
     "$src/-Users-x-Coding-firstmate/memory/build_containers.md"
  cat > "$src/-Users-x-Coding-firstmate/memory/container_policy.md" <<'MD'
---
name: Container policy
description: what the fleet expects of a container
type: reference
---
Every container the fleet runs is rebuilt nightly from the pinned base image.
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed on a correct migration holding a cross-lane duplicate: $out"
  case "$out" in
    *"FAIL  9 lane containment"*) fail "a lane's own cross-lane duplicate was reported as a leak: $out" ;;
  esac
  pass "fm-memory-migrate: a lane's own cross-lane duplicate is never reported as a leak"
}

test_verify_passes_after_a_re_migration_supersedes() {
  skip_without_library "the re-migration verification test" && return 0
  local home src data out
  home=$(make_home remigrate-home)
  src=$(make_sources remigrate-src)
  data=$(make_lanes remigrate-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane now runs fastlane beta from a dedicated worktree.
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a legitimate re-migration: $out"
  case "$out" in
    *"superseded kept as history"*) ;;
    *) fail "the superseded row was not reported as history: $out" ;;
  esac
  pass "fm-memory-migrate: a re-migration after an edit verifies as history kept"
}

test_verify_treats_nothing_to_spot_check_as_a_pass() {
  skip_without_library "the empty-spot-check test" && return 0
  local home src data out detail
  home=$(make_home nospot-home)
  src="$TMP_ROOT/nospot-src"
  fm_migrate_assert_scratch "$src"
  mkdir -p "$src/-Users-x-Coding-flags/memory"
  # The only memory this corpus produces is a pointer whose description was
  # itself credential-bearing, so there is no description left to probe by.
  cat > "$src/-Users-x-Coding-flags/memory/vault_only.md" <<MD
---
name: Vault
description: the API key for TestFlight is in 1Password entry 4821
type: user
---
Match password: $SECRET_LITERAL lives in the vault.
MD
  data=$(make_lanes nospot-data products)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify --json) || true
  detail=$(json_field "$out" "next(c['detail'] for c in d['checks'] if c['check'].startswith('8 '))")
  [ "$(json_field "$out" "next(c['pass'] for c in d['checks'] if c['check'].startswith('8 '))")" \
    = "True" ] || fail "a corpus with nothing to spot-check failed check 8: $detail"
  case "$detail" in
    *"no migrated memory carries a description"*) ;;
    *) fail "check 8 did not say there was nothing to spot-check: $detail" ;;
  esac
  pass "fm-memory-migrate: nothing to spot-check passes rather than failing as 0/0"
}

test_verify_parity_covers_only_the_memories_this_migration_wrote() {
  skip_without_library "the parity-scope test" && return 0
  local home src data out
  home=$(make_home parity-home)
  src=$(make_sources parity-src)
  data=$(make_lanes parity-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  plant_unindexed_row "$data" products
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed over a row this migration never wrote: $out"
  case "$out" in
    *"FAIL  5 embedding parity"*) fail "another writer's unindexed row failed our embedding parity: $out" ;;
  esac
  case "$out" in
    *"FAIL  6 FTS parity"*) fail "another writer's unindexed row failed our FTS parity: $out" ;;
  esac
  pass "fm-memory-migrate: index parity is judged over this migration's own memories"
}

test_verify_reads_a_renamed_source_file_as_one_memory() {
  skip_without_library "the renamed-source test" && return 0
  local home src data out
  home=$(make_home rename-home)
  src=$(make_sources rename-src)
  data=$(make_lanes rename-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The ledger keys a memory by its file name, so renaming the file writes a
  # second key for the same unchanged memory. That is one memory under a new
  # name, not a source file that disappeared.
  mv "$src/-Users-x-Coding-flags/memory/project_release.md" \
     "$src/-Users-x-Coding-flags/memory/release_lane.md"
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a source file was renamed: $out"
  case "$out" in
    *"FAIL  1 count reconciliation"*) fail "a renamed source file was double-counted as an orphan: $out" ;;
  esac
  case "$out" in
    *"kept whose source file is gone"*) fail "a renamed source file was reported as a lost source: $out" ;;
  esac
  case "$out" in
    *ORPHANED*) fail "a renamed source file was reported as an orphaned ledger key: $out" ;;
  esac
  pass "fm-memory-migrate: a renamed source file reconciles as one memory, not an orphan"
}

test_verify_catches_a_migration_written_row_in_the_wrong_lane() {
  skip_without_library "the misrouted-write test" && return 0
  local home src data leaked paths out
  home=$(make_home misroute-home)
  src=$(make_sources misroute-src)
  data=$(make_lanes misroute-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A memory this migration wrote into the wrong lane's bank: it carries the
  # migration's own source and fleet-infra's provenance, but it sits in
  # products. This is the exact failure the lane model exists to prevent.
  leaked=$(migrated_content "$data" fleet-infra)
  paths=$(migrated_source_paths "$data" fleet-infra)
  remember_into_lane "$data" products "$leaked" firstmate claude-automemory \
    "{\"source_paths\": $paths, \"migration\": \"claude-automemory-phase3\"}" \
    || fail "could not seed a misrouted migration row through the bridge"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while a migrated memory sat in the wrong lane: $out"
  case "$out" in
    *"FAIL  9 lane containment"*) ;;
    *) fail "lane containment did not catch a memory this migration wrote to the wrong lane: $out" ;;
  esac
  pass "fm-memory-migrate: a migration-written row in the wrong lane fails lane containment"
}

test_verify_catches_a_consolidated_memory_in_the_hermes_bank() {
  skip_without_library "the episodic-intrusion test" && return 0
  local home src data out
  home=$(make_home episodic-home)
  src=$(make_sources episodic-src)
  data=$(make_lanes episodic-data products fleet-infra shared)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  make_hermes_bank "$data" shared
  # A memory of ours the store consolidated out of working_memory still lives
  # in the episodic table, and it is just as much a stray write.
  plant_episodic_hermes_row "$data"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while a consolidated memory of ours sat in the Hermes bank: $out"
  case "$out" in
    *"FAIL  13"*) ;;
    *) fail "check 13 did not read the episodic table of the Hermes bank: $out" ;;
  esac
  pass "fm-memory-migrate: a consolidated memory of ours in the Hermes bank fails verification"
}

test_verify_still_fails_when_our_own_memory_is_unindexed() {
  skip_without_library "the parity-can-fail test" && return 0
  local home src data out
  home=$(make_home unindexed-home)
  src=$(make_sources unindexed-src)
  data=$(make_lanes unindexed-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  drop_one_embedding "$data" products
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while one of our own memories had no embedding: $out"
  case "$out" in
    *"FAIL  5 embedding parity"*) ;;
    *) fail "embedding parity did not catch a migrated memory with no embedding: $out" ;;
  esac
  pass "fm-memory-migrate: a migrated memory with no embedding still fails parity"
}

test_a_vanished_same_stem_sibling_never_retires_its_neighbour() {
  skip_without_library "the same-stem sibling test" && return 0
  local home src data out before after
  home=$(make_home sibling-home)
  src=$(make_sources sibling-src)
  data=$(make_lanes sibling-data products fleet-infra)
  # Canonicalisation puts both checkouts of one project in one channel, so two
  # files can share a stem there while saying different things.
  cat > "$src/-Users-x-Coding-flags/memory/notes.md" <<'MD'
---
name: Notes from the first checkout
description: what the first checkout wrote down
type: reference
---
The simulator build is the one that reproduces the launch crash.
MD
  cat > "$src/-Users-x-live-Coding-flags/memory/notes.md" <<'MD'
---
name: Notes from the second checkout
description: what the second checkout wrote down
type: reference
---
The device build needs the provisioning profile refreshed every ninety days.
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  before=$(live_migrated_rows "$data" products)
  # One checkout goes away - unmounted, renamed, or deleted. The other memory
  # must not inherit its ledger key and must not be superseded by it.
  rm "$src/-Users-x-Coding-flags/memory/notes.md"
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a vanished same-stem sibling superseded the memory that remained: $out"
  after=$(live_migrated_rows "$data" products)
  [ "$before" = "$after" ] \
    || fail "a vanished same-stem sibling cost a live memory: $before -> $after"
  [ "$(bank_text_contains "$data" products 'reproduces the launch crash')" != "0" ] \
    || fail "the memory whose source file vanished was retired instead of kept"
  pass "fm-memory-migrate: a vanished same-stem sibling never retires the memory that remains"
}

test_verify_accepts_a_project_that_changed_lane() {
  skip_without_library "the re-laned project test" && return 0
  local home src data out
  home=$(make_home relane-home)
  src=$(make_sources relane-src)
  data=$(make_lanes relane-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The captain re-registers the project onto another lane. Its old rows stay
  # where they are, because this tool never retires anything.
  cat > "$home/data/projects.md" <<'MD'
# Projects

- flags [no-mistakes +yolo lane:fleet-infra] - Flutter flags app (added 2026-07-29)
- firstmate [no-mistakes +yolo lane:fleet-infra] - the fleet orchestrator (added 2026-08-18)
- jy-cards [local-only +yolo] - registered with no lane token (added 2026-08-18)
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a project was re-registered onto another lane: $out"
  case "$out" in
    *"FAIL  9 lane containment"*) fail "rows left in the old lane were reported as a cross-lane leak: $out" ;;
  esac
  case "$out" in
    *"kept in a lane their project no longer routes to"*) ;;
    *) fail "the stale-lane residue was not reported at all: $out" ;;
  esac
  pass "fm-memory-migrate: rows left behind by a re-laned project are residue, not a leak"
}

test_verify_catches_a_misrouted_row_whose_source_file_is_gone() {
  skip_without_library "the vanished-provenance leak test" && return 0
  local home src data out
  home=$(make_home gonepath-home)
  src=$(make_sources gonepath-src)
  data=$(make_lanes gonepath-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A memory this migration wrote into the wrong bank, whose source file has
  # since disappeared. Its own metadata still records the lane it belongs to.
  remember_into_lane "$data" products "The fleet rebuilds every runner image nightly." firstmate \
    claude-automemory \
    "{\"lane\": \"fleet-infra\", \"migration\": \"claude-automemory-phase3\", \"source_paths\": [\"/gone/fleet-infra/note.md\"]}" \
    || fail "could not seed a misrouted row whose source file is gone"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while a fleet-infra memory sat in the products bank: $out"
  case "$out" in
    *"FAIL  9 lane containment"*) ;;
    *) fail "lane containment went blind because the leaked row's source file was gone: $out" ;;
  esac
  pass "fm-memory-migrate: a misrouted row is caught even after its source file disappears"
}

test_every_check_still_fails_on_the_defect_it_exists_to_catch() {
  skip_without_library "the checks-can-fail audit" && return 0
  local home src data out
  home=$(make_home candetect-home)
  src=$(make_sources candetect-src)
  data=$(make_lanes candetect-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true

  out=$(verify_with_defect "$home" "$src" "$data" unpinned products \
    "UPDATE working_memory SET consolidated_at = NULL WHERE source LIKE 'claude-automemory%';")
  case "$out" in
    *"FAIL  3 no silent loss to trim"*) ;;
    *) fail "check 3 did not catch an unpinned migrated memory: $out" ;;
  esac

  out=$(verify_with_defect "$home" "$src" "$data" scoped products \
    "UPDATE working_memory SET scope = 'local' WHERE source LIKE 'claude-automemory%';")
  case "$out" in
    *"FAIL  4 scope correctness"*) ;;
    *) fail "check 4 did not catch a migrated memory that is not global: $out" ;;
  esac

  out=$(verify_with_defect "$home" "$src" "$data" unsearchable products \
    "DELETE FROM fts_working WHERE id IN (SELECT id FROM working_memory WHERE source LIKE 'claude-automemory%');")
  case "$out" in
    *"FAIL  6 FTS parity"*) ;;
    *) fail "check 6 did not catch a migrated memory missing from the FTS index: $out" ;;
  esac

  out=$(verify_with_defect "$home" "$src" "$data" retired products \
    "UPDATE working_memory SET valid_until = '2020-01-01T00:00:00Z' WHERE id = (SELECT id FROM working_memory WHERE source LIKE 'claude-automemory%' ORDER BY id LIMIT 1);")
  case "$out" in
    *"FAIL  7 clean lifecycle slate"*) ;;
    *) fail "check 7 did not catch a retired memory with nothing replacing it: $out" ;;
  esac

  out=$(verify_with_defect "$home" "$src" "$data" invisible fleet-infra \
    "UPDATE working_memory SET importance = 0.1;")
  case "$out" in
    *"FAIL  10 cross-lane awareness"*) ;;
    *) fail "check 10 did not catch a lane that contributes no title: $out" ;;
  esac

  out=$(verify_with_defect "$home" "$src" "$data" doubled products \
    "INSERT INTO working_memory (id, content, source, scope, channel_id, consolidated_at, metadata_json) SELECT 'duplicate-' || id, content || ' (a second row)', source, scope, channel_id, consolidated_at, metadata_json FROM working_memory WHERE source LIKE 'claude-automemory%' ORDER BY id LIMIT 1;")
  case "$out" in
    *"FAIL  11 no duplicate live rows per source"*) ;;
    *) fail "check 11 did not catch two live rows for one source file: $out" ;;
  esac

  chmod 000 "$src/-Users-x-Coding-flags/memory/project_release.md"
  out=$(fm_migrate "$home" "$src" "$data" verify)
  chmod 644 "$src/-Users-x-Coding-flags/memory/project_release.md"
  case "$out" in
    *"FAIL  14 every source file still readable on disk"*) ;;
    *) fail "check 14 did not catch a source file it could not read: $out" ;;
  esac

  pass "fm-memory-migrate: every check still fails on the defect it exists to catch"
}

test_an_edited_source_is_never_reported_as_an_orphan() {
  skip_without_library "the edited-source orphan test" && return 0
  local home src data out orphans
  home=$(make_home edited-home)
  src=$(make_sources edited-src)
  data=$(make_lanes edited-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The file is edited but not migrated again. Its source is right there on
  # disk, so it is no orphan - but the store does not hold what the plan now
  # derives, and check 15 says so rather than calling the migration clean.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane now runs fastlane beta from a dedicated worktree.
MD
  out=$(fm_migrate "$home" "$src" "$data" verify) || true
  case "$out" in
    *ORPHANED*) fail "an edited source file was reported as an orphaned ledger key: $out" ;;
  esac
  case "$out" in
    *"kept whose source file is gone"*) fail "an edited source file was counted as a lost source: $out" ;;
  esac
  case "$out" in
    *"PASS  1 count reconciliation"*) ;;
    *) fail "an edited source file broke the count reconciliation: $out" ;;
  esac
  case "$out" in
    *"PASS  15"*) ;;
    *) fail "a source edited since the last write was reported as a failed write: $out" ;;
  esac
  case "$out" in
    *"STALE"*"has changed since the last migration wrote it; re-run write"*) ;;
    *) fail "the drifted source was not reported as a visible stale notice: $out" ;;
  esac
  case "$out" in
    *REFUSED*) fail "a source that merely drifted was reported as a refused write: $out" ;;
  esac
  # A file that genuinely goes away must still be reported, and must not be
  # confused with the edited one that is still there.
  rm "$src/-Users-x-Coding-flags/memory/signing_notes.md"
  out=$(fm_migrate "$home" "$src" "$data" verify) || true
  orphans=$(printf '%s\n' "$out" | grep -c ORPHANED)
  [ "$orphans" = "1" ] || fail "expected exactly one orphan, got $orphans: $out"
  case "$out" in
    *"ORPHANED products/"*signing_notes*) ;;
    *) fail "the orphan reported is not the source file that disappeared: $out" ;;
  esac
  case "$out" in
    *"PASS  1 count reconciliation"*) ;;
    *) fail "the vanished source broke the count reconciliation: $out" ;;
  esac
  pass "fm-memory-migrate: an edited source is an update, only a vanished one is an orphan"
}

test_verify_catches_an_update_the_store_refused() {
  skip_without_library "the refused-update test" && return 0
  local home src data out detail
  home=$(make_home refusedupdate-home)
  src=$(make_sources refusedupdate-src)
  data=$(make_lanes refusedupdate-data products fleet-infra)
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
    || fail "the edit did not supersede the memory it replaces: $out"
  # Reverting the file asks the store to bring back text it has already
  # retired, which it refuses. The memory then holds text this run does not
  # derive, and the checklist must not read that as a clean migration.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs fastlane beta from a clean checkout of origin/main.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['refused']")" = "1" ] \
    || fail "the reverted source was not refused, so this no longer exercises a refused update: $out"
  out=$(fm_migrate "$home" "$src" "$data" verify --json) || true
  [ "$(json_field "$out" "next(c['pass'] for c in d['checks'] if c['check'].startswith('15 '))")" \
    = "False" ] || fail "check 15 read a refused update as a clean migration: $out"
  detail=$(json_field "$out" "next(c['detail'] for c in d['checks'] if c['check'].startswith('15 '))")
  case "$detail" in
    *"Flags release lane was REFUSED by the store"*"needs a person"*) ;;
    *) fail "check 15 did not report the refusal with advice a person can act on: $detail" ;;
  esac
  case "$detail" in
    *"re-run write"*) fail "a refused write was given the advice that re-running fixes it: $detail" ;;
  esac
  pass "fm-memory-migrate: an update the store refused fails verification"
}

test_a_renamed_source_needs_no_second_migration_to_verify() {
  skip_without_library "the rename-then-verify test" && return 0
  local home src data out
  home=$(make_home renameverify-home)
  src=$(make_sources renameverify-src)
  data=$(make_lanes renameverify-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The file is renamed but not migrated again. Its text is unchanged, so the
  # store holds that memory already; only the name it is filed under moved.
  mv "$src/-Users-x-Coding-flags/memory/project_release.md" \
     "$src/-Users-x-Coding-flags/memory/release_lane.md"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a rename that was not migrated again: $out"
  case "$out" in
    *ORPHANED*) fail "a renamed source file was reported as an orphaned ledger key: $out" ;;
  esac
  case "$out" in
    *"FAIL  2 provenance completeness"*) fail "a renamed source file was reported as missing provenance: $out" ;;
  esac
  pass "fm-memory-migrate: a rename verifies cleanly without a second migration"
}

test_a_file_created_at_a_renamed_path_never_retires_the_renamed_memory() {
  skip_without_library "the renamed-path reuse test" && return 0
  local home src data out live
  home=$(make_home reuse-home)
  src=$(make_sources reuse-src)
  data=$(make_lanes reuse-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  mv "$src/-Users-x-Coding-flags/memory/project_release.md" \
     "$src/-Users-x-Coding-flags/memory/release_lane.md"
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  live=$(live_migrated_rows "$data" products)
  # A different memory later takes the name the renamed file used to have. It
  # is its own memory and must not be written over the renamed one.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Release checklist
description: what to confirm before a release
type: reference
---
Confirm the changelog, the version bump, and the signing certificate expiry.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a new file at a renamed path superseded the renamed memory: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "1" ] \
    || fail "a new file at a renamed path did not become its own memory: $out"
  [ "$(live_migrated_rows "$data" products)" = "$((live + 1))" ] \
    || fail "the renamed memory did not survive a new file taking its old path"
  [ "$(bank_text_contains "$data" products 'fastlane beta from a clean checkout')" != "0" ] \
    || fail "the renamed memory was retired when its old path was reused"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a renamed path was reused: $out"
  pass "fm-memory-migrate: reusing a renamed file's path never retires the renamed memory"
}

test_a_renamed_and_edited_source_is_a_delete_plus_create() {
  skip_without_library "the rename-plus-edit bound test" && return 0
  local home src data out orphans
  home=$(make_home bound-home)
  src=$(make_sources bound-src)
  data=$(make_lanes bound-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # Renamed and edited between two runs: nothing on disk says whether this is
  # the same memory moved or a different file. The tool does not guess.
  rm "$src/-Users-x-Coding-flags/memory/project_release.md"
  cat > "$src/-Users-x-Coding-flags/memory/release_lane.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs fastlane beta from a dedicated worktree on a tagged commit.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a renamed-and-edited source superseded a memory on a guess: $out"
  [ "$(json_field "$out" "d['counts']['written']")" = "1" ] \
    || fail "a renamed-and-edited source did not become a new memory: $out"
  [ "$(json_field "$out" "len(d['orphaned_ledger_keys'])")" = "1" ] \
    || fail "the memory whose file no longer exists was not reported as an orphan: $out"
  [ "$(bank_text_contains "$data" products 'fastlane beta from a clean checkout')" != "0" ] \
    || fail "the old memory was retired rather than kept as an orphan"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed on the rename-plus-edit bound: $out"
  orphans=$(printf '%s\n' "$out" | grep -c ORPHANED)
  [ "$orphans" = "1" ] || fail "expected exactly one kept orphan, got $orphans: $out"
  pass "fm-memory-migrate: a renamed and edited source is a delete plus a create, and keeps both"
}

test_another_directory_of_one_project_stays_one_memory() {
  skip_without_library "the canonicalisation-identity test" && return 0
  local home src data out live
  home=$(make_home thirdcopy-home)
  src=$(make_sources thirdcopy-src)
  data=$(make_lanes thirdcopy-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  live=$(live_migrated_rows "$data" products)
  # A third checkout of the same project appears, holding the same fact. That
  # is one memory carrying a third source path, never a second memory.
  mkdir -p "$src/-Users-x-other-Coding-flags/memory"
  cp "$src/-Users-x-Coding-flags/memory/shared_fact.md" \
     "$src/-Users-x-other-Coding-flags/memory/shared_fact.md"
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['written']")" = "0" ] \
    || fail "a third copy of one fact was written as a second memory: $out"
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "a third copy of one fact superseded the memory it belongs to: $out"
  [ "$(live_migrated_rows "$data" products)" = "$live" ] \
    || fail "a third copy of one fact changed the number of live memories"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after a third checkout of one project appeared: $out"
  pass "fm-memory-migrate: another directory of one project stays one memory"
}

test_a_channel_move_is_refused_and_check_15_names_it() {
  skip_without_library "the channel-move test" && return 0
  local home src data out detail
  home=$(make_home chanmove-home)
  src=$(make_sources chanmove-src)
  data=$(make_lanes chanmove-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A second project of the same lane takes up the same fact, so the memory
  # now belongs to the lane-wide channel. The store's dedupe is keyed on the
  # session and the content and ignores the channel, so that move cannot be
  # expressed and the write is refused. This is the documented bound; when
  # follow-up memory-bridge-channel-move-followup-q73 makes the move land,
  # this test going red is the signal that it worked.
  mkdir -p "$src/-Users-x-Coding-widgets/memory"
  cp "$src/-Users-x-Coding-flags/memory/shared_fact.md" \
     "$src/-Users-x-Coding-widgets/memory/shared_fact.md"
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['refused']")" = "1" ] \
    || fail "the channel move was not refused, so the documented bound no longer holds: $out"
  [ "$(json_field "$out" "d['counts']['updated']")" = "0" ] \
    || fail "the channel move landed as a supersession the bridge cannot express: $out"
  [ "$(json_field "$out" "next(r['code'] for r in d['refusals'])")" = "duplicate_in_other_project" ] \
    || fail "the refusal is not the store refusing to relocate the content: $out"
  # The refusal must be reported by verify, not absorbed by another check.
  out=$(fm_migrate "$home" "$src" "$data" verify --json) || true
  [ "$(json_field "$out" "next(c['pass'] for c in d['checks'] if c['check'].startswith('15 '))")" \
    = "False" ] || fail "check 15 did not report the refused channel move: $out"
  detail=$(json_field "$out" "next(c['detail'] for c in d['checks'] if c['check'].startswith('15 '))")
  case "$detail" in
    *"Shared build fact"*"held under channel 'flags'"*"derives it for '_lane'"*) ;;
    *) fail "check 15 did not name the memory and both channels: $detail" ;;
  esac
  [ "$(bank_text_contains "$data" products 'wall-clock timestamps')" != "0" ] \
    || fail "the memory was lost while its channel move was refused"
  pass "fm-memory-migrate: a channel move is refused and check 15 names the memory and both channels"
}

test_verify_catches_a_memory_the_store_refused() {
  skip_without_library "the refused-write test" && return 0
  local home src data out
  home=$(make_home refused-home)
  src=$(make_sources refused-src)
  # fleet-infra is deliberately never provisioned, so its memories cannot land.
  data=$(make_lanes refused-data products)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    && fail "verification passed while a refused memory was missing from the store: $out"
  case "$out" in
    *"FAIL  15 every derived memory landed in the store"*) ;;
    *) fail "a refused write did not fail its own check: $out" ;;
  esac
  case "$out" in
    *"was REFUSED by the store"*"needs a person"*) ;;
    *) fail "check 15 did not say which memory the store refused: $out" ;;
  esac
  case "$out" in
    *STALE*) fail "a refused write was reported as a source that merely drifted: $out" ;;
  esac
  pass "fm-memory-migrate: a memory the store refused fails verification on its own check"
}

test_two_successive_edits_verify_as_history_kept() {
  skip_without_library "the supersession-chain test" && return 0
  local home src data out
  home=$(make_home chain-home)
  src=$(make_sources chain-src)
  data=$(make_lanes chain-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs fastlane beta from a dedicated worktree.
MD
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # A second edit builds a chain A -> B -> C in which B is itself retired, so
  # the row naming A is a retired one.
  cat > "$src/-Users-x-Coding-flags/memory/project_release.md" <<'MD'
---
name: Flags release lane
description: how the flags app reaches TestFlight
type: project
---
The release lane runs fastlane beta from a dedicated worktree on a signed tag.
MD
  out=$(fm_migrate "$home" "$src" "$data" write --json) || true
  [ "$(json_field "$out" "d['counts']['updated']")" = "1" ] \
    || fail "the second edit did not supersede the memory the first one wrote: $out"
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed after two successive edits of one source: $out"
  case "$out" in
    *"FAIL  7 clean lifecycle slate"*) fail "a supersession chain was read as a memory lost: $out" ;;
  esac
  pass "fm-memory-migrate: two successive edits verify as history kept"
}

test_verify_catches_a_memory_the_ledger_claims_but_the_store_lost() {
  skip_without_library "the lost-write test" && return 0
  local home src data out
  home=$(make_home lostwrite-home)
  src=$(make_sources lostwrite-src)
  data=$(make_lanes lostwrite-data products fleet-infra)
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  # The ledger records this exact text as written. A store that no longer
  # holds it has lost a memory, and that is not drift the captain can fix by
  # re-running write.
  python3 - "$data/banks/lane-products/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("DELETE FROM working_memory WHERE content LIKE '%fastlane beta from a clean checkout%'")
conn.commit()
conn.close()
PY
  out=$(fm_migrate "$home" "$src" "$data" verify --json) || true
  [ "$(json_field "$out" "next(c['pass'] for c in d['checks'] if c['check'].startswith('15 '))")" \
    = "False" ] || fail "check 15 passed over a memory the store lost: $out"
  case "$(json_field "$out" "next(c['detail'] for c in d['checks'] if c['check'].startswith('15 '))")" in
    *"Flags release lane"*"recorded in the ledger as written, but the store does not hold it"*) ;;
    *) fail "check 15 did not report the lost memory in its own words: $out" ;;
  esac
  pass "fm-memory-migrate: a memory the ledger claims but the store lost fails verification"
}

test_the_stored_form_matches_what_the_bridge_really_stores() {
  skip_without_library "the stored-form round-trip test" && return 0
  local home src data out stored
  home=$(make_home roundtrip-home)
  src=$(make_sources roundtrip-src)
  data=$(make_lanes roundtrip-data products fleet-infra)
  # The store rewrites content past its size cap into a content-addressed
  # stub, so what the bank holds is not what the file says. The tool models
  # that with the store's own sanitizer; this drives the whole round trip and
  # reads back what actually landed.
  {
    printf '%s\n' '---' 'name: Captured build log' 'description: the full log of a failing build' 'type: reference' '---'
    python3 -c "print('The build log line that repeats and repeats. ' * 30000)"
  } > "$src/-Users-x-Coding-flags/memory/build_log.md"
  fm_migrate "$home" "$src" "$data" write >/dev/null || true
  stored=$(stored_row_text "$data" products 'Captured build log')
  case "$stored" in
    *"The build log line that repeats"*)
      fail "the store kept the raw text, so this no longer exercises the rewriting" ;;
    "") fail "the oversized memory did not land in the bank at all" ;;
    *) ;;
  esac
  # The tool's model of the stored form matched what the bridge really wrote,
  # which is exactly what check 15 asserts memory by memory.
  out=$(fm_migrate "$home" "$src" "$data" verify) \
    || fail "verification failed over content the store rewrote to a blob: $out"
  case "$out" in
    *"FAIL  15"*) fail "a memory the store rewrote to a blob was read as never landed: $out" ;;
  esac
  pass "fm-memory-migrate: the stored form matches what the bridge really stores"
}

test_store_content_refuses_comparison_with_raw_text() {
  local out
  # The stored form is its own type so that a consumer comparing derived text
  # straight against store content fails at the moment of the mistake rather
  # than quietly answering "no, that memory never landed".
  out=$(python3 - "$MIGRATE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_loader(
    "fm_memory_migrate", importlib.machinery.SourceFileLoader("fm_memory_migrate", sys.argv[1]))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
held = module.stored_form("a memory the store holds")
if held != module.stored_form("a memory the store holds"):
    print("two stored forms of one text compared unequal")
    raise SystemExit
try:
    held == "a memory the store holds"
except TypeError:
    print("guarded")
else:
    print("a raw string comparison was answered instead of refused")
PY
) || fail "the stored-form guard could not be exercised: $out"
  [ "$out" = "guarded" ] || fail "store content did not refuse comparison with raw text: $out"
  pass "fm-memory-migrate: store content refuses to be compared with raw derived text"
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
test_verify_accounts_for_a_source_file_that_disappeared
test_verify_ignores_hermes_activity_that_is_not_ours
test_verify_catches_a_memory_of_ours_in_the_hermes_bank
test_verify_accepts_a_cross_lane_duplicate
test_verify_passes_after_a_re_migration_supersedes
test_verify_treats_nothing_to_spot_check_as_a_pass
test_verify_parity_covers_only_the_memories_this_migration_wrote
test_verify_still_fails_when_our_own_memory_is_unindexed
test_verify_reads_a_renamed_source_file_as_one_memory
test_verify_catches_a_migration_written_row_in_the_wrong_lane
test_verify_catches_a_consolidated_memory_in_the_hermes_bank
test_a_vanished_same_stem_sibling_never_retires_its_neighbour
test_verify_accepts_a_project_that_changed_lane
test_verify_catches_a_misrouted_row_whose_source_file_is_gone
test_every_check_still_fails_on_the_defect_it_exists_to_catch
test_an_edited_source_is_never_reported_as_an_orphan
test_verify_catches_an_update_the_store_refused
test_the_stored_form_matches_what_the_bridge_really_stores
test_store_content_refuses_comparison_with_raw_text
test_verify_catches_a_memory_the_ledger_claims_but_the_store_lost
test_a_renamed_source_needs_no_second_migration_to_verify
test_a_file_created_at_a_renamed_path_never_retires_the_renamed_memory
test_a_renamed_and_edited_source_is_a_delete_plus_create
test_another_directory_of_one_project_stays_one_memory
test_a_channel_move_is_refused_and_check_15_names_it
test_verify_catches_a_memory_the_store_refused
test_two_successive_edits_verify_as_history_kept
test_verify_catches_a_memory_that_never_landed
test_rollback_leaves_every_source_intact
