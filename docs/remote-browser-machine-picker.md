# Browse on a machine: the picker and the remote tab

Status: spec and gallery variants, 2026-11-21. Lane `lane/remote-browser-ui`. Backend: draft #49378
(`lane/remote-browser-vm`, `docs/remote-browser-on-vm.md` there), slice 4 ("the Open on machine affordance,
gallery variants first").

Leo, 2026-11-21: "99 if not 100% of what I need from Cosmic Gray is essentially just some sort of interface to
talk to you guys and then to browse the f***ing web. ... we have VMs ... we can also potentially browse the web,
offload our s***, our f***ing web browsing, our f***ing RAM usage, our CPU usage, all of that onto the VMs
themselves. That's the feature"

## What the person does

1. **Choose where a tab runs.** One control, in the omnibar, at the place the machine chip already sits
   (`MachineBadgeView`, `AddressBarView.badges`). It names where the current tab runs: `This Mac` or the
   machine's name. Pressing it opens the machine list: This Mac first, then each machine from
   `MachineRegistry` that can run a browser, each with its state and round trip. Picking one moves the tab
   there at the address it shows (`browser.openOnMachine`, which exists; this generalizes it from "the
   pane's machine" to any machine). New tabs follow the existing placement rule (`BrowserPlacement.resolve`);
   a setting for "new tabs open on" is a later flag, not this PR.
2. **See that a tab runs remotely.** Without opening anything: the chip names the machine, and the tab in the
   tab strip carries the machine's tab color (`MachineRegistry.tabColorName`, the color its terminals use).
   A local tab shows neither, as today.
3. **See its latency and state.** The chip carries one dot: green under 60 ms round trip, yellow 60 to 150 ms,
   red over 150 ms or no frame for 2 s. The number itself is in the chip's menu and the hover, never in the
   omnibar text. States: starting, live, slow, paused (unreachable: the last frame stays, dimmed, with
   Reconnect and Open on This Mac, as `remote-browser-on-vm.md` "When the machine is unreachable" says; never
   an automatic local fallback, because a local tab has other cookies).
4. **See what it saves.** The menu's row for the current machine says what this Mac pays for the tab (decode
   only, tens of MB) next to what the machine pays. Leo's reason for the feature is the RAM and CPU; the
   picker is where that shows.

## Where each fact comes from

All state is the machine's and the daemon's; the UI only draws it.

| Fact | Source |
|---|---|
| machine list, names, tab colors | `MachineRegistry` (Cloud and added machines) |
| can run a browser | `MachineBrowserHosts.available` / `installed` (`browser-runtime-status`) |
| starting, failed, not installed | `MachineBrowserState` |
| round trip, last frame age | the rd engine's link stats on the viewer (Rust, `cmux-remote-browser`); new: one `rb.stats` read the chip polls on the frame clock it already has |
| machine RAM and CPU of the tab | the host's `browser-runtime-status` (new field, Rust) |

New logic (thresholds, the dot's level, the paused rule) goes in Rust next to the rb/1 reducers and reaches
Swift as one value; Swift draws it. The gallery variants are presentation only.

## References

Described, not copied.

- **Editor remote indicator** (VS Code's Remote Development): a colored block at one corner of the window
  names the host the window is attached to; clicking it opens a list of hosts (local, SSH, containers) and
  connecting actions. One persistent control that is both the label and the picker.
- **Browser containers** (Firefox Multi-Account Containers): each tab of a container has a colored line on
  the tab, and the address bar shows the container's name in that color at its end. Identity by color on the
  tab, name in the omnibar.
- **Isolated tab windows** (Edge Application Guard, when it shipped): the isolated window had a distinct
  frame color and a labelled badge by the address bar. Strong, whole-window signal; costly in chrome.
- **Profile chips** (Chrome, Arc): an avatar chip in the toolbar; the profile's color tints the frame.
- **Remote desktop connection bars** (Windows App / Remote Desktop, Jump Desktop, Chrome Remote Desktop):
  a slim bar at the top edge names the host and shows a signal-bars glyph for connection quality; detail
  (RTT, bandwidth, codec) on hover or click. Game-streaming clients (Parsec, Moonlight) instead offer a
  toggled stats overlay with the milliseconds.
- **Remote browser isolation** products: usually invisible, a small "isolated" marker; latency hidden.
  The lesson: a remote tab should feel local, so the signal stays small until something is wrong.
- **Memory hover cards** (Chrome's tab hover card "Memory usage: N MB"): per-tab cost shown on hover, not
  in the strip.

## Variants (gallery `prototypes.remote-browser`)

- **A, chip picker**: the omnibar chip names the machine with a latency dot; its menu is the picker
  (This Mac, machines, state, ms, RAM saved). The tab gets the machine's tab color as a leading bar.
  Smallest change; reuses the chip and its menu.
- **B, container line**: the tab gets a colored underline (containers) and the omnibar a leading
  machine segment `cloud-1 ›` before the address; latency as small text at the omnibar's end. Picker on
  the segment.
- **C, connection bar**: a slim bar under the omnibar (remote desktop) names the machine with signal bars,
  ms, and what this Mac saves, plus Move to This Mac. Most explicit; costs a row of height.

Each has live, menu open (A, B) or slow (C), and paused states.

## Not in this PR

The native views. A pick becomes a Swift change to `MachineBadgeView` / `AddressBarView` (and the tab strip)
behind DEBUG, with the Rust `rb.stats` value, after Leo picks.
