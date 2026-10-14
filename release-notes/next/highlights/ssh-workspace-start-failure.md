title: A terminal that cannot start on an SSH machine says why
category: fixed

When the first terminal of a workspace does not start, for example on a slow SSH machine, the workspace now shows the reason and lets you press Return to try again. Before, it stayed blank and Cmd-T did nothing. A new workspace on an SSH machine that fails now names the real cause instead of "not connected".
