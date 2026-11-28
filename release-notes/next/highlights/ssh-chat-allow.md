title: Allow works for chats on SSH machines

When a chat on an SSH machine asks to run a command, Allow now runs it there. Before, the first Allow on that machine did nothing, because its agent service did not hold this Mac's approval key. cmux now gives the key before the chat starts when nothing else runs on that machine's agent service. When other agents run there, cmux asks first: the chat shows a Restart button, and the running agents keep working through the restart.
