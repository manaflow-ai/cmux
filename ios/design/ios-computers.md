# iOS computers list

The sheet that lists the person's computers (paired Macs, Cloud, SSH) and adds new ones. Written
from the code as of this file's commit; a change to the screen updates this file. Rule and
detector: [docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `DeviceTreeView` (Packages/iOS/CmuxMobileShellUI), a sheet opened by the Computers button in
the workspace list's toolbar (`MobileWorkspaceDevicesButton`). Its own `NavigationStack` holds an
inset-grouped `List` titled "Computers", with Done. Rows: `MacComputerRow` (pushes
`MacComputerDetailView`), `CloudComputerRow`, `SSHComputersSection`, and `ComputerVisibilityRows`
for hidden Macs. With no computer at all, the shell shows `DisconnectedWorkspaceShellView` instead,
which reuses `MacComputerRow` as a reconnect row.

App Store reviewer: sees the demo account's "Demo Mac" and the prepared review Mac right after
sign-in; if that Mac can't be reached, Add Computer with the values from the review notes.

## Sections, in order

One section per connection method with Macs in it (Iroh, Tailscale, Direct), Hidden Computers,
Cloud, Add Computer (with a footer about hiding), SSH.

## States

| State | Shows |
| --- | --- |
| Loading | no spinner; the list reloads on appear, every 10 s, and on pull to refresh, and rows fill in |
| Empty (no Mac, no hidden, no Cloud) | one section of secondary text: turn on Enable iOS pairing on the Mac, same team on both, keep cmux running; SSH still shows below |
| Signed out | only SSH; "+" opens the SSH editor |
| Mac row | a dot (green connected, orange reconnecting, faint otherwise), "Connected / Reconnecting… / Not connected · N workspaces", then presence ("Online" or "Last seen …") and route; "Older pairing ·" for a stale duplicate |
| Cloud row | the same three phrases; the workspace count only when connected |
| SSH row | spinner while connecting, else a dot (secondary, orange, green, red); failure text in red |
| Hidden computer | its row under Hidden Computers with the switch off; avatar, name, badges, no status lines |
| Warnings | an orange triangle with a "Mac update required" popover; an orange cup when Keep Awake is on |
| Error | per row only; a delete-SSH confirmation alert |
| Offline | rows show Not connected and their last presence |

## Selected and foreground

No row is selected or highlighted in the sheet. The chosen computer scope lives in
`WorkspaceMacSelection` (default All Computers); tapping an SSH row selects it, connects and
closes the sheet. Tapping a Mac row opens its detail.

## Zones

- Stable: the toolbar ("+" menu: Pair a Mac…, Add SSH computer; Done), section headers and
  footers, Add rows.
- Dynamic: status dots and lines, presence and route, workspace counts, build badge, Keep Awake
  cup, warning triangle. Rows move between sections when hidden or shown (`.smooth(0.3)`, none
  under Reduce Motion).

## Device variants

- iPhone, iPad, foldable folded or unfolded, rotation: no layout code of its own; the system sizes
  the sheet and the inset-grouped list. Popovers stay popovers on iPhone
  (`presentationCompactAdaptation(.popover)`, 300 to 340 pt).
- Dynamic Type: text styles; avatars (40 pt, hidden 36 pt) and icon frames are fixed, rows are one
  line each with no large-text layout.
- Dark mode: semantic colors; no scheme override.

## Tokens

- Text: `.headline` names, `.caption` and `.caption2` status lines, `.body` Cloud and SSH names;
  `.primary`, `.secondary`, `.tertiary`.
- Accent: `.tint` Cloud icon, `Color.accentColor` SSH add.
- Avatars: `MachineAvatarColors` gradients (eight pairs), slot from `MachineAvatarPalette`, or the
  person's `#RRGGBB` color.
- Literals still in the code (baselined): status dot `.green` / `.orange`, the warning and cup
  `.orange`, build-badge hues (DEV/RC/Staging orange, Nightly blue), swipe tints (`.indigo`,
  `.blue`, `.orange`), SSH failure `.red`, and the avatar glyph sizes (`.system(size: 16)` and
  `20`; hidden 14 and 18). Connection status has no shared color token yet; the workspace list and
  terminal use the same three hues separately.
