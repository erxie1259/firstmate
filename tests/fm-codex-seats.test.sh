#!/usr/bin/env bash
# Behavior tests for Codex seats: bin/fm-codex-seat-lib.sh's config contract and
# bin/fm-codex-seat.sh's inspection CLI.
#
# A seat is one Codex subscription seat with its own usage windows, so every
# refusal here protects the same property: work dispatched on one seat never
# quietly spends another seat's quota, and no credential is ever copied between
# two stores whose refresh tokens rotate independently.
#
# The quota cases drive a fake quota-axi so the per-seat read is proven by the
# CODEX_HOME each invocation actually receives, with no network call and no real
# account quota spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEAT="$ROOT/bin/fm-codex-seat.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-seats)

# new_home <name> -> echoes a case dir with an empty config/
new_home() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/config"
  printf '%s\n' "$dir"
}

# store <case-dir> <name> [--no-credential] -> echoes a seat store directory
store() {
  local dir="$1/stores/$2"
  mkdir -p "$dir"
  [ "${3:-}" = --no-credential ] || printf '{"fixture":"not-a-credential"}\n' > "$dir/auth.json"
  printf '%s\n' "$dir"
}

# seats <case-dir> <line...>
seats() {
  local dir=$1
  shift
  printf '%s\n' "$@" > "$dir/home/config/codex-seats"
}

run_seat() {  # <case-dir> <args...>
  local dir=$1
  shift
  env FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$SEAT" "$@" 2>&1
}

# A fake quota-axi that satisfies the version floor and reports which store the
# invocation was pointed at, so a per-seat read is observable without a network
# call or a real account.
install_fake_quota_axi() {  # <case-dir>
  local dir=$1 bin
  bin=$(fm_fakebin "$dir")
  cat > "$bin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'quota-axi 9.9.9\n'; exit 0 ;;
esac
if [ -n "${FM_FAKE_QUOTA_FAIL_HOME:-}" ] && [ "${CODEX_HOME:-}" = "$FM_FAKE_QUOTA_FAIL_HOME" ]; then
  printf 'quota-axi: cannot read that store\n' >&2
  exit 1
fi
for a in "$@"; do
  if [ "$a" = --json ]; then
    printf '{"providers":[{"provider":"codex","home":"%s"}]}\n' "${CODEX_HOME:-unset}"
    exit 0
  fi
done
printf 'codex store: %s\n' "${CODEX_HOME:-unset}"
SH
  chmod +x "$bin/quota-axi"
  printf '%s\n' "$bin"
}

test_absent_seat_file_is_the_ordinary_single_seat_home() {
  local dir out status
  dir=$(new_home absent)
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 3 "$status" "an absent seat file is a distinct outcome, not a validation failure"
  assert_contains "$out" "ambient Codex store" "check did not explain what an absent seat file means"

  out=$(run_seat "$dir" list)
  status=$?
  expect_code 1 "$status" "listing seats with no seat file must refuse rather than print nothing and succeed"
  assert_contains "$out" "no seat configuration at" "the refusal did not name the missing file"
  pass "an absent config/codex-seats is reported as the ambient single-seat home, never as a valid empty list"
}

test_list_shows_each_store_and_whether_it_is_signed_in() {
  local dir out status main selene selene_pi
  dir=$(new_home list)
  main=$(store "$dir" main)
  selene=$(store "$dir" selene)
  selene_pi=$(store "$dir" selene-pi --no-credential)
  seats "$dir" "main $main" "selene $selene $selene_pi"

  out=$(run_seat "$dir" list)
  status=$?
  expect_code 0 "$status" "listing a well-formed seat file should succeed"
  assert_contains "$out" "main codex=$main credential=present" "list did not report the main seat's store state"
  assert_contains "$out" "selene codex=$selene credential=present pi=$selene_pi pi-credential=missing" \
    "list did not distinguish a signed-in Codex store from a Pi store still awaiting its own login"
  pass "list prints every seat's stores and says which ones still need a sign-in"
}

test_malformed_seat_files_are_refused_with_their_reason() {
  local dir out status main alias_dir hardlink_dir pi_dir
  dir=$(new_home malformed)
  main=$(store "$dir" main)

  seats "$dir" "default $main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "'default' must not be usable as a seat name"
  assert_contains "$out" "'default' is not a usable seat name" "the refusal did not explain the reserved name"

  seats "$dir" "main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "a seat with no store must be refused"
  assert_contains "$out" "has no Codex home" "the refusal did not name the missing store"

  seats "$dir" "main relative/store"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "a relative store path must be refused"
  assert_contains "$out" "must be absolute" "the refusal did not explain the path requirement"

  seats "$dir" "main $main" "main $main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "a duplicate seat name must be refused"
  assert_contains "$out" "declared more than once" "the refusal did not name the duplicate seat"

  seats "$dir" "main $main" "selene $main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "two seats sharing one store must be refused"
  assert_contains "$out" "would log each other out" \
    "the refusal did not explain why two seats cannot share one credential file"

  seats "$dir" "main $main $main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "one directory used as both stores of a seat must be refused"
  assert_contains "$out" "each store keeps its own credential file" \
    "the refusal did not explain why the two stores of a seat must differ"

  pi_dir="$dir/stores/main-pi"
  mkdir -p "$pi_dir"
  ln "$main/auth.json" "$pi_dir/auth.json"
  seats "$dir" "main $main $pi_dir"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "a seat must not use one credential inode for Codex and Pi"
  assert_contains "$out" "uses one credential inode" \
    "the refusal did not identify the same-seat credential inode"

  alias_dir="$dir/stores/alias"
  ln -s "$main" "$alias_dir"
  seats "$dir" "main $main" "selene $alias_dir"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "two seats that resolve to one directory must be refused"
  assert_contains "$out" "would log each other out" \
    "the refusal did not compare existing stores by their resolved directory"

  seats "$dir" "main $main" "selene $main/../main"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "two seats that resolve through dot segments to one directory must be refused"
  assert_contains "$out" "would log each other out" \
    "the refusal did not normalize dot segments in existing stores"

  ln -s "$main/auth.json" "$dir/stores/shared-auth.json"
  mkdir -p "$dir/stores/selene"
  ln -s "$dir/stores/shared-auth.json" "$dir/stores/selene/auth.json"
  seats "$dir" "main $main" "selene $dir/stores/selene"
  out=$(run_seat "$dir" path selene codex)
  status=$?
  expect_code 1 "$status" "a symlinked credential must not authorize a seat"
  assert_contains "$out" "has no credential at" \
    "the refusal did not reject a credential symlink"

  hardlink_dir="$dir/stores/hardlink-selene"
  mkdir -p "$hardlink_dir"
  ln "$main/auth.json" "$hardlink_dir/auth.json"
  seats "$dir" "main $main" "selene $hardlink_dir"
  out=$(run_seat "$dir" check)
  status=$?
  expect_code 1 "$status" "hard-linked credentials must not authorize two seats"
  assert_contains "$out" "shares a credential inode" \
    "the refusal did not identify the shared credential inode"
  pass "every malformed seat file is refused with the concrete reason, never parsed loosely"
}

test_env_prints_the_exact_launch_prefix_per_runtime() {
  local dir out status codex_store pi_store
  dir=$(new_home env)
  codex_store=$(store "$dir" selene)
  pi_store=$(store "$dir" selene-pi)
  seats "$dir" "selene $codex_store $pi_store"

  out=$(run_seat "$dir" env selene codex)
  status=$?
  expect_code 0 "$status" "a codex seat env read should succeed"
  [ "$out" = "CODEX_HOME='$codex_store'" ] \
    || fail "codex env prefix mismatch, got: $out"

  out=$(run_seat "$dir" env selene pi openai-codex/gpt-5.6-sol)
  status=$?
  expect_code 0 "$status" "a pi seat env read on an openai-codex model should succeed"
  [ "$out" = "PI_CODING_AGENT_DIR='$pi_store'" ] \
    || fail "pi env prefix mismatch, got: $out"

  out=$(run_seat "$dir" env selene pi-signed openai-codex/gpt-5.6-sol)
  status=$?
  expect_code 0 "$status" "pi-signed must resolve the same seat axis as pi"
  [ "$out" = "PI_CODING_AGENT_DIR='$pi_store'" ] \
    || fail "pi-signed env prefix mismatch, got: $out"

  out=$(run_seat "$dir" env selene pi anthropic/claude-sonnet-5)
  status=$?
  expect_code 1 "$status" "a pi model outside the Codex family spends no seat and must refuse"
  assert_contains "$out" "does not use a Codex seat" "the refusal did not explain the model mismatch"

  out=$(run_seat "$dir" env selene claude)
  status=$?
  expect_code 1 "$status" "a harness that spends no Codex seat must refuse rather than print an empty prefix"
  assert_contains "$out" "does not use a Codex seat" "the refusal did not explain the harness mismatch"
  pass "env prints the one correct launch prefix per runtime and refuses every tuple that spends no seat"
}

test_a_store_without_a_credential_is_never_offered_for_a_launch() {
  local dir out status signed unsigned
  dir=$(new_home unsigned)
  signed=$(store "$dir" signed)
  unsigned=$(store "$dir" unsigned --no-credential)
  seats "$dir" "signed $signed" "unsigned $unsigned"

  out=$(run_seat "$dir" path unsigned codex)
  status=$?
  expect_code 1 "$status" "a store with no credential must not resolve for a launch"
  assert_contains "$out" "has no credential at" "the refusal did not name the missing credential"
  assert_not_contains "$out" "$signed" "the refusal must not offer another seat's store instead"

  # Pi writes an empty `{}` auth.json into a fresh agent dir, which is a created
  # file rather than a login; treating it as a credential would launch a worker
  # onto a login prompt nobody will answer.
  printf '{}\n' > "$unsigned/auth.json"
  out=$(run_seat "$dir" path unsigned codex)
  status=$?
  expect_code 1 "$status" "an empty JSON object must not count as a credential"
  assert_contains "$out" "has no credential at" "an empty credential file was accepted as a login"
  out=$(run_seat "$dir" list)
  assert_contains "$out" "unsigned codex=$unsigned credential=missing" \
    "list reported an empty credential file as a completed sign-in"

  out=$(run_seat "$dir" path signed pi)
  status=$?
  expect_code 1 "$status" "a seat with no declared Pi agent dir must refuse a Pi resolution"
  assert_contains "$out" "declares no Pi agent dir" "the refusal did not explain the missing Pi field"
  pass "an unsigned or undeclared store refuses rather than resolving to another seat"
}

test_quota_reads_each_seat_against_its_own_store() {
  local dir out status main selene fakebin
  dir=$(new_home quota)
  main=$(store "$dir" main)
  selene=$(store "$dir" selene)
  seats "$dir" "main $main" "selene $selene"
  fakebin=$(install_fake_quota_axi "$dir")

  out=$(PATH="$fakebin:$PATH" run_seat "$dir" quota)
  status=$?
  expect_code 0 "$status" "reading both seats' windows should succeed"
  assert_contains "$out" "== seat main (CODEX_HOME=$main) ==" "the main seat report is missing its header"
  assert_contains "$out" "codex store: $main" "the main seat was not read against its own store"
  assert_contains "$out" "codex store: $selene" "the second seat was not read against its own store"

  out=$(PATH="$fakebin:$PATH" run_seat "$dir" quota selene)
  status=$?
  expect_code 0 "$status" "reading one named seat should succeed"
  assert_contains "$out" "codex store: $selene" "the named seat was not read"
  assert_not_contains "$out" "codex store: $main" "a named seat read must not report every other seat"

  out=$(PATH="$fakebin:$PATH" run_seat "$dir" quota missing)
  status=$?
  expect_code 1 "$status" "naming a seat that is not configured must refuse"

  out=$(PATH="$fakebin:$PATH" FM_FAKE_QUOTA_FAIL_HOME="$main" run_seat "$dir" quota)
  status=$?
  expect_code 1 "$status" "one unreadable seat must make the run non-zero"
  assert_contains "$out" "codex store: $selene" \
    "one unreadable seat must not hide the seats that could be read"
  pass "quota reads every configured seat against its own store and reports a failed read without hiding the rest"
}

test_quota_json_wraps_each_seat_report() {
  local dir out status main selene fakebin
  dir=$(new_home quotajson)
  main=$(store "$dir" main)
  selene=$(store "$dir" selene)
  seats "$dir" "main $main" "selene $selene"
  fakebin=$(install_fake_quota_axi "$dir")
  command -v jq >/dev/null 2>&1 || { pass "quota --json skipped: jq is unavailable"; return 0; }

  out=$(PATH="$fakebin:$PATH" run_seat "$dir" quota --json)
  status=$?
  expect_code 0 "$status" "the JSON per-seat report should succeed"
  assert_contains "$out" "\"seat\":\"selene\"" "the JSON report did not label each seat"
  assert_contains "$out" "\"codexHome\":\"$selene\"" "the JSON report did not name each seat's store"
  printf '%s\n' "$out" | jq -e . >/dev/null || fail "each quota --json line must be valid JSON"
  pass "quota --json emits one labelled, valid JSON report per seat"
}

test_mirror_shares_config_and_never_touches_a_credential() {
  local dir out status source target source_real
  dir=$(new_home mirror)
  source="$dir/primary"
  target="$dir/stores/selene"
  mkdir -p "$source/skills"
  printf 'model = "x"\n' > "$source/config.toml"
  printf 'PRIMARY-TOKEN\n' > "$source/auth.json"
  seats "$dir" "selene $target"

  out=$(FM_CODEX_SEAT_PRIMARY_CODEX_HOME="$source" run_seat "$dir" mirror selene codex)
  status=$?
  expect_code 0 "$status" "mirroring a seat's Codex store should succeed"
  assert_contains "$out" "linked config.toml" "the mirror did not share the primary config"
  assert_contains "$out" "linked skills" "the mirror did not share the primary skills"
  assert_contains "$out" "credential MISSING" "the mirror must say the seat still needs its own sign-in"
  assert_absent "$target/auth.json" "the mirror must never create or copy a credential"
  # The mirror links the RESOLVED source path, so compare against that: the temp
  # root is reached through a symlinked /tmp on macOS.
  source_real=$(cd "$source" && pwd -P)
  [ "$(readlink "$target/config.toml")" = "$source_real/config.toml" ] \
    || fail "the mirror must link shared config back to the primary store"

  out=$(FM_CODEX_SEAT_PRIMARY_CODEX_HOME="$source" run_seat "$dir" mirror selene codex)
  status=$?
  expect_code 0 "$status" "re-running the mirror should be idempotent"
  assert_contains "$out" "kept config.toml" "a second mirror run must keep existing links rather than relinking"

  # An entry that exists in BOTH stores: the seat's copy was put there by hand and
  # must survive, because the mirror owns only the links it created itself.
  printf 'shared\n' > "$source/rules"
  printf 'HAND-WRITTEN\n' > "$target/rules"
  out=$(FM_CODEX_SEAT_PRIMARY_CODEX_HOME="$source" run_seat "$dir" mirror selene codex)
  status=$?
  expect_code 1 "$status" "the mirror must refuse to clobber a file the captain put there"
  assert_contains "$out" "already exists and is not a mirror link" "the refusal did not explain what it found"
  [ "$(cat "$target/rules")" = HAND-WRITTEN ] || fail "the mirror overwrote existing content"
  pass "mirror shares only credential-free config, is idempotent, and refuses to clobber existing content"
}

test_pi_mirror_uses_only_the_required_entries() {
  local dir out status source target
  dir=$(new_home pimirror)
  source="$dir/primary-pi"
  target="$dir/stores/selene-pi"
  mkdir -p "$source/extensions" "$source/skills" "$source/themes" "$source/prompts" "$source/bin" "$source/npm"
  printf '{}\n' > "$source/settings.json"
  printf '{}\n' > "$source/models.json"
  printf 'PRIMARY-TOKEN\n' > "$source/auth.json"
  seats "$dir" "selene $dir/stores/selene-codex $target"

  out=$(FM_CODEX_SEAT_PRIMARY_PI_DIR="$source" run_seat "$dir" mirror selene pi)
  status=$?
  expect_code 0 "$status" "mirroring a Pi store should succeed"
  assert_contains "$out" "linked settings.json" "the Pi mirror did not share settings.json"
  assert_contains "$out" "linked models.json" "the Pi mirror did not share models.json"
  assert_contains "$out" "linked extensions" "the Pi mirror did not share extensions"
  assert_contains "$out" "linked skills" "the Pi mirror did not share skills"
  assert_contains "$out" "linked themes" "the Pi mirror did not share themes"
  assert_absent "$target/prompts" "the Pi mirror must not share prompts"
  assert_absent "$target/bin" "the Pi mirror must not share bin"
  assert_absent "$target/npm" "the Pi mirror must not share npm"
  assert_absent "$target/auth.json" "the Pi mirror must never create or copy a credential"
  pass "the Pi mirror shares exactly the five required credential-free entries"
}

test_mirror_refuses_a_store_that_is_the_primary_store() {
  local dir out status source
  dir=$(new_home mirrorself)
  source="$dir/primary"
  mkdir -p "$source"
  printf 'x\n' > "$source/config.toml"
  seats "$dir" "selene $source"

  out=$(FM_CODEX_SEAT_PRIMARY_CODEX_HOME="$source" run_seat "$dir" mirror selene codex)
  status=$?
  expect_code 0 "$status" "a seat pointed at the primary store needs no mirror and is not an error"
  assert_contains "$out" "IS the primary store" "the report did not say why nothing was mirrored"
  pass "a seat whose store is the primary store is reported as needing no mirror"
}

test_absent_seat_file_is_the_ordinary_single_seat_home
test_list_shows_each_store_and_whether_it_is_signed_in
test_malformed_seat_files_are_refused_with_their_reason
test_env_prints_the_exact_launch_prefix_per_runtime
test_a_store_without_a_credential_is_never_offered_for_a_launch
test_quota_reads_each_seat_against_its_own_store
test_quota_json_wraps_each_seat_report
test_mirror_shares_config_and_never_touches_a_credential
test_pi_mirror_uses_only_the_required_entries
test_mirror_refuses_a_store_that_is_the_primary_store

echo "# all fm-codex-seats tests passed"
