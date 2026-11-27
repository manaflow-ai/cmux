title: Stopping the agent daemon keeps your agents running
category: fixed
docs: https://cmux.com/docs/session-restore

`cmux acp daemon shutdown` now stops only the agent daemon, and the next daemon picks your agents back up. Add `--end-agents` to end every agent too.
