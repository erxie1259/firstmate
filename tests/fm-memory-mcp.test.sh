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
  } | FM_HOME="$TMP_ROOT/no-such-home" "$MCP" serve --lane "$lane" --data-dir "$data_dir" 2>/dev/null
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

test_preflight_refuses_missing_data_dir
test_preflight_refuses_missing_bank
test_preflight_refuses_unprovisioned_bank
test_preflight_refuses_empty_store
test_preflight_refuses_wiped_store_below_recorded_floor
test_preflight_refuses_foreign_database
test_preflight_passes_a_ready_lane
test_preflight_reads_a_wal_store_with_no_live_writer
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
test_a_lane_is_never_visible_to_another_lanes_recall
test_the_default_bank_is_never_touched
