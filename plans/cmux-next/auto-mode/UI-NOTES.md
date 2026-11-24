# Auto mode: Mac app and web chat UI notes

Slice D of [DESIGN.md](DESIGN.md). Every visual decision below reuses a component and tokens that
already draw a Cloud chat's state; nothing here adds a color, a size or a motion. Each line names the
reference it follows. Two decisions had a real alternative; the default is built and the alternative
is described under [Alternatives](#alternatives) for Leo to pick from.

## Where things are

| Surface | File | Gallery |
|---|---|---|
| The row field and what the pane says about it | `webviews/src/agent-session/acpmux/autoSession/autoSession.ts` | |
| The line and the kept-changes notice under the header | `autoSession/AutoSessionBanner.tsx` | `agent-pane.auto-session`, `agent-pane.auto-leftover` |
| The chat menu's Auto and Keep in Cloud rows | `header/autoRow.ts`, placed by `header/chatRows.ts` `moveMachineRow` | `agent-pane.auto-session/menu-auto-off`, `menu-in-cloud` |
| The chat list's place for a chat the Cloud runs | `sessionList.ts` `sessionPlace` | |
| The requests | `direct.ts` `setAutoSession`, `autoLeftover` | |
| The host's allowlist for them | `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods.swift`, `cmux-tui/crates/cmux-agent-pane-policy/policy.json` | |
| The setting | `schemas/settings/source/machines.json` `cloud.autoCloud` (AutoCloud's one switch; this branch's own `cloud.autoMode` is gone) | |
| The wake notice | `CmuxNextAgentPane/AcpmuxEnvironment+AutoWake.swift`, called from `CmuxNextApp/Cloud/CloudService.swift` | |

## Decisions

1. **The state is a line under the chat's header**, built from the peer copy banner's parts
   (`PeerCopyBanner.tsx`: `acpmux-link-missing acpmux-peer-copy`, `acpmux-peer-copy-title`,
   `acpmux-watch-hint`). Reference: that banner already says a Cloud chat's machine is paused,
   starting or offline in this place, and follows `cmux-design-references/index.json`
   `cmux/live/status-remote-agent-offline-reconnect` (the quiet "The chat catches up once it
   connects." line, cited in `design/agent-host-line.md`).
2. **One row per state, no red, no animation** beyond the banner's own drop-in (`data-enter="top"`).
   Reference: `design/agent-host-line.md`, "Each state is one row" and "None is red and none animates".
3. **"Resuming…" reuses the composer machine chip's string and spinner** (`composer.envResuming`,
   `Spinner` at 12 px with `acpmux-peer-copy-spinner`). Reference: `design/composer-menus.md`, "Cloud
   machines in the machine menu" (Paused, Resume, Starting…), and the peer copy banner's `starting`
   state, which draws the same spinner before its title.
4. **Resuming stays out of sight for 1.5 s, and "Waiting for the network" for 10 s.** Reference:
   `afterDelay.ts` `RESUME_NOTE_DELAY_MS` (Leo, 2026-11-03: a resume reads as part of thinking) and
   `LINK_DOWN_SAID_MS` (Leo, 2026-11-14: connectivity says nothing the person can do nothing
   about). The line's place is taken from the first frame (`acpmux-peer-copy-slot`), so its text
   fading in moves no row.
5. **A chat this Mac runs, and a parked chat before a send, draw nothing.** Reference: DESIGN.md
   ("a chat held here shows nothing new; parked shows nothing until a send") and
   `design/agent-host-line.md`, "Before that nothing shows".
6. **"Running in the Cloud" is the title of the `cloud` and `coming_back` lines; `coming_back` adds
   the hint "Comes back to this Mac when this turn ends."** as the banner's second line
   (`acpmux-watch-hint`, which draws in the title's ink today). Reference: the peer copy banner's
   title plus hint pair.
7. **A blocked chat is one short line; only `no_machine` has an action**, drawn as the banner's quiet
   underlined text button (`acpmux-folder-choice-button`) labelled with the existing "New Cloud
   Machine…" string (`composer.newCloudMachine`), and it runs the existing Cloud start flow
   (`connectMachine("cloud")`, the environment picker's row). Reference: `design/agent-host-line.md`
   ("an optional step, never a filled button") and the peer copy banner's inline Resume
   (`pausedMachine.experiment.ts`, arm `inline`).
8. **The kept-changes notice has the watch banner's shape**: a sentence, then a row of text buttons
   (`acpmux-link-missing acpmux-watch-banner`, `acpmux-live-chat-actions`,
   `acpmux-folder-choice-button`). Reference: `WatchBanner.tsx` (Take Over, Continue in New Chat),
   the pane's existing "a thing happened to this chat, here is what you can do" line.
9. **Show lists file paths in the banner's mono line** (`acpmux-live-chat-command`: 11 px mono,
   muted, one line each, ellipsis), at most 8 then "+N more" (`planBuild.moreFiles`); the button
   then reads Hide (`rules.hide`). Reference: `LiveChatChoice.tsx`, which draws a command in that
   line under the same kind of banner.
10. **Discard asks once more in the notice**: a row under the buttons, "Discard these changes?" then
    Discard and Keep; Show, Apply and Discard stay where they were and wait for the answer.
    Reference: `header/WorktreeRemove.tsx`, whose Remove asks with a discard and a Keep button in
    place instead of opening a dialog; Keep is that pill's string (`header.worktreeRemoveKeep`).
    The question is its own row because the gallery's play checks allow no layout shift
    (`webviews/src/gallery/ENTRIES.md`, "layout shift: 0 allowed"): replacing the buttons moved
    them 12 px, and a second Discard must not land under the pointer that clicked the first.
11. **Auto and Keep in Cloud are rows that are on or off on their own, drawn with the menu's
    check**, in the chat menu's Cloud submenu ("Move to…", or "Environment" when the chat can move
    nowhere), under a separator after the places the chat can move. Reference: Transcript view's
    Wrap lines (`header/transcriptViewRow.ts`), the menu's existing on/off row; and the task's
    "beside the existing Cloud items" (Move to…, Bring Back Local live in that submenu,
    `header/chatRows.ts`). The native tab-row menu draws the same rows with a native check
    (`header/nativeMenuBindings.ts`).
12. **While the Cloud runs the chat, Auto is checked and disabled, and Keep in Cloud is offered.**
    Reference: DESIGN.md (acpmux refuses `auto: false` with `auto.held_in_cloud` while a machine
    holds the chat); a disabled menu row is the menu's existing way to say "not now"
    (`ChatMenuChild.disabled`).
13. **A chat the Cloud runs is placed as "Cloud" in the chat list** (`sessionPlace`, the label the
    composer's Where menu uses, `composer.cloud`), and a chat that names a machine keeps that
    machine's name. Reference: a Cloud chat's list row already names its place this way.
14. **Failures are the pane's failed toast** (`notices.failed`): "Auto could not be changed.", "The
    changes could not be shown / applied / discarded." Reference: `paneToasts.ts`, "a click or
    action that failed". An acpmux that predates Auto (`-32601`, not a host refusal) says nothing.
15. **The setting is a toggle named "Auto" in Settings > Machines, Cloud Workspaces**, after "New
    Cloud Workspaces Start In". Reference: the section's existing toggles
    (`schemas/settings/source/machines.json`); help text is DESIGN.md's sentence.
16. **No surface says lease, epoch, mirror, snapshot or pause**, and none names a vendor
    (`AutoSessionBanner.test.tsx`, "no line names how Auto works").

## State table

| Element | Rest | Hover | Press | Focus | Open / on |
|---|---|---|---|---|---|
| Chat menu row "Auto" | Menu row, label only | The menu's row highlight | The menu's pressed fill (`design/pressed-state.md`: fill only) | The menu's keyboard highlight | On: the menu's check before the label. Disabled (the Cloud runs the chat): the menu's disabled ink, check kept |
| Chat menu row "Keep in Cloud" | Same; shown only while the Cloud runs the chat | Same | Same | Same | On: check |
| State line (`cloud`, `resuming`, `coming_back`, `too_large`, `offline`) | 12 px text in `--agent-text`, the hint line too; the Resuming spinner in the muted ink | None: not a control | None | None | None |
| "New Cloud Machine…" on `no_machine` | Text ink, underlined | Unchanged (the banner's text button has no hover fill) | Unchanged | The browser's focus ring | Runs the Cloud start flow; the line goes when acpmux drops `blocked` |
| Notice buttons Show, Apply, Discard | Text ink, underlined | Unchanged | Unchanged | The browser's focus ring | Show open: file list under the sentence (11 px mono, muted), label Hide, `aria-expanded`. Busy (a request runs) or asked: disabled |
| Discard, asked | A row under the buttons: "Discard these changes?" then Discard and Keep | Unchanged | Unchanged | Focus ring | Keep removes the row; Discard sends it |

The text buttons take the existing class as it is: it has no hover, press or disabled look of its
own today (`styles.css` `.acpmux-folder-choice-button`). Giving it one is a change to every banner
that uses it, so it is not made here.

## Alternatives

**A. Where Auto sits in the chat menu.** Built: inside the Cloud submenu (decision 11). Alternative:
a top-level "Auto" row in the menu's own Cloud group, checked when on, with "Keep in Cloud" under
it. It is one click closer. It would need a `checked` field on top-level `ChatMenuItem` rows and a
check glyph in `ChatHeaderTools.tsx`'s row renderer (today only submenu rows draw one), and it adds
one or two rows to a menu `transcriptView.gallery.ts` already checks for fitting without a scroll.

**B. Where the state is said.** Built: the line under the header (decision 1), the same place and
parts as the peer copy banner. Alternative: one muted line in the composer's notice slot
(`NoticeSlot`, `Notice tier="status"`, as `AutoResumeNotice.tsx` draws "Retrying…"). It sits next
to where the person types, and costs no transcript height. It would change `AutoStateLine` to
render through `Notice`, move its mount from `pane/PaneBody.tsx`'s under-header lines to
`pane/PaneComposer.tsx`, and drop the `underHeader.autoSession` flag for the state line (the
kept-changes notice would stay under the header: it has three buttons).

## Not built here

- The native tab right-click menu has "Move to Cloud" and "Bring Back Local" as action-catalog
  actions (Rust, `cmux-tui/crates/cmux-action-catalog`). Auto is not added there: it is a per-chat
  toggle that needs the chat's `autoSession`, which that menu does not read. The chat's "..." menu
  and its native twin have it.
- Show lists the files; it does not open a diff. Show's answer may carry a `patch`
  (`autoSession/leftover.ts` keeps it), which a later change can open in the diff viewer.
- The native sidebar and All Chats list read acpmux's rows as they do today. A chat started on the
  phone appears there as any Cloud chat when acpmux lists it as one (see the assumptions in the
  slice's report).
