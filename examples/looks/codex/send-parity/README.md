# Reference send

Opt-in. Send the way the reference desktop chat app does: the sent prompt has no entrance animation,
and the chat scrolls so the prompt sits near the top with empty room under it for the reply.

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/codex/send-parity@feat-cmux-next
cmux setup remove manaflow-ai/codex-send-parity
```

Until the switches below exist in your build, the setup's settings are comments, so installing it
changes nothing.

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
