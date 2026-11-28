# Agents and subagents

Run Claude Code, Codex, and other agents as chats.

An agent runs as a chat tab. The chat shows messages, tool calls, and diffs. The agent itself lives in acpmux, a daemon, so it keeps running when the app closes.

## Start and stop

```bash
cmux agent quick          # start an agent
cmux agent new-chat       # new agent chat in this pane
cmux agent stop-turn      # stop the current turn
cmux agent archive-chat
```

## Fork a conversation

A fork copies the conversation so you can try another path. Fork to the right, left, above, below, a new column on either side, a new row, a new tab, a new workspace, or a new window.

```bash
cmux agent fork-conversation-to-right
cmux agent fork-conversation-to-new-column-right
cmux agent fork-conversation-to-new-workspace
```

## Teams

```bash
cmux agent launch-claude-teams
cmux agent launch-codex-teams
```

## Subagents

A subagent is an agent another agent started. It gets its own workspace and chat, so you can open it, read it, and stop it like any other.

- [acpmux, the agent daemon](acpmux.md)
- [Run agents on your own API keys](own-keys.md)
- [Open-weight models](open-models.md)
- [Audit agent spend](agent-spend.md)
