# Screen sharing surface

This surface makes Mac Screen reachable from the object a person is already looking at. It follows the shared interaction found in Zoom, Google Meet, Discord, and FaceTime:

- one visible Share or View action beside the device or machine;
- an explicit source choice when a host has more than one source: entire screen, window, or device;
- a persistent “you are sharing” state that names the viewer and access scope;
- one click to stop, available in the host surface and the menu bar indicator.

Zoom puts Share Screen in the meeting toolbar, then offers Desktop, a specific Window, or an iPhone/iPad. Meet uses Present now with cards for A tab, A window, and Your entire screen. Discord puts Screen in the voice/video rail and distinguishes an application window from the entire screen. FaceTime keeps screen sharing on the call toolbar and uses the system window or full-screen picker. All four keep the active state visible and expose Stop without reopening a palette.

## cmux NEXT surfaces

The Machines sidebar gives connected remote Mac and Cloud rows a `View screen` control. This Mac receives `Share`; a remote row never shares this Mac. The screen action is the one visible primary action at rest, while workspace and management actions stay in the trailing overflow on hover, focus, or an open menu so names and captions retain their space. The action opens the Mac Screen viewer directly when the hub can resolve the row to a device and otherwise opens the Mac Screen home so the person can select a device. Joined ids are normalized before the hub lookup.

The host state is a compact anchored bar at the top of the Machines section. It uses `--ds-space-*`, `--ds-control-*`, `--ds-radius-control`, `--ds-color-success-subtle`, `--ds-color-danger`, `--page-text`, and `--page-text-2`. Its title says “You are sharing this Mac”; the detail names the viewer and `View Only` or `Full Control`; `Stop sharing` ends the current host session in one click. The existing menu bar indicator remains the system-wide fallback and carries the same stop action.

First use follows the existing Mac Screen host flow: the share action starts the host request, the host checks Screen Recording and Accessibility, and the device approval prompt presents the viewer, requested scope, and Allow/Deny/Always choices. The prompt is a guided sheet with a visible scope; the sidebar does not send a person hunting through Settings for a toggle.

Gallery coverage keeps the affected elements together in three states: row actions at rest, an active host bar, and a connecting or unavailable machine. The gallery and page CSS use design tokens only; no fixed colors or surface-specific dimensions are introduced.
