# Agent session close warning exploration

This exploration is for deciding when closing agent tabs should ask before it closes a working session.

Usage cases:

- Closing a completed session: the agent is idle at its prompt, so closing should be immediate.
- Accidental Cmd-W during a turn: the agent is mid-turn, so closing should ask and name the agent, for example, “Claude Code is still working.”
- Closing a workspace with several agents: each active agent should remain protected by the agent warning; idle agents should not create an extra prompt.

The proposed behavior adds `app.warnBeforeClosingAgentSession`, enabled by default. It applies only to an agent session reported as active by the existing sidebar agent state. The dialog’s “Don’t ask again” changes only this agent-session setting. The existing tab warning remains responsible for ordinary running terminal processes and its own setting. The exploration stays unmerged until Leo and the team decide whether this policy belongs in classic.
