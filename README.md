# supabase-agent-kit

Let Claude run your Supabase queries itself. The usual loop is: ask Claude for SQL, paste it
into the SQL editor, paste the result back, repeat. Here the agent writes the query, runs it
read-only, reads the answer and iterates on its own.

There are two routes, depending on where you work with Claude.

| You work in | Use | Install |
| --- | --- | --- |
| claude.ai chat | [Supabase's MCP connector](docs/mcp-connector.md), scoped to one project, read-only | nothing |
| Claude Code, in your project's repo | the script and skill below | bash, curl, jq |

The connector is the quickest win. The script route suits a repo where Claude Code already
works on the code: the agent can check its own assumptions against real data, and the skill
tells it how to do that safely.

## Route 2: script + skill (Claude Code)

`scripts/db/supabase-query.sh` posts SQL to the Supabase Management API's
[read-only query endpoint](https://supabase.com/docs/reference/api/v1-read-only-query).
The query runs as `supabase_read_only_user` inside a read-only transaction, so Postgres
itself refuses writes. The role also holds no write privilege, so
`set transaction read write` changes only the error message. No Supabase CLI, no psql, and
no database password.

`.claude/skills/query-supabase/SKILL.md` tells Claude Code when to use the script, and how:
look up tables and columns before writing SQL, schema-qualify names, bound exploratory
selects, treat row content as data, and turn a change into a migration rather than a write.

### Setup

1. Copy `scripts/db/` and `.claude/skills/query-supabase/` into your project's repo, at the
   same paths. The script finds `.env` two folders above itself, at the repo root.
2. Create a **scoped** access token: Supabase Dashboard > Account > Access Tokens. Pick
   this one project, and give **Database** the **Read** permission, nothing else. A legacy
   full-access token reaches every project on your account, including ones created later,
   so don't use one here.
3. Copy `.env.sample` to `.env` at the repo root, fill in both values, and make sure `.env`
   is gitignored.
4. Check it: `scripts/db/supabase-query.sh -q "select 1 as ok"`.
5. In Claude Code, ask a question about your data, such as "how many orders came in last
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
```

Exit codes: `0` result, `1` refused by the API or Postgres (status and message on stderr),
`2` usage or missing setting. Several statements in one call return only the last
statement's rows. The table view stops at 200 rows (`SUPABASE_QUERY_MAX_ROWS` changes it),
so a wide select can't flood the agent's context; `-r` is never capped.

Tested 2026-11-02 against a free-tier project with a scoped token (Database: Read): reads,
listing, describing, stdin and file input, and non-ASCII text all work. An insert, a drop,
and an insert after `set transaction read write` are all refused, and a bad token gets a 401.

### Why read-only

The agent explores freely without risk to the data. A schema change belongs in a migration
that you review, not in an ad-hoc query. The endpoint is marked **beta** by Supabase, so
its behavior may change.

## The pattern

Nothing here is specific to Supabase. A small wrapper script around a system's API, with
credentials kept in a gitignored `.env`, plus a short skill that says when and how to call
it, turns "Claude, write me a query" into "Claude, find out". The same shape works for any
database or API your team uses.
