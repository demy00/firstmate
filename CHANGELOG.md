# Changelog

All notable changes to this fork are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- A Claude worker stopped by an account usage limit now declares the wait itself, with the time the limit resets, instead of going silent; the next turn closes it, and `bin/fm-claude-usage.sh resume --due` brings back every worker the reset left idle in one step (#23).
- A design-variants skill: firstmate proposes design directions for a UI, has workers build them as live code versions or as Paper designs, shows them on one compare board for a pick, and turns the pick into a PR.
- A fresh worker spawn refuses instructions that name no required skills, unless `--no-skills "<reason>"` records why in the task record.
- Skill selection falls back to the project's `AGENTS.md` "Skills to load" table when no installed skill clears the confidence floor, or when the selector is off or fails.

### Fixed

- Cleanup with the captain's discard approval now closes a task whose local copy has a broken git link, leaving the copy untouched and reporting its lost pool slot, instead of failing; a copy linked to another task's copy no longer has that task's branch deleted.
- Claude second mates launch with transcript saving on, even when their terminal inherits Claude's child-session marker, so a restart keeps their conversation.
- Relaunching a second mate, by hand or through the automatic liveness respawn, keeps its recorded model and effort when its configured pin names neither.

### Changed

- Merged upstream kunchenguid/firstmate main into the fork, bringing the self-repository role gate, more dispatch providers and worker runtimes, and many supervision fixes (#19).

### Fixed

- Steering doorbells now reach a named Claude session on Herdr whose doorbell wraps onto a second composer row, instead of being cleared and reported as never reaching the pane.
