#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture, or its memory lane, from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --lane, prints the project's memory lane instead, one word.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# The bracket group is a set of tokens, not a fixed sequence. A "lane:<name>"
# token names the project's memory lane; "+yolo" sets the autonomy posture; any
# remaining unrecognized token is ignored. The mode is the first token that is
# none of those, so a line may carry a lane and no mode:
#   - <name> [lane:<lane>] - <desc>                    -> no-mistakes off, lane <lane>
#   - <name> [<mode> +yolo lane:<lane>] - <desc>       -> <mode> on, lane <lane>
# Token order does not matter and a lane token never changes the posture.
#
# --lane prints just that lane, so a caller routing memory does not have to
# re-parse the annotation. An unregistered project, or a registered one with no
# lane token, prints nothing, warns to stderr, and exits 1: a memory written to
# a guessed lane is the cross-lane leak the lane model exists to prevent, so
# there is deliberately no default lane. bin/fm-memory-mcp resolves the same
# token itself and owns what the lane names mean.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw | --lane] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
WANT_LANE=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --lane) WANT_LANE=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw | --lane] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$WANT_LANE" -eq 1 ]; then
    echo "warn: no registry at $REG; $NAME has no memory lane" >&2
    exit 1
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# One pass over the registry answers both questions, so the annotation is only
# ever parsed one way. Emits "<mode> <yolo> <lane>" for a registered project,
# with "-" for an absent lane, or nothing at all when the project is not there.
# Only the bracket group carries tokens: a lane named in a description is
# prose, not a routing instruction.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; lane="-"; seen=0;
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # The annotation is a token SET, not a fixed sequence: the mode is the
      # first token that is none of the named ones. Reading field 1
      # positionally made a lane-only annotation look like an unknown mode.
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        # An empty value after "lane:" names no lane, so it is left absent
        # rather than answered with a blank one.
        if (a[j] ~ /^lane:/) { if (lane=="-") { t=a[j]; sub(/^lane:/, "", t); if (t!="") lane=t } continue }
        if (a[j]!="" && !seen) { mode=a[j]; seen=1 }
      }
    }
    print mode, yolo, lane; exit
  }
' "$REG")

if [ "$WANT_LANE" -eq 1 ]; then
  lane=${parsed##* }
  if [ -z "$parsed" ]; then
    # Two different fixes, so two different messages: register the project, or
    # add its lane token. bin/fm-memory-mcp draws the same distinction.
    echo "warn: project \"$NAME\" is not in $REG" >&2
    exit 1
  fi
  if [ "$lane" = "-" ] || [ -z "$lane" ]; then
    echo "warn: project \"$NAME\" carries no lane:<name> token in $REG" >&2
    exit 1
  fi
  echo "$lane"
  exit 0
fi

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
rest=${parsed#* }
yolo=${rest%% *}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
