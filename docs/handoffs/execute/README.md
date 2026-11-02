# Open briefs

Each brief here is one unit of work, written so a session with none of
its writer's context can pick it up, and holds its own state in
frontmatter. `.claude/rules/handoff-briefs.md` has the keys, and loads on
the first Read under `docs/handoffs/`. The queue is printed, never kept:

```bash
uv run --no-project ~/.claude/skills/triage-inbox/scripts/handoff-status.py . --no-inbox
```

A brief is deleted in the commit that lands its work, so git history is
its archive. Learnings from sessions in other repos arrive as notes in
`~/handoff-inbox/<this repo's directory>/`, and `/triage-inbox` turns
each into a verdict, a brief here among them.
