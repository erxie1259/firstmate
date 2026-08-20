#!/usr/bin/env bash
# Behavior tests for bin/fm-memory-mcp.
#
# Every test drives the real script through its CLI and its stdio JSON-RPC
# surface. All store I/O is confined to scratch data dirs under this test's own
# temp root: nothing here ever names or opens the operator's live Mnemosyne
# store, and fm_memory_assert_scratch enforces that on every invocation.
#
# The tests that need the mnemosyne library skip cleanly where it is absent,
# which is every CI runner. The preflight, lane-resolution, protocol, and
# typed-error tests need only the standard library and always run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-mcp)
MCP="$ROOT/bin/fm-memory-mcp"

# --- helpers -----------------------------------------------------------------

# Refuse to run anything against a path outside this test's temp root, so a
# broken fixture can never reach the operator's real memory store.
fm_memory_assert_scratch() {
  case "$1" in
    "$TMP_ROOT"/*) ;;
    *) fail "refusing to run against a data dir outside the test temp root: $1" ;;
  esac
}

fm_memory_mcp() {
  local data_dir=$1
  shift
  fm_memory_assert_scratch "$data_dir"
  FM_HOME="$TMP_ROOT/no-such-home" "$MCP" "$@" --data-dir "$data_dir" 2>&1
}

# Build a store that satisfies every structural preflight check without the
# mnemosyne library: WAL, the tables the bridge reads and writes, and <rows>
# working memories.
make_store() {
  local data_dir=$1 lane=$2 rows=$3
  fm_memory_assert_scratch "$data_dir"
  mkdir -p "$data_dir/banks/lane-$lane"
  python3 - "$data_dir/banks/lane-$lane/mnemosyne.db" "$rows" <<'PY'
import sqlite3, sys
db, rows = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute(
    "CREATE TABLE IF NOT EXISTS working_memory ("
    "id TEXT PRIMARY KEY, content TEXT NOT NULL, source TEXT, timestamp TEXT,"
    "session_id TEXT DEFAULT 'default', importance REAL DEFAULT 0.5, metadata_json TEXT,"
    "veracity TEXT DEFAULT 'unknown', memory_type TEXT, consolidated_at TEXT,"
    "valid_until TIMESTAMP DEFAULT NULL, superseded_by TEXT DEFAULT NULL,"
    "scope TEXT DEFAULT 'global', channel_id TEXT)")
for table in ("episodic_memory", "gists", "facts", "memory_embeddings",
              "fts_working", "consolidation_log", "scratchpad"):
    conn.execute(f"CREATE TABLE IF NOT EXISTS {table} (id TEXT)")
for i in range(rows):
    conn.execute(
        "INSERT INTO working_memory (id, content, importance, scope, channel_id, consolidated_at)"
        " VALUES (?, ?, ?, 'global', '_lane', '2026-08-20T00:00:00')",
        (f"seed{i}", f"seeded memory {i}", 0.8))
conn.commit()
conn.close()
PY
}

write_record() {
  local data_dir=$1 lane=$2 floor=$3
  fm_memory_assert_scratch "$data_dir"
  cat > "$data_dir/banks/lane-$lane/fm-memory-provision.json" <<JSON
{
  "version": 1,
  "lane": "$lane",
  "bank": "lane-$lane",
  "db_path": "$data_dir/banks/lane-$lane/mnemosyne.db",
  "provisioned_at": "2026-08-20T00:00:00",
  "row_floor": $floor
}
JSON
}

# A ready lane: structural store plus its provisioning record.
make_ready_lane() {
  local data_dir=$1 lane=$2 rows=${3:-2}
  make_store "$data_dir" "$lane" "$rows"
  write_record "$data_dir" "$lane" 1
}

json_field() {  # <json> <python-expression over `d`>
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

# Feed JSON-RPC lines to `serve` and echo its stdout, keeping stderr separate so
# a diagnostic can never be mistaken for a protocol message.
serve_rpc() {
  local data_dir=$1 lane=$2
  shift 2
  fm_memory_assert_scratch "$data_dir"
  local line
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    for line in "$@"; do printf '%s\n' "$line"; done
  } | env HOME="${FM_MEMORY_TEST_HOME:-$HOME}" FM_HOME="$TMP_ROOT/no-such-home" \
      "$MCP" serve --lane "$lane" --data-dir "$data_dir" 2>/dev/null
}

# The JSON payload a tool call answered with, and whether it was flagged an error.
tool_payload() {  # <rpc-response-line>
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d['result']
print(json.dumps({'isError': r['isError'], 'payload': json.loads(r['content'][0]['text'])}))
"
}

library_available() {
  python3 - <<'PY' >/dev/null 2>&1
import importlib.util, sys
sys.exit(0 if importlib.util.find_spec("mnemosyne") else 1)
PY
}

# --- preflight refusals ------------------------------------------------------

test_preflight_refuses_missing_data_dir() {
  local out
  out=$(fm_memory_mcp "$TMP_ROOT/absent" preflight --lane products) && fail "preflight passed on a missing data dir"
  assert_contains "$out" '"code": "data_dir_missing"' "missing data dir did not report data_dir_missing"
  assert_contains "$out" '"store_verified": false' "a failed preflight did not report store_verified false"
  pass "fm-memory-mcp: preflight refuses a missing data dir"
}

test_preflight_refuses_missing_bank() {
  local dir out
  dir="$TMP_ROOT/no-bank"
  mkdir -p "$dir"
  out=$(fm_memory_mcp "$dir" preflight --lane products) && fail "preflight passed with no bank database"
  assert_contains "$out" '"code": "bank_missing"' "a missing bank did not report bank_missing"
  pass "fm-memory-mcp: preflight refuses a lane with no bank database"
}

test_preflight_refuses_unprovisioned_bank() {
  local dir out
  dir="$TMP_ROOT/unprovisioned"
  make_store "$dir" products 3
  out=$(fm_memory_mcp "$dir" preflight --lane products) && fail "preflight passed with no provisioning record"
  assert_contains "$out" '"code": "provision_missing"' "an unprovisioned bank did not report provision_missing"
  pass "fm-memory-mcp: preflight refuses a bank with no provisioning record"
}

test_preflight_refuses_empty_store() {
  local dir out
  dir="$TMP_ROOT/empty-store"
  make_store "$dir" products 0
  write_record "$dir" products 1
  out=$(fm_memory_mcp "$dir" preflight --lane products) && fail "preflight passed on an empty store"
  assert_contains "$out" '"code": "store_empty"' "an empty store did not report store_empty"
  assert_not_contains "$out" '"store_verified": true' "an empty store was reported verified"
  pass "fm-memory-mcp: preflight refuses an empty store instead of answering nothing-found"
}

test_preflight_refuses_wiped_store_below_recorded_floor() {
  local dir out
  dir="$TMP_ROOT/wiped-store"
  make_store "$dir" products 2
  write_record "$dir" products 50
  out=$(fm_memory_mcp "$dir" preflight --lane products) && fail "preflight passed below the recorded row floor"
  assert_contains "$out" '"code": "store_empty"' "a wiped store did not report store_empty"
  assert_contains "$out" "below the recorded floor of 50" "the refusal did not name the recorded floor"
  pass "fm-memory-mcp: preflight refuses a store that fell below its recorded row floor"
}

test_preflight_refuses_foreign_database() {
  local dir out
  dir="$TMP_ROOT/foreign"
  mkdir -p "$dir/banks/lane-products"
  python3 - "$dir/banks/lane-products/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE working_memory (id TEXT PRIMARY KEY, content TEXT)")
conn.execute("INSERT INTO working_memory VALUES ('a', 'not a mnemosyne store')")
conn.commit()
conn.close()
PY
  write_record "$dir" products 1
  out=$(fm_memory_mcp "$dir" preflight --lane products) && fail "preflight passed on a foreign database"
  assert_contains "$out" '"code": "schema_incomplete"' "a foreign database did not report schema_incomplete"
  pass "fm-memory-mcp: preflight refuses a database that is not a Mnemosyne store"
}

test_preflight_passes_a_ready_lane() {
  local dir out
  dir="$TMP_ROOT/ready"
  make_ready_lane "$dir" products 3
  out=$(fm_memory_mcp "$dir" preflight --lane products) || fail "preflight failed on a ready lane: $out"
  assert_contains "$out" '"store_verified": true' "a ready lane was not reported verified"
  [ "$(json_field "$out" "d['checks']['working_memory_rows']")" = "3" ] || fail "preflight miscounted the ready lane"
  pass "fm-memory-mcp: preflight passes a provisioned, populated lane"
}

test_preflight_reads_a_wal_store_with_no_live_writer() {
  local dir out
  dir="$TMP_ROOT/cold-wal"
  make_ready_lane "$dir" products 2
  # A WAL database with no -shm cannot be opened mode=ro; the preflight must
  # still complete, and must say which mode it took rather than substituting one
  # silently.
  rm -f "$dir/banks/lane-products/mnemosyne.db-shm" "$dir/banks/lane-products/mnemosyne.db-wal"
  out=$(fm_memory_mcp "$dir" preflight --lane products) || fail "preflight failed on a cold WAL store: $out"
  assert_contains "$out" '"store_verified": true' "a cold WAL store was not verified"
  assert_contains "$out" '"open_mode"' "preflight did not report which open mode it used"
  pass "fm-memory-mcp: preflight reads a WAL store with no live writer and reports the open mode"
}

test_preflight_reads_a_data_dir_whose_path_holds_uri_metacharacters() {
  local dir out
  # A '#' or '?' in the path ends a SQLite URI's path component, so an
  # unescaped path both truncates and silently drops mode=ro - which makes the
  # connection default to rwc and create a stray database at the truncation
  # point. The store here is fine; only its path is awkward.
  dir="$TMP_ROOT/uri#meta?dir"
  make_ready_lane "$dir" products 3
  out=$(fm_memory_mcp "$dir" preflight --lane products) || fail "preflight failed on a data dir with URI metacharacters: $out"
  assert_contains "$out" '"store_verified": true' "a ready lane under an awkward path was not verified"
  [ "$(json_field "$out" "d['checks']['working_memory_rows']")" = "3" ] || fail "preflight miscounted through an awkward path"
  assert_absent "$TMP_ROOT/uri" "preflight created a stray database at the truncated path"
  pass "fm-memory-mcp: preflight reads through a path holding URI metacharacters without creating a stray store"
}

test_awareness_attaches_a_bank_whose_path_holds_a_quote() {
  local dir line payload
  # attach_readable names the bank inside a SQL statement; an apostrophe in the
  # path must not be able to end the string literal it is named in.
  dir="$TMP_ROOT/quote'dir"
  make_ready_lane "$dir" products 2
  make_ready_lane "$dir" shared 2
  line=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_lanes","arguments":{}}}' \
    | tail -n 1)
  payload=$(tool_payload "$line")
  [ "$(json_field "$payload" "d['isError']")" = "False" ] || fail "memory_lanes failed through a quoted path: $payload"
  [ "$(json_field "$payload" "d['payload']['count']")" = "2" ] || fail "awareness did not read the sibling lane through a quoted path: $payload"
  pass "fm-memory-mcp: cross-lane awareness attaches a bank whose path holds an apostrophe"
}

# --- lane resolution ---------------------------------------------------------

test_refuses_unknown_lane() {
  local dir out
  dir="$TMP_ROOT/unknown-lane"
  make_ready_lane "$dir" products
  out=$(fm_memory_mcp "$dir" preflight --lane nonsense) && fail "an unknown lane was accepted"
  assert_contains "$out" '"code": "unknown_lane"' "an unknown lane did not report unknown_lane"
  assert_contains "$out" "products, client-services, brand-business, fleet-infra, personal, shared" \
    "the refusal did not name the registered lanes"
  pass "fm-memory-mcp: refuses an unknown lane instead of guessing one"
}

test_refuses_unresolved_lane() {
  local dir out
  dir="$TMP_ROOT/unresolved"
  make_ready_lane "$dir" products
  out=$(fm_memory_mcp "$dir" preflight) && fail "a missing lane was accepted"
  assert_contains "$out" '"code": "lane_unresolved"' "a missing lane did not report lane_unresolved"
  pass "fm-memory-mcp: refuses to serve when no lane can be resolved"
}

test_resolves_lane_from_the_project_registry() {
  local dir home out
  dir="$TMP_ROOT/registry"
  home="$TMP_ROOT/registry-home"
  make_ready_lane "$dir" products
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- flags [no-mistakes +yolo lane:products] - Flutter flags app (added 2026-07-29)
- house-memory [no-mistakes lane:personal] - home memory project (added 2026-08-02)
- comfy-test [no-mistakes] - no lane token yet (added 2026-08-02)
- decoy [no-mistakes] - description mentioning lane:products, which is not an annotation (added 2026-08-02)
- prose-bracket - migrating the [lane:personal] tooling (added 2026-08-02)
- trailing-bracket [no-mistakes] - later note [lane:personal] about it (added 2026-08-02)
MD
  out=$(FM_HOME="$home" "$MCP" preflight --project flags --data-dir "$dir" 2>&1) \
    || fail "registry lane resolution failed: $out"
  [ "$(json_field "$out" "d['lane']")" = "products" ] || fail "flags did not resolve to the products lane"

  # Only the products lane exists here, so house-memory resolving elsewhere is
  # visible in which bank the refusal names.
  out=$(FM_HOME="$home" "$MCP" preflight --project house-memory --data-dir "$dir" 2>&1) \
    && fail "an unprovisioned lane was accepted"
  assert_contains "$out" "lane 'personal' has no bank database" "house-memory did not route to the personal lane"
  assert_contains "$out" "banks/lane-personal/" "house-memory did not resolve to the personal lane bank"

  out=$(FM_HOME="$home" "$MCP" preflight --project comfy-test --data-dir "$dir" 2>&1) \
    && fail "a project with no lane token was accepted"
  assert_contains "$out" '"code": "lane_unresolved"' "a project with no lane token did not report lane_unresolved"
  assert_contains "$out" "carries no lane:<name> token" "a registered project's refusal did not name the missing token"

  out=$(FM_HOME="$home" "$MCP" preflight --project not-registered --data-dir "$dir" 2>&1) \
    && fail "an unregistered project was accepted"
  assert_contains "$out" "is not in" "an unregistered project was not told it is unregistered"

  # A lane named in prose is not an annotation, and must not route a write.
  out=$(FM_HOME="$home" "$MCP" preflight --project decoy --data-dir "$dir" 2>&1) \
    && fail "a lane named in a description was accepted as a mapping"
  assert_contains "$out" "carries no lane:<name> token" "a description lane token was read as an annotation"

  # bin/fm-project-mode.sh owns this line format and only reads an annotation
  # when field 3 opens with '['. A bracket anywhere else is description, so it
  # must not route a write either - with or without a real annotation ahead of it.
  out=$(FM_HOME="$home" "$MCP" preflight --project prose-bracket --data-dir "$dir" 2>&1) \
    && fail "a bracket in a description was accepted as an annotation"
  assert_contains "$out" "carries no lane:<name> token" "a description bracket was read as an annotation"
  out=$(FM_HOME="$home" "$MCP" preflight --project trailing-bracket --data-dir "$dir" 2>&1) \
    && fail "a bracket after the annotation was accepted as a lane token"
  assert_contains "$out" "carries no lane:<name> token" "a bracket after the annotation was read as a lane token"
  pass "fm-memory-mcp: maps a project to its lane, and refuses when the registry does not say"
}

test_registry_lane_token_does_not_disturb_the_delivery_posture() {
  local home out
  home="$TMP_ROOT/posture-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- flags [no-mistakes +yolo lane:products] - Flutter flags app (added 2026-07-29)
MD
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" flags 2>/dev/null) \
    || fail "fm-project-mode.sh failed on a registry line carrying a lane token"
  [ "$out" = "no-mistakes on" ] || fail "a lane token changed the registered posture: got '$out'"
  pass "fm-memory-mcp: a lane:<name> registry token leaves the registered delivery posture unchanged"
}

# --- serve and the protocol surface ------------------------------------------

test_serve_refuses_to_start_on_a_failed_preflight() {
  local dir out status
  dir="$TMP_ROOT/serve-refusal"
  make_store "$dir" products 0
  write_record "$dir" products 1
  fm_memory_assert_scratch "$dir"
  out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | FM_HOME="$TMP_ROOT/no-such-home" "$MCP" serve --lane products --data-dir "$dir" 2>/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "serve started against an empty store"
  [ -z "$out" ] || fail "a refused server still spoke on the protocol channel: $out"
  pass "fm-memory-mcp: serve refuses to start against an empty store and answers nothing at all"
}

test_serve_lists_the_eight_tools() {
  local dir out names
  dir="$TMP_ROOT/tools"
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
  names=$(json_field "$out" "' '.join(t['name'] for t in d['result']['tools'])")
  [ "$names" = "memory_remember memory_recall memory_supersede memory_expire memory_get memory_lanes memory_cross_lane_recall memory_stats" ] \
    || fail "unexpected tool surface: $names"
  pass "fm-memory-mcp: serve exposes the eight bridge tools"
}

test_initialize_reports_the_protocol_and_server() {
  local dir out
  dir="$TMP_ROOT/initialize"
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products | head -n 1)
  [ "$(json_field "$out" "d['result']['protocolVersion']")" = "2024-11-05" ] || fail "unexpected protocol version"
  [ "$(json_field "$out" "d['result']['serverInfo']['name']")" = "fm-memory-mcp" ] || fail "unexpected server name"
  pass "fm-memory-mcp: initialize reports its protocol version and server identity"
}

test_unknown_tool_is_a_typed_error() {
  local dir out result
  dir="$TMP_ROOT/unknown-tool"
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_nope","arguments":{}}}' | tail -n 1)
  result=$(tool_payload "$out")
  [ "$(json_field "$result" "d['isError']")" = "True" ] || fail "an unknown tool was not flagged as an error"
  [ "$(json_field "$result" "d['payload']['error']['code']")" = "unknown_tool" ] || fail "unknown tool code missing"
  pass "fm-memory-mcp: an unknown tool answers a typed error, not an empty success"
}

test_cross_lane_write_is_refused() {
  local dir out result
  dir="$TMP_ROOT/cross-write"
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"x","lane":"personal"}}}' \
    | tail -n 1)
  result=$(tool_payload "$out")
  [ "$(json_field "$result" "d['isError']")" = "True" ] || fail "a cross-lane write was not flagged as an error"
  [ "$(json_field "$result" "d['payload']['error']['code']")" = "cross_lane_write_refused" ] \
    || fail "a cross-lane write was not refused by code"
  pass "fm-memory-mcp: refuses to write a memory into a lane it does not serve"
}

test_cross_lane_read_requires_a_reason() {
  local dir out result
  dir="$TMP_ROOT/cross-read"
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_cross_lane_recall","arguments":{"query":"q","lane":"shared"}}}' \
    | tail -n 1)
  result=$(tool_payload "$out")
  [ "$(json_field "$result" "d['payload']['error']['code']")" = "reason_required" ] \
    || fail "a reasonless cross-lane read was allowed"
  pass "fm-memory-mcp: a cross-lane read without a stated reason is refused"
}

test_a_failing_store_never_answers_an_empty_success() {
  local dir out result
  dir="$TMP_ROOT/broken-store"
  # A structurally valid store the library cannot actually serve from. However
  # the write fails, it must come back flagged and typed - the eric-os failure
  # was an unflagged empty string that read exactly like "nothing matched".
  make_ready_lane "$dir" products
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"anything"}}}' \
    | tail -n 1)
  result=$(tool_payload "$out")
  [ "$(json_field "$result" "d['isError']")" = "True" ] || fail "a write against an unusable store was reported successful"
  [ "$(json_field "$result" "d['payload']['status']")" = "error" ] || fail "the failure was not status error"
  [ -n "$(json_field "$result" "d['payload']['error']['code']")" ] || fail "the failure carried no error code"
  pass "fm-memory-mcp: a store it cannot write answers a typed, flagged error"
}

# --- library-backed behavior -------------------------------------------------

test_provisioned_lane_writes_are_global_and_pinned() {
  local dir out row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the library-backed write test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the global-and-pinned write test"
    return
  fi
  dir="$TMP_ROOT/live-write"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A durable bridge memory.","project":"flags","memory_type":"decision","veracity":"stated","importance":0.9}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "the write failed: $out"
  [ "$(json_field "$out" "d['payload']['scope']")" = "global" ] || fail "a durable write did not default to global scope"
  [ "$(json_field "$out" "d['payload']['pinned']")" = "True" ] || fail "a durable write was not reported pinned"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$(json_field "$out" "d['payload']['id']")" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute(
    "SELECT scope, channel_id, veracity, memory_type, consolidated_at IS NOT NULL"
    " FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY
)
  [ "$row" = "global|flags|stated|decision|1" ] || fail "the stored row is not as written: $row"
  pass "fm-memory-mcp: a durable write lands global, channel-scoped, and pinned against the trim"
}

test_pinned_writes_survive_the_trim_that_deletes_unpinned_rows() {
  local dir first old survivors
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the trim-survival test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the trim-survival test"
    return
  fi
  dir="$TMP_ROOT/trim"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A memory that must outlive the 24h trim.","project":"flags"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  [ -n "$first" ] || fail "no id came back from the first write"

  # Age the bridge write past the trim window, and plant an unpinned control row
  # of the same age in the same session. The control is what proves the trim
  # actually ran; without it a surviving row proves nothing.
  old=$(python3 -c "from datetime import datetime, timedelta; print((datetime.now()-timedelta(hours=48)).isoformat())")
  python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" "$old" <<'PY'
import sqlite3, sys
db, first, old = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
conn.execute("UPDATE working_memory SET timestamp = ? WHERE id = ?", (old, first))
conn.execute(
    "INSERT INTO working_memory (id, content, source, timestamp, session_id, importance,"
    " scope, channel_id, consolidated_at)"
    " VALUES ('trim_control', 'unpinned control of the same age', 'test', ?, 'fm:bridge', 0.5,"
    " 'global', 'flags', NULL)", (old,))
conn.commit()
conn.close()
PY

  # One more write in the same session is what runs the trim.
  serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A later write, which runs the trim.","project":"flags"}}}' \
    >/dev/null

  survivors=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
pinned = conn.execute("SELECT count(*) FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()[0]
control = conn.execute("SELECT count(*) FROM working_memory WHERE id = 'trim_control'").fetchone()[0]
print(f"pinned={pinned} control={control}")
PY
)
  [ "$survivors" = "pinned=1 control=0" ] || fail "trim divergence not as expected: $survivors"
  pass "fm-memory-mcp: a pinned bridge write survives the 24h trim that deletes an unpinned row beside it"
}

test_supersede_marks_the_old_memory_and_links_the_replacement() {
  local dir first replacement row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the supersession test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the supersession test"
    return
  fi
  dir="$TMP_ROOT/supersede"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"The original standing decision.","project":"flags","memory_type":"decision"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")

  replacement=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"The revised standing decision.\",\"project\":\"flags\",\"memory_type\":\"decision\"}}}" \
    | tail -n 1)
  replacement=$(tool_payload "$replacement")
  [ "$(json_field "$replacement" "d['isError']")" = "False" ] || fail "supersede failed: $replacement"
  replacement=$(json_field "$replacement" "d['payload']['id']")

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT superseded_by, valid_until IS NOT NULL FROM working_memory WHERE id = ?",
                 (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY
)
  [ "$row" = "$replacement|1" ] || fail "the superseded row was not linked and expired: $row"
  pass "fm-memory-mcp: supersede writes the replacement first, then links and expires the old memory"
}

test_supersede_refuses_identical_content_and_leaves_the_memory_readable() {
  local dir first out row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the identical-content supersede test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the identical-content supersede test"
    return
  fi
  dir="$TMP_ROOT/supersede-identical"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  # The store dedupes on (session_id, content), so re-sending the same content
  # updates the target in place and returns its own id. Superseding it by itself
  # would expire the memory and hide it from every read.
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A standing decision worth keeping.","project":"flags","memory_type":"decision"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  [ -n "$first" ] || fail "no id came back from the first write"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"A standing decision worth keeping.\",\"project\":\"other-project\",\"importance\":0.9,\"memory_type\":\"observation\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] || fail "superseding a memory with its own content was reported successful: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "supersede_noop" ] || fail "the refusal was not typed supersede_noop: $out"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY_ROW'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute(
    "SELECT superseded_by IS NULL, valid_until IS NULL, channel_id, importance, memory_type"
    " FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY_ROW
)
  # "untouched" has to mean the whole row: the dedupe update would also move the
  # memory out of its project channel and overwrite its importance and type.
  [ "$row" = "1|1|flags|0.5|decision" ] || fail "the refused supersede still mutated the memory: $row"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"memory_id\":\"$first\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "the memory was unreadable after a refused supersede: $out"
  pass "fm-memory-mcp: superseding a memory with its own content is refused and leaves it readable"
}

test_expiring_a_superseded_memory_keeps_its_replacement_link() {
  local dir first replacement out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the expire-chain test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the expire-chain test"
    return
  fi
  dir="$TMP_ROOT/expire-chain"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"The decision before it was revised.","project":"flags"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  [ -n "$first" ] || fail "no id came back from the first write"

  replacement=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"The decision after it was revised.\",\"project\":\"flags\"}}}" \
    | tail -n 1)
  replacement=$(tool_payload "$replacement")
  [ "$(json_field "$replacement" "d['isError']")" = "False" ] || fail "supersede failed: $replacement"
  replacement=$(json_field "$replacement" "d['payload']['id']")

  # Expiring an already-superseded memory must not erase the pointer that makes
  # the supersession chain queryable as history.
  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_expire\",\"arguments\":{\"memory_id\":\"$first\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "expiring a superseded memory failed: $out"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"memory_id\":\"$first\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['payload']['memory']['superseded_by']")" = "$replacement" ] \
    || fail "expiring the memory erased its link to the replacement: $out"
  pass "fm-memory-mcp: expiring an already-superseded memory keeps its link to the replacement"
}

test_a_session_scoped_write_is_readable_and_expirable_under_the_same_session() {
  local dir written id out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the session-override test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the session-override test"
    return
  fi
  dir="$TMP_ROOT/session-override"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  # session_id is provenance on the way in; it must also be what the read and
  # expire paths match on, or a session-scoped write is unreachable by the very
  # client that just made it.
  written=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A session-scoped note from another agent.","scope":"session","session_id":"other-agent"}}}' \
    | tail -n 1)
  written=$(tool_payload "$written")
  [ "$(json_field "$written" "d['isError']")" = "False" ] || fail "the session-scoped write failed: $written"
  id=$(json_field "$written" "d['payload']['id']")
  [ -n "$id" ] || fail "no id came back from the session-scoped write"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"memory_id\":\"$id\",\"session_id\":\"other-agent\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "a session-scoped memory could not be read back under its own session: $out"
  [ "$(json_field "$out" "d['payload']['memory']['session_id']")" = "other-agent" ] || fail "the memory did not record the overridden session: $out"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_expire\",\"arguments\":{\"memory_id\":\"$id\",\"session_id\":\"other-agent\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "a session-scoped memory could not be expired under its own session: $out"
  pass "fm-memory-mcp: a session-scoped write is readable and expirable under the session it names"
}

test_a_lane_is_never_visible_to_another_lanes_recall() {
  local dir out count
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the lane-containment test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the lane-containment test"
    return
  fi
  dir="$TMP_ROOT/containment"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning products failed"
  fm_memory_mcp "$dir" provision --lane personal >/dev/null || fail "provisioning personal failed"
  serve_rpc "$dir" personal \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Zarquon is the personal-lane distinctive term."}}}' \
    >/dev/null

  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Zarquon","top_k":20}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "recall failed: $out"
  count=$(json_field "$out" "sum(1 for r in d['payload']['results'] if 'Zarquon' in r['content'])")
  [ "$count" = "0" ] || fail "another lane's memory leaked into this lane's recall"
  # Awareness is the sanctioned cross-lane surface, and it carries titles only.
  count=$(json_field "$out" "sum(1 for t in d['payload']['awareness'] if len(t['title']) > 120)")
  [ "$count" = "0" ] || fail "cross-lane awareness returned more than a title"
  pass "fm-memory-mcp: one lane's memories never reach another lane's recall, only its awareness titles"
}

test_the_default_bank_is_never_touched() {
  local dir
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the default-bank test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the default-bank test"
    return
  fi
  # Hermes owns the default bank. A full provision-and-write cycle must leave it
  # non-existent, which is what proves the bridge never opened it - the library
  # creates a store the moment anything opens one.
  dir="$TMP_ROOT/default-bank"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"a write that must not reach the default bank"}}}' \
    >/dev/null
  assert_present "$dir/banks/lane-products/mnemosyne.db" "the lane bank was not written"
  assert_absent "$dir/mnemosyne.db" "the bridge created or opened the default bank"
  pass "fm-memory-mcp: a full write cycle never opens the default bank"
}

test_lanes_tells_a_wiped_sibling_apart_from_an_empty_one() {
  local dir line payload states
  # The awareness list is the whole result of memory_lanes, so a sibling bank
  # that was wiped contributes nothing - exactly what a genuinely quiet lane
  # contributes. Requirement 2 forbids those sharing a shape, so each lane has
  # to carry the state it proved.
  dir="$TMP_ROOT/wiped-sibling"
  make_ready_lane "$dir" products 2
  make_ready_lane "$dir" shared 2
  # personal was provisioned and then wiped: its record survives, its rows do not.
  make_store "$dir" personal 0
  write_record "$dir" personal 4

  line=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_lanes","arguments":{}}}' \
    | tail -n 1)
  payload=$(tool_payload "$line")
  [ "$(json_field "$payload" "d['isError']")" = "False" ] || fail "one broken sibling took memory_lanes down: $payload"
  states=$(json_field "$payload" "','.join(sorted(f\"{l['lane']}={l['state']}\" for l in d['payload']['lanes']))")
  case "$states" in
    *"personal=store_empty"*) ;;
    *) fail "the wiped sibling was not reported as a refused store: $states" ;;
  esac
  case "$states" in
    *"shared=ready"*) ;;
    *) fail "the healthy sibling was not reported ready: $states" ;;
  esac
  case "$states" in
    *"brand-business=unprovisioned"*) ;;
    *) fail "a lane with no bank at all was not reported unprovisioned: $states" ;;
  esac
  # The serving lane's own awareness still works, and the wiped lane contributed
  # no titles - which is only readable as a failure because of its state.
  [ "$(json_field "$payload" "sum(1 for t in d['payload']['titles'] if t['lane'] == 'personal')")" = "0" ] \
    || fail "a store that failed its floor still contributed titles"
  [ "$(json_field "$payload" "d['count']>0 if False else sum(1 for t in d['payload']['titles'] if t['lane']=='shared')")" != "0" ] \
    || fail "the healthy sibling contributed no titles"
  pass "fm-memory-mcp: a wiped sibling lane is reported broken, not silently empty"
}

test_stats_names_the_lane_bank_and_leaves_no_stray_directory() {
  local dir before after payload line
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the stats test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the stats test"
    return
  fi
  dir="$TMP_ROOT/stats"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  before=$(find "$dir/banks/lane-products" -type d | sort)

  line=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_stats","arguments":{}}}' \
    | tail -n 1)
  payload=$(tool_payload "$line")
  [ "$(json_field "$payload" "d['isError']")" = "False" ] || fail "memory_stats failed: $payload"
  # The library's own bank list is rooted at the parent of the database it reads,
  # which for a lane bank is that bank's own directory - so it names the default
  # bank this bridge never opens. The bridge owns this field.
  [ "$(json_field "$payload" "d['payload']['stats']['banks']")" = "['lane-products']" ] \
    || fail "stats did not name the lane bank it is serving: $payload"
  [ "$(json_field "$payload" "d['payload']['preflight']['store_verified']")" = "True" ] \
    || fail "stats did not carry a verified preflight: $payload"

  after=$(find "$dir/banks/lane-products" -type d | sort)
  [ "$before" = "$after" ] || fail "memory_stats left a stray directory under the bank dir: $after"
  pass "fm-memory-mcp: memory_stats names the served bank and leaves no stray directory"
}

test_the_same_content_is_never_relocated_out_of_its_project() {
  local dir first second row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the cross-project dedupe test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the cross-project dedupe test"
    return
  fi
  # The store dedupes on (session_id, content) and overwrites the matched row's
  # channel, so re-asserting alpha's memory under beta would move it out of
  # alpha, where alpha's recall can never reach it again.
  dir="$TMP_ROOT/cross-project-dedupe"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Ship on Fridays.","project":"alpha"}}}' \
    | tail -n 1)
  first=$(tool_payload "$first")
  [ "$(json_field "$first" "d['isError']")" = "False" ] || fail "the first write failed: $first"
  first=$(json_field "$first" "d['payload']['id']")

  second=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Ship on Fridays.","project":"beta"}}}' \
    | tail -n 1)
  second=$(tool_payload "$second")
  [ "$(json_field "$second" "d['isError']")" = "True" ] || fail "the same content was accepted under a second project: $second"
  [ "$(json_field "$second" "d['payload']['error']['code']")" = "duplicate_in_other_project" ] \
    || fail "the refusal was not typed duplicate_in_other_project: $second"
  assert_contains "$second" "alpha" "the refusal did not name the project that already holds the content"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT channel_id, consolidated_at IS NOT NULL FROM working_memory WHERE id = ?",
                 (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY
)
  [ "$row" = "alpha|1" ] || fail "the refused write still relocated or unpinned the memory: $row"

  # And alpha can still recall what alpha wrote.
  second=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Fridays","project":"alpha","include_awareness":false}}}' \
    | tail -n 1)
  second=$(tool_payload "$second")
  [ "$(json_field "$second" "sum(1 for r in d['payload']['results'] if r['id'] == '$first')")" = "1" ] \
    || fail "the memory left the project that wrote it: $second"
  pass "fm-memory-mcp: re-asserting content under a second project is refused, not relocated"
}

test_supersede_refuses_content_the_store_matched_onto_the_target() {
  local dir first out row blobs
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the sanitized-supersede test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the sanitized-supersede test"
    return
  fi
  # The library rewrites a data: URI to a content-addressed stub before it
  # dedupes, so two writes of the same URI collide on content the caller never
  # sees. A guard that compares what the caller sent cannot catch that; only the
  # id that came back can.
  dir="$TMP_ROOT/sanitized-supersede"
  mkdir -p "$dir"
  # A scratch home, so a regressed blob pin writes bytes here rather than into
  # the operator's shared tree. The library's embedding cache is hardcoded to
  # ~/.hermes/cache, so that one subtree is lent back to keep the test from
  # re-downloading a model; nothing else under this home is shared.
  export FM_MEMORY_TEST_HOME="$TMP_ROOT/scratch-home"
  mkdir -p "$FM_MEMORY_TEST_HOME/.hermes"
  [ -d "$HOME/.hermes/cache" ] && ln -sfn "$HOME/.hermes/cache" "$FM_MEMORY_TEST_HOME/.hermes/cache"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"

  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==","project":"flags"}}}' \
    | tail -n 1)
  first=$(tool_payload "$first")
  [ "$(json_field "$first" "d['isError']")" = "False" ] || fail "the data-URI write failed: $first"
  first=$(json_field "$first" "d['payload']['id']")

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==\",\"project\":\"flags\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] || fail "a self-matching supersession was reported successful: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "supersede_noop" ] \
    || fail "the refusal was not typed supersede_noop: $out"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT superseded_by IS NULL, valid_until IS NULL FROM working_memory WHERE id = ?",
                 (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY
)
  [ "$row" = "1|1" ] || fail "the memory was superseded by itself and is now invisible to recall: $row"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"memory_id\":\"$first\"}}}" \
    | tail -n 1)
  [ "$(json_field "$(tool_payload "$out")" "d['isError']")" = "False" ] || fail "the memory was unreadable after the refusal: $out"

  # The extracted bytes belong beside the lane bank, never in the shared tree
  # the library defaults to.
  blobs=$(find "$dir/banks/lane-products/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$blobs" != "0" ] || fail "the extracted payload did not land beside the lane bank"
  assert_absent "$FM_MEMORY_TEST_HOME/.hermes/mnemosyne" \
    "blob bytes were written to the library's default home tree instead of the lane"
  unset FM_MEMORY_TEST_HOME
  pass "fm-memory-mcp: a supersession the store matched onto its target is refused, and blobs stay in the lane"
}

test_recall_honors_the_session_it_is_told_to_act_as() {
  local dir out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the recall-session test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the recall-session test"
    return
  fi
  # session_id is documented as the one to pass to every call that must reach a
  # row. Recall has to accept it and act as it, and say which session it used.
  dir="$TMP_ROOT/recall-session"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Zarquon is the session-scoped marker.","project":"sess","scope":"session","session_id":"other-agent"}}}' \
    >/dev/null

  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Zarquon","project":"sess","session_id":"other-agent","include_awareness":false}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "recall as another session failed: $out"
  [ "$(json_field "$out" "d['payload']['session_id']")" = "other-agent" ] \
    || fail "recall did not act as the session it was given: $out"
  [ "$(json_field "$out" "sum(1 for r in d['payload']['results'] if 'Zarquon' in r['content'])")" = "1" ] \
    || fail "a session-scoped write was not recallable under its own session: $out"

  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Zarquon","project":"sess","include_awareness":false}}}' \
    | tail -n 1)
  [ "$(json_field "$(tool_payload "$out")" "d['payload']['session_id']")" = "fm:bridge" ] \
    || fail "recall without a session_id did not report the server's own session: $out"
  pass "fm-memory-mcp: recall acts as the session it is told to act as, and reports it"
}

test_extracted_content_is_never_relocated_out_of_its_project() {
  local dir first second row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the extracted-content dedupe test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the extracted-content dedupe test"
    return
  fi
  # The store rewrites a data: URI to a content-addressed stub before it dedupes,
  # so two projects sending the same payload collide on content neither of them
  # sent. A cross-project guard keyed on what the caller wrote cannot see that,
  # and the row leaves the project that wrote it without a word.
  dir="$TMP_ROOT/extracted-dedupe"
  mkdir -p "$dir"
  export FM_MEMORY_TEST_HOME="$TMP_ROOT/extracted-home"
  mkdir -p "$FM_MEMORY_TEST_HOME/.hermes"
  [ -d "$HOME/.hermes/cache" ] && ln -sfn "$HOME/.hermes/cache" "$FM_MEMORY_TEST_HOME/.hermes/cache"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"

  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB","project":"alpha"}}}' \
    | tail -n 1)
  first=$(tool_payload "$first")
  [ "$(json_field "$first" "d['isError']")" = "False" ] || fail "the first extracted write failed: $first"
  first=$(json_field "$first" "d['payload']['id']")

  second=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB","project":"beta"}}}' \
    | tail -n 1)
  second=$(tool_payload "$second")
  [ "$(json_field "$second" "d['isError']")" = "True" ] \
    || fail "the same extracted payload was accepted under a second project: $second"
  [ "$(json_field "$second" "d['payload']['error']['code']")" = "duplicate_in_other_project" ] \
    || fail "the refusal was not typed duplicate_in_other_project: $second"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT channel_id FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()
print(r[0])
PY
)
  [ "$row" = "alpha" ] || fail "the extracted memory was relocated out of the project that wrote it: $row"
  unset FM_MEMORY_TEST_HOME
  pass "fm-memory-mcp: extracted content is refused under a second project, not relocated"
}

test_reasserting_a_superseded_memory_is_refused_not_reported_durable() {
  local dir first replacement out row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the retired-reassert test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the retired-reassert test"
    return
  fi
  # The store's dedupe updates a matched row in place and leaves superseded_by
  # and valid_until untouched, so re-asserting a retired memory's text would
  # report a pinned durable write for a row every recall filters out.
  dir="$TMP_ROOT/reassert-superseded"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Ship on Fridays.","project":"alpha"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  [ -n "$first" ] || fail "no id came back from the first write"

  replacement=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"Ship on Tuesdays.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  replacement=$(tool_payload "$replacement")
  [ "$(json_field "$replacement" "d['isError']")" = "False" ] || fail "supersede failed: $replacement"
  replacement=$(json_field "$replacement" "d['payload']['id']")

  # The decision reverts, so the agent re-asserts the original text.
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Ship on Fridays.","project":"alpha"}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] \
    || fail "re-asserting a superseded memory was reported as a durable write: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "duplicate_is_retired" ] \
    || fail "the refusal was not typed duplicate_is_retired: $out"
  assert_contains "$out" "superseded" "the refusal did not name the state the memory is actually in"
  assert_contains "$out" "$first" "the refusal did not name the retired memory"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT superseded_by, valid_until IS NOT NULL FROM working_memory WHERE id = ?",
                 (sys.argv[2],)).fetchone()
print("|".join(str(x) for x in r))
PY
)
  # Refused means untouched: the retirement stands and nothing was revived.
  [ "$row" = "$replacement|1" ] || fail "the refused write still touched the retired memory: $row"
  pass "fm-memory-mcp: re-asserting a superseded memory is refused, never reported durable"
}

test_reasserting_an_expired_memory_is_refused_not_reported_durable() {
  local dir first out row
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the expired-reassert test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the expired-reassert test"
    return
  fi
  # memory_expire retires a row the same way, with no replacement, so it reaches
  # the same dedupe path.
  dir="$TMP_ROOT/reassert-expired"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"The staging cluster is on the old image.","project":"alpha"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  [ -n "$first" ] || fail "no id came back from the first write"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_expire\",\"arguments\":{\"memory_id\":\"$first\"}}}" \
    | tail -n 1)
  [ "$(json_field "$(tool_payload "$out")" "d['isError']")" = "False" ] || fail "expire failed: $out"

  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"The staging cluster is on the old image.","project":"alpha"}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] \
    || fail "re-asserting an expired memory was reported as a durable write: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "duplicate_is_retired" ] \
    || fail "the refusal was not typed duplicate_is_retired: $out"
  assert_contains "$out" "expired" "the refusal did not name the state the memory is actually in"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
r = conn.execute("SELECT valid_until IS NOT NULL FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()
print(r[0])
PY
)
  [ "$row" = "1" ] || fail "the refused write revived the expired memory: $row"
  pass "fm-memory-mcp: re-asserting an expired memory is refused, never reported durable"
}

test_a_memory_with_a_future_shelf_life_is_still_writable() {
  local dir out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the shelf-life test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the shelf-life test"
    return
  fi
  # valid_until in the future is a shelf life, not a retirement; only a past one
  # takes a memory out of recall.
  local future
  dir="$TMP_ROOT/shelf-life"
  mkdir -p "$dir"
  future=$(python3 -c "from datetime import datetime, timedelta; print((datetime.now()+timedelta(days=30)).isoformat())")
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_remember\",\"arguments\":{\"content\":\"The trial ends next month.\",\"project\":\"alpha\",\"valid_until\":\"$future\"}}}" \
    >/dev/null
  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_remember\",\"arguments\":{\"content\":\"The trial ends next month.\",\"project\":\"alpha\",\"valid_until\":\"$future\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] \
    || fail "a memory that has not expired yet was refused as retired: $out"
  pass "fm-memory-mcp: a future shelf life is not a retirement"
}

test_superseding_an_already_superseded_memory_is_refused() {
  local dir first second out row live
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the chain-guard test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the chain-guard test"
    return
  fi
  # invalidate() rewrites valid_until and superseded_by unconditionally, so a
  # second supersede of the same target would point it at the newer row and
  # leave the first replacement live beside it - two rows claiming one fact,
  # and the original audit link gone.
  dir="$TMP_ROOT/supersede-chain"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Deploys go out on Monday.","project":"alpha"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")

  second=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"Deploys go out on Tuesday.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  second=$(tool_payload "$second")
  [ "$(json_field "$second" "d['isError']")" = "False" ] || fail "the first supersede failed: $second"
  second=$(json_field "$second" "d['payload']['id']")

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"Deploys go out on Wednesday.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] \
    || fail "superseding an already-superseded memory was accepted: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "supersede_target_retired" ] \
    || fail "the refusal was not typed supersede_target_retired: $out"
  assert_contains "$out" "$second" "the refusal did not name the live replacement to act on instead"

  row=$(python3 - "$dir/banks/lane-products/mnemosyne.db" "$first" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute("SELECT superseded_by FROM working_memory WHERE id = ?", (sys.argv[2],)).fetchone()[0])
PY
)
  [ "$row" = "$second" ] || fail "the refused supersede rewrote the existing chain: $row"

  # Exactly one live row still claims the fact, and it is the first replacement.
  live=$(python3 - "$dir/banks/lane-products/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
rows = conn.execute(
    "SELECT id FROM working_memory WHERE content LIKE 'Deploys go out%'"
    " AND superseded_by IS NULL AND valid_until IS NULL").fetchall()
print(" ".join(r[0] for r in rows))
PY
)
  [ "$live" = "$second" ] || fail "the fact is claimed by something other than the single live replacement: $live"
  pass "fm-memory-mcp: superseding an already-superseded memory is refused, and its chain stands"
}

test_a_valid_until_already_in_the_past_is_refused() {
  local dir out rows
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the past-shelf-life test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the past-shelf-life test"
    return
  fi
  # A row whose valid_until has passed is filtered out of every recall, so
  # reporting that write pinned and durable is the success-shaped unreachable
  # write the whole contract forbids.
  dir="$TMP_ROOT/past-shelf-life"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A fact that was already stale when written.","project":"alpha","valid_until":"2020-01-01T00:00:00"}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] \
    || fail "a memory that expired before it was written was reported durable: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "valid_until_in_the_past" ] \
    || fail "the refusal was not typed valid_until_in_the_past: $out"

  rows=$(python3 - "$dir/banks/lane-products/mnemosyne.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute("SELECT count(*) FROM working_memory WHERE content LIKE 'A fact that was already stale%'").fetchone()[0])
PY
)
  [ "$rows" = "0" ] || fail "the refused write still landed a row: $rows"
  pass "fm-memory-mcp: a valid_until already in the past is refused, not written and reported durable"
}

test_a_malformed_valid_until_is_refused() {
  local dir out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the malformed-shelf-life test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the malformed-shelf-life test"
    return
  fi
  # The store never parses this field, it compares it as text, so 'next week'
  # would silently become permanent or immediately dead by its first character.
  dir="$TMP_ROOT/malformed-shelf-life"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"A fact with a hand-written shelf life.","project":"alpha","valid_until":"next week"}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "True" ] || fail "a malformed valid_until was accepted verbatim: $out"
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "invalid_argument" ] \
    || fail "the refusal was not typed invalid_argument: $out"
  pass "fm-memory-mcp: a malformed valid_until is refused rather than compared as text"
}

test_a_non_canonical_shelf_life_is_recallable_not_dead_on_arrival() {
  local dir spaced offset out
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the canonical-shelf-life test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the canonical-shelf-life test"
    return
  fi
  # The store never parses this field: it holds the string and every recall
  # filters it with a text compare against an ISO timestamp. A space separator
  # sorts below 'T', so a same-day deadline written that way is dead the moment
  # it lands even though the clock says hours away; an offset timestamp sorts by
  # its wall-clock digits rather than the instant it names. Anything reported
  # pinned and durable has to actually be recallable.
  #
  # Both values are the last second of today, which is what puts the separator
  # and the offset digits where the compare actually reaches them - a later date
  # would sort correctly whatever follows it. Within the final minute of the day
  # there is no same-day future second, so the value rolls to tomorrow and the
  # assertions still hold, just without that pressure.
  dir="$TMP_ROOT/canonical-shelf-life"
  mkdir -p "$dir"
  spaced=$(python3 -c "
from datetime import datetime, timedelta
now = datetime.now()
end = now.replace(hour=23, minute=59, second=59, microsecond=0)
if end <= now + timedelta(seconds=30):
    end += timedelta(days=1)
print(end.strftime('%Y-%m-%d %H:%M:%S'))")
  offset=$(python3 -c "
from datetime import datetime, timedelta
now = datetime.now().astimezone()
end = now.replace(hour=23, minute=59, second=59, microsecond=0)
if end <= now + timedelta(seconds=30):
    end += timedelta(days=1)
print(end.isoformat())")
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_remember\",\"arguments\":{\"content\":\"Zarquon holds until the space-separated deadline.\",\"project\":\"alpha\",\"valid_until\":\"$spaced\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "a space-separated future timestamp was refused: $out"

  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_remember\",\"arguments\":{\"content\":\"Quuxbar holds until the offset deadline.\",\"project\":\"alpha\",\"valid_until\":\"$offset\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['isError']")" = "False" ] || fail "a timezone-aware future timestamp was refused: $out"

  # The write was reported durable, so recall has to be able to return it.
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Zarquon","project":"alpha","include_awareness":false}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "sum(1 for r in d['payload']['results'] if 'Zarquon' in r['content'])")" = "1" ] \
    || fail "a write reported pinned and durable was already expired to recall: $out"

  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"Quuxbar","project":"alpha","include_awareness":false}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "sum(1 for r in d['payload']['results'] if 'Quuxbar' in r['content'])")" = "1" ] \
    || fail "an offset-timestamp write reported durable was already expired to recall: $out"
  pass "fm-memory-mcp: a non-canonical future shelf life is stored recallable, not dead on arrival"
}

test_retired_refusals_name_the_live_head_of_the_chain() {
  local dir first second third out hint
  if ! library_available; then
    echo "note: mnemosyne not importable under $(command -v python3); skipping the chain-head test" >&2
    pass "fm-memory-mcp: mnemosyne not installed, skipping the chain-head test"
    return
  fi
  # A fact revised twice leaves a chain: X -> Y -> Z. Y is retired, so pointing
  # a caller at Y just earns another refusal; only Z is actionable.
  dir="$TMP_ROOT/chain-head"
  mkdir -p "$dir"
  fm_memory_mcp "$dir" provision --lane products >/dev/null || fail "provisioning failed"
  first=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Standups are at nine.","project":"alpha"}}}' \
    | tail -n 1)
  first=$(json_field "$(tool_payload "$first")" "d['payload']['id']")
  second=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"Standups are at ten.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  second=$(json_field "$(tool_payload "$second")" "d['payload']['id']")
  third=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$second\",\"content\":\"Standups are at eleven.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  third=$(tool_payload "$third")
  [ "$(json_field "$third" "d['isError']")" = "False" ] || fail "superseding the live replacement failed: $third"
  third=$(json_field "$third" "d['payload']['id']")
  [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] || fail "the chain was not built: $first $second $third"

  # Re-asserting the oldest text must point at the head, not at the middle.
  out=$(serve_rpc "$dir" products \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_remember","arguments":{"content":"Standups are at nine.","project":"alpha"}}}' \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "duplicate_is_retired" ] \
    || fail "re-asserting retired content was not refused: $out"
  hint=$(json_field "$out" "d['payload']['error']['hint']")
  case "$hint" in
    *"$third"*) ;;
    *) fail "the refusal did not name the live head of the chain: $hint" ;;
  esac
  case "$hint" in
    *"$second"*) fail "the refusal pointed at a replacement that is itself retired: $hint" ;;
    *) ;;
  esac

  # And so must a supersede of the oldest row.
  out=$(serve_rpc "$dir" products \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_supersede\",\"arguments\":{\"memory_id\":\"$first\",\"content\":\"Standups are at noon.\",\"project\":\"alpha\"}}}" \
    | tail -n 1)
  out=$(tool_payload "$out")
  [ "$(json_field "$out" "d['payload']['error']['code']")" = "supersede_target_retired" ] \
    || fail "superseding a retired target was not refused: $out"
  hint=$(json_field "$out" "d['payload']['error']['hint']")
  case "$hint" in
    *"$third"*) ;;
    *) fail "the supersede refusal did not name the live head of the chain: $hint" ;;
  esac
  case "$hint" in
    *"$second"*) fail "the supersede refusal pointed at a retired row: $hint" ;;
    *) ;;
  esac
  pass "fm-memory-mcp: refusals point at the live head of a chain, never at a retired link"
}

test_preflight_refuses_missing_data_dir
test_preflight_refuses_missing_bank
test_preflight_refuses_unprovisioned_bank
test_preflight_refuses_empty_store
test_preflight_refuses_wiped_store_below_recorded_floor
test_preflight_refuses_foreign_database
test_preflight_passes_a_ready_lane
test_preflight_reads_a_wal_store_with_no_live_writer
test_preflight_reads_a_data_dir_whose_path_holds_uri_metacharacters
test_awareness_attaches_a_bank_whose_path_holds_a_quote
test_refuses_unknown_lane
test_refuses_unresolved_lane
test_resolves_lane_from_the_project_registry
test_registry_lane_token_does_not_disturb_the_delivery_posture
test_serve_refuses_to_start_on_a_failed_preflight
test_serve_lists_the_eight_tools
test_initialize_reports_the_protocol_and_server
test_unknown_tool_is_a_typed_error
test_cross_lane_write_is_refused
test_cross_lane_read_requires_a_reason
test_a_failing_store_never_answers_an_empty_success
test_provisioned_lane_writes_are_global_and_pinned
test_pinned_writes_survive_the_trim_that_deletes_unpinned_rows
test_supersede_marks_the_old_memory_and_links_the_replacement
test_supersede_refuses_identical_content_and_leaves_the_memory_readable
test_expiring_a_superseded_memory_keeps_its_replacement_link
test_a_session_scoped_write_is_readable_and_expirable_under_the_same_session
test_a_lane_is_never_visible_to_another_lanes_recall
test_the_default_bank_is_never_touched
test_lanes_tells_a_wiped_sibling_apart_from_an_empty_one
test_stats_names_the_lane_bank_and_leaves_no_stray_directory
test_the_same_content_is_never_relocated_out_of_its_project
test_supersede_refuses_content_the_store_matched_onto_the_target
test_recall_honors_the_session_it_is_told_to_act_as
test_extracted_content_is_never_relocated_out_of_its_project
test_reasserting_a_superseded_memory_is_refused_not_reported_durable
test_reasserting_an_expired_memory_is_refused_not_reported_durable
test_a_memory_with_a_future_shelf_life_is_still_writable
test_superseding_an_already_superseded_memory_is_refused
test_a_valid_until_already_in_the_past_is_refused
test_a_malformed_valid_until_is_refused
test_a_non_canonical_shelf_life_is_recallable_not_dead_on_arrival
test_retired_refusals_name_the_live_head_of_the_chain
