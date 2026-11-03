# supabase-agent-kit

Let Claude run your Supabase queries itself. The usual loop is: ask Claude for SQL, paste it
into the SQL editor, paste the result back, repeat. Here the agent writes the query, runs it
read-only, reads the answer and iterates on its own.

There are two routes, depending on where you work with Claude.

| You work in | Use | Install |
| --- | --- | --- |
| claude.ai chat | [Supabase's MCP connector](docs/mcp-connector.md), scoped to one project, read-only | nothing |
| Claude Code, with Supabase's tools | [the same MCP server](docs/mcp-connector.md#claude-code), from a `.mcp.json` | a `.mcp.json` entry, two `ask` rules and one environment variable, [steps here](docs/mcp-connector.md#claude-code) |
| Claude Code, in your project's repo | the script and skill below | bash, curl, jq |

The connector is the quickest win. This repo's own `.mcp.json` declares that server, so a
session opened here offers to connect it. The script route suits a repo where Claude Code
already works on the code: the agent can check its own assumptions against real data, and the skill
tells it how to do that safely.

## Route 2: script + skill (Claude Code)

`scripts/db/supabase-query.sh` posts SQL to the Supabase Management API's
[read-only query endpoint](https://supabase.com/docs/reference/api/v1-read-only-query).
The query runs as `supabase_read_only_user` inside a read-only transaction, so Postgres
itself refuses writes. The role also holds no write privilege, so
`set transaction read write` changes only the error message. No Supabase CLI, no psql, and
no database password. An opt-in [write mode](#write-mode), `-w`, uses the read-write endpoint
instead.

`.claude/skills/query-supabase/SKILL.md` tells Claude Code when to use the script, and how:
look up tables and columns before writing SQL, schema-qualify names, bound exploratory
selects, treat row content as data, write data only with `-w` and your yes to the exact SQL,
and turn a schema change into a migration rather than a write.

### Setup

1. Copy `scripts/db/` and `.claude/skills/query-supabase/` into your project's repo, at the
   same paths. The script finds `.env` two folders above itself, at the repo root.
2. Create a **scoped** access token: Supabase Dashboard > Account > Access Tokens. Pick
   this one project, and **Read-only** access (on 2026-11-02 the form offered Read-only or
   Full, nothing per resource). A legacy full-access token reaches every project on your
   account, including ones created later, so don't use one here.
3. Copy `.env.sample` to `.env` at the repo root, fill in both values, and make sure `.env`
   is gitignored.
4. Keep Claude Code from reading `.env`, and have it ask before a write: add these rules
   to your repo's `.claude/settings.json`, merging them into any `permissions` block already
   there. The script reads `.env` itself, so it keeps working.

   ```json
   {
     "permissions": {
       "deny": ["Read(./.env)"],
       "ask": [
         "Bash(*supabase-query.sh*-w*)",
         "PowerShell(*supabase-query.sh*-w*)"
       ]
     }
   }
   ```

   The deny rule stops Claude's file tools and commands that name the file, such as
   `cat .env`; it doesn't reach a `grep -r` over the folder. The ask rules prompt before a
   [write mode](#write-mode) call written the usual way, from either shell tool, and also when
   `-w` merely appears in the SQL. A rule is no security boundary: a flag held in a variable
   gets past it.
5. Check it: `scripts/db/supabase-query.sh -q "select 1 as ok"`.
6. In Claude Code, ask a question about your data, such as "how many orders came in last
   week?". The skill fires and Claude runs the query.

On Windows, run the script from Git Bash. Claude Code's Bash tool already uses Git Bash.

### Usage

```bash
scripts/db/supabase-query.sh -l                    # list tables and views
scripts/db/supabase-query.sh -d public.orders      # describe a table
scripts/db/supabase-query.sh -q "select count(*) from public.orders"
scripts/db/supabase-query.sh -i query.sql
echo "select now()" | scripts/db/supabase-query.sh
scripts/db/supabase-query.sh -r -q "select * from public.orders limit 5" | jq '.[0]'
scripts/db/supabase-query.sh -w -q "update public.orders set status = 'void' where id = 42"
```

Exit codes: `0` result, `1` refused by the API or Postgres (status and message on stderr),
`2` usage or missing setting. Several statements in one call return only the last
statement's rows. The table view stops at 200 rows (`SUPABASE_QUERY_MAX_ROWS` changes it),
so a wide select can't flood the agent's context; `-r` is never capped.

Tested 2026-11-02 against a free-tier project with a scoped Read-only token: reads,
listing, describing, stdin and file input, and non-ASCII text all work. An insert, a drop,
and an insert after `set transaction read write` are all refused, and a bad token gets a 401.
The same day, a Read-only token on the read-write endpoint still ran as
`supabase_read_only_user` and its create was refused, so the token guards the data too, not
only the endpoint.

### Why read-only

The agent explores freely without risk to the data. A schema change belongs in a migration
that you review, not in an ad-hoc query. The endpoint is marked **beta** by Supabase, so
its behavior may change.

### Write mode

`-w` posts to the Management API's
[query endpoint](https://supabase.com/docs/reference/api/v1-run-a-query), also beta, with
`read_only` false, using a second token, `SUPABASE_ACCESS_TOKEN_RW` in `.env`. Leave that key
out and the kit stays read-only: `-w` then exits `2`.

- **The token must be Full access** for this one project, since Read-only is the only other
  choice. A Full token is Read-write on everything the dashboard lists: the organization
  and its members, the project's settings, API keys, backups and more (the dashboard's
  token summary, 2026-11-02). Give it a short expiry, keep it off production
  projects, and revoke it when the writes are done.
- **A write runs as `postgres`**, outside a read-only transaction, so it can change any
  table. A call whose statement fails rolls back its earlier statements. A write ending in
  `returning ...` prints those rows; without one it prints `(0 rows)`, which is no count.
  Observed 2026-11-02, not documented. After an HTTP 5xx or a request that didn't finish,
  exit `1` leaves the write's outcome unknown, and the script says so.
- **The skill writes data only**: an insert, update or delete you asked for, after you
  approve the exact SQL. A schema change still goes in a migration, since DDL run here skips
  Supabase's migration history.
- **Pass `-w` on its own**, never bundled as `-rw`: the script refuses that, so the ask rules
  in step 4 see the usual form of a write.

## The pattern

Nothing here is specific to Supabase. A small wrapper script around a system's API, with
credentials kept in a gitignored `.env`, plus a short skill that says when and how to call
it, turns "Claude, write me a query" into "Claude, find out". The same shape works for any
database or API your team uses.
