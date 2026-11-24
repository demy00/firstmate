# Voice replies

Voice replies speak a short line from each captain-facing reply out loud on the Mac, so the outcome can be heard without reading the whole reply.
This build covers speaking on the Mac only.
Sending the line to a phone, cloud voices, and answering by voice are not built yet.

## What is spoken

Only one line of a reply is spoken: the last line that starts with `🔊`.
The agent writes that line for the ear, as one to three plain sentences with the outcome and the one thing it needs, and no paths, links, ids, or code.
A reply without a `🔊` line is not spoken, so supervision turns and replies with nothing for the captain stay silent.

The `🔊` line is also visible in the chat, where it works as a short summary.
Whether and how an agent writes the line is part of the captain's working agreement in the home's captain preference files, not of Firstmate's shared code.
This feature only speaks the line once it is there.

Leading space and Markdown quote or emphasis marks before the `🔊` are allowed, and `*` and backticks are dropped before speaking.

## Turn it on

1. Create `config/voice-replies` in the home with the line `mode=mac`.
2. Optionally download a better voice once in System Settings > Accessibility > Read & Speak (the Premium and Enhanced voices are free), and name it on a `voice=` line.
3. Optionally add quiet hours, such as `quiet=22:00-07:00`.

For example:

```
mode=mac
voice=Zoe (Premium)
quiet=22:00-07:00
```

The hook reads the file at every reply, so a change applies from the next reply in any session that has loaded the hook.
Set `mode=off` or remove the file to turn it off.
[`docs/configuration.md`](configuration.md#voice-replies-configvoice-replies) owns the full file format.

## Where it speaks

It speaks only in a Claude Code session of a Firstmate primary home: the main home, or a second mate's home whose own `config/voice-replies` turns it on.
The file is per home and is not inherited, so a second mate stays silent until its own home has the file.
Worker sessions never speak, even when the home that started them has voice replies on.

Remote Control keeps the session running on the Mac, so a reply to a message sent from the phone is still spoken on the Mac.

## Behavior

- The session never waits for speech, because the hook runs in the background.
- Speech starts about two seconds after the reply, so a reply that is replaced right away is never spoken.
- A newer reply cuts off an older one that is still speaking.
- The same line twice within two minutes is spoken once.
- During quiet hours nothing is spoken.
- The spoken text is never written to a log or a state file.
- A voice name that is not installed falls back to the system voice instead of staying silent.

## Limits

- Claude Code only: the hook is a Claude Code Stop hook, and other primary harnesses do not run it.
- A one-shot `claude -p` run exits before its background hooks finish, so its reply is not spoken; an interactive session, including one driven through Remote Control, is.
- A reply delivered through a tool, such as a channel's `reply` tool, is not the session's final message and is not spoken.
- `phone` and `auto` are reserved mode values for later builds and are silent today.

The script header of [`bin/fm-voice-reply.sh`](../bin/fm-voice-reply.sh) owns the mechanics, and `tests/fm-voice-reply.test.sh` verifies them with a fake `say`.
