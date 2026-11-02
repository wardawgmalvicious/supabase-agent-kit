# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A kit that users **copy into their own project's repo**, not an app. It
has two parts, and the README explains both:

- **Route 1**, `docs/mcp-connector.md`: setup notes for Supabase's hosted
  MCP server, scoped by URL parameters. There is no code.
- **Route 2**: `scripts/db/supabase-query.sh`, which posts SQL to the
  Supabase Management API's read-only query endpoint, plus
  `.claude/skills/query-supabase/SKILL.md`, which tells an agent when and
  how to call it.

The script and skill are installed by copying them **to the same paths**
in the target repo. The script finds `.env` at `SCRIPT_DIR/../..`, so
moving or renaming `scripts/db/` breaks every install. The skill also
fires in this repo itself, against whatever project `.env` points at.

## Commands

No build and no test suite. Lint and format-check the script (both pass
clean as of 2026-11-02):

```bash
shellcheck scripts/db/supabase-query.sh
shfmt -d -i 4 -ci scripts/db/supabase-query.sh
```

The only end-to-end test is a live call, which needs a filled-in `.env`
at the repo root (a local one exists and is gitignored):

```bash
scripts/db/supabase-query.sh -q "select 1 as ok"
scripts/db/supabase-query.sh -h    # prints the header block as help
```

Never read, print or echo `.env` or the token.

## How the script works

- **Read-only is enforced by Postgres, not by the script.** The endpoint
  runs queries as `supabase_read_only_user` in a read-only transaction.
  Don't add SQL filtering as a "safety" layer; it would imply a guarantee
  the script doesn't make.
- **Secrets and payloads stay off argv.** The token reaches curl as a
  header on stdin (`-H @-`); the SQL reaches jq on stdin and curl through
  a temp file. This avoids the process list and Windows' 32,767-character
  command-line limit. Keep it that way in any change.
- `.env` is read key by key with `grep`/`cut`, never sourced. Environment
  variables override it.
- jq gets `-b` under Git Bash (`OSTYPE` `msys*` or `cygwin*`), or its
  output is CRLF.
- The table view uses `join("\t")`, not `@tsv`, because `@tsv` doubles
  backslashes. It caps at `SUPABASE_QUERY_MAX_ROWS` (default 200); `-r`
  is never capped.
- Exit codes are a contract the skill relies on: `0` result, `1` refused
  by the API or Postgres, `2` usage or missing setting.
- `-d` validates `schema.table` as plain identifiers and does not quote
  them, because it interpolates them into SQL.

## Keeping the docs in step

The script's header block doubles as `-h` output (the `usage()` function
prints from `# Run read-only SQL` to the first blank line), so keep that
block contiguous.

Behavior is described in three places: the script header, the README,
and `SKILL.md`. A change to flags, exit codes, the row cap or observed
endpoint behavior needs all three updated. Observed, undocumented
behavior is dated (for example "observed 2026-11-02"); keep that
convention, and re-date a claim when you re-test it. The endpoint is
marked beta by Supabase.

`*.sh` is pinned to LF in `.gitattributes`.
