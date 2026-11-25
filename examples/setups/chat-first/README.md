# Chat-first

The agent chat is the main pane and reads like a messenger: messages, not a transcript. Touches only where the agent lives.

One axis: **where the agent lives**. Nothing here is a default; it changes only what you install.

| Setting | Value |
| --- | --- |
| `layout.mainPane` | `"agent-chats"` |
| `agentPane.display.presentation` | `"messages"` |
| `agentPane.display.transcriptView` | `"normal"` |

Its rival is [terminal-first](../terminal-first/README.md): the two set the same keys, so installing one after the other replaces the earlier one on those keys.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/setups/chat-first@feat-cmux-next
cmux setup remove manaflow-ai/chat-first-setup
```

`remove` puts back what you had on these keys.
