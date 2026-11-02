#!/usr/bin/env bash
# Check that the query script's flags, exit codes and row cap are described in
# all three of its homes: the script's header block (its -h output), README.md
# and the query-supabase SKILL.md. It enforces CLAUDE.md's "Keeping the docs in
# step", and runs as the docs-in-step pre-commit hook.
#
# Why facts, not wording: the three are prose written for different readers, so
# the check reads whether each names a fact, never how it phrases it. A failure
# means a doc lost a fact, or the doc was reworded past this check's pattern:
# fix whichever is wrong.
#
# What it compares, each read from the script itself:
#   flags        getopts' option string; each flag must appear as -X in the -h
#                output, the README and SKILL.md
#   exit codes   every `exit N`, die's default and each `die ... N`; each code
#                must appear in the header's "Exit status:" paragraph, the
#                README's "Exit codes:" paragraph and SKILL.md
#   row cap      SUPABASE_QUERY_MAX_ROWS and its default, in -h and the README
#   -h           prints the whole header block, so no blank line has cut it
#
# Left out on purpose (the exception lists below say why): -h in the docs,
# exit 0 and the row cap in SKILL.md.
#
# Not part of the kit: installers copy scripts/db/ only, so this lives apart.
#
# Usage:
#   scripts/dev/check-docs-in-step.sh
#
# Exit status: 0 in step, 1 out of step (each gap on stderr), 2 a file missing
# or a fact the check could not read from the script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUERY_SH="$REPO_ROOT/scripts/db/supabase-query.sh"
README="$REPO_ROOT/README.md"
SKILL="$REPO_ROOT/.claude/skills/query-supabase/SKILL.md"

# Exceptions, each with its reason.
#   -h: the header block is -h's own output, and neither doc needs a help flag.
EXEMPT_FLAGS="h"
#   exit 0 in SKILL.md: the skill acts on failures; success needs no handling.
EXEMPT_SKILL_CODES="0"
#   the row cap in SKILL.md: the skill bounds its own selects with `limit 50`.

die() {
    echo "error: $1" >&2
    exit 2
}

for f in "$QUERY_SH" "$README" "$SKILL"; do
    [[ -f "$f" ]] || die "missing $f"
done

GAPS=0
gap() {
    echo "out of step: $1" >&2
    GAPS=$((GAPS + 1))
}

# A flag as a word of its own: -q, not part of --quiet or read-quickly.
has_flag() { grep -q -E -- "(^|[^[:alnum:]-])-$1([^[:alnum:]]|\$)"; }
# The paragraph that starts with $1, through the next blank line.
paragraph() { awk -v start="$1" 'index($0, start) == 1 { p = 1 } p && /^$/ { exit } p'; }

HELP="$(bash "$QUERY_SH" -h)" || die "$QUERY_SH -h failed"
README_TEXT="$(cat "$README")"
SKILL_TEXT="$(cat "$SKILL")"

# --- -h prints the whole header ---------------------------------------------------
# The header runs from its first line to the last comment before the first line
# of code, blank lines included, so a stray blank inside it shows as a shortfall.
HEADER_LINES="$(awk '/^# Run read-only SQL/ { p = 1 }
    p && !/^#/ && !/^$/ { exit }
    p { n++; if ($0 ~ /^#/) last = n }
    END { print last + 0 }' "$QUERY_SH")"
HELP_LINES="$(printf '%s\n' "$HELP" | wc -l)"
[[ "$HEADER_LINES" -gt 0 ]] || die "no header block starting '# Run read-only SQL' in $QUERY_SH"
[[ "$HELP_LINES" -eq "$HEADER_LINES" ]] ||
    gap "-h prints $HELP_LINES of the header's $HEADER_LINES lines: a blank line splits the block"

# --- flags --------------------------------------------------------------------------
OPTSTRING="$(sed -n -E 's/^while getopts "([^"]+)" opt.*/\1/p' "$QUERY_SH")"
FLAGS="${OPTSTRING//:/}"
[[ -n "$FLAGS" ]] || die "no getopts option string found in $QUERY_SH"

for ((n = 0; n < ${#FLAGS}; n++)); do
    flag="${FLAGS:n:1}"
    [[ "$EXEMPT_FLAGS" == *"$flag"* ]] && continue
    printf '%s\n' "$HELP" | has_flag "$flag" || gap "-$flag is missing from the script's header (-h)"
    printf '%s\n' "$README_TEXT" | has_flag "$flag" || gap "-$flag is missing from README.md"
    printf '%s\n' "$SKILL_TEXT" | has_flag "$flag" || gap "-$flag is missing from SKILL.md"
done

# --- exit codes -----------------------------------------------------------------------
CODES="$(
    {
        grep -o -E '\bexit [0-9]+' "$QUERY_SH" | grep -o -E '[0-9]+$' || true
        grep -o -E '\$\{2:-[0-9]+\}' "$QUERY_SH" | grep -o -E '[0-9]+' || true
        grep -E '\bdie .*" [0-9]+$' "$QUERY_SH" | grep -o -E '[0-9]+$' || true
    } | sort -u
)"
[[ -n "$CODES" ]] || die "no exit codes found in $QUERY_SH"

HELP_EXIT="$(printf '%s\n' "$HELP" | paragraph 'Exit status:')"
README_EXIT="$(printf '%s\n' "$README_TEXT" | paragraph 'Exit codes:')"
[[ -n "$HELP_EXIT" ]] || gap "the script's header has no 'Exit status:' paragraph"
[[ -n "$README_EXIT" ]] || gap "README.md has no 'Exit codes:' paragraph"

for code in $CODES; do
    printf '%s\n' "$HELP_EXIT" | grep -q -w -- "$code" ||
        gap "exit $code is missing from the header's 'Exit status:' paragraph"
    printf '%s\n' "$README_EXIT" | grep -q -w -- "$code" ||
        gap "exit $code is missing from README.md's 'Exit codes:' paragraph"
    [[ "$EXEMPT_SKILL_CODES" == *"$code"* ]] && continue
    printf '%s\n' "$SKILL_TEXT" | grep -q -i -E -- "\bexit $code\b" ||
        gap "exit $code is missing from SKILL.md"
done

# --- row cap ----------------------------------------------------------------------------
CAP="$(sed -n -E 's/^MAX_ROWS="\$\{SUPABASE_QUERY_MAX_ROWS:-([0-9]+)\}".*/\1/p' "$QUERY_SH")"
[[ -n "$CAP" ]] || die "no SUPABASE_QUERY_MAX_ROWS default found in $QUERY_SH"

for doc in header README.md; do
    if [[ "$doc" == header ]]; then text="$HELP"; else text="$README_TEXT"; fi
    printf '%s\n' "$text" | grep -q -F SUPABASE_QUERY_MAX_ROWS ||
        gap "SUPABASE_QUERY_MAX_ROWS is missing from the $doc"
    printf '%s\n' "$text" | grep -q -w -- "$CAP" ||
        gap "the row cap's default, $CAP, is missing from the $doc"
done

if [[ "$GAPS" -gt 0 ]]; then
    echo "hint: CLAUDE.md, 'Keeping the docs in step'; update the doc, or this check's pattern if only the wording moved" >&2
    exit 1
fi
echo "docs in step: flags ${FLAGS}, exit codes ${CODES//$'\n'/ }, row cap $CAP"
