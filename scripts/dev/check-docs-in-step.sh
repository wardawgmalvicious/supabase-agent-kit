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

for required_file in "$QUERY_SH" "$README" "$SKILL"; do
    [[ -f "$required_file" ]] || die "missing $required_file"
done

GAPS=0
gap() {
    echo "out of step: $1" >&2
    GAPS=$((GAPS + 1))
}

# Text goes to grep and awk as a here-string, never a pipe: under pipefail a
# grep -q or awk that exits early on a large text kills its writer with SIGPIPE,
# and the pipe's 141 reads as a miss.
# A flag as a word of its own: -q, not part of --quiet or read-quickly.
has_flag() { grep -q -E -- "(^|[^[:alnum:]-])-$1([^[:alnum:]]|\$)" <<<"$2"; }
# The paragraph of $2 that starts with $1, through the next blank line.
paragraph() { awk -v start="$1" 'index($0, start) == 1 { p = 1 } p && /^$/ { exit } p' <<<"$2"; }

# $BASH, the interpreter running this, not a PATH lookup, which from PowerShell
# on Windows can find WSL's bash.
HELP="$("$BASH" "$QUERY_SH" -h)" || die "$QUERY_SH -h failed"
README_TEXT="$(cat "$README")"
SKILL_TEXT="$(cat "$SKILL")"

# --- -h prints the whole header ---------------------------------------------------
# The header runs from its first line to the last comment before the first line
# of code, blank lines included, so a stray blank inside it shows as a shortfall.
HEADER_LINES="$(awk '/^# Run read-only SQL/ { p = 1 }
    p && !/^#/ && !/^$/ { exit }
    p { n++; if ($0 ~ /^#/) last = n }
    END { print last + 0 }' "$QUERY_SH")"
HELP_LINES="$(wc -l <<<"$HELP")"
[[ "$HEADER_LINES" -gt 0 ]] || die "no header block starting '# Run read-only SQL' in $QUERY_SH"
[[ "$HELP_LINES" -eq "$HEADER_LINES" ]] ||
    gap "-h prints $HELP_LINES of the header's $HEADER_LINES lines: a blank line splits the block"

# --- flags --------------------------------------------------------------------------
OPTSTRING="$(sed -n -E 's/^while getopts "([^"]+)" opt.*/\1/p' "$QUERY_SH")"
FLAGS="${OPTSTRING//:/}"
[[ -n "$FLAGS" ]] || die "no getopts option string found in $QUERY_SH"

for ((flag_index = 0; flag_index < ${#FLAGS}; flag_index++)); do
    flag="${FLAGS:flag_index:1}"
    [[ "$EXEMPT_FLAGS" == *"$flag"* ]] && continue
    has_flag "$flag" "$HELP" || gap "-$flag is missing from the script's header (-h)"
    has_flag "$flag" "$README_TEXT" || gap "-$flag is missing from README.md"
    has_flag "$flag" "$SKILL_TEXT" || gap "-$flag is missing from SKILL.md"
done

# --- exit codes -----------------------------------------------------------------------
# die's default is the N of ${2:-N}; the 2 before it is the argument's position.
CODES="$(
    {
        grep -o -E '\bexit [0-9]+' "$QUERY_SH" | grep -o -E '[0-9]+$' || true
        sed -n -E 's/.*\$\{2:-([0-9]+)\}.*/\1/p' "$QUERY_SH"
        grep -E '\bdie .*" [0-9]+$' "$QUERY_SH" | grep -o -E '[0-9]+$' || true
    } | sort -u
)"
[[ -n "$CODES" ]] || die "no exit codes found in $QUERY_SH"

HELP_EXIT="$(paragraph 'Exit status:' "$HELP")"
README_EXIT="$(paragraph 'Exit codes:' "$README_TEXT")"
[[ -n "$HELP_EXIT" ]] || gap "the script's header has no 'Exit status:' paragraph"
[[ -n "$README_EXIT" ]] || gap "README.md has no 'Exit codes:' paragraph"

for code in $CODES; do
    grep -q -w -- "$code" <<<"$HELP_EXIT" ||
        gap "exit $code is missing from the header's 'Exit status:' paragraph"
    grep -q -w -- "$code" <<<"$README_EXIT" ||
        gap "exit $code is missing from README.md's 'Exit codes:' paragraph"
    [[ "$EXEMPT_SKILL_CODES" == *"$code"* ]] && continue
    grep -q -i -E -- "\bexit $code\b" <<<"$SKILL_TEXT" ||
        gap "exit $code is missing from SKILL.md"
done

# --- row cap ----------------------------------------------------------------------------
CAP="$(sed -n -E 's/^MAX_ROWS="\$\{SUPABASE_QUERY_MAX_ROWS:-([0-9]+)\}".*/\1/p' "$QUERY_SH")"
[[ -n "$CAP" ]] || die "no SUPABASE_QUERY_MAX_ROWS default found in $QUERY_SH"

for source_name in header README.md; do
    if [[ "$source_name" == header ]]; then source_text="$HELP"; else source_text="$README_TEXT"; fi
    grep -q -F SUPABASE_QUERY_MAX_ROWS <<<"$source_text" ||
        gap "SUPABASE_QUERY_MAX_ROWS is missing from the $source_name"
    grep -q -w -- "$CAP" <<<"$source_text" ||
        gap "the row cap's default, $CAP, is missing from the $source_name"
done

if [[ "$GAPS" -gt 0 ]]; then
    echo "hint: CLAUDE.md, 'Keeping the docs in step'; update the doc, or this check's pattern if only the wording moved" >&2
    exit 1
fi
echo "docs in step: flags ${FLAGS}, exit codes ${CODES//$'\n'/ }, row cap $CAP"
