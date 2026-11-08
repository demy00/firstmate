# Claude Code 2.1.319 titled composer captures

These files are the visible viewport of a named Claude Code 2.1.319 session in a 142-column Herdr 0.7.4 pane, replayed by `test_claude_titled_composer_reads_wrapped_input_back` in `../../fm-composer-lib.test.sh` and by the `titled_wrapped` cases in `../../fm-backend-herdr.test.sh`.
They were recorded on 2026-11-08 on macOS arm64 with `herdr pane read <pane> --source visible --format ansi`, which ends each row with CRLF.

## Capture provenance

Every row outside the composer is unchanged Herdr output: the right-aligned `✘ Auto-update failed · Run claude doctor` notice, the titled top rule `───…─── LifeMate ─`, the solid closing rule, the transcript-saving warning, the statusline, and the mode row.
The transcript above the notice is dropped, and the label after the mode row's trailing `⧉` is replaced by `notes`.
The composer rows are Claude's own rendering at that width: Herdr draws typed input as plain text after `❯` and U+00A0, with each continuation row indented by two spaces, and the row breaks are where real Claude Code 2.1.319 wrapped the same text in a 142-column window.

| File | Composer |
| --- | --- |
| `idle.ansi` | Empty: `❯` and U+00A0 alone |
| `doorbell-typed.ansi` | The steering doorbell for a `lifemate.inbox` inbox, wrapped over two rows |
| `draft-typed.ansi` | A typed draft wrapped over three rows |

## Replay limits

The replays prove how the shared classifier and the Herdr adapter read these exact screens.
Whether the installed Claude still renders a wrapped composer under its titled rule this way is the live guard's question: the `claude-named-wrap` arm of `tests/fm-composer-matrix-live-e2e.test.sh`.
