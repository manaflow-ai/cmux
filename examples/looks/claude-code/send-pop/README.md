# Claude Code send pop

Opt-in. A prompt you send pops in where it lands and settles, the way the Claude desktop app's sent
message does. The shipped send stays instant; this setup is how you turn the pop on.

## Install

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/send-pop@feat-cmux-next
cmux setup remove manaflow-ai/claude-code-send-pop
```

Until the switch below exists in your build, the setup's only setting is a comment, so installing it
changes nothing.

## The motion

Read from the Claude desktop app's stylesheet (`cds-um-enter`), not guessed from a recording; the pop
itself is cmux#50293.

| Part | Value |
| --- | --- |
| What moves | the prompt's bubble and its pictures together, as one transform |
| From | `scale(0.92) translateY(6px)` |
| Origin | the trailing edge (`right center`; `left center` right to left) |
| Duration | 450 ms, scaled by `ui.animationSpeed`; 0 with motion off |
| Easing | `cubic-bezier(0.34, 1.3, 0.64, 1)`: past its size by about 0.25% at 300 ms, back by 450 ms |
| Opacity | none: the prompt is readable from its first frame |
| Everything else | the thread, the prompt's room and the thinking row land in one frame, as today |
| Reduce Motion | the prompt is drawn in place |
| Cost | compositor only: no layout or paint per frame, the same for any transcript length |

## The switch

`agentPane.display.sendPop`: `"off"` (default, today's instant send) or `"pop"`. This setup sets
`"pop"`. The page puts it on its root as `data-send-pop`, and `conversation.css` plays `cv-send-pop`
only under `"pop"`. The key is not in any build yet; see `cmux-setup.json`.

## Limits

A prompt another agent sent and a prompt the composer morphed into place keep their own entrances.
