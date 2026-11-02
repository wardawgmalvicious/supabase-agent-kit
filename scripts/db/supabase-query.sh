#!/usr/bin/env bash
# jq programs sit in single quotes on purpose: their $names are jq's, not bash's.
# shellcheck disable=SC2016
# Run read-only SQL against a Supabase project's Postgres database, from a shell
# or from a coding agent such as Claude Code, without the Supabase CLI or psql.
#
# It posts the query to the Supabase Management API's read-only query endpoint,
#   POST https://api.supabase.com/v1/projects/<ref>/database/query/read-only
# which runs it as the database role supabase_read_only_user (documented). The
# endpoint is marked beta in Supabase's API reference. Observed on a free-tier
# project on 2026-11-02, not documented: the query runs in a read-only
# transaction AND the role holds no write privilege, so an insert or drop is
# refused, and `set transaction read write` only changes the error. Nothing in
# this script enforces read-only; Postgres does.
# Requires bash, curl and jq; column is used for the table view.
#
# Credentials. Use a SCOPED personal access token: in the Supabase Dashboard,
# Account > Access Tokens, pick this one project and give Database the Read
# permission, nothing else. Never use a legacy full-access token here: it can
# reach every organization and project on the account, including ones created
# after the token. The token is read from the environment first, then from the
# repo root's .env, and is passed to curl on stdin, never on its command line.
#
# .env keys (repo root, two levels above this script, gitignored):
#   SUPABASE_PROJECT_REF    the project ref: Project Settings > General, or the
#                           <ref> in https://<ref>.supabase.co
#   SUPABASE_ACCESS_TOKEN   the scoped token, sbp_...
# One KEY=value per line: no `export`, and no comment after a value.
#
# SUPABASE_QUERY_MAX_ROWS (environment, default 200) caps the table view, so a
# wide select cannot flood an agent's context; -r is never capped.
#
# Usage:
#   scripts/db/supabase-query.sh -q "select count(*) from public.orders"
#   scripts/db/supabase-query.sh -i path/to/query.sql
#   echo "select now()" | scripts/db/supabase-query.sh
#   scripts/db/supabase-query.sh -l                 # list tables and views
#   scripts/db/supabase-query.sh -d public.orders   # describe one table's columns
#   scripts/db/supabase-query.sh -r -q "select ..." | jq '.[0]'   # raw JSON rows
#
# Name every table with its schema (public.orders, not orders). The endpoint's
# reference says all entity references must be schema qualified; an unqualified
# public table did resolve on 2026-11-02, but don't rely on it.
#
# Several statements in one call return only the last statement's rows
# (observed 2026-11-02).
#
# -l and -d read information_schema, which leaves out materialized views.
#
# Exit status: 0 for a result, 1 when the API or Postgres refused the request
# (the HTTP status and message go to stderr), 2 for a usage error, a missing
# tool, or a missing setting.
#
# Deployment assumption: this script lives at <repo>/scripts/db/supabase-query.sh
# so SCRIPT_DIR/../.. resolves to the repo root holding .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
API_BASE="https://api.supabase.com/v1"
CONNECT_TIMEOUT=15 # seconds to establish the connection
MAX_TIME=120       # seconds for the whole request
MAX_ROWS="${SUPABASE_QUERY_MAX_ROWS:-200}"

usage() {
    # The header block: its first line through the first blank line.
    sed -n '/^# Run read-only SQL/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "error: $1" >&2
    exit "${2:-2}"
}

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

# Git Bash's jq writes CRLF unless told otherwise; -b keeps output LF.
JQ=(jq)
case "${OSTYPE:-}" in msys* | cygwin*) JQ=(jq -b) ;; esac

# --- arguments -----------------------------------------------------------------
QUERY=""
RAW=0
MODE="query"
TARGET=""
SOURCES=0 # how many of -q, -i, -d, -l were given; more than one is refused

while getopts ":q:i:d:lrh" opt; do
    case "$opt" in
        q)
            QUERY="$OPTARG"
            SOURCES=$((SOURCES + 1))
            ;;
        i)
            [[ -f "$OPTARG" ]] || die "no such file: $OPTARG"
            QUERY="$(cat "$OPTARG")"
            SOURCES=$((SOURCES + 1))
            ;;
        d)
            MODE="describe"
            TARGET="$OPTARG"
            SOURCES=$((SOURCES + 1))
            ;;
        l)
            MODE="list"
            SOURCES=$((SOURCES + 1))
            ;;
        r) RAW=1 ;;
        h)
            usage
            exit 0
            ;;
        :) die "-$OPTARG needs a value (see -h)" ;;
        *) die "unknown option -$OPTARG (see -h)" ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || die "unexpected argument: $1 (quote the SQL and pass it with -q)"
[[ $SOURCES -le 1 ]] || die "use only one of -q, -i, -d, -l"
[[ "$MAX_ROWS" =~ ^[1-9][0-9]*$ ]] || die "SUPABASE_QUERY_MAX_ROWS must be a positive whole number"

# Schemas Supabase manages. -l hides them so the list shows the project's own
# tables; query them directly when they are what you want.
INTERNAL_SCHEMAS="'auth','storage','realtime','_realtime','extensions','graphql',\
'graphql_public','vault','pgsodium','pgsodium_masks','supabase_functions',\
'supabase_migrations','net','cron','pgbouncer','_analytics','information_schema'"

case "$MODE" in
    list)
        QUERY="select table_schema, table_name, table_type
from information_schema.tables
where table_schema not in ($INTERNAL_SCHEMAS)
  and table_schema not like 'pg\_%'
order by table_schema, table_name"
        ;;
    describe)
        [[ "$TARGET" == *.* ]] || die "-d takes schema.table, such as public.orders"
        SCHEMA="${TARGET%%.*}"
        TABLE="${TARGET#*.}"
        # Identifiers, so validate rather than quote: letters, digits, _ and $.
        [[ "$SCHEMA" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ && "$TABLE" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]] ||
            die "-d: '$TARGET' is not a plain schema.table name"
        QUERY="select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = '$SCHEMA' and table_name = '$TABLE'
order by ordinal_position"
        ;;
    query)
        if [[ -z "$QUERY" && ! -t 0 ]]; then
            QUERY="$(cat)"
        fi
        ;;
esac

[[ -n "${QUERY//[[:space:]]/}" ]] || die "no SQL given: use -q, -i or stdin (see -h)"

# --- settings ------------------------------------------------------------------
# Read one key from .env without sourcing it.
env_value() {
    [[ -f "$ENV_FILE" ]] || return 0
    { grep -E "^$1=" "$ENV_FILE" || true; } | head -n 1 | cut -d '=' -f 2- |
        tr -d '\r' | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

PROJECT_REF="${SUPABASE_PROJECT_REF:-$(env_value SUPABASE_PROJECT_REF)}"
ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-$(env_value SUPABASE_ACCESS_TOKEN)}"

[[ -n "$PROJECT_REF" ]] || die "SUPABASE_PROJECT_REF is not set in the environment or $ENV_FILE"
[[ -n "$ACCESS_TOKEN" ]] || die "SUPABASE_ACCESS_TOKEN is not set in the environment or $ENV_FILE"
[[ "$PROJECT_REF" =~ ^[a-z0-9]+$ ]] || die "SUPABASE_PROJECT_REF should be the bare ref, such as abcdefghijklmnopqrst"

# --- request -------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BODY_FILE="$TMP_DIR/body.json"
RESPONSE_FILE="$TMP_DIR/response.json"

# The SQL reaches jq on stdin and curl through a file: as an argument it would
# share Windows' 32,767-character command line, so a long query would fail.
# jq does the JSON quoting.
printf '%s' "$QUERY" | "${JQ[@]}" -Rs '{query: .}' >"$BODY_FILE"

# The Authorization header arrives on stdin (-H @-), so the token never appears
# in the process list.
HTTP_STATUS="$(
    printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN" | curl -sS \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -X POST "$API_BASE/projects/$PROJECT_REF/database/query/read-only" \
        -H @- \
        -H 'Content-Type: application/json' \
        --data-binary "@$BODY_FILE" \
        -o "$RESPONSE_FILE" \
        -w '%{http_code}'
)" || die "the request did not complete (curl exit $?)" 1

if [[ ! "$HTTP_STATUS" =~ ^2 ]]; then
    MESSAGE="$("${JQ[@]}" -r '.message // .error // . | tostring' "$RESPONSE_FILE" 2>/dev/null ||
        cat "$RESPONSE_FILE")"
    echo "error: HTTP $HTTP_STATUS: $MESSAGE" >&2
    case "$HTTP_STATUS" in
        401) echo "hint: the token is wrong, expired or revoked" >&2 ;;
        403) echo "hint: the token lacks Database read on project $PROJECT_REF" >&2 ;;
        404) echo "hint: check SUPABASE_PROJECT_REF; the read-only endpoint is beta" >&2 ;;
        429) echo "hint: rate limited; wait and retry" >&2 ;;
    esac
    exit 1
fi

# --- output --------------------------------------------------------------------
if [[ "$RAW" -eq 1 ]]; then
    cat "$RESPONSE_FILE"
    echo
    exit 0
fi

# Rows come back as an array of objects. Anything else prints as JSON.
if ! "${JQ[@]}" -e 'type == "array"' "$RESPONSE_FILE" >/dev/null 2>&1; then
    "${JQ[@]}" . "$RESPONSE_FILE"
    exit 0
fi

ROW_COUNT="$("${JQ[@]}" 'length' "$RESPONSE_FILE")"
if [[ "$ROW_COUNT" -eq 0 ]]; then
    echo "(0 rows)"
    if [[ "$MODE" == describe ]]; then
        echo "hint: no such table, a materialized view (not in information_schema), or no privilege on it" >&2
    fi
    exit 0
fi

# join("\t"), not @tsv: @tsv doubles every backslash, so C:\dir would print as
# C:\\dir. Each cell is already free of tabs and newlines by then.
TABLE_JQ='
    (.[0] | keys_unsorted) as $cols
    | ($cols | join("\t")),
      ($cols | map("-" * length) | join("\t")),
      (.[:$max][] | [.[$cols[]] | if . == null then "NULL"
                                  elif type == "string" then gsub("[\t\n\r]"; " ")
                                  else tojson end] | join("\t"))
'
if command -v column >/dev/null 2>&1; then
    "${JQ[@]}" -r --argjson max "$MAX_ROWS" "$TABLE_JQ" "$RESPONSE_FILE" | column -t -s $'\t'
else
    "${JQ[@]}" -r --argjson max "$MAX_ROWS" "$TABLE_JQ" "$RESPONSE_FILE"
fi
if [[ "$ROW_COUNT" -gt "$MAX_ROWS" ]]; then
    echo "(showing $MAX_ROWS of $ROW_COUNT rows; add a limit, or use -r for all)"
else
    echo "($ROW_COUNT row$([[ "$ROW_COUNT" -eq 1 ]] || echo s))"
fi
