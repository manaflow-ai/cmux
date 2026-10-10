title: Keys typed right after a split or a new tab are never lost
category: fixed

When you press Cmd-D or open a new terminal tab and type at once, every key now goes to the new terminal, in order. Before, the first keys could go to the old pane, or the end of the line could go there.

If you click somewhere else, switch workspace or switch window before the new terminal is ready, the keys go to the terminal that has focus in that window. The first Cmd-T after launch also keeps every key that you type into the New Tab field.
