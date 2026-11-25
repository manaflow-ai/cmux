# Reference composer

Opt-in, for the ChatGPT replica only. The reference chat app's round composer, as one applyable
unit: the prompt on its own line with the controls in a row under it, and every icon button's hover
highlight a circle. cmux's own composers stay as they are (Claude's one-line composer by default).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/codex/composer@feat-cmux-next
cmux setup remove manaflow-ai/codex-composer
```

Leo, 2026-11-23:

> "because for the chatgpt parity, if you're going to have it be that round, it necessarily has to be at baseline longer than one line. and the highlight also necessarily has to be a circle instead of a rounded square. that's just design."

> "the chatgpt roundedness only makes sense for the chatgpt replica, which i guess you guys have done. but we dont want codex parity for the composer. the more minimal single line claude code version is more favourable."

## What it maps

| Reference | Where here |
| --- | --- |
| Taller than one line at baseline: the prompt's own line over a controls row | `agentPane.composerLook: "studio"` in `cmux-setup.json`, the in-box composer a setting can pick |
| The + (attach) highlight is a circle | `--cv-composer-icon-radius: 50%` in `agent-pane/theme.css` |
| The mic and Send are circles | already round in the in-box look; nothing to set |

## What it cannot do yet

- Codex's own in-box layout (+ and the mode on the left, the context ring, model, mic and Send on the
  right) is staged only by gallery previews; no setting picks it, so this look uses Studio's.
