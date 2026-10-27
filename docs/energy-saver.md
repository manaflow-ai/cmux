# Energy Saver

Energy Saver makes cmux use less power on battery and in Low Power Mode. It works like the Energy Saver of Google
Chrome: web pages that you do not use draw fewer frames, background animations stop, and timers and background
checks run less often. It does not slow typing in a terminal, a Chromium page that you use, or the animations that
you start.

## Turn on the Labs feature

Energy Saver is a Labs feature. It is off by default in all builds, and while it is off, Energy Saver never turns
on.

- Start cmux with the environment variable `CMUX_ENABLE_FEATURES=energySaver`.
- In Dev and Nightly builds, the Feature Flags card in **Settings > Experimental** (or the command palette action
  **Feature Flags**) can also turn on `energySaver`, when that card shows (feature `featureFlagsCard`).

The feature changes only when cmux starts. Quit cmux and open it again.

## When Energy Saver turns on

The `energy.saver` setting controls when Energy Saver turns on. Set it in `~/.config/cmux/cmux-next.json`:

```json
{
  "energy": {
    "saver": "auto"
  }
}
```

| Value | Energy Saver is on |
| --- | --- |
| `auto` (default) | When macOS Low Power Mode is on (also when the Mac is plugged in), when the Mac is on battery with less than 20% charge, or when the Mac is on battery and hot. When the Mac is hot, Energy Saver stays on until the Mac cools down or you plug it in. |
| `onBattery` | When the Mac is on battery |
| `always` | Always |
| `off` | Never |

A hot Mac turns on Energy Saver only on battery. A plugged-in Mac that is hot because of a build stays at full
speed.

When Energy Saver is on, the sidebar footer shows an Energy Saver indicator. Hold the pointer on it to see why
Energy Saver is on: Low Power Mode, a low battery, a hot Mac on battery, or your setting.

## What changes

When Energy Saver is on:

- Chromium web pages that you did not type in, click or scroll in the last second draw at most 30 frames per
  second. The limit applies to all that such a page draws, also animations and video. A Chromium page that you
  use keeps its full frame rate. This needs a Chromium runtime of cmux that supports Energy Saver; with an older
  runtime, Chromium pages do not change.
- Browser tabs in the WebKit engine draw at about 60 frames per second, also the tab that you use. Tabs next to
  the tab that you see are not kept ready, and hidden cmux pages are put to sleep sooner.
- Spinners, pulses and other animations that repeat show a still icon.
- Timers that are not urgent fire in groups 32 ms apart, not 8 ms apart, so the Mac wakes up less often.
- Background checks wait 4 times longer: the GitHub feed, the check for web page updates, the collection of error
  reports and the check for Cloud access requests.

## What never changes

- The time from a key press to the text on the screen in a terminal or a native text field.
- Typing and scrolling in a Chromium web page: the page keeps its full frame rate for one second after your
  last input.
- The animations that you start: panes that move, the sidebar that opens, fades.
- The frame rate of cmux's own pages, such as Home and Settings.
- Terminal output.

## Turn it off

- **For now:** hold the pointer on the Energy Saver indicator in the sidebar footer and click **Turn Off for Now**,
  or run **Turn Off Energy Saver for Now** from the command palette. Energy Saver stays off until you plug in the
  Mac or change the `energy.saver` setting. To end this before then, run **Turn On Energy Saver Again** from the
  command palette.
- **Always:** set `energy.saver` to `off`.

## For developers

- The control socket method `debug.energy` shows the power inputs, the setting, whether Energy Saver is on and why,
  and whether Chromium took the last state (`cef.energySaver`).
- In Debug and bench builds, `debug.energy.simulate` sets a simulated power source, battery charge, thermal state
  or Low Power Mode. Fleet Macs have no battery, so tests use it.
- The design, the Chrome references and the places where cmux differs from Chrome are in
  [plans/cmux-next/idle-wakeups.md](../plans/cmux-next/idle-wakeups.md), section 9.
