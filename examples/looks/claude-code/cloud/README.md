# Continue a Claude session in the cloud or locally

## Local Claude CLI session to cloud

1. In the pane for the project, choose **Open Latest Local CLI Session in Claude Desktop** from the palette. It runs `claude --desktop --continue` for the most recent local CLI conversation in that directory. For a session still open in a Claude terminal, run `/desktop` inside that conversation. For a specific inactive session, use `claude --desktop --resume <session-id>`.
2. In the Desktop Code tab, check the session title and conversation. Open its session menu and choose **Open in → Cloud**.
3. Review the dialog for file transfer and local archiving, then confirm. Claude carries a summary of the conversation into the cloud session.

The launcher requires Claude Code 2.1.285 or later, Claude Desktop, and a signed-in Claude subscription on macOS or x64 Windows. Desktop offers cloud handoff for local sessions. An SSH or WSL session is ineligible. The CLI exposes no direct upload of an existing session. Desktop accepts a local Claude CLI session ID. This setup has no transfer API for a cmux-native chat transcript.

## Claude cloud session to local CLI

Choose **Resume Claude Cloud Session in CLI…** from the palette, then pick a cloud session. This runs `claude --teleport` in a new local terminal tab. Later work in the local copy stays there.

## Choose a cmux computer

With a cmux chat focused, press **⌘J** then **C** to open its computer picker. This selects a cmux machine. Claude Desktop owns the outbound Claude cloud transfer described above.

![Actions for Claude cloud handoff, local resumption, and cmux computer selection](preview.png)

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/cloud@feat-cmux-next
```

To install from this pull request, replace `feat-cmux-next` with its head SHA.

## Remove

```sh
cmux setup remove manaflow-ai/claude-code-cloud
```

## Source

[Desktop handoff and confirmation](https://code.claude.com/docs/en/desktop#continue-in-another-surface) · [CLI handoff direction](https://code.claude.com/docs/en/claude-code-on-the-web#move-tasks-between-terminal-and-cloud) · [CLI flags](https://code.claude.com/docs/en/cli-reference) · [cmux implementation](https://github.com/manaflow-ai/cmux/blob/97069dfb49aa8e3eca0cd92c42bef96743d95829/webviews/src/agent-session/acpmux/shortcuts.ts#L18)
