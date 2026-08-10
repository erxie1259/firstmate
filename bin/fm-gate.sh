#!/usr/bin/env bash
# fm-gate.sh - mechanical post-run gates that check a finished task's own claims
# against what actually happened.
#
# bin/fm-teardown.sh already answers "did this work LAND?". Nothing answers "is
# the work real?", so a worker that reports completion for work it did not do is
# taken at its word. These gates answer only the second question. They are
# deterministic, cost no model tokens, and NEVER mutate anything: no commit, no
# branch change, no fetch, no cleanup. A stale local base ref is reported as the
# base that was used rather than refreshed.
#
# A gate failure is a stop-and-investigate signal, so every mismatch is named in
# full and the output stands alone without re-running the script.
#
# Usage:
#   fm-gate.sh <task-id> [--claims <file>] [--base <ref>] [--run-tests]
#   fm-gate.sh --help
#
# Options:
#   --claims <file>  Read the normalized claim record from <file> and skip claim
#                    source resolution. See "Claim sources" below.
#   --base <ref>     Compare the task branch against <ref> instead of the
#                    project's default branch.
#   --run-tests      Execute a declared tests_command. Without it the run stays
#                    strictly read-only and tests_pass reports SKIP.
#
# Exit status:
#   0  every applicable gate passed
#   1  at least one gate FAILED
#   2  usage error
#   3  inconclusive - a gate could not run, or there were no claims to check.
#      An unrunnable check must never look like a pass.
#
# Claim sources
# -------------
# Each source is one resolver function that writes the SAME normalized claim
# record; claims_resolve lists them in precedence order, and no gate below ever
# learns which source a claim came from.
#
#   file      an explicit --claims <file> record, used verbatim.
#   envelope  the crewmate's typed terminal envelope at data/<task-id>/envelope.json.
#             Declared and exhaustive, so an unclaimed touch FAILS. The envelope's
#             contract is owned by the bin/fm-brief.sh scaffold and parsed by
#             bin/fm-envelope-lib.sh; this script only consumes the result.
#   status    state/<task-id>.status prose. Heuristic and non-exhaustive: prose
#             never enumerates every changed file, so this source declares
#             files_changed_exhaustive=0 and unclaimed touches stay a note.
#
# The envelope outranks status prose because a declared exhaustive list is
# strictly better evidence than tokens scraped out of sentences. It is optional:
# a task without one resolves claims exactly as it did before envelopes existed.
#
# Normalized claim record (the format --claims reads, one key=value per line,
# blank lines and # comments ignored):
#
#   claim_source=<label>              required, free-form label for reporting
#   claim_confidence=declared|derived required; derived means heuristic
#   files_changed_exhaustive=0|1      required; 1 means the record lists EVERY
#                                     changed file, so an unclaimed touch fails
#   files_changed=<repo-relative path> repeatable, may be absent
#   tests_command=<shell command>     optional, run only under --run-tests
#   tests_run=<count>                 optional, a self-reported test count
#   tests_passed=<count>              optional, how many of those passed
#
# An unknown key is refused rather than ignored, so a claim producer cannot
# silently emit a field these gates do not honor.
#
# Deriving claims from status prose
# ---------------------------------
# Only `done:` and `working:` lines are read: those assert work, while
# `blocked:`, `paused:`, `needs-decision:`, and `failed:` lines describe
# obstacles and routinely name files that were deliberately NOT touched. The
# leading verb is parsed by bin/fm-classify-lib.sh, the one owner of that
# vocabulary, so the optional `[key=<slug>]` token is handled and a keyed line
# such as `working [key=phase]: ...` is read like any other.
#
# A token counts as a claimed path when it is path-shaped (a slash or a
# dot-extension, no `..`, not a bare number, not a URL) AND it is anchored in
# the repository. The anchor is what keeps incidental prose - a ref name, a
# version string, the name of a tool the worker merely RAN - out of the claim
# set. A nested token anchors on its parent directory existing in the tree at
# HEAD or at the base, so a file the worker said it created under an existing
# directory and did not create is still caught. A repo-root token has no such
# parent to distinguish it from any other dotted word, so it anchors only on
# being tracked or actually changed.
#
# That costs one case knowingly: a repo-root file claimed as newly created but
# never created is dropped rather than reported, because at the root there is
# no evidence separating that claim from prose about an unrelated file. A
# derived source that cries wolf gets ignored, which would cost more. An
# exhaustive claim source has no such gap.
#
# Gates
# -----
#   envelope_valid       A PRESENT data/<id>/envelope.json must parse and satisfy
#                        its contract. The envelope is optional, so its absence
#                        is N/A - never a failure and never a pass.
#   diff_matches_claims  The files the worker says it changed against the actual
#                        diff of its branch. Files claimed but untouched always
#                        FAIL. Files touched but unclaimed FAIL only for an
#                        exhaustive claim source and are otherwise a note.
#   artifacts_exist      A scout must have left a non-empty data/<id>/report.md.
#                        A ship must have commits on its branch. A secondmate is
#                        not a work deliverable, so the gate is not applicable.
#   tests_pass           A declared tests_command is verified only when the
#                        caller passes --run-tests; this script never guesses a
#                        test command. Failing that, a claim record carrying
#                        self-reported tests_run/tests_passed is checked for
#                        internal consistency and reported as unverified, since
#                        counts with no re-runnable command prove nothing.
#
# The task's recorded metadata supplies kind, worktree, and project; the branch
# is the worktree's checked-out branch. Any of those being absent makes the
# affected gate report CANNOT-RUN, never a pass. A worktree that has been
# returned and re-leased is detached on the project's default branch and no
# longer holds the task's work, so that too is CANNOT-RUN rather than a
# fabricated FAIL: run these gates while the task's worktree is still standing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-envelope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-envelope-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-gate: %s\n' "$*" >&2
  printf 'usage: fm-gate.sh <task-id> [--claims <file>] [--base <ref>] [--run-tests]\n' >&2
  exit 2
}

ID=
CLAIMS_FILE=
BASE_OVERRIDE=
RUN_TESTS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --claims)
      [ "$#" -ge 2 ] || die_usage "--claims requires a file path"
      CLAIMS_FILE=$2
      shift 2
      ;;
    --claims=*)
      CLAIMS_FILE=${1#--claims=}
      shift
      ;;
    --base)
      [ "$#" -ge 2 ] || die_usage "--base requires a git ref"
      BASE_OVERRIDE=$2
      shift 2
      ;;
    --base=*)
      BASE_OVERRIDE=${1#--base=}
      shift
      ;;
    --run-tests)
      RUN_TESTS=1
      shift
      ;;
    --)
      shift
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      [ -z "$ID" ] || die_usage "only one task id is accepted (got '$ID' and '$1')"
      ID=$1
      shift
      ;;
  esac
done

[ -n "$ID" ] || die_usage "a task id is required"
fm_task_id_path_safe "$ID" || die_usage "unsafe task id: $ID"
[ -z "$CLAIMS_FILE" ] || [ -f "$CLAIMS_FILE" ] || die_usage "claims file not found: $CLAIMS_FILE"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate.XXXXXX") || {
  printf 'fm-gate: cannot create a scratch directory\n' >&2
  exit 2
}
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- verdict accounting -----------------------------------------------------

PASSED=0
FAILED=0
SKIPPED=0
NOT_APPLICABLE=0
COULD_NOT_RUN=0

gate_result() {  # <gate-name> <PASS|FAIL|SKIP|N/A|CANNOT-RUN> [detail...]
  local name=$1 verdict=$2 detail
  shift 2
  printf 'GATE %s: %s\n' "$name" "$verdict"
  for detail in "$@"; do
    printf '  %s\n' "$detail"
  done
  case "$verdict" in
    PASS) PASSED=$((PASSED + 1)) ;;
    FAIL) FAILED=$((FAILED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    N/A) NOT_APPLICABLE=$((NOT_APPLICABLE + 1)) ;;
    CANNOT-RUN) COULD_NOT_RUN=$((COULD_NOT_RUN + 1)) ;;
  esac
}

# --- task record ------------------------------------------------------------

META="$STATE/$ID.meta"
STATUS_LOG="$STATE/$ID.status"
REPORT="$DATA/$ID/report.md"
ENVELOPE=$(fm_envelope_path "$DATA" "$ID")

printf 'task: %s\n' "$ID"
if [ ! -f "$META" ]; then
  printf 'CANNOT RUN: no recorded metadata for task %s at %s\n' "$ID" "$META" >&2
  printf 'verdict: INCONCLUSIVE (no task record to check claims against)\n'
  exit 3
fi

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
MODE=$(fm_meta_get "$META" mode)
[ -n "$MODE" ] || MODE=unrecorded
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
printf 'kind: %s  mode: %s\n' "$KIND" "$MODE"

# --- git plumbing (read-only) -----------------------------------------------

GIT_OK=0
if command -v git >/dev/null 2>&1; then
  GIT_OK=1
fi

WT_OK=0
if [ "$GIT_OK" -eq 1 ] && [ -n "$WT" ] && [ -d "$WT" ] \
  && git -C "$WT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  WT_OK=1
fi

# The compare tip is the recorded worktree's HEAD, and it must be a real branch.
# A returned or re-leased worktree sits detached on the project's default
# branch: judging a finished task's claims against that is meaningless, so the
# affected gates report CANNOT-RUN instead of a fabricated FAIL.
BRANCH=
BRANCH_WHY=
if [ "$WT_OK" -eq 1 ]; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$BRANCH" ]; then
    BRANCH_WHY="recorded worktree $WT is detached at $(git -C "$WT" rev-parse --short HEAD 2>/dev/null || printf 'an unknown commit'); it no longer holds this task's branch"
  fi
fi
BRANCH_OK=0
[ -n "$BRANCH" ] && BRANCH_OK=1

default_branch_name() {
  local ref branch
  [ -n "$PROJ" ] && [ -d "$PROJ" ] || return 1
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the compare base WITHOUT fetching, so the run stays read-only. The
# printed base is exactly what was compared against.
BASE=
BASE_WHY=
resolve_base() {
  local name
  if [ -n "$BASE_OVERRIDE" ]; then
    if git -C "$WT" rev-parse --verify --quiet "$BASE_OVERRIDE^{commit}" >/dev/null 2>&1; then
      BASE=$BASE_OVERRIDE
      BASE_WHY="explicit --base"
      return 0
    fi
    BASE_WHY="explicit --base $BASE_OVERRIDE does not resolve in $WT"
    return 1
  fi
  if ! name=$(default_branch_name); then
    BASE_WHY="cannot determine the project's default branch (expected origin/HEAD, main, or master in ${PROJ:-<unrecorded project>})"
    return 1
  fi
  if git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$name^{commit}" >/dev/null 2>&1; then
    BASE="refs/remotes/origin/$name"
    BASE_WHY="project default branch, last-fetched remote ref (not refreshed)"
    return 0
  fi
  if git -C "$WT" rev-parse --verify --quiet "refs/heads/$name^{commit}" >/dev/null 2>&1; then
    BASE="refs/heads/$name"
    BASE_WHY="project default branch, local ref"
    return 0
  fi
  BASE_WHY="default branch $name resolves in neither origin/$name nor refs/heads/$name"
  return 1
}

BASE_OK=0
if [ "$WT_OK" -eq 1 ] && [ "$BRANCH_OK" -eq 1 ] && resolve_base; then
  BASE_OK=1
fi

ACTUAL_CHANGED="$TMP_ROOT/actual-changed"
ACTUAL_CHANGED_COUNT=0
: > "$ACTUAL_CHANGED"
actual_changed_collect() {
  {
    # Committed branch work against the merge base, plus anything still
    # uncommitted in the worktree - staged, unstaged, and new files git would
    # accept. Ignored files stay out, so build output never reads as a touch.
    # Renames are split into their real paths so a claim naming either side is
    # judged honestly.
    git -C "$WT" diff --name-only --no-renames "$BASE...HEAD" -- 2>/dev/null
    git -C "$WT" diff --name-only --no-renames HEAD -- 2>/dev/null
    git -C "$WT" ls-files --others --exclude-standard 2>/dev/null
  } | LC_ALL=C sort -u > "$ACTUAL_CHANGED"
  ACTUAL_CHANGED_COUNT=$(grep -c . "$ACTUAL_CHANGED" 2>/dev/null) || ACTUAL_CHANGED_COUNT=0
  case "$ACTUAL_CHANGED_COUNT" in ''|*[!0-9]*) ACTUAL_CHANGED_COUNT=0 ;; esac
}
[ "$BASE_OK" -eq 1 ] && actual_changed_collect

# --- claim sources ----------------------------------------------------------

CLAIM_SOURCE=
CLAIM_CONFIDENCE=
CLAIM_EXHAUSTIVE=0
CLAIM_TESTS_COMMAND=
CLAIM_TESTS_RUN=
CLAIM_TESTS_PASSED=
CLAIMED_FILES="$TMP_ROOT/claimed-files"
: > "$CLAIMED_FILES"

# The envelope is read ONCE, here, so its verdict is the same fact the
# envelope_valid gate reports and the claim resolver acts on. Presence is tested
# with -e rather than -f: a path that exists but is not a readable regular file
# is a present-and-broken envelope, not an absent one.
ENVELOPE_PRESENT=0
ENVELOPE_STATUS=0
ENVELOPE_WHY=
if [ -e "$ENVELOPE" ]; then
  ENVELOPE_PRESENT=1
  ENVELOPE_WHY=$(fm_envelope_validate "$ENVELOPE") || ENVELOPE_STATUS=$?
fi

claim_record_read() {  # <file>
  local file=$1 line key value
  local source='' confidence='' exhaustive='' tests=''
  local tests_run='' tests_passed=''
  : > "$CLAIMED_FILES"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        printf 'fm-gate: claim record line is not key=value: %s\n' "$line" >&2
        return 1
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      claim_source) source=$value ;;
      claim_confidence) confidence=$value ;;
      files_changed_exhaustive) exhaustive=$value ;;
      files_changed) [ -z "$value" ] || printf '%s\n' "$value" >> "$CLAIMED_FILES" ;;
      tests_command) tests=$value ;;
      tests_run) tests_run=$value ;;
      tests_passed) tests_passed=$value ;;
      *)
        printf 'fm-gate: unknown claim record key: %s\n' "$key" >&2
        return 1
        ;;
    esac
  done < "$file"
  [ -n "$source" ] || { printf 'fm-gate: claim record is missing claim_source=\n' >&2; return 1; }
  case "$confidence" in
    declared|derived) ;;
    *) printf 'fm-gate: claim_confidence must be declared or derived, got "%s"\n' "$confidence" >&2; return 1 ;;
  esac
  case "$exhaustive" in
    0|1) ;;
    *) printf 'fm-gate: files_changed_exhaustive must be 0 or 1, got "%s"\n' "$exhaustive" >&2; return 1 ;;
  esac
  # Both counts are optional, but a present one must be a plain non-negative
  # integer: a count that cannot be compared is refused rather than dropped.
  for value in "$tests_run" "$tests_passed"; do
    case "$value" in
      ''|*[!0-9]*)
        [ -z "$value" ] || {
          printf 'fm-gate: tests_run and tests_passed must be non-negative integers, got "%s"\n' "$value" >&2
          return 1
        }
        ;;
    esac
  done
  if [ -n "$tests_run" ] && [ -n "$tests_passed" ] && [ "$tests_passed" -gt "$tests_run" ]; then
    printf 'fm-gate: tests_passed (%s) exceeds tests_run (%s)\n' "$tests_passed" "$tests_run" >&2
    return 1
  fi
  CLAIM_SOURCE=$source
  CLAIM_CONFIDENCE=$confidence
  CLAIM_EXHAUSTIVE=$exhaustive
  CLAIM_TESTS_COMMAND=$tests
  CLAIM_TESTS_RUN=$tests_run
  CLAIM_TESTS_PASSED=$tests_passed
  LC_ALL=C sort -u "$CLAIMED_FILES" -o "$CLAIMED_FILES"
}

# Every path tracked at HEAD or at the base, plus every actually changed path:
# the anchor set that keeps incidental prose out of a derived claim.
KNOWN_FILES="$TMP_ROOT/known-files"
KNOWN_DIRS="$TMP_ROOT/known-dirs"
anchor_sets_build() {
  {
    git -C "$WT" ls-tree -r --name-only HEAD 2>/dev/null
    git -C "$WT" ls-tree -r --name-only "$BASE" 2>/dev/null
    cat "$ACTUAL_CHANGED"
  } | LC_ALL=C sort -u > "$KNOWN_FILES"
  awk -F/ '{
    d = ""
    for (i = 1; i < NF; i++) {
      d = (i == 1) ? $i : d "/" $i
      print d
    }
  }' "$KNOWN_FILES" | LC_ALL=C sort -u > "$KNOWN_DIRS"
}

path_is_anchored() {  # <candidate>
  local candidate=$1 parent
  grep -qxF -- "$candidate" "$KNOWN_FILES" && return 0
  case "$candidate" in
    */*) parent=${candidate%/*} ;;
    # A repo-root token has no parent directory that could distinguish it from
    # any other dotted word in the prose, so the known-file check above is its
    # only anchor. See the header for what that trades away.
    *) return 1 ;;
  esac
  grep -qxF -- "$parent" "$KNOWN_DIRS"
}

path_is_shaped() {  # <candidate>
  local candidate=$1
  case "$candidate" in
    ''|-*|*/) return 1 ;;
    /*) return 1 ;;
    *..*) return 1 ;;
    *//*) return 1 ;;
    *[!A-Za-z0-9._/+-]*) return 1 ;;
  esac
  # Must look like a path: a directory separator or a dot-extension.
  case "$candidate" in
    */*) ;;
    *.[A-Za-z]*) ;;
    *) return 1 ;;
  esac
  # A bare number or version string is not a path.
  case "$candidate" in
    *[!0-9.]*) ;;
    *) return 1 ;;
  esac
  return 0
}

claims_from_file() {
  [ -n "$CLAIMS_FILE" ] || return 1
  claim_record_read "$CLAIMS_FILE" || exit 2
}

# The typed terminal envelope, when the crewmate left one that satisfies its
# contract. A present-but-invalid envelope is deliberately NOT used as a claim
# source: the envelope_valid gate reports it, and resolution falls through to
# status prose so the rest of the report still says something useful.
claims_from_envelope() {
  local record="$TMP_ROOT/envelope-claims"
  [ "$ENVELOPE_PRESENT" -eq 1 ] && [ "$ENVELOPE_STATUS" -eq 0 ] || return 1
  fm_envelope_claim_record "$ENVELOPE" > "$record" || return 1
  claim_record_read "$record" || exit 2
}

claims_from_status() {
  local record="$TMP_ROOT/status-claims" work="$TMP_ROOT/status-work" line token
  [ -f "$STATUS_LOG" ] || return 1
  [ "$WT_OK" -eq 1 ] && [ "$BASE_OK" -eq 1 ] || return 1
  anchor_sets_build
  # Only lines that assert work; obstacle lines routinely name files that were
  # deliberately not touched. Verb parsing is NOT re-implemented here:
  # bin/fm-classify-lib.sh owns it, so a keyed line such as
  # "working [key=phase]: ..." is recognized exactly as that contract defines,
  # and its verb and key token are stripped before tokenizing.
  : > "$work"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$(status_line_verb "$line")" in
      done|working)
        status_line_note "$line" >> "$work"
        printf '\n' >> "$work"
        ;;
    esac
  done < "$STATUS_LOG"
  {
    printf 'claim_source=status\n'
    printf 'claim_confidence=derived\n'
    printf 'files_changed_exhaustive=0\n'
    tr -c 'A-Za-z0-9._/+-' '\n' < "$work" \
      | sed -e 's#^\./##' -e 's/\.*$//' \
      | LC_ALL=C sort -u \
      | while IFS= read -r token; do
          [ -n "$token" ] || continue
          path_is_shaped "$token" || continue
          path_is_anchored "$token" || continue
          printf 'files_changed=%s\n' "$token"
        done
  } > "$record"
  claim_record_read "$record" || exit 2
}

# Claim sources in precedence order; the gates below never learn where a claim
# came from.
claims_resolve() {
  claims_from_file && return 0
  claims_from_envelope && return 0
  claims_from_status && return 0
  return 1
}

CLAIMS_OK=0
if claims_resolve; then
  CLAIMS_OK=1
fi

CLAIMED_COUNT=0
if [ "$CLAIMS_OK" -eq 1 ]; then
  CLAIMED_COUNT=$(grep -c . "$CLAIMED_FILES" 2>/dev/null || true)
  case "$CLAIMED_COUNT" in ''|*[!0-9]*) CLAIMED_COUNT=0 ;; esac
  if [ "$CLAIM_EXHAUSTIVE" -eq 1 ]; then
    printf 'claims: source=%s confidence=%s files=%s exhaustive=yes\n' \
      "$CLAIM_SOURCE" "$CLAIM_CONFIDENCE" "$CLAIMED_COUNT"
  else
    printf 'claims: source=%s confidence=%s files=%s exhaustive=no\n' \
      "$CLAIM_SOURCE" "$CLAIM_CONFIDENCE" "$CLAIMED_COUNT"
  fi
else
  printf 'claims: none resolved\n'
fi
if [ "$BASE_OK" -eq 1 ]; then
  printf 'base: %s (%s)\n' "$BASE" "$BASE_WHY"
fi

# --- gate: envelope_valid ---------------------------------------------------

gate_envelope_valid() {
  local summary
  if [ "$ENVELOPE_PRESENT" -ne 1 ]; then
    gate_result envelope_valid N/A \
      "no envelope at $ENVELOPE; the typed terminal envelope is optional"
    return
  fi
  case "$ENVELOPE_STATUS" in
    0)
      summary=$(fm_envelope_summary "$ENVELOPE" 2>/dev/null || true)
      if [ -n "$summary" ]; then
        gate_result envelope_valid PASS "$ENVELOPE" "$summary"
      else
        gate_result envelope_valid PASS "$ENVELOPE"
      fi
      ;;
    2)
      gate_result envelope_valid CANNOT-RUN "$ENVELOPE" "$ENVELOPE_WHY"
      ;;
    *)
      gate_result envelope_valid FAIL "$ENVELOPE" "$ENVELOPE_WHY" \
        "the envelope's contract is stated in this task's brief"
      ;;
  esac
}

# --- gate: diff_matches_claims ----------------------------------------------

gate_diff_matches_claims() {
  local missing extra details=() line failed=0
  if [ "$GIT_OK" -ne 1 ]; then
    gate_result diff_matches_claims CANNOT-RUN "git is not installed, so no diff can be read"
    return
  fi
  if [ "$WT_OK" -ne 1 ]; then
    gate_result diff_matches_claims CANNOT-RUN \
      "no readable task worktree with a commit: ${WT:-<no worktree recorded>}"
    return
  fi
  if [ "$BRANCH_OK" -ne 1 ]; then
    gate_result diff_matches_claims CANNOT-RUN "$BRANCH_WHY"
    return
  fi
  if [ "$BASE_OK" -ne 1 ]; then
    gate_result diff_matches_claims CANNOT-RUN "no comparable base: $BASE_WHY"
    return
  fi
  if [ "$CLAIMS_OK" -ne 1 ]; then
    gate_result diff_matches_claims CANNOT-RUN \
      "no claim source produced a record (no --claims file, and no readable status log at $STATUS_LOG)"
    return
  fi
  if [ "$CLAIMED_COUNT" -eq 0 ]; then
    gate_result diff_matches_claims CANNOT-RUN \
      "claim source '$CLAIM_SOURCE' names no changed files, so there is nothing to check against the diff" \
      "branch $BRANCH actually changed $ACTUAL_CHANGED_COUNT file(s) vs $BASE"
    return
  fi

  missing=$(LC_ALL=C comm -23 "$CLAIMED_FILES" "$ACTUAL_CHANGED" || true)
  extra=$(LC_ALL=C comm -13 "$CLAIMED_FILES" "$ACTUAL_CHANGED" || true)

  details+=("branch $BRANCH vs $BASE")
  details+=("claim source $CLAIM_SOURCE, confidence $CLAIM_CONFIDENCE")
  if [ -n "$missing" ]; then
    failed=1
    details+=("claimed but untouched:")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      details+=("  $line")
    done <<EOF
$missing
EOF
  fi
  if [ -n "$extra" ]; then
    if [ "$CLAIM_EXHAUSTIVE" -eq 1 ]; then
      failed=1
      details+=("touched but unclaimed:")
    else
      details+=("touched but unclaimed (note only: claim source '$CLAIM_SOURCE' does not enumerate every file):")
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      details+=("  $line")
    done <<EOF
$extra
EOF
  fi
  if [ "$failed" -eq 1 ]; then
    gate_result diff_matches_claims FAIL "${details[@]}"
  else
    details+=("every claimed file appears in the diff")
    gate_result diff_matches_claims PASS "${details[@]}"
  fi
}

# --- gate: artifacts_exist --------------------------------------------------

gate_artifacts_exist() {
  local commits
  case "$KIND" in
    secondmate)
      gate_result artifacts_exist N/A "a secondmate is a persistent home, not a work deliverable"
      return
      ;;
    scout)
      if [ ! -f "$REPORT" ]; then
        gate_result artifacts_exist FAIL "scout deliverable is missing: $REPORT"
        return
      fi
      if ! grep -q '[^[:space:]]' "$REPORT" 2>/dev/null; then
        gate_result artifacts_exist FAIL "scout deliverable exists but is empty: $REPORT"
        return
      fi
      gate_result artifacts_exist PASS "scout report present and non-empty: $REPORT"
      return
      ;;
  esac
  if [ "$GIT_OK" -ne 1 ]; then
    gate_result artifacts_exist CANNOT-RUN "git is not installed, so branch commits cannot be counted"
    return
  fi
  if [ "$WT_OK" -ne 1 ]; then
    gate_result artifacts_exist CANNOT-RUN \
      "no readable task worktree with a commit: ${WT:-<no worktree recorded>}"
    return
  fi
  if [ "$BRANCH_OK" -ne 1 ]; then
    gate_result artifacts_exist CANNOT-RUN "$BRANCH_WHY"
    return
  fi
  if [ "$BASE_OK" -ne 1 ]; then
    gate_result artifacts_exist CANNOT-RUN "no comparable base: $BASE_WHY"
    return
  fi
  commits=$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null || true)
  case "$commits" in ''|*[!0-9]*) commits= ;; esac
  if [ -z "$commits" ]; then
    gate_result artifacts_exist CANNOT-RUN "cannot count commits in $BASE..HEAD from $WT"
    return
  fi
  if [ "$commits" -eq 0 ]; then
    gate_result artifacts_exist FAIL "branch $BRANCH has no commits of its own vs $BASE"
    return
  fi
  gate_result artifacts_exist PASS "branch $BRANCH carries $commits commit(s) vs $BASE"
}

# --- gate: tests_pass -------------------------------------------------------

gate_tests_pass() {
  local out rc=0
  if [ "$CLAIMS_OK" -ne 1 ] || [ -z "$CLAIM_TESTS_COMMAND" ]; then
    # No re-runnable command. Self-reported counts cannot stand in for one, but
    # they are still a claim, so an internally inconsistent pair is reported
    # rather than passed over. A consistent pair is explicitly UNVERIFIED.
    if [ -n "$CLAIM_TESTS_RUN" ] && [ -n "$CLAIM_TESTS_PASSED" ]; then
      if [ "$CLAIM_TESTS_PASSED" -lt "$CLAIM_TESTS_RUN" ]; then
        gate_result tests_pass FAIL \
          "claim source '$CLAIM_SOURCE' reports only $CLAIM_TESTS_PASSED of $CLAIM_TESTS_RUN tests passing" \
          "a terminal record should not declare failing tests; check the task before accepting it"
        return
      fi
      if [ "$CLAIM_TESTS_RUN" -eq 0 ]; then
        gate_result tests_pass SKIP \
          "claim source '$CLAIM_SOURCE' reports that no tests were run"
        return
      fi
      gate_result tests_pass SKIP \
        "claim source '$CLAIM_SOURCE' reports $CLAIM_TESTS_PASSED of $CLAIM_TESTS_RUN tests passing" \
        "unverified: the record carries no re-runnable tests_command, and this gate never guesses one"
      return
    fi
    gate_result tests_pass SKIP \
      "the task declares no tests_command, and this gate never guesses one"
    return
  fi
  if [ "$RUN_TESTS" -ne 1 ]; then
    gate_result tests_pass SKIP \
      "declared: $CLAIM_TESTS_COMMAND" \
      "not executed: this run is read-only, pass --run-tests to execute it"
    return
  fi
  if [ "$WT_OK" -ne 1 ]; then
    gate_result tests_pass CANNOT-RUN \
      "no readable task worktree to run the declared command in: ${WT:-<no worktree recorded>}"
    return
  fi
  out=$( cd "$WT" && bash -c "$CLAIM_TESTS_COMMAND" 2>&1 ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    gate_result tests_pass PASS "declared command exited 0: $CLAIM_TESTS_COMMAND"
    return
  fi
  gate_result tests_pass FAIL \
    "declared command exited $rc: $CLAIM_TESTS_COMMAND" \
    "last output:" \
    "$(printf '%s\n' "$out" | tail -20 | sed 's/^/  /')"
}

gate_envelope_valid
gate_diff_matches_claims
gate_artifacts_exist
gate_tests_pass

VERDICT=PASS
EXIT=0
if [ "$FAILED" -gt 0 ]; then
  VERDICT=FAIL
  EXIT=1
elif [ "$COULD_NOT_RUN" -gt 0 ] || [ "$PASSED" -eq 0 ]; then
  VERDICT=INCONCLUSIVE
  EXIT=3
fi
printf 'verdict: %s (passed=%s failed=%s skipped=%s not-applicable=%s could-not-run=%s)\n' \
  "$VERDICT" "$PASSED" "$FAILED" "$SKIPPED" "$NOT_APPLICABLE" "$COULD_NOT_RUN"
exit "$EXIT"
