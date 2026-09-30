---
name: clickup-tickets
description: Rules for managing the owner's ClickUp tickets through the pinned `cup` CLI. Use the first time ClickUp work comes up in a session (never at session start), for any ClickUp read or write, when filing new project work, when a task changes state (started, PR ready, decision needed, failed, merged, cancelled), and when the owner asks what is on their plate.
user-invocable: false
metadata:
  internal: true
---

# ClickUp tickets

ClickUp is the shared truth about what work exists. Each firstmate's queue is a private working copy of it. "The owner" is the person whose firstmate this is.

## Applicability boundary

These rules bind from installation forward. They never rewrite tickets people wrote and never bulk-upload an existing queue.

## Access rules

1. Use only the `cup` command-line tool (npm `@krodak/clickup-cli`, pinned to exactly 1.46.1). Never use a ClickUp connector or MCP server.
2. Only firstmate and its cheap helper touch ClickUp. Workers never do. Hand workers the ticket text they need, not credentials or commands.
3. Never read, print, log, or copy a token. Do not run `cup config get` on token keys or print `cup config path` file contents. `CU_API_TOKEN` and `CU_TEAM_ID` in the environment override every profile; if they are set, stop and tell the owner.
4. Pick the workspace with the global flag `-p <profile>`: `cup -p <profile> <command>`. One profile per workspace. Never rely on the default profile for a write.
5. Settings live in `config/clickup.json` (gitignored, private). Read it for: the owner's user id, profiles (name -> workspace id, kind `personal` or `team`), the project map (firstmate project -> profile, list id, repository tag), and the life list. If a project is not in the map, ask the owner; do not guess a list.
6. Add `--json` when a helper or script parses the output.

## Scope and starting work

- Every ticket assigned to the owner is in scope.
- Work starts ONLY when the owner asks. A ticket appearing, being assigned, or being tagged never starts anything.
- Firstmate-originated work: when firstmate files new project work, ask the owner "ticket or local only?". Existing queue items are never bulk-uploaded. An old item gets the same question when it comes alive: the owner asks about it, it is started, or it needs a decision.

## Workspace limits

- Personal workspace (`kind: personal`): firstmate creates, updates, and closes tickets freely.
- Team workspace (`kind: team`): touch only tickets assigned to the owner or claimed by the owner's firstmate. A claim is made when the owner tells firstmate to take a ticket; record it with a comment ("claimed by the owner's firstmate"). Delete nothing, archive nothing, never use `cup delete`, `cup archive`, `cup list-delete`, `cup folder-delete`, `cup space-delete`, or any `cup bulk` command there. Never create lists, folders, or spaces there.
- Team tickets carry one repository tag each (the `repositoryTag` of the project).
- Never put ticket content from a team workspace into this repository or any fork's tracked files.

## Statuses

The same eight everywhere. Use the exact names.

| Firstmate state | ClickUp status | Comment carries |
|---|---|---|
| ticket exists, not started | `to do` | - |
| investigation or design, no code change | `planning` | what is being investigated |
| worker building | `in progress` | task/branch name |
| PR ready, decision needed, credential needed (waiting on the owner) | `update required` | PR URL, the question, or the credential needed |
| parked, or external wait | `on hold` | what it waits for |
| failed or stuck | `at risk` | the failure |
| delivery proven (merged and verified) | `complete` | PR URL and proof |
| owner said to drop it | `cancelled` | the owner's word |

Rules:
- `complete` ONLY after delivery is proven. An open PR is `update required`, never `complete`.
- `cancelled` only on the owner's word.
- Every move gets a one-line comment stating the fact behind it (PR URL, the question, the failure).
- `-s` is fuzzy matched ("prog" matches "in progress"), so always pass the full exact name and re-read the ticket afterwards to confirm the status landed.

## Re-read before write

Immediately before any change to a ticket (status, description, tags, assignee), re-read it:

```
cup -p <profile> task <taskId> --json
cup -p <profile> comments <taskId> --json
```

If it changed since you last looked (status, assignee, description, a new comment), stop and tell the owner instead of overwriting.

## Commands

All commands below are verified against `cup` 1.46.1 help. `<profile>`, `<listId>`, `<taskId>` come from config or the ticket.

Read:

```
cup -p <profile> assigned --json                       # the owner's plate, grouped by status
cup -p <profile> assigned --status "update required" --json
cup -p <profile> tasks --list <listId> --json          # tasks assigned to the owner in one list
cup -p <profile> tasks --list <listId> --all --json    # everyone's tasks in one list
cup -p <profile> search "<words>" --json               # by name, the owner's tasks
cup -p <profile> inbox --days 1 --json                 # recently updated
cup -p <profile> task <taskId> --json                  # one ticket
cup -p <profile> comments <taskId> --json              # its comments
cup -p <profile> activity <taskId>                     # ticket and comments together
cup -p <profile> checklist view <taskId> --json
```

Create (personal or team list from config; long text goes through a file or stdin to avoid quoting):

```
cup -p <profile> create -l <listId> -n "[FEATURE] <title>" \
  --description-file <path> -s "to do" --assignee me --tags <repositoryTag> --json
```

Move and annotate (single moves, firstmate runs these directly):

```
cup -p <profile> update <taskId> -s "in progress"
cup -p <profile> comment <taskId> -m "<one-line fact>"
cup -p <profile> comment <taskId> --message-file <path>
cup -p <profile> tag <taskId> --add <tag>
cup -p <profile> update <taskId> --assignee me
```

PR link once a PR exists: post it as a comment (`cup comment <taskId> -m "PR: <url>"`) and, on tickets firstmate created, also append a `PR: <url>` line to the description. Re-read the description first, then `cup update <taskId> --description-file <path>` with the full text plus the new line.

Class of defects sharing one cause: one ticket with a checklist, not many tickets.

```
cup -p <profile> checklist create <taskId> "<name>"
cup -p <profile> checklist add-item <checklistId> "<item>"
cup -p <profile> checklist edit-item <checklistId> <checklistItemId> --resolved
```

Setup and checks:

```
cup profile list
cup -p <profile> auth
```

## Ticket format (conventions v1)

Title prefix `[FEATURE]`, `[BUG]`, or `[TECH]`, then a short title. Description:

```
## Why
One or two lines.

## Acceptance criteria
- Given <state>, when <action>, then <observable result>.
- Given ..., when ..., then ...

## Breakdown
- [ ] step
- [ ] step

Repository: <repositoryTag>
PR: <added once one exists>
```

- `[BUG]`: add "Steps to reproduce" and "Expected / actual" under Why.
- `[TECH]`: acceptance criteria state the measurable end state (for example "Given the build runs, when lint executes, then it reports zero warnings").
- Non-software tickets use `[LIFE]` and one line: `Done when: <observable condition>`. No Given/When/Then needed.
- Always set the repository tag on software tickets in a team workspace.
- Tickets written by people are never rewritten. When asked to start one that misses the convention, say exactly what is missing and ask the owner. Do not edit it yourself.

## Life tickets

Capture and remind only. Never spend money, send messages, book anything, or sign anything on a life ticket. Put new ones in the life list from config with prefix `[LIFE]`.

## Who runs commands

- Single moves (one status, one comment, one ticket): firstmate runs them directly.
- Bulk and reading work (reading the plate, convention checks, long comment threads, sweeps): spawn a Haiku helper. Give it the exact read-only `cup` commands and profile to run and ask for a short result (ticket id, title, status, and one line each). The helper never writes unless the owner-approved write is spelled out command by command.

## Change detection

- On demand, plus one look at session start: newly assigned tickets (`cup -p <profile> assigned --json` for each profile in config, compared with the working queue) and new comments on tickets under work (`cup -p <profile> comments <taskId> --json`). Delegate this look to the Haiku helper.
- No background polling, no scheduled sweeps, no webhooks. Report what changed to the owner and wait.
- Always re-read a ticket immediately before changing it.
