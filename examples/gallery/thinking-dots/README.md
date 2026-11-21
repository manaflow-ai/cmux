# Starter Thinking Dots

The agent's thinking dots as a `cmux.particles/1` document. Three dots in the theme accent pulse in
when you send a message. They trade size while the agent runs a command and orbit while it reads.
Jump to latest plays the same glyph.

**This look needs cmux#47525.** That change adds the `agentPane.display.thinking.*` settings and
`{"$file": PATH}`. Until it ships in your build, `cmux setup install` refuses this look because
it does not know the keys.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Sets `agentPane.display.thinking.glyph` to `{"$file": "agent-pane/thinking-glyph.json"}`, `glyphSize` to 2.4 and `jumpButton` to `glyph` |
| `agent-pane/thinking-glyph.json` | The particles document, with three phases. `lone` is one small dot. `trade` has three dots, where the middle and the ends swap size over 1.4 s. `orbit` has three dots turning a third of a circle over 1.2 s |

The document's parts:

- `particle`: the shape, the size in points, the color (a scene color token or `#RRGGBB`), and `max`, the most dots.
- `phases`: each phase has a `duration` in ms, an optional `ease`, and `frames`. A frame has `at` (0 to 1) and `dots`. Each dot is `[x, y, scale]`, in points from the center, with scale from 0 to 4.
- `triggers`: the phases each activity plays, either as a list or as `{intro, loop}`. The activities are `read`, `execute`, `sendMessage`, `thinking` and others. Any activity with no trigger of its own plays `cycle`.

The full format is ABI.md "Particles choreography" in `cmux-tui/crates/cmux-app-host/js`. cmux
refuses an invalid document and names the first bad path, such as
`phases.trade.frames[1].dots[0][2]: must be from 0 to 4`.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/thinking-dots@feat-cmux-next
cmux setup remove manaflow-ai/starter-thinking-dots
```
