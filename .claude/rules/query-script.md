---
paths:
  - "scripts/db/**"
  - "scripts/dev/check-docs-in-step.sh"
  - "README.md"
  - ".claude/skills/query-supabase/**"
  - ".claude/skills/migrate-supabase/**"
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

## The migration helper

- **`supabase-migration-sql.sh` only prints.** It reads no `.env` and
  never calls the query script: a helper that ran `-w` itself would hide
  the write from the ask rules, which match the command's text. Keep it
  a printer, applied by a pipe into `supabase-query.sh -w`.
- **Its batch is one call, so it is one transaction**: the CLI's
  history-table setup, the file, then the history insert ending in
  `returning version, name`. A failing statement rolls back the rest
  (observed 2026-11-02), so a change never lands without its row.
- **`statements` holds the whole file as one element**, since splitting
  on `;` breaks dollar-quoted bodies. The CLI's `migration list` and
  `db push` read only `version`, and `migration fetch` rebuilds a file
  from the elements (supabase/cli `develop`, read 2026-11-02); the
  header has the detail.
- **The refusals scan the SQL in jq**, already a requirement, with
  comments, quoted text and dollar-quoted bodies blanked, so PL/pgSQL's
  `begin ... end` passes. It is a light scan, not a lexer: the header
  says what it misses. jq prints nothing until the checks pass and
  leaves by `halt_error` with exit 2.
- **Names and versions are validated, not quoted**: the filename's
  `<version>` and `<name>` reach the SQL as literals, so `<name>` is
  limited to letters, digits, `_` and `-`. The file's SQL sits in a
  dollar quote whose tag the file does not hold.

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

The migration helper's header block is its `-h` output too, printed from
`# Print a Supabase migration` to the first blank line, and its only
full description. The README's "Schema migrations" section and
`migrate-supabase`'s `SKILL.md` restate its pipe and its refusals: change
those with it. `check-docs-in-step.sh` does not read the helper, which
has no flag but `-h`.
