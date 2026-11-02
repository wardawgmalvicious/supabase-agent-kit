# Route 1: Supabase's MCP connector

This route works in claude.ai chat, with nothing to install. Claude runs the query against your
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

```powershell
claude mcp add --transport http supabase "https://mcp.supabase.com/mcp?project_ref=<ref>&read_only=true&features=database,docs"
```

Then run `/mcp` in a session to sign in.

## Before you connect it

Supabase's own guidance, condensed:

- **Not production**, unless the task needs it, and then read-only and project-scoped.
- **Prompt injection**: a row can hold text written to steer the model, such as a support
  ticket body. Read results before acting on them, and keep tool-call approval on.
- **It acts as you.** Never hand the connector to customers or end users.

Source: [Supabase MCP docs](https://supabase.com/docs/guides/getting-started/mcp).
