# Screen sharing surface

Screen sharing is reachable from the device or machine a person already sees. Reference captures, official interaction receipts, and the product comparison live in the private [screen-sharing reference study](https://github.com/manaflow-ai/cmuxterm-hq/blob/lane/screen-share-references/docs/remote-transport/screen-sharing-references.md). The shared pattern is one visible Share entry, an explicit source choice, a persistent host indicator naming what is shared, and a direct Stop action.

## Live entry points

The native sidebar's existing Projects header exposes Share This Mac. In the flat-list layout, which has no list or machine heading, local workspace rows expose Share This Mac and remote workspace rows expose View screen beside their existing controls. Grouped machine section headers expose Share for This Mac and View screen for Cloud machines or devices identified as Macs by the device hub. A remote row never invokes Share This Mac. Linux and unidentified SSH machines do not acquire a Mac Screen action.

A screen action is compact and visible at rest. Existing workspace and management actions retain their established hover and menu behavior. Names and status captions keep their own layout space; actions use the shared trailing-column geometry and never cover the label. The accessible name and tooltip identify both the operation and its target.

A Mac View action uses the screen-device UUID reported by that machine's authenticated daemon, checks it against the device hub's Mac records, and opens the existing Mac Screen tab with View Only scope as a person-initiated action. Machine, mesh, session, and screen-device identifiers are distinct; neither a joined-machine prefix nor a matching display name establishes that relationship. Initial readiness, identity rotation, and removal update the mapping through the existing subscription stream, without row-level requests. Automation and restored tabs retain the existing confirmation boundary. Cloud View uses the existing desktop action and its picker; this change adds no parallel Cloud connection flow.

The existing Devices list also exposes View screen on other registered Macs and Share on This Mac. Those rows already carry the authoritative device UUID, so viewing a registered Mac does not first require a terminal connection. Share uses the same guided sheet as the sidebar; it does not require finding a separate sharing checkbox.

The old web Machines section and remote-chat transient rows are not mounted in the live sidebar. Their galleries are not evidence for these entry points, and this change does not reactivate them.

## Host guide and source

Share This Mac immediately presents a standard `CmuxDialogSpec` sheet. Its overview names this Mac's main display and explains approval, the host indicator, and Stop. This implementation shares that existing display source; it does not imply that window, tab, or external-device capture is implemented. A future source picker must retain one Share entry and make its source explicit before capture begins.

The guide then offers Screen Recording permission and an explicit Check Again step. A fresh `cmux rd permissions` child checks the app's responsible-process permissions with the same binary used for capture. Failure cannot grant permission. Accessibility has its own optional Allow and Check Again steps, plus Continue Without Control. Cancel never enables sharing. The existing device approval flow still owns who may view or control; a granted macOS permission alone is not remote authorization.

## Host indicator and stop

While a viewer is connected, a floating native bar remains visible across spaces without taking keyboard focus. It names the viewer and View Only or Full Control state, shows Screen sharing is on, and exposes Stop Sharing directly. Stop ends the local capture on the action's turn; it does not wait for a network response. The menu-bar indicator and legacy stop action use the same host action. CLI and MCP stop commands target the app while it owns the session and use the standalone worker only when the app transport is absent.

The app owns host tickets and approval while attached. Its worker supplies identity and push delivery only. The last app channel closing restores standalone worker ownership; neither side may consume the same ticket concurrently.

## Tokens and evidence

Native layout uses `Metrics` spacing, control heights and corner radius; `SidebarStyle` trailing-column geometry; shared icon sizes; `TypeScale`/`MacScreenType` text; and semantic theme ink/fill tokens. The guide uses the standard dialog layout and key hints. There are no surface-specific colors, font sizes, motion, or fixed action widths.

Gallery requirements cover each new element together with its surrounding content: local Share in list and section headers, flat remote workspace rows, registered device rows, a capable Mac, Cloud, offline and long-name rows; the permission overview, Screen Recording and Accessibility steps; and host bars for View Only, Full Control, and a long viewer name. Each runs in light and dark themes, with overlap and routing checks against the live builders. A gallery test definition is not a render receipt: actual image artifacts and exact-head test results are recorded on the pull request before landing.
