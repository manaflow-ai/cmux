# Reference send

Opt-in. Send the way the reference desktop chat app does: the sent prompt has no entrance animation,
and the chat scrolls so the prompt sits near the top with empty room under it for the reply. It also
brings the builder new-chat page, "What should we build in {project}?", as your New Tab page
(below): cmux's own new chat stays plain, and this page shows only for whoever installs this setup.

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/codex/send-parity@feat-cmux-next
cmux setup remove manaflow-ai/codex-send-parity
```

Installing sets your New Tab page to the builder page (`tabs.newTabApp: local/customize`, and
`tabs.nativeNewTabPage: false`, its default, pinned because the page draws only on the web New Tab
page). Until the send switches below exist in your build, those settings are comments. Turn on
**Run actions** for Reference send in Settings > Apps for the field and the picker. The setup's app is
`local/customize`, so it replaces another installed customize app (`codex/threads`, `codex/sidebar`).

## The builder new-chat page

Why it is here, Leo, 2026-11-22 14:14Z: "the what should we build no builder screen ughhh i thuoght
we removed that bit? what's up why is that still there? on like the reconnecting screen. pls... if we
want it as a proper option then we shouldnt have things be in disparate places... why teh fuck would a
disconnection make it show up... and we wanted the plain one didnt we? without the chatter intro...
the current one that's just always there... so why... why would it be there.." And at 14:23Z: "if you
wanna do this properly then stick this in the chatgpt replica customiztaion repo"

So the screen that cmux drew over an empty chat (`EmptyState.tsx`, with `HomeLists.tsx` under it)
lives here as an opt-in New Tab page (`customize/`, a `cmux.newtab/1` app), not in the chat.

| Part | Here |
| --- | --- |
| The line | centered and quiet, 20 pt regular: "What should we build in {project}?", the project being the New Tab's folder |
| The project | its name is a menu: your chats' other folders, newest first (at most eight), and Open Folder… |
| No folder | "What should we build?", with "Choose a folder" under it |
| Under it | "Needs you": up to five chats waiting on you or failed, as HomeLists' inbox; a click shows the chat |
| The field | at the foot: a prompt starts a chat in this tab's folder (`newTab.submit`, the same field as cmux's own) |

### What `cmux.newtab/1` cannot express

| Built-in behavior | What is missing |
| --- | --- |
| A pick moves this new chat to the folder | `newTab.submit` takes no folder and a page cannot change its tab's folder, so a pick opens a new chat in that folder (`palette.newAgentChat` with `cwd`) instead |
| The project name drawn as a dotted underline in the sentence, caret-less | `Menu` draws as the host's menu button; the scene has no inline text control |
| The project chooser's full list (projects with no chat yet, New project, No folder, remote browse) | No op lists projects; the list is the folders of `chat.list` |
| Answering an ask in place, Ready for review (a chat's pull request title) | `chat.list` gives `state` and pull request ids, no ask body or title; rows only open the chat |
| The repo tour offer under the line | No op for it |

## What the reference does on send

Read from the reference app's own shipped web bundle (its macOS desktop build 26.1111, the
conversation view's response spacer and its submit handler), read only. Not filmed: a recording needs
a signed-in account and a real send, and this was done without signing in anywhere.

| Part | Value |
| --- | --- |
| When | the moment the composer's submit is accepted (before any reply arrives) |
| Room under the turn | a spacer after the last turn, `min(2/3 × V, V − 240 px)`, never below 0, where V is the scroll view's height less its bottom scroll padding (the floating composer) |
| Scroll target | the end of the thread, 1 px short of the bottom, so with short turns the prompt's foot sits at `max(V / 3, 240 px)` from the top: the top third, not flush with the top |
| Motion | the scroll offset runs on a spring, `bounce: 0`, `duration: 0.5 s` (critically damped, no overshoot) |
| Reduce Motion | the same place, at once |
| Interruption | any wheel, touch, pointer down or key on the scroll view stops the scroll where it is |
| The room afterwards | shrinks by exactly what the reply grows; trims to fit when the view resizes; goes when it scrolls out of view or the reader scrolls up past it |
| Entrance on the sent message | none: no keyframe, transition or opacity change on the prompt bubble or its row in the shipped stylesheet |

The bundle also has a placement mode that lines a target element's top up with the view's top; this
build's submit handlers do not pass a target, so it is not what a send does.

Unverified: the web app (chatgpt.com) may differ from the desktop build; the claim that no script
animates the bubble rests on its stylesheet and the bubble's render code, not on frames.

## The switches

| Part | Key | Values | Default | State |
| --- | --- | --- | --- | --- |
| No entrance | `agentPane.display.sendPop` | `"off"`, `"pop"` | `"off"` | arrives with cmux#50293; today the send is already instant |
| Placement | `agentPane.sendPlacement` | `"bottom"` (today), `"top"` (the table above) | `"bottom"` | missing, no pull request yet |

The nearest setting today, `agentPane.scrollToBottomOnSend` (toggle, default on), only decides
whether a send scrolls at all; with it off, `"top"` would also not scroll. An agent may not set it.
