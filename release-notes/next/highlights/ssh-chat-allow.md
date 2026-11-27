title: Allow works for chats on SSH machines
category: fixed
docs: https://cmux.com/docs/ssh

When a chat on an SSH machine asks to run a command, Allow now runs it there instead of doing nothing. If other agents run on that machine, the chat asks first with a Restart button, and they keep working.
