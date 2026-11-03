---
paths:
  - "scripts/db/**"
  - "scripts/dev/check-docs-in-step.sh"
  - "README.md"
  - ".claude/skills/query-supabase/**"
---

# The query script and its three descriptions

## How the script works

- **Read-only is enforced by Postgres, not by the script.** The endpoint
  runs queries as `supabase_read_only_user` in a read-only transaction.
  Don't add SQL filtering as a "safety" layer; it would imply a guarantee
  the script doesn't make.
- **`-w` is the one way to write**: it posts to `/database/query` with a
  second, Full token, `SUPABASE_ACCESS_TOKEN_RW`, and runs as `postgres`
  (observed 2026-11-02). Its gates are that key's absence by default, the
  skill's yes to the exact SQL, and the `Bash(...)` and `PowerShell(...)`
  ask rules on `*supabase-query.sh*-w*` in `.claude/settings.json`. The
  script refuses `-w` bundled with another flag so the rules see the
  usual form; a flag in a variable still gets past them, as a rule is no
  boundary. Keep that check in any change to the arguments.
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
endpoint behavior needs all three updated.
`scripts/dev/check-docs-in-step.sh` checks the flags, exit codes and row
cap, and that `-h` prints the whole header, with its exceptions listed
in the script; observed behavior and its dates it does not check.
Observed, undocumented behavior is dated (for example "observed
2026-11-02"); keep that convention, and re-date a claim when you re-test
it. The endpoint is marked beta by Supabase.
