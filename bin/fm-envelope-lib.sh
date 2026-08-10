#!/usr/bin/env bash
# fm-envelope-lib.sh - read and validate a crewmate's typed terminal envelope.
#
# A finished crewmate reports through state/<id>.status prose. That protocol is
# unchanged. The envelope at data/<id>/envelope.json is an ADDITIONAL, optional,
# machine-checkable record of the same terminal state, so a claim can be checked
# against reality instead of taken on trust.
#
# The CONTRACT - which keys a crewmate writes and what they mean - is owned by
# the bin/fm-brief.sh scaffold, because that is the text crewmates are actually
# given. This library only enforces it, and bin/fm-gate.sh and bin/fm-teardown.sh
# both read envelopes through here so there is exactly one parser.
#
# Absence is not a failure. Every consumer must treat a missing envelope as "not
# applicable" and behave exactly as it did before envelopes existed. A PRESENT
# envelope that does not parse or does not satisfy the contract is a different
# thing entirely, and is reported.
#
# Sourced, not executed:
#   . "$SCRIPT_DIR/fm-envelope-lib.sh"
#
# Functions:
#   fm_envelope_path <data-dir> <task-id>
#       Echo the envelope path for a task. No existence check.
#   fm_envelope_validate <file>
#       Echo one reason line and return non-zero unless <file> satisfies the
#       contract. 0 valid, 1 present but invalid, 2 cannot be checked at all
#       (unreadable, or jq is not installed). A checker that cannot run must
#       never be mistaken for a pass, so those are distinct.
#   fm_envelope_claim_record <file>
#       Echo the envelope as bin/fm-gate.sh's normalized claim record. Call it
#       only on a file fm_envelope_validate accepted.
#
# jq is the parser. It is already required for several firstmate surfaces and is
# verified by CI; when it is missing, validation reports CANNOT-RUN rather than
# guessing at JSON with shell string matching.

# The six keys, exactly. An unknown key is refused rather than ignored, so a
# crewmate cannot believe it recorded something a consumer silently dropped, and
# a future key cannot be read by an older firstmate that does not honor it.
# shellcheck disable=SC2016  # single quotes are deliberate: this is a jq program, and every $binding in it is jq's, not the shell's.
FM_ENVELOPE_VALIDATE_JQ='
["files_changed","tests_run","tests_passed","claims","acceptance_criteria_met","open_questions"] as $required
| ["files_changed","claims","acceptance_criteria_met","open_questions"] as $stringarrays
| . as $e
| if ($e | type) != "object" then
    "the envelope must be a JSON object, got \($e | type)"
  else
    ([$required[] | . as $k | select(($e | has($k)) | not)]) as $missing
    | ([$e | keys_unsorted[] | . as $k | select(($required | index($k)) == null)]) as $unknown
    | ([$stringarrays[] | . as $k | select(($e[$k] | type) != "array")]) as $notarray
    | ([$stringarrays[] | . as $k | select([$e[$k][]? | select(type != "string")] | length > 0)]) as $notstrings
    | ([$e.files_changed[]? | select(type == "string")
        | select(. == ""
            or startswith("/")
            or endswith("/")
            or ((split("/") | index("..")) != null)
            or (explode | any(. < 32)))]) as $badpaths
    | ([("tests_run","tests_passed") | . as $k
        | select(($e[$k] | type) != "number" or ($e[$k] | floor) != $e[$k] or $e[$k] < 0)]) as $badcounts
    | if ($missing | length) > 0 then
        "missing required key(s): \($missing | join(", "))"
      elif ($unknown | length) > 0 then
        "unknown key(s): \($unknown | join(", "))"
      elif ($notarray | length) > 0 then
        "must be an array: \($notarray | join(", "))"
      elif ($notstrings | length) > 0 then
        "must contain only strings: \($notstrings | join(", "))"
      elif ($badpaths | length) > 0 then
        "files_changed must hold plain repo-relative paths, rejected: \($badpaths | map(tojson) | join(", "))"
      elif ($badcounts | length) > 0 then
        "must be a non-negative whole number: \($badcounts | join(", "))"
      elif $e.tests_passed > $e.tests_run then
        "tests_passed (\($e.tests_passed)) exceeds tests_run (\($e.tests_run))"
      else
        "OK"
      end
  end
'

FM_ENVELOPE_CLAIM_JQ='
"claim_source=envelope",
"claim_confidence=declared",
"files_changed_exhaustive=1",
"tests_run=\(.tests_run | floor)",
"tests_passed=\(.tests_passed | floor)",
(.files_changed[] | "files_changed=\(.)")
'

fm_envelope_path() {  # <data-dir> <task-id>
  printf '%s/%s/envelope.json\n' "$1" "$2"
}

fm_envelope_validate() {  # <file>
  local file=${1:-} verdict rc=0
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'not a readable file: %s\n' "${file:-<no path>}"
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is not installed, so the envelope cannot be parsed\n'
    return 2
  fi
  verdict=$(jq -r "$FM_ENVELOPE_VALIDATE_JQ" < "$file" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    # jq's own parse error, trimmed to its first line: the rest is a repeat of
    # the offending text and would bury the reason in a gate report.
    printf 'not valid JSON: %s\n' "$(printf '%s' "$verdict" | sed -n 1p)"
    return 1
  fi
  if [ "$verdict" = OK ]; then
    return 0
  fi
  printf '%s\n' "$verdict"
  return 1
}

fm_envelope_claim_record() {  # <file>
  local file=${1:-}
  [ -n "$file" ] && [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r "$FM_ENVELOPE_CLAIM_JQ" < "$file"
}

fm_envelope_summary() {  # <file> - one short human line for a report
  local file=${1:-}
  [ -n "$file" ] && [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '"\(.files_changed | length) file(s) claimed, \(.tests_passed | floor)/\(.tests_run | floor) tests passing, \(.open_questions | length) open question(s)"' < "$file"
}
