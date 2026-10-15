title: Stopping the agent daemon keeps your agents running

`cmux acp daemon shutdown` now stops only the agent daemon: agents keep running and the next daemon picks them up, the same as a restart or an update. Add `--end-agents` to end every agent too. Before, a plain shutdown ended every agent on the machine, including agents that other windows or other people were using.
