//! The rules of the cmux NEXT window handlers, in Rust so the macOS app keeps
//! only the platform work (Leo, 2026-11-06: "ok we need to go all hands on
//! deck here. don't just do baby steps. we can just... do it"). Pure: no I/O.
//! The app reads the facts (its tab models, the settings, the daemon's
//! answers), asks here, and acts on the answer: the dialog, the toast, the
//! daemon command. Served to the app over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `window_*`).
//!
//! - [`close`]: what closing tabs asks first (a working agent, a foreground
//!   program) and whether the close earns an undo toast.
//! - [`desktop_center`], [`desktop_attention`], [`desktop_bursts`],
//!   [`desktop_announce`]: the desktop notification rules (whether a launch
//!   uses Notification Center, a banner's category and what its actions do,
//!   the Needs you banners a mark change posts or withdraws, agent-finished
//!   bursts and VoiceOver's status line).
//! - [`tabs`]: what a new tab or pane opens and where (its kind, the browser
//!   open plan, a split's plan), tab moves, numbers, duplicates, restarts and
//!   icons; [`tabs::panes`] the pane and terminal tables; [`tabs::strip`]
//!   the strip's close, move and next-tab commands.
//! - [`chat`]: where an agent chat, a tool opened from it and a column action
//!   go (the chat dock, the strip, the column target), and the agent chat
//!   handlers' rules ([`chat::agent`]).
//! - [`targets`]: how an action finds what it acts on (the 9-is-last
//!   ordinal, the wrapping step, id-then-name lookup, the explicit target)
//!   and the refusal a handler's failure becomes.
//! - [`workspaces`]: the workspace, screen, space and group verbs' rules
//!   (bulk closes and their question, the question each destructive action
//!   asks, space defaults, description and status, screen moves).
//! - [`restore`]: which saved windows a launch makes before its front window
//!   is live (only the front one; the others follow, one per turn).
//! - [`right_column`]: what opens on the right of a pane (a split right, a
//!   split below the one pane there, or a tab), and [`subagent_panes`]: a
//!   chat's subagent panes, opened one at a time, and the focus a click owes.
//! - [`closed`]: the daemon's closed history (page rows, Cmd-Shift-T's
//!   owner) and the undo toast's expected closes, a reducer.
//! - [`auto_namer`]: workspace auto-naming's bookkeeping (one live rename
//!   per workspace, attempt numbers, retry marks) and the sidebar's held names.
//! - [`notifications`], [`history`], [`remote`], [`browser`], [`files`],
//!   [`appearance`]: the smaller handlers' tables and refusals (which unread
//!   tab a verb reads, the trail walks, the SSH machine an action names, a
//!   page fit, Picture in Picture's page, where a file or diff opens, the
//!   appearance verbs).
//! - [`notification_policy`]: what a notification does when it arrives
//!   (read on sight, ring, banner, Dock bounce, timeout, its sound and how
//!   loud), which interactions clear it, and the burst sound cooldown.
//! - [`notification_rings`]: the notification service's attention rings and
//!   reads (which panes ring, what a look or Dismiss Highlight reads, the
//!   turn-end burst, where an arriving notification goes, a banner reply's
//!   guard, a workspace mark's resend).
//! - [`launch`]: whether the launch snapshot drawn before the daemon answered
//!   is that daemon's, or stale (the launch then goes on as a bare one), and
//!   where the launch lands: the last workspace and tab, or Home.
//! - [`launch_recovery`]: how a launch follows the previous run (clean, a
//!   restart with the notice, a safe restart after a restart loop).
//! - [`keybind_route`]: which registry action a Ghostty keybind runs.
//! - [`server`]: Add Server…'s headless approval (the code and the four
//!   words) and the helper fix ledger Stop Serving reverts.
//! - [`crash_report`]: the app's crash report objects, file names and
//!   pruning, which log Show Crash Logs opens, and the restart cause line.
//! - [`cloud_pairing`]: the cloud pairing calls' Worker bodies, how their
//!   replies read, the hosts paging bound and which refusal a failure shows.
//! - [`editors`]: the code editors Open in Editor knows and which one opens
//!   a folder (the person's `editor.default`, else the first installed).
//! - [`empty_workspace`]: what happens to a workspace with no pane (its
//!   last tab closed: it closes; its terminal was lost: it gets a new one).
//! - [`update_idle`]: whether Update When Idle installs a staged app update
//!   now, or why it waits (input, a running turn, an unsent draft).
//! - [`naming`]: the names a workspace takes (from a moved tab, its front
//!   tab while no one named it, Name from Activity's prompt and reply).
//! - [`onboarding`]: the onboarding tool window's footer (the primary
//!   button, Skip, Back) and Import from Browser's selection rules.

pub mod appearance;
pub mod auto_namer;
pub mod browser;
pub mod chat;
pub mod close;
pub mod closed;
pub mod cloud_pairing;
pub mod crash_report;
pub mod desktop_announce;
pub mod desktop_attention;
pub mod desktop_bursts;
pub mod desktop_center;
pub mod editors;
pub mod empty_workspace;
pub mod files;
pub mod handlers_verbs;
pub mod history;
pub mod keybind_route;
pub mod launch;
pub mod launch_recovery;
pub mod naming;
pub mod notification_policy;
pub mod notification_rings;
pub mod notifications;
pub mod onboarding;
pub mod remote;
pub mod restore;
pub mod right_column;
pub mod screen_share;
pub mod server;
pub mod subagent_panes;
pub mod tabs;
pub mod targets;
pub mod update_idle;
pub mod workspaces;
