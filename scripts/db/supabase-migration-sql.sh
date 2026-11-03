#!/usr/bin/env bash
# jq programs sit in single quotes on purpose: their $names are jq's, not bash's.
# shellcheck disable=SC2016
# Print a Supabase migration file as one SQL batch that also records it in
# Supabase's migration history, for scripts/db/supabase-query.sh -w to apply.
# It only prints: it reads no .env, holds no token and sends nothing.
#
# Apply a migration by a pipe, never from inside this script:
#   scripts/db/supabase-migration-sql.sh <file> | scripts/db/supabase-query.sh -w
# The write stays in the command's text, so a permission rule matching
# *supabase-query.sh*-w* still asks before it runs. A helper that called the
# query script itself would hide the write from that rule, so keep it a printer.
#
# What it prints, in order:
#   1. the history table's setup, as the Supabase CLI runs it: create schema
#      supabase_migrations and table schema_migrations (version text primary
#      key) if not exists, then add columns statements text[] and name text if
#      not exists (supabase/cli develop,
#      apps/cli/src/command-internal/migration-history.ts, read 2026-11-02).
#      Idempotent, so every batch carries it.
#   2. the file's SQL, as written.
#   3. the history row: insert into supabase_migrations.schema_migrations
#      (version, name, statements) ... returning version, name.
# The query script sends the batch in one call, and a call whose statement
# fails rolls back its earlier statements (observed 2026-11-02), so the
# migration and its history row land together or not at all. A version
# recorded already fails the insert's primary key, which rolls back the rest.
#
# statements holds the whole file as one element, not one per statement:
# splitting SQL on ; breaks inside a dollar-quoted body, and the CLI splits
# with a lexer this script does not copy. The CLI reads the one element
# safely (same source, read 2026-11-02): `migration list` and `db push` read
# only version, and `migration fetch` writes a file back as the elements
# joined by ";\n", plus ";\n" (migration-fetch-run.ts). So the element is the
# file less its leading blanks and its trailing blanks and semicolons, and a
# fetch gives back the same SQL.
#
# Refused, exit 2, with nothing printed:
#   - a path not of the CLI's form, supabase/migrations/<version>_<name>.sql,
#     <version> 14 digits (the UTC yyyymmddhhmmss `supabase migration new`
#     writes) and <name> letters, digits, _ and -
#   - a file with no SQL, or whose last statement does not end in ;, which the
#     history insert would run on into
#   - transaction control (begin, start transaction, commit, rollback, abort)
#     and concurrently: a commit or rollback mid-batch would split the one
#     transaction, and create index concurrently cannot run inside one.
#     begin atomic, a SQL-standard function body, is allowed.
# The check reads the SQL with its comments, quoted strings and identifiers
# and dollar-quoted bodies blanked out, so a PL/pgSQL begin ... end inside
# $$ ... $$ passes. It is a light scan, not Postgres's lexer: an E'...' string
# holding \' can mislead it, and end, COMMIT's other name, goes unchecked,
# since case ... end shares it. It also refuses some valid SQL, failing safe:
# a nested /* /* */ */ comment ends at its first */, and on commit drop, on a
# temporary table, reads as commit.
#
# Usage:
#   scripts/db/supabase-migration-sql.sh supabase/migrations/20261102120000_create_demo.sql
#   scripts/db/supabase-migration-sql.sh supabase/migrations/<file> > /dev/null   # check only
#   scripts/db/supabase-migration-sql.sh supabase/migrations/<file> | scripts/db/supabase-query.sh
#   scripts/db/supabase-migration-sql.sh supabase/migrations/<file> | scripts/db/supabase-query.sh -w
# The pipe without -w is a dry run of the syntax: a read-only call parses the
# whole batch first, so a syntax error anywhere returns 42601, and a batch that
# parses stops at its first DDL with 25006, changing nothing (observed
# 2026-11-02).
# Requires bash and jq.
#
# Exit status: 0 printed, 2 refused (usage, the file's path or its SQL), with
# the reason on stderr. Piped into the query script, a refusal prints nothing,
# and the query script exits 2 with "no SQL given": nothing is sent.

set -euo pipefail

usage() {
    # The header block: its first line through the first blank line.
    sed -n '/^# Print a Supabase migration/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $1" >&2
    exit 2
}

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# Git Bash's jq writes CRLF unless told otherwise; -b keeps output LF.
JQ=(jq)
case "${OSTYPE:-}" in msys* | cygwin*) JQ=(jq -b) ;; esac

if [[ $# -eq 1 && "$1" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -eq 1 ]] || die "pass one migration file, supabase/migrations/<version>_<name>.sql (see -h)"
FILE="$1"
[[ "$FILE" != -* ]] || die "unknown option $FILE (see -h)"
[[ -f "$FILE" ]] || die "no such file: $FILE"

# --- the path ------------------------------------------------------------------
# The CLI reads supabase/migrations/ alone, so a file anywhere else would be
# recorded as applied with no file where the CLI, or the skill, looks for it.
FILE_FWD="${FILE//\\//}"
BASE="${FILE_FWD##*/}"
DIR="."
[[ "$FILE_FWD" != */* ]] || DIR="${FILE_FWD%/*}"
DIR_ABS="$(cd "$DIR" && pwd)"
[[ "$DIR_ABS" == */supabase/migrations ]] ||
    die "$FILE is not in a supabase/migrations folder, where the Supabase CLI keeps them"
# The name reaches the SQL as a quoted literal, so its characters are limited
# rather than escaped.
[[ "$BASE" =~ ^([0-9]{14})_([A-Za-z0-9_-]+)\.sql$ ]] ||
    die "$BASE is not <version>_<name>.sql, a 14-digit UTC time then letters, digits, _ or -"
VERSION="${BASH_REMATCH[1]}"
NAME="${BASH_REMATCH[2]}"

# --- the batch -----------------------------------------------------------------
# jq checks the SQL and builds the batch. It prints nothing until both are
# done, and a refusal leaves by halt_error with exit 2.
PROGRAM='
def refuse($why): "error: \($file): \($why)\n" | halt_error(2);

# The file as written, less a byte order mark, which Postgres reads as text.
ltrimstr("﻿") as $sql

# The SQL with comments, quoted strings and identifiers, and dollar-quoted
# bodies blanked, so a word inside one is not read as a statement. The
# leftmost match wins, as in a lexer: a -- inside a string stays in it.
| ($sql | gsub("(?s)--[^\n]*|/\\*.*?\\*/|'"'"'(?:[^'"'"']|'"'"''"'"')*'"'"'|\"(?:[^\"]|\"\")*\"|\\$(?<t>[A-Za-z_][A-Za-z0-9_]*|)\\$.*?\\$\\k<t>\\$"; " ")) as $bare

| if ($bare | test("\\S") | not) then refuse("it holds no SQL")
  elif ($bare | test(";\\s*\\z") | not) then refuse("its last statement does not end in ;")
  else . end

| [$bare | match("\\b(begin(?!\\s+atomic\\b)|start\\s+transaction|commit|rollback|abort|concurrently)\\b"; "gi")
   | .captures[0].string | ascii_downcase | gsub("\\s+"; " ")] as $found
| if ($found | length) > 0
  then refuse("\($found | unique | join(", ")) cannot run in the batch'"'"'s one transaction; remove it")
  else . end

# The history element: the file less its leading blanks and trailing blanks
# and semicolons, which migration fetch adds back as ";\n".
| ($sql | sub("^\\s+"; "") | sub("[\\s;]+\\z"; "")) as $statement

# A dollar-quote tag the file does not hold, so the element needs no escaping.
# The check leaves off the closing $: a file ending in $migration would
# otherwise run on into the closing tag and end the quote early.
| (first(range(0; 1000) | "$migration\(if . == 0 then "" else "_\(.)" end)"
         | select(. as $open | $sql | contains($open) | not))
   // refuse("no free dollar-quote tag")) as $open
| "\($open)$" as $tag

| "-- \($version)_\($name).sql and its history row, printed by supabase-migration-sql.sh\n"
  + "create schema if not exists supabase_migrations;\n"
  + "create table if not exists supabase_migrations.schema_migrations (version text not null primary key);\n"
  + "alter table supabase_migrations.schema_migrations add column if not exists statements text[];\n"
  + "alter table supabase_migrations.schema_migrations add column if not exists name text;\n"
  + "\n-- \($version)_\($name).sql\n"
  + $sql + "\n"
  + "\n-- The history row. A version recorded already fails here, and the batch rolls back.\n"
  + "insert into supabase_migrations.schema_migrations (version, name, statements)\n"
  + "values ('"'"'\($version)'"'"', '"'"'\($name)'"'"', array[\($tag)\($statement)\($tag)])\n"
  + "returning version, name;"
'

# The file reaches jq on stdin, never as an argument, as in the query script.
STATUS=0
"${JQ[@]}" -Rrs --arg file "$BASE" --arg version "$VERSION" --arg name "$NAME" "$PROGRAM" <"$FILE" ||
    STATUS=$?
[[ "$STATUS" -eq 0 || "$STATUS" -eq 2 ]] || die "jq failed (exit $STATUS)"
exit "$STATUS"
