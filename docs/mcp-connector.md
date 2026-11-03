# Route 1: Supabase's MCP connector

This route works in claude.ai chat, with nothing to install, and in Claude Code from a
`.mcp.json` ([below](#claude-code)). Claude runs the query against your
project and reads the result. You no longer copy SQL into the dashboard's SQL editor.

Supabase hosts an official MCP server at `https://mcp.supabase.com/mcp`. It signs in with
Supabase OAuth in your browser, so no token is pasted anywhere. Query parameters on the URL
narrow what it can do:

| Parameter | Effect |
| --- | --- |
| `project_ref=<ref>` | One project only; account-level tools are switched off |
| `read_only=true` | Every query runs as a read-only Postgres user |
| `features=database,docs` | Only the database and docs tool groups |

**Use the scoped URL, not the bare one:**

```
https://mcp.supabase.com/mcp?project_ref=<ref>&read_only=true&features=database,docs
```

## claude.ai

Supabase is in claude.ai's connector directory. The scoping above lives in the URL. If the
directory entry offers no place to set the URL, add the server as a custom connector instead
(Settings > Connectors > Add custom connector), with the scoped URL. Then sign in to Supabase
when prompted, and pick the organization.

## Claude Code

This repo's `.mcp.json` declares the server, so a Claude Code session opened here offers to
connect it. Its URL adds two more tool groups to the one above: `debugging` (log queries,
security and performance advisors) and `development` (the project URL, publishable keys and
TypeScript types). The project ref comes from an environment variable, so the file names no
one's project.

To use it in your own repo:

1. Copy the `supabase` entry from this repo's `.mcp.json` into a `.mcp.json` at your repo's
   root. Leave out the `github-mcp` entry beside it, which is this repo's own.
2. Copy the two `ask` rules from this repo's `.claude/settings.json` into yours. They make
   Claude ask you before every SQL query and log query, even in auto mode.
3. Set `SUPABASE_MCP_PROJECT_REF` to your project ref, as [below](#set-the-project-ref).
4. Quit your editor or the Claude app completely, every window, and reopen it. A program
   reads environment variables once, when it starts, so a reloaded window doesn't see a new
   one.
5. Approve the `supabase` server when Claude Code asks. Then run `/mcp`, pick `supabase`,
   choose **Authenticate**, sign in to Supabase in the browser, and pick the organization.

Tested 2026-11-02 from this repo: the OAuth sign-in worked, and
the session listed only the database, debugging, development and docs tools, with no
`apply_migration`, account, Edge Functions or feedback tools. Each `execute_sql` call asked
for approval first. A query ran as `supabase_read_only_user` with `transaction_read_only`
on, and `create temp table` was refused with `cannot execute CREATE TABLE in a read-only
transaction`.

The other nine tools each ran once the same day, under `read_only=true`, on a project with
one table and no migrations:

- `list_tables`: `["public"]` listed the one table with its RLS flag and row count, and `[]`
  listed all 42 in `auth`, `realtime`, `storage`, `vault` and `public`, each one readable
  by the read-only user ([below](#before-you-connect-it)). The tool's schema requires
  `schemas` and declares `public` its default, while its description says all schemas.
- `list_extensions`: all 78 extensions the project offers, the 5 installed carrying an
  `installed_version`.
- `list_migrations`: `{"migrations":[]}`.
- `query_logs`: asked for approval first, each call. It read seven sources, `auth_logs`,
  `edge_logs`, `pgbouncer_logs`, `postgres_logs`, `postgrest_logs`, `realtime_logs` and
  `storage_logs`. A 49-hour window was refused with `The log window can be at most 24
  hours.`, and its description gives the last 24 hours as the default. How far back a
  window may start is untested.
- `get_advisors`: `security` returned one INFO lint, `rls_enabled_no_policy`, and
  `performance` returned none.
- `get_project_url`: `https://<ref>.supabase.co`.
- `get_publishable_keys`: two keys, the legacy `anon` JWT, whose `role` claim is `anon`, and
  one `sb_publishable_` key. Neither is a secret or `service_role` key.
- `generate_typescript_types`: about 170 lines of TypeScript for the one table, from the
  `public` schema alone.
- `search_docs`: a GraphQL `searchDocs` query, which takes no project argument, returned
  the Row Level Security guide's title and link.

To connect it for yourself in one repo, with nothing committed, `claude mcp add` stores it in
your local scope instead, with the ref written in:

```powershell
claude mcp add --transport http supabase "https://mcp.supabase.com/mcp?project_ref=<ref>&read_only=true&features=database,docs"
```

### Set the project ref

The ref is the ID in your project's dashboard address, `supabase.com/dashboard/project/<ref>`,
and in its API URL, `https://<ref>.supabase.co`. It isn't a secret.

On Windows, either:

- **PowerShell**, in any window:

  ```powershell
  [Environment]::SetEnvironmentVariable('SUPABASE_MCP_PROJECT_REF', '<your-project-ref>', 'User')
  ```

- **Windows settings**: press Start, type `environment variables`, and open **Edit
  environment variables for your account**. Under *User variables* choose **New**, enter
  `SUPABASE_MCP_PROJECT_REF` as the name and your ref as the value, then choose **OK** twice.

To check, open a new PowerShell window and run `$env:SUPABASE_MCP_PROJECT_REF`: it prints
the ref. A window opened before the change prints nothing.

On macOS or Linux, add `export SUPABASE_MCP_PROJECT_REF=<your-project-ref>` to your shell
profile (`~/.zshrc` or `~/.bashrc`), and start Claude Code from a new terminal.

The name isn't `SUPABASE_PROJECT_REF` on purpose. Route 2's script lets an environment
variable override `.env`, so a machine-wide `SUPABASE_PROJECT_REF` would point the script at
this one project in every repo.

If the variable is missing, `/mcp` warns that `SUPABASE_MCP_PROJECT_REF` isn't set, and
Claude Code still sends the URL holding the literal `${SUPABASE_MCP_PROJECT_REF}`. What
Supabase does with that ref, or with an empty one, is untested, so fix the variable before
you connect rather than relying on a failure.

## Before you connect it

Supabase's own guidance, condensed:

- **Not production**, unless the task needs it, and then read-only and project-scoped.
- **Prompt injection**: a row can hold text written to steer the model, such as a support
  ticket body. Read results before acting on them, and keep tool-call approval on. In
  Claude Code, the `ask` rules [above](#claude-code) keep it on for queries.
- **It acts as you.** Never hand the connector to customers or end users.

Source: [Supabase MCP docs](https://supabase.com/docs/guides/ai-tools/mcp), read 2026-11-02.

**Read-only is not row-scoped.** The read-only user is a member of `pg_read_all_data` and has
`BYPASSRLS` (observed 2026-11-02), so a query reads every row a policy would hide,
`auth.users` included.
