preinstall vim + zsh in the docker container
make the default shell zsh, and copy over the user's zshrc and .zshrc plugins stuff into the container
like the ghost text autocomplete (zsh-autosuggestions), history, etc
so the history inside the sandbox should autocomplete like outside the sandbox

preinstall some common editors like emacs, vim, neovim. if user has configs for those editors, we should copy it into the sandbox

implement better mouse scrolling behavior in the terminal, similar to how we do it in the chat scroll area (momentum etc.). touchpad scroll at low velocity should scroll one line at a time.

[x] for cmux, in sidebar, when we navigate, we should automatically show the selected sandbox's terminal in the main area. also, when we make a new tab in the main area (or a new horizontal/vertical split), it should make a new tab in the selected sandbox (aka make a new terminal in the selected sandbox). basically, the workspace on the right will only ever correspond to a single sandbox at a time. so we need a refactor to our data structures to support this. sidebar can hold many sandbox workspaces. each sandbox workspace can hold many tabs/splits (each tab/split will correspond to a single workspace).

add a command pallete action for opening the sandbox's browser that does the same thing as cmux browser <sandbox-id> (auto infer the active sandbox based on the selected one in the sidebar). also, add a command pallete action for opening in the editor. right below open in editor, we should have set default editor command, which should be configurable to a bash command the user provides, eg. (code, cursor, windsurf, vim, emacs, etc.). open in editor should be alt+e.

for command pallete actions for deleting focused tab/panel, i got confused since i searched for delete instead of close. can we add potential synonyms to all the keyboard shortcuts so they're more easily searchable?

[x] dont write code yet. research codebase and lmk how many websocket connectsion are made when user runs the `cmux` command and makes a bunch of sandboxes/tabs/panes.
[x] refactor so each `cmux` command only makes one websocket connection by updating the protocol. implement auto-reconnect with state recovery as well.

for panes focus up/down/right/left, let's do vim style keyboard shortcuts so we should add alt+hjkl in addition to the existing alt+arrows. we should be able to focus to the sidebar as well with alt+h, and focus to the main area with alt+l. (think about how to make this as intuitive as possible). make sure these shortcuts work in sidebar as well as main area.

implement text highlighting->copy for each of the virtual terminals (shouldn't copy text outside of the highlighted region, we should see the highlight, as well as a status message like "copied to clipboard", highlight bg color should be chosen carefully based on the terminal bg color theme)

handle alt+d/alt+D to split the focused pane horizontally/vertically. (lowercase for horizontal, uppercase for vertical)

[x] after running `cmux` and exiting via ctrl+q, and then i open git diff, pressing "q" fails to close the less program

handle option+shift+w to delete an entire sandbox (make sure it's wired up to the command palette action)

for the emulated terminal, support option+backspace to delete the prev word (ctrl+w in vim). and also support command+backspace to delete up to the beginning of the line (ctrl+u in vim).

inside sandboxes, we need to handle open commands and propagate it to the host machine. eg open in browser.

make sure mouse events can be passed through to the virtual terminal for the `cmux` command.
change ctrl+s shortcut to alt+s for sidebar
inside sandbox virtual terminal, make links command clickable

[x] add a REST endpoint that will mark a sandbox+tab pair as "needs attention". then go through

[x] add a REST endpoint for notifications. inside each sandbox, we need to have an "internal cmux cli" client. think of a good command name for this. refactor open-url.sh to use the internal cmux cli client instead. the internal cmux cli client should talk to the cmux. the internal cmux cli should be written in rust and compiled into a binary that can be used inside each sandbox. first, let me know if REST is fine for this (like is using unix sockets + REST endpoints fine for this use case?). also, for each sandbox, we need to inject environment variables for both the sandbox id and the tab id.
first thing we should implement is to replace open-url.sh with the internal cmux cli client. let me know what commands i need to run to test this like the equivalent of `open https://www.google.com`

[x] if we're in dmux, can we render [debug build] in bottom left so it's obvious?

[] add git-delta and set it as the default pager (git config --global core.pager delta
git config --global interactive.diffFilter 'delta --color-only'
git config --global delta.navigate true
git config --global merge.conflictStyle zdiff3)

implement cmux prune, which will list oldest->most recent sandboxes that are not in use, and allow the user to interactively delete them. it should then prune the sandboxes/bubblewrap stuff, etc. from the docker volume.

for virtual terminal make sure TUIs inside the sandbox can also control the pointer (osc22, xterm-style cursor control sequences)

clone https://github.com/zellij-org/zellij to a temp place, and refactor our virtual terminal implementation to use the same strategy they do, to increase our performance and handle edge cases. think of how our implementation differs, like how we have server<>client architecture over websockets, and make sure to adapt zellij's terminal strategy accordingly.

go through @docs/escape-sequence-todos.md and let's start fixing the ones that aren't checked off yet. you should fix one at a time, and for each of them, you also need to come up with an easy way for the user to verify it. perhaps by creating a program that user will run inside cmux/dmux that will return debug info as well as query the feature and print out if it worked or not. make sure to write tests for each. after completing each item, ask me to test it with the verification tools you made. i will then test it and tell you "continue" or give you the failing logs. if fail, keep fixing. if i say "continue", you should check off the item in the todolist, commit + push, then keep going with the next one. don't forget to reload + run say cmd at end.

if user is typing something, we should make sure to scroll it into view iff it's not already in view.

i want git diff to always use less. rn if diffs fit vertical space, there's no less, and it just prints it.

## dogfood blockers

what's the minimum viable useful version of cmux?

- new sandboxes
- notification sandbox type thing?

let's say I'm working on a feature branch. what's the best way to work in parallel on a feature branch?
simplest option for now is to have a command pallete action for merging. this makes sense for feature branches.
maybe adding to merge queue is interesting as well, if we want to add more complexity.
