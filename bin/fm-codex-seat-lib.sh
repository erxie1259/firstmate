# shellcheck shell=bash
# Codex seat resolution: the single owner of the config/codex-seats format, of
# which launch environment variable carries a seat, and of the per-seat
# credential validation every consumer performs before a launch.
# Usage: . bin/fm-codex-seat-lib.sh
#
# A "seat" is one Codex subscription seat in the captain's Codex team workspace.
# Each seat has its own usage windows, so dispatch can move work to a seat with
# headroom instead of waiting on a reset. Seats are captain-private local
# configuration; docs/configuration.md "Codex seats" owns the operator-facing
# contract and bin/fm-codex-seat.sh is the inspectable CLI over these functions.
#
# config/codex-seats format, one seat per line:
#     <name> <codex-home> [<pi-agent-dir>]
# Fields are whitespace-separated, `#` starts a comment line, blank lines are
# ignored, and a leading `~/` in either path expands against $HOME. `name` is
# [A-Za-z0-9] followed by [A-Za-z0-9._-]; `default` is refused because an absent
# seat already means "launch exactly as before, with no seat environment".
#
# Two consumers must never share one seat's credential file: Codex OAuth refresh
# tokens rotate, so a second reader of the same auth.json can log the first one
# out. Every duplicate path in the file is therefore a hard parse error, and the
# Pi side of a seat gets its OWN login rather than a copied token.
#
# Every function refuses rather than falling back to another seat, because a
# silent fallback would spend the wrong seat's quota under the captain's chosen
# one. A refusal prints its concrete reason on stderr through
# fm_codex_seat_fail and also leaves it in FM_CODEX_SEAT_ERROR.

FM_CODEX_SEATS_FILE=codex-seats
# Set by every function below and read by its caller before reporting.
# shellcheck disable=SC2034  # consumed by sourcing scripts, not by this file
FM_CODEX_SEAT_ERROR=''

# The environment variable each consuming runtime reads for its own store.
# Verified 2026-09-25: codex-cli reads CODEX_HOME, and Pi 0.83.0 reads
# PI_CODING_AGENT_DIR (docs/verification/dispatch-auth.md).
FM_CODEX_SEAT_CODEX_ENV=CODEX_HOME
FM_CODEX_SEAT_PI_ENV=PI_CODING_AGENT_DIR

# Entries a seat mirror may symlink back to the primary store. Everything else,
# including every credential file and every per-seat mutable record (sessions,
# caches, trust decisions, logs), stays the seat's own.
FM_CODEX_SEAT_CODEX_MIRROR='config.toml AGENTS.md agents hooks hooks.json plugins rules skills'
FM_CODEX_SEAT_PI_MIRROR='settings.json models.json extensions skills themes prompts bin npm'
FM_CODEX_SEAT_CREDENTIAL=auth.json

# fm_codex_seat_credential_present <store-dir>
# A store counts as signed in only when its credential file holds something.
# An EMPTY JSON object does not: Pi 0.83.0 creates `{}` in a fresh agent dir the
# first time it runs there (verified 2026-09-25), and treating that as a
# credential would launch a worker that sits on a login prompt no one will answer,
# which supervision reads as a wedged agent rather than a missing login.
fm_codex_seat_credential_present() {
  local file=$1/$FM_CODEX_SEAT_CREDENTIAL body
  [ -s "$file" ] || return 1
  body=$(tr -d '[:space:]' < "$file" 2>/dev/null) || return 1
  case "$body" in
    ''|'{}'|'null') return 1 ;;
  esac
  return 0
}

# Report a refusal exactly once, on stderr, and set the reason for a caller that
# did not run this function in a command substitution. Printing here is what makes
# the reason survive: most callers DO capture stdout, and a global set inside that
# subshell never reaches them.
fm_codex_seat_fail() {
  FM_CODEX_SEAT_ERROR=$1
  printf 'codex-seat: %s\n' "$1" >&2
  return 1
}

fm_codex_seat_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Path to this home's seat config.
fm_codex_seat_config_path() {
  printf '%s/%s\n' "${1%/}" "$FM_CODEX_SEATS_FILE"
}

fm_codex_seat_configured() {
  [ -f "$(fm_codex_seat_config_path "$1")" ]
}

fm_codex_seat_name_valid() {
  case "$1" in
    ''|default) return 1 ;;
    [A-Za-z0-9]) return 0 ;;
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "${1#?}" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_codex_seat_expand_path() {
  # A literal leading tilde in the config file, expanded against $HOME here
  # because the file is read rather than evaluated by a shell.
  # shellcheck disable=SC2088  # the tilde is data being expanded, not a path to run
  case "$1" in
    '~') printf '%s\n' "${HOME:-}" ;;
    '~/'*) printf '%s/%s\n' "${HOME:-}" "${1:2}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# fm_codex_seat_records <config-dir>
# Print one validated, TAB-separated record per configured seat:
#     <name><TAB><codex-home><TAB><pi-agent-dir or empty>
# Paths are expanded but NOT required to exist here: existence and credentials
# are a per-launch check (fm_codex_seat_dir), so `list` and `check` can still
# describe a seat whose directory has not been created yet.
fm_codex_seat_records() {
  local config=$1 file line lineno=0 name home pi extra seen_name seen_path
  local out=''
  file=$(fm_codex_seat_config_path "$config")
  FM_CODEX_SEAT_ERROR=
  if [ ! -f "$file" ]; then
    fm_codex_seat_fail "no seat configuration at $file"
    return 1
  fi
  seen_name=
  seen_path=
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    # `read` rather than `set --`: a seat path may legitimately contain a glob
    # character, and word-splitting an unquoted expansion would expand it against
    # the working directory. A fourth field lands whole in `extra`, which is what
    # the arity check below reports.
    IFS=$' \t' read -r name home pi extra <<< "$line"
    if [ -n "$extra" ]; then
      fm_codex_seat_fail "$file line $lineno: expected '<name> <codex-home> [<pi-agent-dir>]', found extra field '$extra'"
      return 1
    fi
    if ! fm_codex_seat_name_valid "$name"; then
      fm_codex_seat_fail "$file line $lineno: '$name' is not a usable seat name (letters, digits, '.', '_', '-', starting with a letter or digit; 'default' is reserved for launching with no seat)"
      return 1
    fi
    if [ -z "$home" ]; then
      fm_codex_seat_fail "$file line $lineno: seat '$name' has no Codex home"
      return 1
    fi
    home=$(fm_codex_seat_expand_path "$home")
    case "$home" in
      /*) ;;
      *)
        fm_codex_seat_fail "$file line $lineno: seat '$name' Codex home must be absolute or start with '~/', found '$home'"
        return 1
        ;;
    esac
    home=${home%/}
    if [ -n "$pi" ]; then
      pi=$(fm_codex_seat_expand_path "$pi")
      case "$pi" in
        /*) ;;
        *)
          fm_codex_seat_fail "$file line $lineno: seat '$name' Pi agent dir must be absolute or start with '~/', found '$pi'"
          return 1
          ;;
      esac
      pi=${pi%/}
      if [ "$pi" = "$home" ]; then
        fm_codex_seat_fail "$file line $lineno: seat '$name' uses one directory as both its Codex home and its Pi agent dir; each store keeps its own credential file"
        return 1
      fi
    fi
    case " $seen_name " in
      *" $name "*)
        fm_codex_seat_fail "$file line $lineno: seat '$name' is declared more than once"
        return 1
        ;;
    esac
    case "$seen_path" in
      *"|$home|"*)
        fm_codex_seat_fail "$file line $lineno: seat '$name' reuses directory '$home' already claimed by another seat; two seats sharing one credential file would log each other out"
        return 1
        ;;
    esac
    if [ -n "$pi" ]; then
      case "$seen_path" in
        *"|$pi|"*)
          fm_codex_seat_fail "$file line $lineno: seat '$name' reuses directory '$pi' already claimed by another seat; two seats sharing one credential file would log each other out"
          return 1
          ;;
      esac
    fi
    seen_name="$seen_name $name"
    seen_path="$seen_path|$home|"
    [ -z "$pi" ] || seen_path="$seen_path|$pi|"
    out="$out$name	$home	$pi
"
  done < "$file"
  if [ -z "$out" ]; then
    fm_codex_seat_fail "$file declares no seats"
    return 1
  fi
  printf '%s' "$out"
}

# fm_codex_seat_names <config-dir>
fm_codex_seat_names() {
  local records
  records=$(fm_codex_seat_records "$1") || return 1
  printf '%s\n' "$records" | while IFS='	' read -r name _home _pi; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done
}

# fm_codex_seat_record <config-dir> <name>: the one seat's TSV record.
fm_codex_seat_record() {
  local config=$1 want=$2 records name home pi
  local known=''
  records=$(fm_codex_seat_records "$config") || return 1
  while IFS='	' read -r name home pi; do
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      printf '%s\t%s\t%s\n' "$name" "$home" "$pi"
      return 0
    fi
    known="$known $name"
  done <<EOF
$records
EOF
  fm_codex_seat_fail "unknown Codex seat '$want'; $(fm_codex_seat_config_path "$config") declares:${known:- none}"
  return 1
}

# fm_codex_seat_dir <config-dir> <name> <codex|pi>
# Print the seat's validated store directory for that runtime. Fails closed when
# the seat, the directory, or its credential file is missing, because a launch
# that silently used the ambient store would spend the wrong seat's quota.
fm_codex_seat_dir() {
  local config=$1 want=$2 which=$3 record name home pi dir label
  record=$(fm_codex_seat_record "$config" "$want") || return 1
  IFS='	' read -r name home pi <<EOF
$record
EOF
  case "$which" in
    codex) dir=$home; label="Codex home" ;;
    pi)
      dir=$pi
      label="Pi agent dir"
      if [ -z "$dir" ]; then
        fm_codex_seat_fail "Codex seat '$name' declares no Pi agent dir; add a third field to its line in $(fm_codex_seat_config_path "$config") and give that dir its own Pi login"
        return 1
      fi
      ;;
    *)
      fm_codex_seat_fail "unknown seat store '$which' (expected codex or pi)"
      return 1
      ;;
  esac
  if [ ! -d "$dir" ]; then
    fm_codex_seat_fail "Codex seat '$name' $label '$dir' does not exist"
    return 1
  fi
  if ! fm_codex_seat_credential_present "$dir"; then
    fm_codex_seat_fail "Codex seat '$name' has no credential at '$dir/$FM_CODEX_SEAT_CREDENTIAL'; sign that store in once before dispatching on this seat"
    return 1
  fi
  printf '%s\n' "$dir"
}

# fm_codex_seat_consumer <harness> <model>
# Print which store a seat reaches for this launch tuple: `codex` for the Codex
# CLI adapter, `pi` for a Pi-family adapter running an openai-codex model, and
# nothing (returning 1) for every tuple that does not spend a Codex seat.
fm_codex_seat_consumer() {
  local harness=$1 model=${2:-}
  case "$harness" in
    codex) printf 'codex\n'; return 0 ;;
    pi|pi-signed)
      case "$model" in
        openai-codex/*) printf 'pi\n'; return 0 ;;
      esac
      ;;
  esac
  return 1
}

# fm_codex_seat_env_prefix <config-dir> <name> <harness> <model>
# Print the exact `NAME='<dir>' ` launch prefix for this seat and tuple. This is
# the one place that turns a seat into launch environment, so bin/fm-spawn.sh and
# bin/fm-codex-seat.sh cannot drift apart.
fm_codex_seat_env_prefix() {
  local config=$1 want=$2 harness=$3 model=${4:-} consumer dir var
  FM_CODEX_SEAT_ERROR=
  local tuple="harness '$harness'"
  [ -z "$model" ] || tuple="$tuple with model '$model'"
  if ! consumer=$(fm_codex_seat_consumer "$harness" "$model"); then
    fm_codex_seat_fail "$tuple does not use a Codex seat; a seat applies to harness codex, or a pi-family harness running an openai-codex/* model"
    return 1
  fi
  dir=$(fm_codex_seat_dir "$config" "$want" "$consumer") || return 1
  case "$consumer" in
    codex) var=$FM_CODEX_SEAT_CODEX_ENV ;;
    *) var=$FM_CODEX_SEAT_PI_ENV ;;
  esac
  printf '%s=%s ' "$var" "$(fm_codex_seat_shell_quote "$dir")"
}

# fm_codex_seat_mirror_entries <codex|pi>: the allowlist for that store.
fm_codex_seat_mirror_entries() {
  case "$1" in
    codex) printf '%s\n' "$FM_CODEX_SEAT_CODEX_MIRROR" ;;
    pi) printf '%s\n' "$FM_CODEX_SEAT_PI_MIRROR" ;;
    *) fm_codex_seat_fail "unknown seat store '$1' (expected codex or pi)"; return 1 ;;
  esac
}

# fm_codex_seat_mirror <source-dir> <target-dir> <codex|pi>
# Symlink the allowlisted shared entries of <source-dir> into <target-dir>,
# creating it when absent. It never reads, writes, copies, or removes a
# credential, never writes inside <source-dir>, and refuses to replace anything
# already in <target-dir> that is not the exact symlink it would create, so a
# store the captain set up by hand is never clobbered. Progress lines go to
# stdout; the caller decides how loud to be.
fm_codex_seat_mirror() {
  local source=$1 target=$2 which=$3 entries entry src_real target_real
  # shellcheck disable=SC2034 # Public failure reason consumed by the caller after sourcing.
  FM_CODEX_SEAT_ERROR=
  entries=$(fm_codex_seat_mirror_entries "$which") || return 1
  if [ ! -d "$source" ]; then
    fm_codex_seat_fail "mirror source '$source' does not exist"
    return 1
  fi
  src_real=$(CDPATH='' cd -- "$source" 2>/dev/null && pwd -P) || {
    fm_codex_seat_fail "mirror source '$source' cannot be resolved"
    return 1
  }
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ ! -d "$target" ] || [ -L "$target" ]; then
      fm_codex_seat_fail "mirror target '$target' exists and is not a directory"
      return 1
    fi
  elif ! mkdir -p "$target"; then
    fm_codex_seat_fail "mirror target '$target' could not be created"
    return 1
  fi
  chmod 700 "$target" 2>/dev/null || true
  target_real=$(CDPATH='' cd -- "$target" 2>/dev/null && pwd -P) || {
    fm_codex_seat_fail "mirror target '$target' cannot be resolved"
    return 1
  }
  if [ "$target_real" = "$src_real" ]; then
    fm_codex_seat_fail "mirror target and source are the same directory ($target_real); a seat needs its own store"
    return 1
  fi
  # shellcheck disable=SC2086  # deliberate word-splitting: the allowlist is a list
  set -- $entries
  for entry in "$@"; do
    if [ "$entry" = "$FM_CODEX_SEAT_CREDENTIAL" ]; then
      fm_codex_seat_fail "refusing to mirror the credential file '$entry'"
      return 1
    fi
    if [ ! -e "$src_real/$entry" ] && [ ! -L "$src_real/$entry" ]; then
      printf 'skipped %s (absent in %s)\n' "$entry" "$src_real"
      continue
    fi
    if [ -L "$target_real/$entry" ]; then
      if [ "$(readlink "$target_real/$entry")" = "$src_real/$entry" ]; then
        printf 'kept %s\n' "$entry"
        continue
      fi
      fm_codex_seat_fail "'$target_real/$entry' already links elsewhere; remove it by hand if the mirror should own it"
      return 1
    fi
    if [ -e "$target_real/$entry" ]; then
      fm_codex_seat_fail "'$target_real/$entry' already exists and is not a mirror link; remove it by hand if the mirror should own it"
      return 1
    fi
    if ! ln -s "$src_real/$entry" "$target_real/$entry"; then
      # shellcheck disable=SC2034 # Public failure reason consumed by the caller after sourcing.
      fm_codex_seat_fail "could not link $entry into '$target_real'"
      return 1
    fi
    printf 'linked %s\n' "$entry"
  done
  if fm_codex_seat_credential_present "$target_real"; then
    printf 'credential present (%s)\n' "$FM_CODEX_SEAT_CREDENTIAL"
  else
    printf 'credential MISSING (%s) - sign this store in before dispatching on it\n' "$FM_CODEX_SEAT_CREDENTIAL"
  fi
}
