# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A kit that users **copy into their own project's repo**, not an app. It
has two parts, and the README explains both:

- **Route 1**, `docs/mcp-connector.md`: setup notes for Supabase's hosted
  MCP server, scoped by URL parameters, and the `supabase` entry in
  `.mcp.json` that it tells installers to copy. There is no code.
- **Route 2**: `scripts/db/supabase-query.sh`, which posts SQL to the
  Supabase Management API's read-only query endpoint, or with `-w` to its
  read-write one, plus
  `.claude/skills/query-supabase/SKILL.md`, which tells an agent when and
  how to call it.

The script and skill are installed by copying them **to the same paths**
in the target repo. The script finds `.env` at `SCRIPT_DIR/../..`, so
moving or renaming `scripts/db/` breaks every install. The skill also
fires in this repo itself, against whatever project `.env` points at.

How the script works, and how its three descriptions stay in step, are
in `.claude/rules/query-script.md`, which loads on a Read of the script,
the README or `SKILL.md`.

## Commands

No build and no test suite. Lint and format-check the script (both pass
clean, re-run 2026-11-02), and check its three descriptions agree; the
pre-commit hooks `shellcheck`, `shfmt` and `docs-in-step` run all three:

```bash
shellcheck scripts/db/supabase-query.sh
shfmt -d -i 4 -ci scripts/db/supabase-query.sh
scripts/dev/check-docs-in-step.sh
```

`.github/workflows/pre-commit.yml` runs the same hooks on every push to
`main` and every pull request, and scans every commit with gitleaks in a
step of its own, since the hook scans only the index. A `main` ruleset
blocks force pushes and deletion; landing is still a fast-forward push.

`scripts/dev/` is this repo's tooling, not part of the kit.

The only end-to-end test is a live call, which needs a filled-in `.env`
at the repo root (a local one exists and is gitignored):

```bash
scripts/db/supabase-query.sh -q "select 1 as ok"
scripts/db/supabase-query.sh -h    # prints the header block as help
```

Never read, print or echo `.env` or the token. `.claude/settings.json`
denies `Read(./.env)`, `printenv`, `echo` and `printf` commands that name
`SUPABASE_ACCESS_TOKEN`, and any PowerShell command that names it. It does
not cover `env`, bare `printenv`, `declare -p`, `Get-ChildItem Env:`,
`sh -c '…'`, a `grep -r` or a script. README setup step 4 tells
installers to copy the `.env` deny rule and the `-w` ask rules, so
change it with them.

## MCP servers

`.mcp.json` is tracked and declares two servers:

- `supabase`, Route 1 in Claude Code. Its URL takes the project ref from
  `SUPABASE_MCP_PROJECT_REF`, named apart from `SUPABASE_PROJECT_REF`
  because an environment variable overrides `.env` for the query script.
  It signs in by OAuth through `/mcp`; no token. `.claude/settings.json`
  asks before `execute_sql` and `query_logs`, the tools that return row
  and log content. Changing its URL or its rules means updating
  `docs/mcp-connector.md`, which tells installers to copy both.
- `github-mcp`, this repo's own tooling, not part of the kit. It sends
  `GITHUB_PAT_PERSONAL` as its bearer token, and `.claude/settings.json`
  allows its three read-only tools unprompted.

## Handoff briefs

Handoff briefs wait in `docs/handoffs/execute/`, and
`.claude/rules/handoff-briefs.md` has their keys; print the queue with `uv run --no-project ~/.claude/skills/triage-inbox/scripts/handoff-status.py . --no-inbox`.

Without that script: `grep -H -E '^(status|priority|needs|blocked-by|reopen-when):' docs/handoffs/execute/*.md`
