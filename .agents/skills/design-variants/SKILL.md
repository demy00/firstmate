---
name: design-variants
description: >-
  Load when the captain asks to see several design versions of a UI side by side, or to try a design more than one way before choosing, whether in live code or in Paper.
user-invocable: false
metadata:
  internal: true
---

# design-variants

Build several versions of one UI surface, let the captain compare them and pick, then turn the pick into a PR.
One run has one mode, which changes only the build step (section 3 or 4); every other step is shared.

- **Code mode** builds live versions in parallel, default 3, each by its own scout in its own isolated copy on its own local port.
- **Paper mode** has one design scout draw the versions one after another on a new page of a Paper file, default 5, raised to 10, 15 or more on the captain's word.

## 1. Intake

- Resolve the project, the surface (page or component), and the base branch as for any task (`AGENTS.md` section 7).
- Use the mode the captain named ("in code" or "in Paper").
  When the captain named none, suggest one with a one-line reason and ask for confirmation together with the directions: Paper for wide exploration, many versions, or image inspiration; code for a few versions that must run with real content and behavior.
- From the captain's input (sketch, words, references, pasted images), propose one one-line direction per version.
  When the captain gave a concrete sketch, version 1 is that sketch built literally.
- Paper mode: name the Paper file the run may draw in.
  "ada" is the standing file; any other file needs the captain's OK for this run.
- Send the mode, the count, the directions, and in Paper mode the file, in one message, and start no worker until the captain OKs them or edits them.
  Choosing the directions is the captain's design call.
- File one backlog item for the run; it carries the pick in section 5.

## 2. Shared worker instructions

Scaffold every worker's instructions as a scout with `bin/fm-brief.sh` and spawn through `bin/fm-spawn.sh` (`AGENTS.md` section 4).
In every brief:

- `## Captain's intent` holds the captain's own words, sketch, and references, the same for every version.
- `## Firstmate spec` holds the version's direction or directions only, built on the project's existing design tokens and content.
- The worker commits on its local branch at most, never pushes, never opens a PR, and shares no link.
- The worker hosts no Lavish board of its own; firstmate hosts the compare board (section 5).
- The report at `data/<id>/report.md` names, per version, its direction, what was built and why, and its screenshot paths.

## 3. Build in code mode

- Run `bin/fm-capacity.sh` first; every version is a worker and counts toward the worker limit, so lower the count to the free lanes and tell the captain rather than exceeding it.
- Version n gets port 44n0 (4410, 4420, 4430, ...).
  Before assigning it, prove it free with `lsof -nP -iTCP:<port> -sTCP:LISTEN`; when it is taken, take the next free port above it and never stop the process that holds it.
- One scout per version, task id `<slug>-v<n>`.
  Its spec adds: start the dev server bound to 127.0.0.1 on the assigned port with a strict port (stop rather than move to another port), keep it running after reporting, and include screenshots at 1440 and 390 wide.
- Spawn every version in the same turn.

## 4. Build in Paper mode

Several agents cannot draw on one Paper board safely, so one design scout draws every version in sequence.

- One scout, task id `<slug>-paper`, with `- app: Paper` under the brief's `# Needs` so the spawn refuses when Paper is not running.
- Save the captain's pasted inspiration images under `data/<id>/inspiration/` and list their paths in the brief.
- Its spec adds: the Paper file named at intake is the only file it may draw in; create one new page for this round and touch no other page; draw one artboard per direction, named `v<n> <direction>`; state on each artboard and in the report which inspiration images it borrowed from; export a screenshot of every artboard into `data/<id>/`.

## 5. Compare and pick

- When every version has reported, build one Lavish page with one panel per version: its direction and screenshots, plus in code mode the live URL and live iframes at 1440 and 390 wide, and in Paper mode the borrowed images and the Paper file and page to open.
  In Paper mode the Paper page itself is also a compare view.
- The page's form offers: pick one / combine (which parts from which versions) / another round (notes per version) / none.
- Open and arm the page as a firstmate-owned Lavish source through `process-event-sources`, and keep the versions' servers and the Paper page alive while it is open.
- Hold the pick on the run's backlog item through `captain-hold-lifecycle`: one held task for the whole pick, never one per version.
- Load `scout-completion` as each worker reports; a version's report does not end the run.

## 6. Another round

- Code mode: route each version's notes only to that version's worker with `bin/fm-send.sh`; it updates in place on the same port and reports.
- Paper mode: route all notes to the one design scout; it draws the new round on a new page, leaving earlier pages as they are.
- Refresh the compare page and keep the pick held.

## 7. Land and clean up

- **Pick, code mode:** promote that version's scout through `scout-completion` with the project's delivery mode, with the version's screenshots in the PR.
- **Pick, Paper mode:** either write a ship brief that builds the picked artboard, naming its file, page, and screenshots, or, when the captain wants a final live choice, seed a code-mode run of 2-3 versions with the picked design as the sketch, back at section 1.
- **Combine:** write a new ship brief naming the versions and the parts to take from each.
- **None:** record the captain's answer and close the run.
- Record the captain's words through `captain-hold-lifecycle` before acting on any of these.
- Have every worker stop the dev server it started, then clean up the versions that were not picked; scout copies are scratch once their report exists.

## Guardrails

- Nothing leaves the Mac until the pick: no pushes, no PRs, no shared links.
- Dev servers listen on 127.0.0.1 only.
- Versions count toward the worker limit.
- Never stop a process you did not start to free a port.
- A Paper run draws only in the file it named, on its own new pages.
