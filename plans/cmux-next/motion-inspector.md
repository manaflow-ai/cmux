# Motion Inspector

Lawrence, 2026-10-28: "make a swift tool that helps us slow down, inspect, and review animations properly".
Owner of the motion switches and tokens: [motion-DESIGN.md](motion-DESIGN.md). The animation inventory (133) and
the first-principles rules: [motion-first-principles.md](motion-first-principles.md) (branch cp/motion-split-fade).

One model (`MotionInspector`, CmuxNextDesign/Motion/Inspector), reached three ways:

- Debug > Debug Windows > Motion Inspector (DEV and NIGHTLY; action `debug.motionInspector`, palette too).
- `debug.motion` socket actions (any build with the debug socket: Debug and the optimized bench/dogfood build):
  `inspect_start`, `inspect_stop`, `time_scale` (`value` 1, 2, 5, 10, 0 = paused), `filter` (`kind` or
  `categories`), `step` (`frames`), `running` (`ended`), `findings`, `inspector`, `window` (`open`).
- `scripts/cmux-next/motion.py` for agents (`--tag TAG`, `--json`).

The composition root (`AppServices.motionInspector`) makes the model and its window. While the model inspects it
registers on `DesignSettings.shared` (`activeMotionInspector`), the object every gate already reads; the gates'
hooks reach it there. No global of its own.

## Slice 1: slow motion

One `MotionTimeScale` for every motion path, applied where each path keeps its time:

| Path | How it slows | Pause | Step |
| --- | --- | --- | --- |
| Core Animation (render server): every gate layer animation, RenderSpring, MotionMove (tab strip), sidebar row springs, ColorTransition layer blends, loops, and ungated CA animations too | each window's root layer time base (`speed`, `beginTime`, `timeOffset`, `MotionTimebase`): running animations slow from where they are | speed 0 | timeOffset +- one display frame, both ways |
| CPU springs (`MotionClock`: pane layout, tab autoscroll) | each frame's dt times the rate | the clock parks: no display link, animators kept | one frame forward (a spring's past is not kept: no step back) |
| AppKit `animator()` groups (gate `animate`, `animateTimed`, `animateExit`), gate SwiftUI animations | lengthened by the scale when they start | 10x | no |
| Ghostty terminal color blend | lengthened at start (`ghostty_surface_set_color_transition` duration) | 10x | no |
| Web pages (CSS transitions and animations, Web Animations) | `playbackRate` from the theme payload's `motionRate` (WebTheme bootstrap) | rate 0 | no |

The filter leaves categories out (`MotionInspection.excludedCategories`, unioned into the base policy's disabled
categories): their changes apply in one frame. Named kinds: `sidebarRows`, `tabStrip`, `panes`, `overlays`,
`feedback` (a kind also narrows the list to its call sites).

Zero cost when off: each gate hook is one load of `DesignSettings.shared.activeMotionInspector` and a nil check;
arguments are autoclosures; no frame client, observation or notification runs.

## Slice 2: the live list

Each animation a gate entry point starts is a record: owner (`Module/File.swift:line` of the gate call, the
animated layer's owner type), category, kind, property, from/to, curve (spring response, damping, perceived
duration; timed duration and timing function; loop period), start and expected end in animation time, frames the
main thread saw, dropped frames (refreshes with no main-thread frame while it ran), main-thread ms per frame (CPU
springs), where it runs (render server, main, AppKit). One call site's starts in one turn are one record of N
layers. While a record runs, one frame client counts frames; it stops with the last record.

Findings (on demand, `findings` / the window's button): one walk of the visible windows' layer trees lists every
animation with no gate tag (`cmuxMotionRecord`) that matches no running gate transaction, AppKit-owned ones
marked. The known bypasses a walk cannot see are listed with them (`MotionInspector.staticFindings`).

## Slices 3-5

3. Record and review: ScreenCaptureKit region capture at full rate plus the record timeline; frame-by-frame
   playback with an overlay (layer frames, curve plot and current point, dropped-frame markers); export a clip
   and a JSON timeline for PRs. Empty-slot detection for the sidebar burst (sidebar-burst-motion.md) lands here.
4. Compare: two recordings side by side at matched time; a reference (macOS system animation, Chrome) when one exists.
5. Checks: dropped frames, main-thread animation, an intermediate frame with missing content, overshoot past
   bounds, longer than the policy's duration; result-v1 bench rows for the perf lab.
