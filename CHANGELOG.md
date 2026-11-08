# Changelog

All notable changes to this fork are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Claude second mates launch with transcript saving on, even when their terminal inherits Claude's child-session marker, so a restart keeps their conversation.
- Relaunching a second mate, by hand or through the automatic liveness respawn, keeps its recorded model and effort when its configured pin names neither.

### Changed

- Merged upstream kunchenguid/firstmate main into the fork, bringing the self-repository role gate, more dispatch providers and worker runtimes, and many supervision fixes (#19).

### Fixed

- Steering doorbells now reach a named Claude session on Herdr whose doorbell wraps onto a second composer row, instead of being cleared and reported as never reaching the pane.
