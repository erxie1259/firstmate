#!/usr/bin/env bash
# Inspect the Codex seats this home can dispatch on.
# Usage: fm-codex-seat.sh list                       print every configured seat
#        fm-codex-seat.sh check                      validate config/codex-seats only
#        fm-codex-seat.sh path <seat> codex|pi       print one validated store dir
#        fm-codex-seat.sh env <seat> <harness> [<model>]
#                                                    print the exact launch env prefix
#        fm-codex-seat.sh quota [--json] [<seat>...] per-seat quota windows
#        fm-codex-seat.sh mirror <seat> [codex|pi]   build a seat's shared-config mirror
#
# A seat is one Codex subscription seat with its own usage windows. This script
# is read-only apart from `mirror`, which only creates symlinks inside the seat's
# own store. bin/fm-codex-seat-lib.sh owns the config format, the seat-to-env
# mapping, the credential validation, and the mirror allowlist;
# docs/configuration.md "Codex seats" owns the operator-facing contract.
#
# list     One line per seat: `<name> codex=<dir>[ pi=<dir>]`, plus a trailing
#          `credential=present|missing` per store so a seat that still needs its
#          one-time sign-in is visible without running a spawn.
# check    Parse-only validation. Exit 0 when the file is well formed, 1 with the
#          exact reason otherwise, and 3 when no seat file exists at all (which
#          is the ordinary single-seat home, not an error).
# path     Fails closed when the seat, its directory, or its auth.json is absent.
# env      The same prefix bin/fm-spawn.sh puts in front of the launch command, so
#          a seat can be verified without spawning. It exits non-zero for a
#          harness/model tuple that spends no Codex seat rather than printing an
#          empty prefix that would read as success.
# quota    Runs `CODEX_HOME=<seat home> quota-axi --provider codex` once per seat,
#          which is the documented way to read one seat's own windows. Codex
#          OAuth identity comes from the store CODEX_HOME points at, so each seat
#          reports its own five-hour and weekly windows. --json emits one JSON
#          object per line: {"seat","codexHome","quota"}. No credential is read,
#          printed, or written. A seat whose read fails is reported and the
#          remaining seats are still printed; the exit status is non-zero.
# mirror   Creates the seat's store directory and symlinks the shared,
#          credential-free entries from the primary store. It never copies,
#          reads, or removes a credential, and it refuses to replace anything
#          already there that is not the exact link it would create. The seat's
#          own one-time sign-in stays the captain's to run:
#            Codex CLI:  CODEX_HOME=<seat codex dir> codex login --device-auth
#            Pi:         PI_CODING_AGENT_DIR=<seat pi dir> pi
#                        then `/login` and select ChatGPT Plus/Pro (Codex)
#          (Pi's supported subscription login is `/login` in interactive mode;
#          see Pi's own docs/providers.md "Subscriptions".)
#          The primary stores it mirrors FROM are ~/.codex and ~/.pi/agent.
#          FM_CODEX_SEAT_PRIMARY_CODEX_HOME and FM_CODEX_SEAT_PRIMARY_PI_DIR
#          override them, which is how the tests mirror fixture stores instead of
#          the captain's real ones; they are not an operating knob.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-codex-seat-lib.sh
. "$SCRIPT_DIR/fm-codex-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# fm_quota_axi_compatible's bounded form requires fm_run_timed to be defined,
# and refuses rather than falling back to an unbounded probe without it.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-codex-seat: %s\n' "$*" >&2
  exit 1
}

# The library already printed the concrete reason on stderr (its failures cross a
# command substitution, where a returned global would be lost), so a refusal here
# adds no second line.
refused() {
  exit 1
}

credential_state() {
  if fm_codex_seat_credential_present "$1"; then printf 'present\n'; else printf 'missing\n'; fi
}

cmd_list() {
  local records name home pi line
  records=$(fm_codex_seat_records "$CONFIG") || refused
  while IFS='	' read -r name home pi; do
    [ -n "$name" ] || continue
    line="$name codex=$home credential=$(credential_state "$home")"
    [ -z "$pi" ] || line="$line pi=$pi pi-credential=$(credential_state "$pi")"
    printf '%s\n' "$line"
  done <<EOF
$records
EOF
}

cmd_check() {
  local file
  file=$(fm_codex_seat_config_path "$CONFIG")
  if [ ! -f "$file" ]; then
    printf 'no seat configuration at %s; launches use the ambient Codex store\n' "$file"
    exit 3
  fi
  fm_codex_seat_records "$CONFIG" >/dev/null || refused
  printf '%s is well formed (%s)\n' "$file" "$(fm_codex_seat_names "$CONFIG" | tr '\n' ' ')"
}

cmd_path() {
  local seat=${1:-} which=${2:-} dir
  [ -n "$seat" ] && [ -n "$which" ] || { usage; exit 2; }
  dir=$(fm_codex_seat_dir "$CONFIG" "$seat" "$which") || refused
  printf '%s\n' "$dir"
}

cmd_env() {
  local seat=${1:-} harness=${2:-} model=${3:-} prefix
  [ -n "$seat" ] && [ -n "$harness" ] || { usage; exit 2; }
  prefix=$(fm_codex_seat_env_prefix "$CONFIG" "$seat" "$harness" "$model") \
    || refused
  # Trim the single trailing separator the launch prefix carries.
  printf '%s\n' "${prefix% }"
}

quota_for_seat() {
  local name=$1 home=$2 json=$3 out
  local args=(--provider codex)
  [ -z "$json" ] || args+=(--json)
  if ! out=$(CODEX_HOME="$home" quota-axi "${args[@]}" 2>&1); then
    printf 'fm-codex-seat: seat %s quota read failed:\n%s\n' "$name" "$out" >&2
    return 1
  fi
  if [ -n "$json" ]; then
    printf '%s' "$out" | jq -c --arg seat "$name" --arg home "$home" \
      '{seat: $seat, codexHome: $home, quota: .}' || return 1
  else
    printf '== seat %s (%s=%s) ==\n%s\n' "$name" "$FM_CODEX_SEAT_CODEX_ENV" "$home" "$out"
  fi
}

cmd_quota() {
  local records name home pi status=0 matched
  local json='' wanted=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --) shift; break ;;
      -*) usage; exit 2 ;;
      *) break ;;
    esac
  done
  wanted=$*
  fm_quota_axi_compatible 10 \
    || die "quota-axi $FM_QUOTA_AXI_MIN or newer is required to read per-seat windows"
  if [ -n "$json" ] && ! command -v jq >/dev/null 2>&1; then
    die "--json needs jq to wrap each seat's report"
  fi
  records=$(fm_codex_seat_records "$CONFIG") || refused
  matched=0
  while IFS='	' read -r name home pi; do
    [ -n "$name" ] || continue
    if [ -n "$wanted" ]; then
      case " $wanted " in
        *" $name "*) ;;
        *) continue ;;
      esac
    fi
    matched=$((matched + 1))
    quota_for_seat "$name" "$home" "$json" || status=1
  done <<EOF
$records
EOF
  if [ "$matched" -eq 0 ]; then
    die "no configured seat matched: $wanted"
  fi
  return "$status"
}

cmd_mirror() {
  local seat=${1:-} which=${2:-} record name home pi source target out
  [ -n "$seat" ] || { usage; exit 2; }
  record=$(fm_codex_seat_record "$CONFIG" "$seat") || refused
  IFS='	' read -r name home pi <<EOF
$record
EOF
  case "$which" in
    ''|codex|pi) ;;
    *) die "mirror takes codex or pi, not '$which'" ;;
  esac
  if [ -z "$which" ] || [ "$which" = codex ]; then
    source=${FM_CODEX_SEAT_PRIMARY_CODEX_HOME:-${HOME:-}/.codex}
    if [ "$home" = "$source" ]; then
      printf 'seat %s: codex store IS the primary store (%s); nothing to mirror\n' "$name" "$home"
    else
      printf 'seat %s: codex store %s -> mirror of %s\n' "$name" "$home" "$source"
      out=$(fm_codex_seat_mirror "$source" "$home" codex) || refused
      printf '%s\n' "$out" | sed 's/^/  /'
    fi
  fi
  if [ -z "$which" ] || [ "$which" = pi ]; then
    if [ -z "$pi" ]; then
      if [ "$which" = pi ]; then
        die "seat $name declares no Pi agent dir; add a third field to its line in $(fm_codex_seat_config_path "$CONFIG")"
      fi
      printf 'seat %s: no Pi agent dir declared; skipping the Pi mirror\n' "$name"
      return 0
    fi
    source=${FM_CODEX_SEAT_PRIMARY_PI_DIR:-${HOME:-}/.pi/agent}
    if [ "$pi" = "$source" ]; then
      printf 'seat %s: pi store IS the primary store (%s); nothing to mirror\n' "$name" "$pi"
    else
      printf 'seat %s: pi store %s -> mirror of %s\n' "$name" "$pi" "$source"
      out=$(fm_codex_seat_mirror "$source" "$pi" pi) || refused
      printf '%s\n' "$out" | sed 's/^/  /'
    fi
  fi
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  check) shift; cmd_check "$@" ;;
  path) shift; cmd_path "$@" ;;
  env) shift; cmd_env "$@" ;;
  quota) shift; cmd_quota "$@" ;;
  mirror) shift; cmd_mirror "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
