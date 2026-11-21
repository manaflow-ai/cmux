# Launch reveal

Leo, 2026-11-16: "do we have an initial load logo fade in glass thing like how [a chat app] has theirs/[an issue tracker] has a thing".

## What it is

The cmux chevron on the window glass, shown only in the gap between the launch window's first frame and the
cached first frame (the saved sidebar and pane or Home, `LaunchReveal`'s regions). It is a cover for a wait that
already exists, never a splash screen with its own length.

## Rules

- **Instant-first.** It adds no time to launch-ready. The mark waits `motion.launch.markDelay` (150 ms) after the
  window's first frame; a launch whose cached frame is ready sooner never shows it and never adds its layer.
- **It yields at once.** When the regions it covers are ready, they fade in (`fadeIn`) in that same turn and the
  mark fades out under them (`fadeOut`). The mark never holds, delays or gates `markReady`, a region's fade-in or
  any `reveal.*` launch mark.
- **Not on a fresh profile.** A fresh profile's window opens on the sidebar and the empty main pane
  (cx-r650e, `FreshLaunchSidebarTests`: "a launch never shows glass alone"). Nothing there is cached, so there is
  no gap to cover.
- **Not while connecting.** `DaemonConnectingView` keeps its own mark for a failure only.
- **Not in later windows.** A window opened after launch finds its regions ready.
- **Stops.** Every loop (the sheen) ends when the mark is concealed; the launch deadline (1.5 s) shows the regions
  anyway and the mark leaves with them.
- **Motion.** Through `Motion.panes` (master switch, animation speed); Reduce Motion is a plain fade; with
  animation off the mark just shows and hides.

## Variants (`launch.reveal`, Debug Settings)

Gallery: `design/launch-reveal-gallery.html`. References: cmux-design-references `launch-reveal/` (two desktop
apps' launches).

| Choice | Look |
|---|---|
| off | today: glass until the regions fade in |
| bloom | the chevron condenses from a soft glow, 6% larger, to its crisp size (240 ms) |
| lens | the chevron in a 64 pt glass tile, resolving from blurred and 96% scale |
| trace | the outline draws itself, then the body fills |
| sheen | the chevron fades in, then a highlight sweeps across it every 1.2 s while it waits |

Leo picks one; the others go.

## Measured

`scripts/measure/launch-ready.sh`, base vs head on one fleet Mac, interleaved runs: the `reveal.*` marks and
`window_on_screen` must not move. The numbers are in the PR.
