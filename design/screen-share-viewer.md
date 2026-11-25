# Screen-share viewer (Mac first, then iPhone)

Leo, 2026-11-21 07:02Z: "hey speaking of this screen sharing, we need far better ui/ux for our s***! our screen shared
scren look slike ass... plus most of our vms (if we even have any lanes on freestyle vms yet!?) dont have screns..."

Lane `screen-share-ux` (ask cluster c-9430e81024). The virtual screens on VMs are not covered here. They belong to
`remote-as-the-route` and `give-lane-vms-screens`.

## Where it stands (base 2015d04d8f1, 2026-11-22)

- The look seam and three looks are on base (cmux#48677). Look A is the default: quiet glass, picture first
  (cmux#49263). Each look has its own `MacScreenViewerLook+*.swift`, and `macScreen.viewerLook` switches between them.
- `AAMacScreenViewerGalleryTests` draws the real pane in every look and state. **No image has ever been rendered from
  it.** cmux#49263 says so: the lane that wrote it had no macOS GUI session. This lane renders it first, on a fleet Mac.
- Look A's glass is already the shared material (`Glass.makeOverlayPanel`, neutral transient glass). Nothing new is
  invented here.

## What is still wrong

1. **The quality is hidden (D10).** The host sends `stats {kbps, loss_pct, encode_ms_p50, cpu_pct}` once a second
   (`RemoteRdHostStats`). The viewer only logs it. The stats line reads `path · fps · ms · codec · size`, so an ultra
   session at 148 Mbps with near-lossless text looks the same as a starved one at 1 Mbps. D10 says the link is
   spent. The view must show that it is.
2. **The states break the zero-touch rule.** The viewer's offline card says "Open cmux on that Mac and make sure it is
   signed in." (`MacScreenCardView.swift`, `macScreen.hub.offlineBody`). The rule (remote-screen-share-zero-touch Z7)
   is: no state tells the person to go do something on the other machine. cmux#49489 adds the offline card's
   Start cmux on NAME button. This lane changes only the body text, to "Offline · seen …", and matches its button.
3. **Record has no look yet.** cmux#49168 adds a toolbar Record button. Look A needs a recording mark on the picture,
   the way it marks Control and View Only.

## References

Patterns from the remote-desktop clients people already use. Screenshots of each stay in the lane notes, not here.

| Product | What we take |
| --- | --- |
| The built-in OS screen-sharing app | Window chrome only: no header over the picture, and a scaling/control toggle in the toolbar. Its quality picker names two modes, not bitrates. |
| A game-streaming client | A stats overlay you turn on (bitrate, decode, encode, network latency, loss) in a corner of the picture. It stays out of the way until asked for, then shows exact numbers. |
| A pro remote-desktop client | An auto-hiding floating toolbar and a connection-quality glyph whose bars follow measured throughput. |
| A VNC client for Mac and iPhone | A floating pill toolbar that hides, and a big calm full-window "Connecting to NAME" state. |

## The three readout variants (gallery, `macScreen.qualityReadout`)

Every variant shows the same numbers from one model (`MacScreenSession.LiveStats` with the host's rate, loss and
encode time added). They differ only in where the numbers go.

- **R1, inline.** The toolbar's stats line leads with the rate: `Direct · 148 Mbps · 120/120 fps · 3 ms`. Codec and
  size go to the tooltip. An ultra session adds `Ultra` before the rate.
- **R2, quality chip.** The Quality button itself shows the rate: `Ultra · 148 Mbps`, or `12 Mbps`. Its menu
  (the current Quality menu) starts with a readout section: rate, fps of target, round trip, loss, encode p50,
  codec, size. The button's tint goes from neutral to attention when loss passes 5% or fps falls under half its
  target.
- **R3, stats HUD.** A glass panel in the picture's bottom-left corner, with one number per line; a straining
  stream marks the Rate line in the attention ink. You turn it on with Show Stats in the Quality menu (no shortcut).
  The toolbar keeps today's short line.

### Where each number comes from

The readout shows what was measured, never the setting (the architect's decision). The host's numbers come from the
same cmux.rd/1 `stats` line the bottleneck table reads (`Control::Stats`, sent once a second from
`cmux-rd-host/src/stream.rs`), so the view and the table never disagree.

| Readout | Source | Measured by |
|---|---|---|
| Route (`Direct`, `Relay`) | `MacScreenSession.streamPath` | the viewer's transport |
| `Ultra` | `stats.encode_profile` | the host's encoder (the profile it runs now) |
| Rate (`148 Mbps`) | `stats.kbps` | the host |
| Loss | `stats.loss_pct` | the host |
| Encode | `stats.encode_ms_p50` | the host |
| Frames (`118/120 fps`) | frames the viewer decoded per second, over the target the session asked for | the viewer |
| Round trip | ping round trip on the session | the viewer |
| Codec, size | the decoder's format | the viewer |

`Ultra` shows only when the host sends `encode_profile: "ultra"`. A standard session shows the rate alone, and a host too
old to send the field shows the rate with no profile word; the gallery's `bar-row-oldhost` image is that case. The
quality the viewer asked for never names the stream.

R1 (inline) is the default: it puts the rate where the eye already reads the stats line and adds no new control.
R2 and R3 stay as choices of the setting. The gallery images (`readout-*`) go on the PR when the display pool runs
them, and the default changes only if they show a better pick.

## States (every look)

| State | Line | Button |
| --- | --- | --- |
| Connecting | "Connecting to NAME…" (quiet mark in look A) | none |
| Offline | "NAME is offline · seen 2 h ago" | Start cmux on NAME (cmux#49489) |
| Needs grant | "Screen sharing needs to be allowed once on NAME" (names what is missing) | the grant step (cmux#44228) |
| Can't capture | the host's reason (cmux#44228) | Try Again |
| Failed | the host's reason (cmux#46762) | Try Again |

No line says "open cmux on X" or "turn on … on X".

## Record (with cmux#49168)

- The toolbar button is a record glyph. While a recording runs it is filled `danger` and shows the elapsed time.
- Look A adds a picture mark, the same pill as Controlling: `● REC 0:12`. Clicking it stops the recording.

## iPhone

This comes after the Mac. The same states and the same readout model apply. The iPhone viewer's wording follows the
states table above.
