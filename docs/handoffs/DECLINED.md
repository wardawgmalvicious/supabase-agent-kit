# Declined

Learnings that reached this repo's inbox and were refused. `/triage-inbox`
reads this before it gives a verdict, and is its only writer. Entries
are dated and never corrected in place: a learning that comes back with
new evidence gets a verdict, or a new entry.

## 2026-11-02 — bind `-d`'s schema and table through the query endpoint's `parameters`

- **From**: a note of 2026-11-02, by the session that built the kit, in
  the agent payload repo.
- **Why not**: its stated gain, accepting mixed-case names, is already
  there. `-d`'s regex in `scripts/db/supabase-query.sh` takes upper
  case, and the two names are compared as string literals against
  `information_schema.columns`, so a table created as `"MyTable"` is
  described by `-d public.MyTable` (the regex re-run 2026-11-02:
  `MyTable` accepted, `my table` and `café` rejected). What binding
  would add is only names that need quoting, such as one with a space
  or a non-ASCII letter, which no install has reported. The request
  body's `parameters` array is untried.
- **Would change it**: an install whose table or schema name needs
  quoting, or a test showing the endpoint binds `parameters`, which
  would then let `-d` drop the regex.
