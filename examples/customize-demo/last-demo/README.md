# The last demo's setups, redone

Leo, 2026-11-18: "those are extremely lame customizations. we want to show the claude/codex/studio
ones. plus the previous ones that were made for the last demo, looking better. plus glass stuff.
plus the widgets. this is not enough as a demo"

These are four setups from the last demo ([`examples/customize-showcase`](../../customize-showcase)),
rebuilt to look better. Each one keeps what the original does: the same layout settings, the same reads and the same
behavior. What changes is the look. Each setup now carries its own theme file, with a painting
behind glass, a cohesive palette and rounded surfaces, and its views are laid out as designed
cards instead of plain lists.

| Setup | The look | What changed in the views vs. the original |
| --- | --- | --- |
| [`cockpit`](cockpit.json) | Moonlit glass over Dahl's *Dresden by Moonlight*; an ice-blue accent, amber for what waits on you; floating chrome, pane cards | A header with a greeting, a one-line summary ("2 chats need you, 1 more is at work") and a large clock. Four counters show an icon in a tinted disc and a number that rolls when it changes (it adds "reviews for you"). Four launch tiles replace three plain buttons and add "Next waiting". Each card has an icon, a title, a count badge and a divider. Every empty state is designed: GitHub not connected, no PRs, nothing waiting. The sidebar's empty state reads "All clear" with a seal |
| [`collection`](collection.json) | Neon arcade glass over Van Gogh's *Starry Night*; hot magenta, cyan and lime; softened arcade corners | Every card has an icon header. The clock is the card's hero, the weather symbol draws in its own colors, and the low and high sit beside the sky as a badge. Each usage meter shows a provider icon, an "N of M accounts ready" line, a large percent, and badges for session, pace and extra spend. The gacha reel sits in a radial halo and a ring in the rarity's tone that pulses on landing, with a collection progress bar. The page has a heading with an icon and a hint line |
| [`focus`](focus.json) | Ink on warm paper behind frosted glass over Hiroshige's *Zoshigaya*; one sage accent; the chat a size up with airy lines | A centered title card: the question set large with a subtitle, and the field kept to a readable width. One glass card holds a large light clock that rolls its digits, three named presets (Sprint, Pomodoro, Deep work) over the slider, and a play button. Today's sessions show as a row of dots |
| [`tiling`](tiling.json) | Glass pane cards over Hokusai's *Great Wave*; a cyan accent and focus border; compact blocks | The status bar is a glass strip: the workspace name and a rolling clock in the accent, then tinted panes, tabs and agents segments. The numbered rows are unchanged |

Left out: `right-handed` and `ide`. Each is mostly a layout with one small list, so redoing it
would add little to the demo.

## Try one

```sh
cmux customize use examples/customize-demo/last-demo/cockpit.json   # on, live, nothing kept yet
cmux customize discard                                              # off: your setup is back
```

Using one setup replaces the views of the one before it, since each brings its own
`local/customize` app. The clicks need the scopes listed in each manifest. The reads are granted
at install. `actions:run` and `workspace:write` are turned on in Settings > Apps.

## Change one

Each folder holds `profile.json` and the files the setup writes under `~/.config/cmux`
(`customize/cmux-app.json`, `customize/main.js`, `themes/last-demo-<name>.json`). Edit them, then:

```sh
python3 examples/customize-demo/last-demo/bundle.py          # rebuild the four bundles
python3 examples/customize-demo/last-demo/bundle.py --check  # exits 1 while one is stale
```

Checks:

- `examples/customize-demo/looks/check` previews each bundle on a fresh home and fails on any
  problem or theme diagnostic:

  ```sh
  CARGO_TARGET_DIR=/tmp/looks-check cargo run -q --manifest-path examples/customize-demo/looks/check/Cargo.toml -- examples/customize-demo/last-demo/*.json
  ```

- `check/views.test.ts` mounts every view in the app host's fake host and fails on a script
  error or an empty mount. Run it from `cmux-tui/crates/cmux-app-host/js`:

  ```sh
  bun test ../../../../examples/customize-demo/last-demo/check/views.test.ts
  ```

The views use only the kit in
[local-app-views.md](../../../skills/cmux-customization/references/local-app-views.md#matching-the-app):
tones instead of colors and fonts by name. That way they follow each theme.
