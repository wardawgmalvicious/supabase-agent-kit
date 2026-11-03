---
paths:
  - "docs/handoffs/**"
---

# Before touching a brief

A brief, a file in `docs/handoffs/execute/` or an issue on the repo's
board, is one unit of work, written so a session with none of its
writer's context can pick it up. Its frontmatter is its whole state, and
its body restates none of it. No file lists the queue; this prints it
from the briefs and the board:

```bash
uv run --no-project ~/.claude/skills/triage-inbox/scripts/handoff-status.py . --no-inbox
```

The `lint-briefs` pre-commit hook runs the same script with `--check`, and
fails a commit on a bad value, a brief with no frontmatter, or a
`blocked-by` naming a brief that is gone.

| Key | Takes |
| --- | --- |
| `status` | `open` or `deferred`; landing deletes the brief |
| `priority` | `1` now, `2` next, `3` later; no order within one |
| `needs` | a list: `user`, `tenant`, `desktop` or a short phrase; `[]` when a session can act alone |
| `blocked-by` | a list of brief filenames in `execute/`, or issue numbers, bare: `[a.md, 62]` |
| `parent` | optional: the issue number its issue is a sub-issue of, bare |
| `reopen-when` | the trigger; required when `deferred` |
| `written` | `YYYY-MM-DD` |
| `work-model` | optional: `haiku`, `sonnet`, `opus` or `fable` |
| `work-effort` | optional: `low`, `medium`, `high`, `xhigh` or `max` |
| `platform` | optional list, each a `platform:*` label in `~/.claude/skills/provision-board/references/board-contract.md` |

Each is `key: value` or `key: [a, b]`; YAML misreads a value opening with
a quote or backtick, or holding a colon before a space or `#` after one,
so an issue is `62`, never `#62`.

- **Work a brief in a worktree named after it**, its filename less `.md`:
  the queue view marks it in flight while that worktree exists.
- **`needs: [user]` is a question for the user**, not a call to make for
  them. A decision lands as yes, no or defer; a defer keeps the brief,
  `deferred` with its `reopen-when`.
- **A brief's worktree lands from the main checkout, with no push**:
  rebase its branch on `main`, run `pre-commit run --all-files` in the
  worktree, `git merge --ff-only` the branch from the main checkout,
  then remove the worktree and delete its branch. The user pushes.
  `/lead-sessions` lands by this line, and stops in a repo that has none.
- **Landing deletes a file's brief** in the commit that finishes its
  work: drop its name from every `blocked-by`, and re-point what linked
  to it. An issue closes when a commit saying `Closes #<n>` reaches the
  default branch.
- **A filename is a link target**, so it carries no date or number.
