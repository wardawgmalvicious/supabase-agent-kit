#!/usr/bin/env bash
# jq programs sit in single quotes on purpose: their $names are jq's, not bash's.
# shellcheck disable=SC2016
# Run read-only SQL against a Supabase project's Postgres database, from a shell
# or from a coding agent such as Claude Code, without the Supabase CLI or psql.
# With -w it runs read-write SQL instead (write mode, below).
#
# It posts the query to the Supabase Management API's read-only query endpoint,
#   POST https://api.supabase.com/v1/projects/<ref>/database/query/read-only
# which runs it as the database role supabase_read_only_user (documented). The
# endpoint is marked beta in Supabase's API reference. Observed on a free-tier
# project on 2026-11-02, not documented: the query runs in a read-only
# transaction AND the role holds no write privilege, so an insert or drop is
# refused, and `set transaction read write` only changes the error. A Full
# token is refused the same way, so the refusal is the endpoint's, not the
# token's. Nothing in this script enforces read-only; Postgres does.
# Requires bash, curl and jq; column is used for the table view.
#
# Write mode, -w, posts to the read-write query endpoint instead, also beta,
#   POST https://api.supabase.com/v1/projects/<ref>/database/query
# with read_only false and the second token, SUPABASE_ACCESS_TOKEN_RW. Observed
# 2026-11-02, not documented: with a Full token the query runs as postgres,
# outside a read-only transaction, so it can change anything; with a Read-only
# token it still runs as supabase_read_only_user, and a write is refused. A
# call whose statement fails rolls back its earlier statements, and an insert,
# update or delete ending in `returning ...` prints those rows. Pass -w as an
# argument of its own, never bundled as -rw, so that a permission rule matching
# the command's text sees a write written the usual way; the script refuses it
# bundled. A rule is no boundary: a flag in a variable still gets past it.
#
# Credentials. Use a SCOPED personal access token: in the Supabase Dashboard,
# Account > Access Tokens, pick this one project and Read-only access (the
# form offered Read-only or Full, nothing per resource, on 2026-11-02). Never
# use a legacy full-access token here: it can reach every organization and
# project on the account, including ones created after the token. Write mode
# needs a second scoped token with Full access, which is Read-write on all the
# dashboard lists: the organization and its members, the project's settings,
# API keys, backups and more (the dashboard's token summary, 2026-11-02). Give
# it a short expiry, and revoke it when the writes are done. Each token is read
# from the environment first, then from the repo root's .env, and is passed to
# curl on stdin, never on its command line.
#
# .env keys (repo root, two levels above this script, gitignored):
#   SUPABASE_PROJECT_REF    the project ref: Project Settings > General, or the
#                           <ref> in https://<ref>.supabase.co
#   SUPABASE_ACCESS_TOKEN   the Read-only scoped token, sbp_...
#   SUPABASE_ACCESS_TOKEN_RW
#                           optional, -w only: the Full scoped token, sbp_...
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
#   scripts/db/supabase-query.sh -w -q "update public.orders set ... where ..."
#
# Name every table with its schema (public.orders, not orders). The endpoint's
# reference says all entity references must be schema qualified; an unqualified
# public table did resolve on 2026-11-02, but don't rely on it.
#
# Several statements in one call return only the last statement's rows
# (observed 2026-11-02, on both endpoints). A write that returns no rows prints
# (0 rows), which is no count of the rows it changed.
#
# -l and -d read information_schema, which leaves out materialized views.
#
# Exit status: 0 for a result, 1 when the API or Postgres refused the request
# (the HTTP status and message go to stderr), 2 for a usage error, a missing
# tool, or a missing setting, such as -w with no SUPABASE_ACCESS_TOKEN_RW.
# Under -w, exit 1 after an HTTP 5xx or an unfinished request leaves the write's
# outcome unknown, and a hint says so.
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
WRITE=0
MODE="query"
TARGET=""
SOURCES=0 # how many of -q, -i, -d, -l were given; more than one is refused
# The arguments as given, to check below that -w stands alone.
ARGS=("$@")

while getopts ":q:i:d:lrwh" opt; do
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
        w) WRITE=1 ;;
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

if [[ "$WRITE" -eq 1 ]]; then
    [[ "$MODE" == query ]] || die "-w takes SQL (-q, -i or stdin), not -l or -d"
    # A permission rule matches the command's text, so -w must be a word of its
    # own there: bundled, as in -rw, a rule written for -w would miss it.
    W_ALONE=0
    for arg in "${ARGS[@]}"; do
        if [[ "$arg" == "-w" ]]; then W_ALONE=1; fi
    done
    [[ "$W_ALONE" -eq 1 ]] || die "pass -w on its own, not bundled with another flag (as in -rw)"
fi

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
if [[ "$WRITE" -eq 1 ]]; then
    TOKEN_KEY="SUPABASE_ACCESS_TOKEN_RW"
    ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN_RW:-$(env_value SUPABASE_ACCESS_TOKEN_RW)}"
    ENDPOINT="database/query"
else
    TOKEN_KEY="SUPABASE_ACCESS_TOKEN"
    ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-$(env_value SUPABASE_ACCESS_TOKEN)}"
    ENDPOINT="database/query/read-only"
fi

[[ -n "$PROJECT_REF" ]] || die "SUPABASE_PROJECT_REF is not set in the environment or $ENV_FILE"
[[ -n "$ACCESS_TOKEN" ]] || die "$TOKEN_KEY is not set in the environment or $ENV_FILE"
[[ "$PROJECT_REF" =~ ^[a-z0-9]+$ ]] || die "SUPABASE_PROJECT_REF should be the bare ref, such as abcdefghijklmnopqrst"

# --- request -------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BODY_FILE="$TMP_DIR/body.json"
RESPONSE_FILE="$TMP_DIR/response.json"

# The SQL reaches jq on stdin and curl through a file: as an argument it would
# share Windows' 32,767-character command line, so a long query would fail.
# jq does the JSON quoting. Write mode says read_only false outright, though
# leaving it out behaved the same (observed 2026-11-02).
if [[ "$WRITE" -eq 1 ]]; then
    printf '%s' "$QUERY" | "${JQ[@]}" -Rs '{query: ., read_only: false}' >"$BODY_FILE"
else
    printf '%s' "$QUERY" | "${JQ[@]}" -Rs '{query: .}' >"$BODY_FILE"
fi

# The Authorization header arrives on stdin (-H @-), so the token never appears
# in the process list.
HTTP_STATUS="$(
    printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN" | curl -sS \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -X POST "$API_BASE/projects/$PROJECT_REF/$ENDPOINT" \
        -H @- \
        -H 'Content-Type: application/json' \
        --data-binary "@$BODY_FILE" \
        -o "$RESPONSE_FILE" \
        -w '%{http_code}'
)" || {
    CURL_STATUS=$?
    echo "error: the request did not complete (curl exit $CURL_STATUS)" >&2
    if [[ "$WRITE" -eq 1 ]]; then
        echo "hint: the write may have been applied; check with a select before retrying" >&2
    fi
    exit 1
}

if [[ ! "$HTTP_STATUS" =~ ^2 ]]; then
    MESSAGE="$("${JQ[@]}" -r '.message // .error // . | tostring' "$RESPONSE_FILE" 2>/dev/null ||
        cat "$RESPONSE_FILE")"
    echo "error: HTTP $HTTP_STATUS: $MESSAGE" >&2
    # Matched on the message, not the status: the refusal came as HTTP 400 on
    # 2026-11-02, a status the API's OpenAPI spec does not list.
    if [[ "$WRITE" -eq 1 && "$MESSAGE" == *"read-only transaction"* ]]; then
        echo "hint: $TOKEN_KEY looks like a Read-only token; write mode needs a Full one" >&2
    fi
    # A 5xx says the API failed, not that Postgres refused: the write may have run.
    if [[ "$WRITE" -eq 1 && "$HTTP_STATUS" =~ ^5 ]]; then
        echo "hint: the write may have been applied; check with a select before retrying" >&2
    fi
    case "$HTTP_STATUS" in
        401) echo "hint: $TOKEN_KEY is wrong, expired or revoked" >&2 ;;
        403) echo "hint: $TOKEN_KEY lacks Database access on project $PROJECT_REF" >&2 ;;
        404) echo "hint: check SUPABASE_PROJECT_REF; the query endpoints are beta" >&2 ;;
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
    if [[ "$WRITE" -eq 1 ]]; then
        echo "hint: (0 rows) counts rows changed only when the SQL ended in returning ...; otherwise select afterwards" >&2
    fi
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
