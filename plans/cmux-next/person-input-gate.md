# The person-input gate

Owner: the agent pane (CmuxNextAgentPane). Rules in Rust: cmux-tui `cmux-agent-pane-policy`
(`policy.json` `gesture_rules`), kept equal to `AcpmuxPaneMethods.gestureRules` by
`tests/swift.rs`.

## Sending never needs it

Leo, 2026-11-17, on a chat message marked "Not sent: it needs your own key press or click": go
remove it. A send goes whoever pressed Send: the person, computer use, a script, an agent, MCP or the
CLI. No send method has a gesture rule: `session/prompt` (Send and Retry), `_acpmux/queue_approve`,
`_acpmux/review_verdict`, `_acpmux/btw` (and `chat.btw.inline`), `_acpmux/side_chat`,
`chat.fix_from_link`, `_acpmux/agent_pair_resume`, `_acpmux/agent_hold`, `_acpmux/app_reply`,
`_acpmux/race/start`, a Cloud start (`cloud.startChat`), a new chat on
another machine (`session/new` on a remote wire), and uploads (`chat.upload`, `chat.upload.begin`:
the page sends the bytes, so an upload reads nothing of this Mac's). A send's ticket
(`transport.gesture` for a prompt, Fix from a link or a Cloud start) is issued with no gesture and
only carries the pick and the uploads it holds; a spent or unknown ticket never refuses a send.

"Computer use can act as me" (the grant that let posted input count for Send, Retry and Approve)
existed only for this gate and is gone with it, with its card, pill, Keychain grant and the
`ComputerUseActsAsPerson` managed key.

## What still needs the person

A frame that grants something past a send still needs the person's own key press or click in the
pane (`AgentPaneUserGestures`); who posted an event decides whether it is the person's
(`AgentPanePersonInput.isPerson`): an agent's permission answer (a click only), a permissive mode or
config option, a folder trust, a harness enable, a secret, a sign-in, standing guidance
(`_acpmux/context_override`, `_acpmux/memory_resolve`), a preset approval and a plan build. These
are the boundaries an agent driving the Mac must not cross on its own. So are a shell line
(`shell.run`, `tab.open` with a command: rendered chat output must not run a line on this Mac) and
attaching a chat outside the pane's scope (its scope credit), and Run on a bigger machine's Run
(`_acpmux/run_elsewhere/start`: it sends the chat's command, files and maybe secrets to another
machine).
