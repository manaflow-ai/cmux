# iOS workspace list

The list of workspaces across the person's computers, and the shell around it. Written from the
code as of this file's commit; a change to the screen updates this file. Rule and detector:
[docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `WorkspaceShellView` (Packages/iOS/CmuxMobileShellUI) hosts the tabs (Workspaces, Feed,
Notifications, Search, Home when Chief is supported). The list is `WorkspaceListView`, rendered on
iOS by a plain `UITableView` (`WorkspaceListTableViewController`) with SwiftUI cells
(`WorkspaceRow`, `WorkspaceGroupHeaderRow`). Toolbar: Settings and Computers at the leading edge,
the computer picker title (`WorkspaceMacTitlePicker`) in the middle, Chief at the trailing edge,
plus filter, sort and "+".

App Store reviewer: sees the Demo Mac's sample workspaces and the review Mac's, then opens the
"App Review" workspace.

## States

| State | Shows |
| --- | --- |
| Loading (first connection) | a status row at the top of the list with a spinner; after the timeout "Still loading" with Retry and Add Device |
| Empty | "No workspaces yet" (44 pt `macbook.and.iphone`), the pairing message, Retry and See Docs; after 30 s a "taking longer than expected" line. SSH-only: "Choose a computer from the menu at the top…", no buttons. Hidden while reconnecting |
| Filter matches nothing | the filter text and Show All, which resets filter and computer scope |
| SSH host with nothing yet | "Connecting…", "Not connected. Pull down to connect.", or the failure; an install notice during the first upload |
| Reconnecting / Not Connected | a caption line under the picker title, with a small spinner when reconnecting; rows stay, each showing the status where its time was |
| Signed into a different account | a recovery banner at the top with Sign Out & Switch Account |
| Error | the loading timeout, the recovery banner, or the SSH failure text |
| Signed out | sign-in replaces the shell |
| Hidden computer | its workspaces leave the list |

## Selected and foreground

Computer scope defaults to All Computers. In the iPad split view the selected workspace shows an
accent title on a 14 pt rounded `accentColor` 14% fill; on iPhone (push) nothing stays highlighted.
The active group header gets a faint `primary` 8% fill in the sidebar only.

## Zones

- Stable: the toolbar, pinned and grouped structure, group headers.
- Dynamic: the picker's status line, chrome rows (loading, recovery banner), and in each row the
  unread dot or count (fixed 10 pt gutter), pin, name, time or status, description (2 lines,
  reserved), preview (1 or 2 lines, reserved), color rail and changes chip. A row redraws only
  when its content changes; times round to the minute.

## Device variants

- iPhone portrait: a `NavigationStack`; opening a workspace pushes it and hides the tab bar, with a
  back button that shows the unread count.
- iPad and other regular widths: a balanced `NavigationSplitView`, sidebar 320 to 440 pt (ideal
  380), detail beside it; toolbar controls grow to 44 pt.
- Foldable iPhone: follows size class only; folded is the stack, unfolded is the split view only if
  the system reports regular width. The one width rule: the picker moves to the leading edge when
  the bar is narrower than 375 pt.
- Rotation: compact height also uses the stack; switching layouts ends an active search.
- Dynamic Type: text styles in rows with reserved lines and self-sizing cells; group headers use
  fixed sizes (11 to 15 pt) and don't scale. Title wrapping is a setting.
- Dark mode: semantic colors; the recovery banner is `.black` at 88% in both.

## Tokens

- Text: `.headline` titles, `.subheadline` times, descriptions and previews, `.caption2` pins,
  status line and chip; `.primary`, `.secondary`.
- Accent: `Color.accentColor` for selection and unread.
- Surfaces: clear cells over the system background; chip `Color.secondary` 12%; the workspace's own
  color through `Color(hexString:)`.
- Literals still in the code (baselined): status tints `.green` / `.orange` / `.red`
  (`MobileMacConnectionStatus+Display`), swipe `.blue` / `.red`, the recovery banner's black and
  white, group-header font sizes, and the empty state's 44 pt icon. Radii (14 selection, 6 header,
  16 banner) and paddings are literals; this surface has no metric tokens.
