//! Control protocol server over Unix JSON-lines and WebSocket text frames.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-tui attach` client, scripts). Unix uses one JSON message
//! per line and WebSocket uses one JSON message per text frame. Two commands
//! additionally turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   surface-output, surface-exited, title-changed, bell) interleaved
//!   with responses.
//! - `attach-surface` — PTYs receive `{"event":"vt-state"}` with a
//!   base64 VT replay followed by live `{"event":"output"}` pty bytes.
//!   Browsers receive `{"event":"browser-state"}` with optional latest
//!   frame followed by live `{"event":"frame"}` PNG payloads.
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-tui","session":"main",...}}
//! ```

use cmux_json::JsonSet as _;

#[cfg(test)]
use crate::mux::DaemonHandoffRequest;
#[cfg(test)]
use crate::workspace_registry::TerminalLifecycle;
#[cfg(test)]
use base64::Engine;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(test)]
use std::net::TcpListener;
use std::net::{Shutdown, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context;
use ghostty_vt::KittyReplayState;
#[cfg(test)]
use ghostty_vt::{KeyAction, Mods, sys};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[cfg(test)]
use tungstenite::WebSocket;
use zeroize::Zeroize;

#[cfg(test)]
use crate::AttachFrame;
#[cfg(test)]
use crate::BrowserAttachState;
#[cfg(test)]
use crate::GraphicsStatus;
#[cfg(test)]
use crate::JournalClass;
#[cfg(test)]
use crate::JournalSensitivity;
#[cfg(test)]
use crate::NotificationSource;
#[cfg(test)]
use crate::SurfaceRenderFrame;
#[cfg(test)]
use crate::TreeDeltaKind;
use crate::browser::BrowserMouseDispatch;
#[cfg(test)]
use crate::browser::BrowserPointerOwner;
#[cfg(test)]
use crate::browser::{BrowserAttachUpdate, BrowserFrameUpdate};
#[cfg(test)]
use crate::journal_kernel::JournalDocument;
use crate::model::{Screen, State};
use crate::mux::ClientSizingIdentity;
use crate::platform::{self, transport};
#[cfg(test)]
use crate::resource::BrowserPublicId;
#[cfg(test)]
use crate::resource::ContentPublicId;
use crate::resource::{
    RequestId as ResourceRequestId, ResourceError, ResourceOperation, StreamPublicId,
    TerminalPublicId,
};
use crate::sizing_policy::{
    TerminalDetachActor, TerminalDeviceKind, TerminalSizingPolicy, detach_reason,
};
use crate::stream_interrupt::StreamInterrupt;
#[cfg(test)]
use crate::surface::AttachLifecycle;
use crate::surface::{ClearHistoryDelivery, ClearHistoryFailure};
use crate::{
    Direction, LayoutLeafSpec, LayoutRatioError, LayoutSpec, MachineUsage, Mux, MuxEvent, Node,
    PairingDecision, PaneId, ScreenId, SplitDir, SplitId, SurfaceId, SurfaceKind, TreeDecorations,
    ViewportWidthError, WorkspaceId, WorkspaceMutation, ZoomMode,
};
#[cfg(test)]
use crate::{Rgb, TerminalColors};
#[cfg(test)]
use ghostty_vt::KeyInput;

pub const ATTACH_INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";
#[cfg(unix)]
mod apps;
#[cfg(unix)]
pub use apps::start_apps_when_ready;
pub use cmd_workspaces::WORKSPACE_NAME_SOURCE_CAPABILITY;
#[cfg(unix)]
mod browser_runtime;
#[path = "server/image_paste.rs"]
mod image_paste;
#[cfg(unix)]
mod scripts;
#[cfg(unix)]
pub use browser_runtime::BROWSER_RUNTIME_CAPABILITY;
#[path = "server/window_title.rs"]
mod window_title;
use window_title::sanitize_window_title;
pub use window_title::window_title_osc;
#[path = "server/loopback_forward.rs"]
mod loopback_forward;
pub use loopback_forward::{
    AuditReporter as LoopbackAuditReporter, LOOPBACK_FORWARD_CAPABILITY, LoopbackForwardPolicy,
};
mod admission;
#[cfg(unix)]
mod agent_cli_intents;
#[cfg(unix)]
mod agent_cli_job;
#[cfg(unix)]
mod agent_inventory;
#[cfg(unix)]
mod agent_session_attach;
#[cfg(unix)]
pub use agent_session_attach::{
    AGENT_SESSION_ATTACH_CAPABILITY, AGENT_SESSION_FOLDERS_CAPABILITY,
    AGENT_SESSION_START_CAPABILITY, AGENT_SESSION_START_KEYED_REASON_CAPABILITY,
    AGENT_SESSION_START_MODEL_CAPABILITY, AGENT_SESSION_START_NO_CWD_CAPABILITY,
    AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY, AGENT_SESSION_START_VM_KIND_CAPABILITY,
    AGENT_SESSION_TRUST_CAPABILITY, AGENT_SESSION_TRUST_VM_KIND_CAPABILITY, AcpmuxStarter,
    AgentStartHost, AgentStartHostSource, start_link_share_bridge,
};
#[cfg(unix)]
pub(crate) use agent_session_attach::{
    close_chat_shares, close_listed_chat_shares, close_unlisted_chat_shares, open_chat_shares,
};
#[cfg(unix)]
pub mod agent_transfer;
mod app_trust;
pub use app_trust::{FrontendKey, frontend_proof, install_frontend_key, read_frontend_key};
mod client_hello;
mod command_args;
#[cfg(unix)]
mod fs_wire;
mod line_connection;
use command_args::{
    parse_direction, parse_split_dir, parse_zoom_mode, present_nullable, workspace_mutation,
};
mod origin_gate;
mod orphan_shutdown;
mod page_router;
pub use orphan_shutdown::stop_orphaned_owner;
#[cfg(any(target_vendor = "apple", target_os = "linux"))]
mod starter_exit;
#[cfg(any(target_vendor = "apple", target_os = "linux"))]
pub use starter_exit::{Starter, exit_with_process};
mod pending_handoff;
mod renderer_grant;
use line_connection::{handle_connection_with_permit, serve_line_connection};
mod attachment_http;
mod bookmarks;
mod browser_host_command;
mod browser_profiles;
pub(crate) mod clipboard_read;
mod close_tabs_command;
mod cloud_attachments;
mod cloud_conversations;
pub mod cloud_host_replica;
mod conversation_attachments;
mod conversation_live;
mod conversation_resource;
mod conversation_runs;
mod resource_trust;
use resource_trust::{
    conversation_resource_client, handles_resource_connection_operation,
    trusted_local_resource_client,
};
mod api_revision_wire;
mod conversation_tabs_wire;
mod conversations;
mod detached_terminals;
mod feed_local;
mod frontend_browser_history;
mod history_search;
mod home;
mod icon_assets;
mod launch_snapshot;
pub(crate) use launch_snapshot::MAX_LAUNCH_SNAPSHOT_BYTES;
mod new_screen;
mod personal;
mod raw_tab;
#[cfg(unix)]
mod remote_entry;
mod remote_relay;
mod remote_terminal_tabs_wire;
#[cfg(test)]
use remote_relay::handle_connection_message;
mod cmd_attach;
mod cmd_browser;
#[cfg(test)]
use cmd_browser::browser_provider_registration;
mod cmd_frontend;
mod cmd_panes;
mod cmd_profiles;
mod cmd_screens;
mod cmd_server;
mod cmd_sizing;
mod size_lease;
use cmd_sizing::{optional_surface_size, paired_surface_size};
pub use size_lease::SIZE_LEASE_CAPABILITY;
mod cmd_subscribe;
mod cmd_tabs;
mod cmd_terminal_io;
mod cmd_terminals;
mod creating_input;
use cmd_terminals::placed_terminal_result;
mod cmd_workspaces;
mod column_move;
mod command_history;
mod page_credential;
mod page_files;
mod page_listener;
pub use page_files::page_bundle_dir;
pub use page_listener::{PageListenerOpener, WS_LISTEN_CAPABILITY, WS_LISTEN_ORIGINS_CAPABILITY};
mod responses;
mod rows;
mod screen_json;
mod server_stats;
mod session_stream;
mod split_kind;
mod split_respawn;
mod tab_column;
mod tab_park;
mod tab_restart;
mod websocket_listener;
#[cfg(test)]
use cmd_subscribe::subscribed_event_json;
use cmd_subscribe::subscription_overflow_json;
#[cfg(unix)]
pub use fs_wire::FsGate;
pub use launch_snapshot::{
    LaunchSnapshotTiming, LaunchSnapshotWriter, start_launch_snapshot_writer,
    start_launch_snapshot_writer_with,
};
#[cfg(unix)]
pub use remote_entry::{
    DenyAllGate, LinkVerifier, RemoteEntryServer, RemoteGate, RemotePeer, serve_remote_entry,
};
pub use remote_relay::ConversationGate;
use responses::{
    response_error_code, send_bad_request, send_request_error, send_request_error_with_delivery,
    send_response,
};
use screen_json::screen_json;
pub(crate) use screen_json::screen_layout_json;
mod group_outcome_json;
use group_outcome_json::{
    pane_tab_group_json, screen_group_outcome_json, tab_drag_outcome_json, tab_group_outcome_json,
    workspace_group_json, workspace_groups_json,
};
use split_respawn::{
    SplitRespawnRequest, frontend_shell, placement_spawn_options, shell_argv, split_tab,
};
mod connection_wait;
mod terminal_create;
mod terminal_history;
mod terminal_ports;
mod terminal_resources;
mod terminal_snapshot;
use terminal_snapshot::{attach_overflow_json, handle_attach_send_error, report_attach_overflow};
mod capabilities;
pub use capabilities::{build_capabilities, static_capabilities};
mod daemon_build;
pub use daemon_build::{
    BuildStamp, DAEMON_BUILD_CAPABILITY, DaemonBuild, install_build_stamp, install_daemon_build,
};
mod socket_path;
#[cfg(test)]
use socket_path::default_socket_path_in_runtime_dir;
#[cfg(unix)]
pub(crate) use socket_path::unix_socket_path_fits;
pub use socket_path::{
    default_socket_path, try_default_socket_path, try_default_socket_path_in_base,
    validate_session_name,
};
pub(crate) mod activity;
mod browser_input;
mod chief_control;
mod chief_engine_mirror;
mod chief_inspect;
mod chief_manage;
mod chief_registry_resource;
mod participant_avatars;
pub use chief_inspect::take_tools_socket_from_env as take_chief_tools_socket_from_env;
mod url_open;
#[cfg(test)]
use capabilities::advertised_capabilities;
use capabilities::identify_capabilities;
/// Maximum JSON payload accepted on the Unix JSON-lines control socket.
const MAX_JSON_LINE_BYTES: usize = crate::REMOTE_CLIENT_MESSAGE_MAX_BYTES;
const WORKSPACE_REGISTRY_CAPABILITY: &str = "workspace-registry-v1";
pub const GUARDED_BROWSER_POINTER_CAPABILITY: &str = "browser-pointer-frame-guard-v1";
pub const DAEMON_HANDOFF_FORCE_CAPABILITY: &str = "daemon-handoff-force-v1";
pub const VIEWPORT_SPLITS_CAPABILITY: &str = "viewport-splits-v1";
pub const VIEWPORT_COLUMN_RESIZE_CAPABILITY: &str = "viewport-column-resize-v1";
/// `set-column-dock` and the optional `Screen.columns[].dock` field: at
/// most one viewport column per edge stays pinned while the others scroll.
pub const DOCK_COLUMNS_CAPABILITY: &str = "dock-columns-v1";
/// `layout-changed` carries the screen's layout fields, its workspace and
/// the transaction of the request that caused it (events.md
/// `layout-changed`): a frontend patches that one screen.
pub const LAYOUT_DELTA_CAPABILITY: &str = "layout-delta-v1";
/// A docked column marked permanent stays docked on its edge for every
/// client: `set-column-dock` takes `permanent`, and an undock, another edge,
/// a replacement or a close or move that would remove it answers
/// `dock-column-permanent`.
pub const PERMANENT_DOCK_CAPABILITY: &str = "permanent-dock-v1";
/// A docked column marked pinned (the Home dock) keeps its first tab: no
/// close, move out or reorder away from the first place, and it takes no
/// other tab unless its `allow_tabs` is on. `set-column-dock` takes `pinned`;
/// `column.update` takes `pinned` and `allow_tabs`; refusals answer
/// `dock-column-pinned`.
pub const PINNED_DOCK_CAPABILITY: &str = "pinned-dock-v1";
/// Top and bottom docks: `set-column-dock` and `move-tab-to-column` accept
/// edges `top` and `bottom`, sent back as `Screen.columns[].dock`.
pub const EDGE_DOCKS_CAPABILITY: &str = "edge-docks-v1";
/// `set-column-dock` and `move-tab-to-column` accept `role` (`agent_chat`),
/// kept with the pin and sent back as `Screen.columns[].dock.role`.
pub const DOCK_COLUMN_ROLE_CAPABILITY: &str = "dock-column-role-v1";
/// `new-row`, `set-row-heights` and `Screen.columns[].rows` (rows.md).
pub const ROWS_CAPABILITY: &str = "rows-v1";
/// `move-column`: a whole viewport column moves one place left or right.
pub const COLUMN_MOVE_CAPABILITY: &str = "column-move-v1";
/// `kind` (`pty` | `browser`) and `url` on `split` and `new-pane-right`.
pub const PANE_BROWSER_KIND_CAPABILITY: &str = "pane-browser-kind-v1";
pub const TAB_WORKSPACE_MOVE_CAPABILITY: &str = "tab-workspace-move-v1";
pub const LAYOUT_UNDO_CAPABILITY: &str = "layout-undo-v1";
pub const CLEAR_HISTORY_CAPABILITY: &str = "clear-history-v1";
/// Finished shell commands (OSC 133) as deletable rows with a retention.
pub const TERMINAL_COMMAND_HISTORY_CAPABILITY: &str = "terminal-command-history-v1";
pub const CLEAR_HISTORY_KEY_CAPABILITY: &str = "clear-history-key-v1";
pub const SURFACE_SUBSCRIBE_FILTER_CAPABILITY: &str = "surface-subscribe-filter";
pub const SESSION_JOURNAL_CAPABILITY: &str = "session-journal-v1";
pub const FRONTEND_JOURNAL_CAPABILITY: &str = "frontend-journal-v1";
/// Journal administration is restricted to the owner-only Unix socket. Use
/// that stable security principal for receipts so a reconnect can safely
/// replay a command instead of creating a second event.
const LOCAL_JOURNAL_PRINCIPAL: &str = "cmux.local-owner";
pub const VIEW_ATTACHMENT_LEASE_CAPABILITY: &str = "view-attachment-lease-v1";
pub const VIEW_ATTACHMENT_DETACH_CAPABILITY: &str = "view-attachment-detach-v1";
/// Shared terminal sizing (`docs/shared-terminal-sizing.md`): `size-state`
/// events, `set-size-policy`, `set-size-counts`, `get-size-state`, relay
/// sub-views on `resize-attached-view`, client identity on `set-client-info`,
/// and `reason`/`by` on `detached`.
pub const SHARED_SIZING_CAPABILITY: &str = "shared-sizing-v1";
/// A client that lists this in `set-client-info` survives losing its own
/// view of a terminal: `detach-client` naming that view's participant
/// detaches the view only (event `detached` with `scope:"view"`) and keeps
/// the connection and its relay sub-views; `reattach-view` restores it. The
/// daemon advertises it in `identify`.
pub const SIZING_VIEW_DETACH_CAPABILITY: &str = "sizing-view-detach-v1";
/// A phone or tablet view that lists this in `set-client-info` shows a
/// terminal grid larger than its own correctly (letterbox or pan). Without it
/// the daemon never applies a PTY grid larger than that view's reported size
/// while the view is attached with one (`mux/terminal_sizing/handheld_ceiling.rs`):
/// such a phone renders the PTY's output into its own grid, so a wider PTY
/// overprints and cuts its rows. The daemon advertises it in `identify`.
pub const HOST_GRID_VIEW_CAPABILITY: &str = "host-grid-view-v1";
/// A client that lists this in `set-client-info` decodes every
/// `device_kind` of a size state and reads a kind it does not know as
/// `unknown`. It receives `linux` and `windows` (and later kinds) as they
/// are; other clients receive them as `unknown`. The daemon advertises it in
/// `identify`.
pub const OPEN_DEVICE_KINDS_CAPABILITY: &str = "open-device-kinds-v1";
pub const TERMINAL_COLOR_OVERRIDES_CAPABILITY: &str = "terminal-color-overrides-v1";
/// Byte viewers that write their own sequences after a replay advertise this
/// to receive the replay's incomplete sequence as a separate `pending` field.
/// Other attachments get it appended to the replay bytes, in the legacy shape.
pub const TERMINAL_PENDING_SEQUENCE_CAPABILITY: &str = "terminal-pending-sequence-v1";
pub const CREATION_RECEIPTS_CAPABILITY: &str = "creation-receipts-v1";
pub const CREATION_ATTEMPT_KEYS_CAPABILITY: &str = "creation-attempt-keys-v1";
pub const CREATION_SELECTOR_FALLBACKS_CAPABILITY: &str = "creation-selector-fallbacks-v1";
pub const MAX_CREATION_SELECTOR_FALLBACKS: usize = 7;
pub const PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY: &str =
    "provider-managed-workspace-authority-v2";
pub const BROWSER_PROVIDER_CAPABILITY: &str = "browser-provider-v1";
/// Advertises `hosting` on `register-browser-provider`: a `"native"` provider
/// presents its pages itself, so the daemon never overrides their device
/// metrics and screencasts them only while a frame viewer is attached.
pub const BROWSER_PROVIDER_NATIVE_HOSTING_CAPABILITY: &str = "browser-provider-native-hosting-v1";
/// Advertises the `server-stats` command.
pub const SERVER_STATS_CAPABILITY: &str = "server-stats-v1";
pub const CLIENT_FOCUS_CAPABILITY: &str = "client-focus-v1";
pub const DAEMON_SHUTDOWN_EVENT: &str = "daemon-shutdown";
/// `error_code` of a request refused while the daemon's shutdown handoff is
/// reserved and not yet announced. The [`DAEMON_SHUTDOWN_EVENT`] follows
/// unless the shutdown is cancelled.
pub const DAEMON_SHUTDOWN_PENDING_CODE: &str = "daemon_shutdown_pending";
/// The daemon answers `machine-usage` and emits `machine-usage-changed`.
pub const MACHINE_USAGE_CAPABILITY: &str = "machine-usage-v1";
/// The daemon reads the host's listening TCP sockets for an authenticated
/// client. Cloud clients use this over the private cmux-tui link, so routine
/// port inventory never needs a provider or web control-plane call.
pub const MACHINE_LISTENING_TCP_CAPABILITY: &str = "machine-listening-tcp-v1";
/// The daemon answers `terminal-ports`: loopback ports the terminal's text
/// names (also from tmux panes) that accept a connect
/// (workspace-proxy-DESIGN.md section 6). No process scanning.
pub const TERMINAL_PORTS_CAPABILITY: &str = "terminal-ports-v1";
/// Advertises `set-terminal-idle-policy` and the owner-side reaper that
/// closes a terminal once it has had no attached view for its policy.
pub const TERMINAL_IDLE_CLOSE_CAPABILITY: &str = "terminal-idle-close-v1";
/// Advertises the owner-side reaper that ends a terminal after it has had no
/// tab placement for the reap grace period, `set-terminal-keep`, the `keep`
/// field on `new-tab`, `split`, and `create-terminal`, the `terminal-reaped`
/// event, and `end_terminals` on `shutdown-daemon`.
pub const TERMINAL_REAP_CAPABILITY: &str = "terminal-reap-v1";
/// Advertises `terminal-resume-command`: a person's resume command for one
/// terminal, typed on the new prompt when the terminal is respawned.
pub const RESUME_COMMAND_CAPABILITY: &str = "resume-command";
/// Advertised only while this owner's unplaced-terminal reaper runs (the
/// owner was started with `--terminal-reap-grace-seconds`). Without it a
/// detached terminal lives until it is ended or the session ends, so a
/// client that closes a tab should end the terminal (`close-terminal`)
/// instead of only detaching it (`close-surface`).
pub const TERMINAL_REAPER_ACTIVE_CAPABILITY: &str = "terminal-reaper-active-v1";
/// Advertises `keep_layout` on `shutdown-daemon`: with `end_terminals`,
/// every terminal ends but the placed ones keep their tabs, so the next
/// owner shows the same screens, splits and tabs, each dead until a
/// frontend starts a new shell in it.
pub const END_TERMINALS_KEEP_LAYOUT_CAPABILITY: &str = "end-terminals-keep-layout-v1";
/// Advertises `close-tabs` and `end_terminals` on `close-pane`,
/// `close-screen`, `close-workspace`, and `close-tab-group`: many
/// placements and the terminals they end close in one durable commit.
pub const BATCH_CLOSE_CAPABILITY: &str = "batch-close-v1";
/// Advertises `if_empty` on `close-workspace`: the close commits only when
/// the workspace has no tab, so closing a workspace a move emptied never
/// deletes a tab another client opened there meanwhile.
pub const CLOSE_WORKSPACE_IF_EMPTY_CAPABILITY: &str = "close-workspace-if-empty-v1";
/// Advertises `terminal-resources`: CPU time and memory of each terminal's
/// shell, its descendants, and its terminal host, read on request.
pub const TERMINAL_RESOURCES_CAPABILITY: &str = "terminal-resources-v1";
/// Advertises a caller-chosen `terminal_id` on `new-tab`, `split`,
/// `new-pane`, and `new-pane-right`, plus `cwd`/`env` on `new-pane` and
/// `new-pane-right`, and `terminal_id`/`terminal_incarnation` in all four
/// results. A frontend can put the id in the child's environment before it
/// starts instead of creating and then moving a terminal.
pub const TERMINAL_PLACEMENT_ENV_CAPABILITY: &str = "terminal-placement-env-v1";
/// Durable sidebar workspace groups: the `*-workspace-group` commands,
/// `move-workspace-to-group`, a `groups` array in `list-workspaces`, and a
/// `group` field on every workspace.
pub const WORKSPACE_GROUPS_CAPABILITY: &str = "workspace-groups-v1";
/// Durable workspace presentation: `set-workspace-metadata`, the
/// `color`/`icon`/`title` workspace fields, and `workspace-changed` deltas.
pub const WORKSPACE_METADATA_CAPABILITY: &str = "workspace-metadata-v1";
/// Live agent presence: the `agent-presence-changed` subscribe event, what
/// the agent in a surface is touching now (activity, tool, file and line).
pub const AGENT_PRESENCE_CAPABILITY: &str = "agent-presence-v1";
/// The sidebar workspace pin: `pinned` on `set-workspace-metadata` and the
/// `pinned` workspace field.
pub const WORKSPACE_PIN_CAPABILITY: &str = "workspace-pin-v1";
/// The manual workspace unread mark: `marked_unread` on
/// `set-workspace-metadata` and the `marked_unread` workspace field.
pub const NOTIFICATION_MARK_UNREAD_CAPABILITY: &str = "notification-mark-unread-v1";
/// The manual tab unread mark: `marked_unread` on `tab.update` and the tab
/// resource's `extra.marked_unread`. It needs no notification; clients clear
/// it when the person views the tab.
pub const TAB_MARK_UNREAD_CAPABILITY: &str = "tab-mark-unread-v1";
/// An agent's "needs you here" mark on a tab: `attention` (a reason, or null
/// to clear) on `tab.update` and the tab resource's `extra.attention`
/// (`{reason, at_ms}`). Viewing the tab keeps it; the agent's clear, a browser
/// tab's navigation to another page, or the tab's close clears it.
pub const TAB_ATTENTION_CAPABILITY: &str = "tab-attention-v1";
/// Persisted request identities and compare-and-clear for tab attention.
pub const TAB_ATTENTION_REQUEST_ID_CAPABILITY: &str = "tab-attention-request-id-v1";
/// A workspace's description: `description` on `workspace.update` (null
/// clears it) and the workspace snapshot's `extra.description` while set.
pub const WORKSPACE_DESCRIPTION_CAPABILITY: &str = "workspace-description-v1";
/// A workspace's manual task status (classic cmux lanes `todo`, `working`,
/// `needs-attention`, `review`, `done`): `task_status` on `workspace.update`
/// (null is automatic) and the workspace snapshot's `extra.task_status`.
pub const WORKSPACE_STATUS_CAPABILITY: &str = "workspace-status-v1";
/// `workspace.create` takes `focus`: a created workspace becomes the focused
/// one only with `focus: true` (the app sends it for the person's creations).
pub const WORKSPACE_CREATE_FOCUS_CAPABILITY: &str = "workspace-create-focus-v1";
/// `workspace.create` takes `placement` (`top`, `after_current`, `bottom`):
/// the new workspace's sidebar place for that create, over the
/// `workspaces.newPlacement` setting; and `workspace.move {index}` moves the
/// workspace in the sidebar document's order too (#29875).
pub const WORKSPACE_SIDEBAR_PLACEMENT_CAPABILITY: &str = "workspace-sidebar-placement-v1";
/// Tab metadata in the raw tree: `set-tab-pinned` with pinned-first order,
/// `Tab.pinned`, `Tab.cwd`, `Tab.git_branch`, `Tab.git_detached`, and the `tab-changed` delta.
pub const TAB_METADATA_CAPABILITY: &str = "tab-metadata-v1";
/// Frontend-rendered browser tabs (WebKit or CEF): `new-frontend-browser-tab`,
/// `update-frontend-browser-tab`, and the `browser_renderer`,
/// `browser_engine`, `favicon_url`, and `browser_profile_id` tab fields.
pub const FRONTEND_BROWSER_TABS_CAPABILITY: &str = "frontend-browser-tabs-v1";
pub use frontend_browser_history::{
    FRONTEND_BROWSER_HISTORY_CAPABILITY, FRONTEND_BROWSER_TAB_PROFILE_CAPABILITY,
};
/// Tab drag outcomes as single atomic commands: `move-tab-to-split`,
/// `move-tab-to-column`, `move-tab-to-new-workspace`, layout undo for
/// same-screen drags, and a client `transaction` id echoed in `tab-changed`.
pub const TAB_DRAG_CAPABILITY: &str = "tab-drag-v1";
pub use split_respawn::{TAB_SPLIT_KEEP_FOCUS_CAPABILITY, TAB_SPLIT_RESPAWN_CAPABILITY};
pub use tab_column::TAB_COLUMN_RESPAWN_CAPABILITY;
/// Optional `name` on `move-tab-to-new-workspace`: the new workspace takes
/// it in the same commit (else the default `workspace-N`).
pub const TAB_WORKSPACE_NAME_CAPABILITY: &str = "tab-workspace-name-v1";
/// Durable notification acknowledgement decoupled from focus:
/// `ack-tab-notifications`, `list-notifications`, and the workspace `unread_count` rollup.
pub const NOTIFICATION_ACK_CAPABILITY: &str = "notification-ack-v1";
/// Tab groups: the `*-tab-group` commands, `Pane.tab_groups`, and `Tab.group`.
pub const TAB_GROUPS_CAPABILITY: &str = "tab-groups-v1";
/// Saved (pinned) tab groups that outlive their placements.
pub const SAVED_TAB_GROUPS_CAPABILITY: &str = "saved-tab-groups-v1";
/// Per-terminal `env` on `new-tab`, `split`, and `create-terminal`, and `cwd` on `split`.
pub const TERMINAL_ENV_CAPABILITY: &str = "terminal-env-v1";
/// `identify` carries `session_id` (the durable registry id) and
/// `machine_name` (plans/cmux-next/data-model.md section 2).
pub const SESSION_IDENTITY_CAPABILITY: &str = "session-identity-v1";
/// Personal state of the home session: rooms (`*-profile`), follows, pins,
/// the session registry, personal groups and order, `list-personal`, and the
/// `personal-changed` event (plans/cmux-next/data-model.md section 3).
pub const PROFILES_CAPABILITY: &str = "profiles-v1";
/// `placement-shift-v1`: an echoing connection gets no `workspace_placement`
/// restatement on `session.events` (state/placement_shift.rs).
pub use crate::state::placement_shift::CAPABILITY as PLACEMENT_SHIFT_CAPABILITY;
/// Per-terminal themes in the home session's personal state:
/// `set-personal-terminal` and `list-personal.terminals`.
pub const PERSONAL_TERMINALS_CAPABILITY: &str = "personal-terminals-v1";
/// Browser profile records in personal state: `browser_profiles` in
/// `list-personal` and the `*-browser-profile` commands (plans/cmux-next/data-model.md section 5).
pub const BROWSER_PROFILES_CAPABILITY: &str = "browser-profiles-v1";
pub use bookmarks::{BOOKMARK_ICON_CAPABILITY, BOOKMARKS_CAPABILITY};
/// Screen presentation: `set-screen-metadata`, `set-screen-pinned`,
/// `move-screen`, `new-screen` with `screen_name`/`color`/`icon`/`pinned`/
/// `index`/`group`/`cwd`, the `color`/`icon`/`pinned`/`group` screen fields,
/// and `screen-changed` deltas.
pub const SCREEN_METADATA_CAPABILITY: &str = "screen-metadata-v1";
/// Screen groups: the `*-screen-group` commands, saved screen
/// groups, and `Workspace.screen_groups`.
pub const SCREEN_GROUPS_CAPABILITY: &str = "screen-groups-v1";
/// `launch_snapshot_path` in `identify`: a read-only file with the last
/// settled tree and frontend projections, for drawing before connecting.
pub const LAUNCH_SNAPSHOT_CAPABILITY: &str = "launch-snapshot-v1";
/// `shell_args` on `new-tab`, `split`, `new-pane`, `new-pane-right`, and
/// `create-terminal`: arguments for the terminal's shell.
pub const TERMINAL_SHELL_ARGS_CAPABILITY: &str = "terminal-shell-args-v1";
/// A client that echoes this in `set-client-info` resolves Ghostty's shell
/// integration itself (into the terminal's `env` and `shell_args`): the
/// terminals it creates start their `SHELL` exactly as given, and the host
/// adds no integration of its own.
pub const TERMINAL_FRONTEND_SHELL_INTEGRATION_CAPABILITY: &str =
    "terminal-frontend-shell-integration-v1";
/// `env`, `terminal_id` and `shell_args` on `new-screen`, and `terminal_id`
/// in its result.
pub const SCREEN_TERMINAL_ENV_CAPABILITY: &str = "screen-terminal-env-v1";
/// Notifications name who posted them: `source` (`cli`, `terminal`, `agent`, `daemon`) on
/// `notify`, the `notification` event, the tab marker and `list-notifications`; the daemon
/// posts OSC 9, OSC 777 and OSC 99 from every terminal's output as `terminal`.
pub const NOTIFICATION_SOURCE_CAPABILITY: &str = "notification-source-v1";
/// The `cmux.protocol/2` state resources (plans/cmux-next/state-ownership.md steps A and B):
/// workspace metadata, tab pins and tab groups, personal workspace groups, rooms and saved
/// tab groups, screen metadata, order and screen groups, closed history, ephemeral
/// workspaces, and workspace status, progress and log, with `extra.state` on session
/// snapshots and `state_upsert`/`state_delete` changes on `session.events`.
pub const STATE_RESOURCES_CAPABILITY: &str = "state-resources-v1";
/// Terminal tabs report `terminal_state` (`running`, `adopting`, `reconnecting`,
/// `failed`, `unadoptable`, `exited`), `host_record_version` for an unadoptable
/// host, and `end`, the typed end of a dead terminal (`exited`, `signaled`,
/// `host_lost` with a stable `reason`, `launch_failed`). A tab is `dead` only
/// when its terminal ended (plans/cmux-next/durable-sessions.md section 7).
pub const TERMINAL_STATE_CAPABILITY: &str = "terminal-state-v1";
/// `window_record.list|put|delete`: one personal record per app window with
/// a per-record revision (OWNERSHIP-PRINCIPLES single writer).
pub const WINDOW_RECORDS_CAPABILITY: &str = "window-records-v1";
/// `owner` on frontend browser records: the raw `new-frontend-browser-tab`
/// and `update-frontend-browser-tab` field, `tab.update {owner}`, and the
/// tab's `extra.owner` and raw `browser_owner`.
pub const FRONTEND_BROWSER_OWNER_CAPABILITY: &str = "frontend-browser-owner-v1";
const INITIAL_BROWSER_RESIZE_TIMEOUT: Duration = Duration::from_secs(10);
pub const STABLE_SPLIT_IDS_PROTOCOL_VERSION: u32 = 8;
pub const STACK_LAYOUT_PROTOCOL_VERSION: u32 = 9;
pub const PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION: u32 = 10;
/// Protocol version in which the session journal capability became available.
pub const SESSION_JOURNAL_PROTOCOL_VERSION: u32 = PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION;
pub const TERMINAL_LIFECYCLE_PROTOCOL_VERSION: u32 = 11;
pub const LIFECYCLE_READINESS_PROTOCOL_VERSION: u32 = 12;
pub const PROTOCOL_VERSION: u32 = LIFECYCLE_READINESS_PROTOCOL_VERSION;

/// The API revisions this build speaks: `(current, oldest it translates)`
/// (server/api_revision_wire.rs, cmux-tui/spec/api-compat.json).
pub fn api_revision_range() -> (u32, u32) {
    api_revision_wire::identify_fields()
}

/// The compiled API revision history for clients connecting to an older daemon.
pub fn api_revision_compat() -> &'static cmux_api_compat::Compat {
    api_revision_wire::compat()
}
mod protocol_key;
#[cfg(test)]
use protocol_key::PROTOCOL_KEY_TEXT_MAX_BYTES;
pub use protocol_key::ProtocolKeyInput;
pub(crate) use protocol_key::{
    decode_terminal_host_clear_history, encode_terminal_host_clear_history,
};

mod wire_values;
use wire_values::{default_renderer_capability_ttl_ms, json_line_payload_len, machine_usage_json};

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: Command,
}

#[derive(Deserialize)]
struct CreateSurfaceWithReceiptRequest {
    operation: String,
    origin: String,
    /// Stable correlation identity for the logical creation across retries.
    receipt: String,
    /// One execution attempt. Omission preserves the original adapter
    /// behavior by using `receipt` for both identities.
    #[serde(default)]
    idempotency_key: Option<String>,
    /// Stable public identities captured by the frontend before the request
    /// is sent. Numeric targets remain a legacy fallback.
    #[serde(default)]
    selectors: Option<crate::ResourceSelectors>,
    /// Ordered client-local selection continuations used only when the
    /// primary creation target disappeared before the mutation committed.
    #[serde(default)]
    selector_fallbacks: Vec<crate::ResourceSelectors>,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BrowserProviderTargetRequest {
    tab_id: String,
    target_id: String,
}

/// `set-host-size-policy`'s `policy`: a mode and optionally the order.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HostSizePolicyRequest {
    mode: String,
    #[serde(default)]
    order: Option<Vec<String>>,
}

/// Optional shared-sizing identity carried by `set-client-info` and relay sub-views.
#[derive(Clone, Debug, Default, Deserialize)]
struct ClientIdentityWire {
    #[serde(default)]
    user_id: Option<String>,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    device_kind: Option<String>,
    #[serde(default)]
    device_name: Option<String>,
    /// Stable per-install device id; tells two devices of one user apart.
    #[serde(default)]
    device_id: Option<String>,
}

impl ClientIdentityWire {
    /// The same identity without a user or a device id.
    fn anonymous(self) -> Self {
        Self { user_id: None, device_id: None, ..self }
    }

    fn is_empty(&self) -> bool {
        self.user_id.is_none()
            && self.display_name.is_none()
            && self.device_kind.is_none()
            && self.device_name.is_none()
            && self.device_id.is_none()
    }

    fn into_identity(self) -> ClientSizingIdentity {
        ClientSizingIdentity {
            user_id: self.user_id.map(clamp_client_label),
            display_name: self.display_name.map(clamp_client_label),
            device_kind: self
                .device_kind
                .as_deref()
                .map_or(TerminalDeviceKind::Unknown, TerminalDeviceKind::parse),
            device_name: self.device_name.map(clamp_client_label),
            device_id: self.device_id.map(clamp_client_label),
            remote: false,
        }
    }
}

/// `detach-client` target: a numeric client id or a host participant id.
#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum DetachClientTarget {
    Client(u64),
    Participant(String),
}

impl DetachClientTarget {
    /// The whole connection this target names, if it names one directly.
    fn whole_client(&self) -> Option<u64> {
        match self {
            Self::Client(client) => Some(*client),
            Self::Participant(id) => id.strip_prefix('c').and_then(|rest| rest.parse().ok()),
        }
    }
}

/// Why a connection or view was detached and who did it.
struct DetachNotice {
    reason: &'static str,
    by: Option<TerminalDetachActor>,
}

impl DetachNotice {
    const fn network() -> Self {
        Self { reason: detach_reason::NETWORK, by: None }
    }
}

// Variant names are the wire command names (`terminal-resume-command`).
#[allow(clippy::enum_variant_names)]
#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    Identify {
        #[serde(default)]
        machine_metadata: bool,
        /// Adds `api_revision`, `min_api_revision`, `crate_version`,
        /// `install` and `update_command` (server/api_revision_wire.rs).
        #[serde(default)]
        revisions: bool,
    },
    BrowserHostProvider,
    SubscribeActivity,
    /// Private, connection-scoped guest-to-frontend OS browser opening.
    UrlOpenSubscribe {
        terminal_ids: Vec<String>,
    },
    UrlOpen {
        terminal_id: String,
        url: String,
    },
    /// The Chief memory inspector's read-only API, for the owner's trusted
    /// connection, forwarded to the brain host (`chief-inspect-v1`).
    ChiefInspect(chief_inspect::Params),
    UrlOpenClaim {
        request_id: String,
    },
    UrlOpenResult {
        request_id: String,
        opened: bool,
    },
    TerminalClipboardSubscribe {
        terminal_ids: Vec<String>,
    },
    TerminalClipboardReply {
        request_id: String,
        text: Option<String>,
    },
    PasteImage {
        surface: SurfaceId,
        terminal_id: String,
        lease: String,
        upload_id: String,
        op: String,
        mime: Option<String>,
        size: Option<usize>,
        offset: Option<usize>,
        data: Option<String>,
    },
    /// Report where this daemon spends its time: registry lock contention
    /// with holder sites, journal writer batch metrics, and connection
    /// admission. Owner-only diagnostics, never journaled. `include` names
    /// optional sections (`resource_projection`); unknown names are ignored.
    ServerStats {
        include: Option<Vec<String>>,
    },
    /// `terminal-command-history-v1`, trusted local only (server/command_history.rs).
    SetTerminalCommandHistory(command_history::SetParams),
    ListTerminalCommands(command_history::ListParams),
    DeleteTerminalCommands(command_history::DeleteParams),
    /// Gracefully hand this daemon's durable session to a replacement.
    /// The caller must fence the request with values from this daemon's `identify` response.
    ShutdownDaemon {
        pid: u32,
        generation: String,
        #[serde(default)]
        force: bool,
        /// End every terminal host before the handoff instead of leaving
        /// hosts for the next owner (`terminal-reap-v1`). For test teardown.
        #[serde(default)]
        end_terminals: bool,
        /// With `end_terminals`, keep the tabs of placed terminals so the
        /// next owner shows the same layout (`end-terminals-keep-layout-v1`).
        #[serde(default)]
        keep_layout: bool,
    },
    Ping,
    SetClientInfo {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        kind: Option<String>,
        #[serde(default)]
        capabilities: Option<Vec<String>>,
        /// Shared-sizing identity. `user_id` is asserted by the connection
        /// and is not verified by this daemon.
        #[serde(default)]
        user_id: Option<String>,
        #[serde(default)]
        display_name: Option<String>,
        #[serde(default)]
        device_kind: Option<String>,
        #[serde(default)]
        device_name: Option<String>,
        #[serde(default)]
        device_id: Option<String>,
        /// The API revision the client reads and writes
        /// (server/api_revision_wire.rs). Absent: revision 12.
        #[serde(default)]
        api_revision: Option<u32>,
        /// The client's release (`cmux --version`), for refusals and logs.
        #[serde(default)]
        version: Option<String>,
        /// How the client was installed (`npm`, `pypi`, `app`, `other`),
        /// so a refusal names its update command.
        #[serde(default)]
        install: Option<String>,
        /// `host-size-policy-v1`: this connection is a remote device's
        /// spliced lane (cmux-mobile-host sets it on every phone), never one
        /// of this host's own views. Sticky: `false` never clears it.
        #[serde(default)]
        remote: Option<bool>,
    },
    ListClients,
    /// Read the machine-level model spend readout hosted by this daemon.
    MachineUsage,
    /// Read listening TCP sockets on this host. The fixed command has no
    /// caller-controlled arguments and returns only the socket listing.
    MachineListeningTcp,
    /// Publish the native browser process's live CDP targets. This is an
    /// owner-only, connection-scoped lease and never enters the journal.
    RegisterBrowserProvider {
        provider_id: String,
        endpoint: String,
        authentication: String,
        #[serde(default)]
        bearer_token: Option<String>,
        /// `browser-provider-native-hosting-v1`: `"native"` or `"daemon"`
        /// (the default when absent).
        #[serde(default)]
        hosting: Option<String>,
        targets: Vec<BrowserProviderTargetRequest>,
    },
    /// Return the current provider lease for local automation such as
    /// Vercel agent-browser. Remote/WebSocket clients cannot read it.
    GetBrowserProvider,
    UnregisterBrowserProvider,
    /// Canonical non-tombstoned terminal placement/lifecycle snapshot.
    ListTerminals,
    /// Durable ordered terminal mutations after `terminal_revision`.
    TerminalEvents {
        #[serde(default)]
        after_revision: u64,
    },
    SetClientSizing {
        surface: SurfaceId,
        #[serde(default)]
        client: Option<u64>,
        enabled: bool,
        #[serde(default)]
        exclusive: bool,
    },
    PairingResponse {
        request: u64,
        approve: bool,
    },
    DetachClient {
        client: DetachClientTarget,
        #[serde(default)]
        by: Option<TerminalDetachActor>,
        /// Resolves a participant id on this terminal only (participant ids are per terminal).
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    /// Restore the caller's own view of a terminal after a view detach.
    /// `counts:false` reattaches as a viewer.
    ReattachView {
        surface: SurfaceId,
        #[serde(default)]
        counts: Option<bool>,
    },
    /// Set the shared sizing policy of one terminal (override) or the default
    /// of one workspace. `policy:null` clears it.
    SetSizePolicy {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        policy: Option<TerminalSizingPolicy>,
    },
    /// Set or clear (`counts:null`) one participant's counts-toward-size
    /// override. Without a selector it targets the caller's own view.
    SetSizeCounts {
        surface: SurfaceId,
        #[serde(default)]
        client: Option<u64>,
        #[serde(default)]
        lease: Option<String>,
        #[serde(default)]
        view: Option<String>,
        #[serde(default)]
        participant: Option<String>,
        counts: Option<bool>,
    },
    GetSizeState {
        surface: SurfaceId,
    },
    /// The host sizing policy (`host-size-policy-v1`) and, with `surface`,
    /// which of its terminal's participants are this host's own views.
    GetHostSizePolicy {
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    /// Store the host sizing policy in the settings file and apply it.
    SetHostSizePolicy {
        policy: HostSizePolicyRequest,
    },
    /// Record explicit input or focus activity for the caller's own view, or
    /// with `view` for one of its relay sub-views (input a relay forwards).
    NoteSizeActivity {
        surface: SurfaceId,
        #[serde(default)]
        view: Option<String>,
    },
    ReloadConfig,
    SetWindowTitle {
        title: String,
    },
    ClearWindowTitle,
    ListWorkspaces,
    GetFrontendProjection {
        frontend: String,
        scope: String,
        subject_key: String,
    },
    PutFrontendProjection {
        frontend: String,
        scope: String,
        subject_key: String,
        schema_version: u32,
        #[serde(default)]
        expected_projection_revision: Option<u64>,
        projection: Value,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    JournalFrontendEvent {
        event: crate::FrontendJournalEvent,
    },
    ExportLayout {
        #[serde(default)]
        screen: Option<ScreenId>,
    },
    ApplyLayout {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        name: Option<String>,
        layout: LayoutRequest,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// `send`: write input to a terminal.
    Send(cmd_terminal_io::SendParams),
    ReadScreen {
        surface: SurfaceId,
    },
    ClearHistory {
        surface: SurfaceId,
        /// Structured key input encoded using the authoritative terminal
        /// modes when the surface is in the alternate screen.
        #[serde(default)]
        fallback_key: Option<ProtocolKeyInput>,
    },
    ReadScrollback {
        surface: SurfaceId,
        start: u32,
        count: u32,
    },
    SidebarPlugin {
        cols: u16,
        rows: u16,
        #[serde(default)]
        relaunch: bool,
    },
    WaitFor {
        surface: SurfaceId,
        pattern: String,
        #[serde(alias = "timeout_ms")]
        timeout_ms: u64,
    },
    Run {
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        new_workspace: bool,
        /// Optional stable key for a newly-created workspace.
        ///
        /// This is rejected unless `new_workspace` is true. Detached and
        /// provider-backed frontends use it to keep workspace identity stable
        /// across display-name changes and reconciliation.
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Execute one destination-creating TUI action behind a durable receipt.
    /// Repeating the same receipt with identical fields returns the exact
    /// created view, so a lost response can never duplicate or retarget it.
    CreateSurfaceWithReceipt(Box<CreateSurfaceWithReceiptRequest>),
    SendKey {
        surface: SurfaceId,
        keys: Vec<String>,
    },
    Copy {
        surface: SurfaceId,
        mode: String,
    },
    Ids {
        #[serde(default)]
        kind: Option<String>,
    },
    Notify {
        title: String,
        body: String,
        #[serde(default)]
        level: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
        /// `notification-source-v1`: `cli` (default), `terminal`, `agent` or `daemon`.
        #[serde(default)]
        source: Option<String>,
    },
    ListAgents {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        state: Option<String>,
    },
    ReportAgent {
        surface: SurfaceId,
        state: String,
        source: String,
        #[serde(default)]
        session: Option<String>,
    },
    /// One-shot VT replay of the surface's current state (base64).
    VtState {
        surface: SurfaceId,
    },
    /// Mint a one-use direct renderer credential without exposing the
    /// daemon's durable owner capability.
    MintTerminalRenderer {
        surface: SurfaceId,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    /// Mint a renderer credential from the stable public terminal identity.
    /// Remote clients must not depend on this daemon generation's local numeric surface handle.
    MintTerminalRendererByTerminal {
        terminal: String,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    /// Resolve a process-stable hosted terminal UUID to this daemon
    /// generation's local surface handle without creating anything.
    ResolveTerminal {
        terminal_id: String,
    },
    /// Close a hosted terminal by stable identity. This is safe across daemon
    /// generations; the incarnation guard prevents a stale close request.
    CloseTerminal {
        terminal_id: String,
        #[serde(default)]
        terminal_incarnation: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Set (`idle_close_seconds`) or clear (`null`, never close) the
    /// idle-close policy of one hosted terminal, named by exactly one of a
    /// PTY `surface` or a stable `terminal_id`. The policy is durable and survives owner restarts.
    SetTerminalIdlePolicy {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        terminal_id: Option<String>,
        #[serde(default)]
        idle_close_seconds: Option<u64>,
    },
    /// Mark (`keep: true`) or unmark one hosted terminal, named by exactly
    /// one of a PTY `surface` or a stable `terminal_id`, as kept: a kept
    /// terminal is not reaped when it has no tab placement.
    SetTerminalKeep {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        terminal_id: Option<String>,
        keep: bool,
    },
    /// Read, set (a string) or clear (null) the resume command of one hosted
    /// terminal, named by exactly one of a PTY `surface` or a stable
    /// `terminal_id`. A respawn of the terminal types the command on its new
    /// prompt without a newline. An absent `command` only reads it.
    TerminalResumeCommand {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        terminal_id: Option<String>,
        #[serde(default, deserialize_with = "present_nullable")]
        command: Option<Option<String>>,
    },
    /// New tab in a pane (default: the active pane).
    NewTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cwd: Option<String>,
        /// Extra environment for the new terminal's child only.
        #[serde(default)]
        env: Option<BTreeMap<String, String>>,
        /// Expected content size in cells (spawn-at-size avoids shell redraw artifacts).
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        /// Mark the new terminal `keep` so it survives with no tab.
        #[serde(default)]
        keep: bool,
        /// Caller-chosen terminal host id (`terminal-placement-env-v1`).
        #[serde(default)]
        terminal_id: Option<String>,
        /// `terminal-shell-args-v1`: arguments for the terminal's shell (its
        /// `SHELL` in `env`, else the daemon's default shell).
        #[serde(default)]
        shell_args: Option<Vec<String>>,
    },
    NewConversationTab(conversation_tabs_wire::NewConversationTabParams),
    BindConversationTabSession(conversation_tabs_wire::BindSessionParams),
    /// New browser tab whose page the frontend renders (WebKit or CEF).
    NewFrontendBrowserTab(frontend_browser_history::NewTabParams),
    RestartTab(tab_restart::Params),
    ParkTabs(tab_park::Params),
    UpdateFrontendBrowserTab(frontend_browser_history::UpdateTabParams),
    SetFrontendBrowserHistory(frontend_browser_history::SetParams),
    GetFrontendBrowserHistory(frontend_browser_history::GetParams),
    /// Remote-terminal tabs (`remote-terminal-tabs-v1`).
    NewRemoteTerminalTab(remote_terminal_tabs_wire::NewParams),
    UpdateRemoteTerminalTab(remote_terminal_tabs_wire::UpdateParams),
    RemoteTerminalSnapshot(remote_terminal_tabs_wire::SnapshotParams),
    NewBrowserTab {
        url: String,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetCellPixels {
        #[serde(alias = "width_px")]
        width_px: u16,
        #[serde(alias = "height_px")]
        height_px: u16,
    },
    GetCellPixels,
    BrowserFramePresented {
        surface: SurfaceId,
        frame_seq: u64,
    },
    BrowserMouse {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
        #[serde(default)]
        frame_seq: Option<u64>,
    },
    BrowserMouseGuarded {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
        frame_seq: u64,
    },
    BrowserWheel {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
        #[serde(default)]
        frame_seq: Option<u64>,
    },
    BrowserWheelGuarded {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
        frame_seq: u64,
    },
    BrowserKey {
        surface: SurfaceId,
        kind: String,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserKeyPress {
        surface: SurfaceId,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserInsertText {
        surface: SurfaceId,
        text: String,
    },
    BrowserNavigate {
        surface: SurfaceId,
        url: String,
    },
    BrowserBack {
        surface: SurfaceId,
    },
    BrowserForward {
        surface: SurfaceId,
    },
    BrowserReload {
        surface: SurfaceId,
    },
    BrowserActivate {
        surface: SurfaceId,
    },
    NewWorkspace {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Create a registry entry without implicitly spawning a terminal.
    CreateWorkspace {
        #[serde(default)]
        name: Option<String>,
        /// Optional frontend-generated stable key. When absent, the mux
        /// generates a UUIDv4 key and returns it.
        #[serde(default)]
        key: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Create a terminal inside an existing workspace selected by stable key or legacy numeric id.
    CreateTerminal {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        /// `terminal-shell-args-v1`: arguments for the terminal's shell (its
        /// `SHELL` in `env`, else the daemon's default shell).
        #[serde(default)]
        shell_args: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        /// Optional frontend-reserved canonical UUID. Supplying it with a
        /// mutation id makes a lost-response retry exactly once.
        #[serde(default)]
        terminal_id: Option<String>,
        /// Extra environment for the new terminal's child only.
        #[serde(default)]
        env: Option<BTreeMap<String, String>>,
        /// Mark the new terminal `keep` so it survives with no tab.
        #[serde(default)]
        keep: bool,
        /// `detached-terminals-v1`: a kept terminal with no tab.
        #[serde(default)]
        detached: bool,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// New screen in a workspace (default: the active one).
    NewScreen(new_screen::NewScreenParams),
    /// Set or clear a screen's color and icon (JSON null clears).
    SetScreenMetadata {
        screen: ScreenId,
        #[serde(default, deserialize_with = "present_nullable")]
        color: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        icon: Option<Option<String>>,
    },
    SetScreenPinned {
        screen: ScreenId,
        pinned: bool,
    },
    /// Move a screen within its workspace, into another one, or into a new one.
    MoveScreen {
        screen: ScreenId,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        new_workspace: bool,
    },
    CreateScreenGroup {
        screens: Vec<ScreenId>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        color: Option<String>,
    },
    UpdateScreenGroup {
        group: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        collapsed: Option<bool>,
        /// `screen-group-icon-v1`: the group's icon; null clears it.
        #[serde(default, deserialize_with = "present_nullable")]
        icon: Option<Option<String>>,
    },
    AddScreensToScreenGroup {
        group: String,
        screens: Vec<ScreenId>,
        #[serde(default)]
        index: Option<usize>,
    },
    RemoveScreensFromScreenGroup {
        screens: Vec<ScreenId>,
    },
    MoveScreenGroup {
        group: String,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        new_workspace: bool,
    },
    UngroupScreenGroup {
        group: String,
    },
    CloseScreenGroup {
        group: String,
        #[serde(default)]
        end_terminals: bool,
    },
    ListSavedScreenGroups,
    SaveScreenGroup {
        group: String,
    },
    UnsaveScreenGroup {
        group: String,
    },
    DeleteSavedScreenGroup {
        saved: String,
    },
    ReopenSavedScreenGroup {
        saved: String,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
    },
    NewPane {
        pane: PaneId,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        #[serde(default)]
        cwd: Option<String>,
        /// Extra environment for the new terminal's child only.
        #[serde(default)]
        env: Option<BTreeMap<String, String>>,
        /// Mark the new terminal `keep` so it survives with no tab.
        #[serde(default)]
        keep: bool,
        /// Caller-chosen terminal host id (`terminal-placement-env-v1`).
        #[serde(default)]
        terminal_id: Option<String>,
        /// `terminal-shell-args-v1`: arguments for the terminal's shell (its
        /// `SHELL` in `env`, else the daemon's default shell).
        #[serde(default)]
        shell_args: Option<Vec<String>>,
        /// `split-client-keys-v1`: caller-minted ids of the pane and its tab.
        #[serde(default)]
        pane_id: Option<String>,
        #[serde(default)]
        tab_id: Option<String>,
    },
    NewPaneRight(split_kind::NewPaneRightParams),
    Split(split_kind::SplitParams),
    SetRatio {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        ratio: f32,
    },
    SetSplitRatio {
        split: SplitId,
        ratio: f32,
        #[serde(default)]
        transaction: Option<u64>,
    },
    SetViewportPaneWidth {
        pane: PaneId,
        width: f32,
        #[serde(default)]
        transaction: Option<u64>,
    },
    /// `dock-columns-v1`: pin or unpin the viewport column containing
    /// `pane`. `edge`, `mode` and `role` (`dock-column-role-v1`) stay strings
    /// so a bad value answers with `error_code:"invalid-argument"` instead of
    /// a decode error.
    SetColumnDock {
        pane: PaneId,
        dock: bool,
        #[serde(default)]
        edge: Option<String>,
        #[serde(default)]
        mode: Option<String>,
        /// `permanent-dock-v1`: mark the column permanent (never cleared once set).
        #[serde(default)]
        permanent: Option<bool>,
        /// `pinned-dock-v1`: mark the column pinned (the Home dock; never
        /// cleared once set). Its `allow_tabs` changes only with `column.update`.
        #[serde(default)]
        pinned: Option<bool>,
        #[serde(default)]
        role: Option<String>,
        #[serde(default)]
        transaction: Option<u64>,
    },
    UndoLayout {
        pane: PaneId,
        #[serde(default)]
        revision: Option<u64>,
        #[serde(default)]
        confirm_close: bool,
    },
    PaneNeighbor {
        pane: PaneId,
        dir: String,
    },
    FocusDirection {
        #[serde(default)]
        pane: Option<PaneId>,
        dir: String,
    },
    SwapPane {
        pane: PaneId,
        #[serde(default)]
        dir: Option<String>,
        #[serde(default)]
        target: Option<PaneId>,
    },
    ZoomPane {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        mode: Option<String>,
    },
    ProcessInfo {
        surface: SurfaceId,
    },
    /// Dev-server ports the terminal shows that accept a loopback connect
    /// (`terminal-ports-v1`), read when the request arrives.
    TerminalPorts {
        surface: SurfaceId,
    },
    /// CPU time and memory of terminal process trees, read on request.
    /// Omitted `surfaces` means every PTY surface.
    TerminalResources {
        #[serde(default)]
        surfaces: Option<Vec<SurfaceId>>,
    },
    MoveTerminal {
        terminal_id: String,
        workspace_key: String,
        #[serde(default)]
        terminal_incarnation: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    MoveTab {
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Every tab group with its pane and members.
    ListTabGroups,
    /// Group tabs of one pane; they become contiguous at the first one.
    CreateTabGroup {
        #[serde(alias = "tabs")]
        surfaces: Vec<TabRef>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Rename, recolor, or collapse a tab group.
    UpdateTabGroup {
        group: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        collapsed: Option<bool>,
        /// `tab-group-icon-v1`: the group's icon; null clears it.
        #[serde(default, deserialize_with = "present_nullable")]
        icon: Option<Option<String>>,
    },
    AddTabsToTabGroup {
        group: String,
        #[serde(alias = "tabs")]
        surfaces: Vec<TabRef>,
        #[serde(default)]
        transaction: Option<String>,
    },
    RemoveTabsFromTabGroup {
        #[serde(alias = "tabs")]
        surfaces: Vec<TabRef>,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Move a whole group within its strip or into another pane's strip.
    MoveTabGroup {
        group: String,
        #[serde(default)]
        pane: Option<PaneRef>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveTabGroupToSplit {
        group: String,
        pane: PaneRef,
        edge: String,
        #[serde(default)]
        ratio: Option<f32>,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveTabGroupToColumn {
        group: String,
        #[serde(default)]
        pane: Option<PaneRef>,
        #[serde(default)]
        screen: Option<ScreenId>,
        #[serde(default)]
        after_column: Option<SplitId>,
        #[serde(default)]
        width: Option<f32>,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveTabGroupToNewWorkspace {
        group: String,
        #[serde(default)]
        workspace_group: Option<String>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        transaction: Option<String>,
    },
    UngroupTabGroup {
        group: String,
    },
    /// Close every member placement of a group in one commit.
    CloseTabGroup {
        group: String,
        #[serde(default)]
        end_terminals: bool,
    },
    ListSavedTabGroups,
    SaveTabGroup {
        group: String,
    },
    UnsaveTabGroup {
        group: String,
    },
    DeleteSavedTabGroup {
        saved: String,
    },
    ReopenSavedTabGroup {
        saved: String,
        pane: PaneRef,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Acknowledge a tab's notifications without selecting or focusing it.
    AckTabNotifications {
        surface: SurfaceId,
    },
    /// Retained notifications, newest first.
    ListNotifications {
        #[serde(default)]
        limit: Option<usize>,
    },
    /// Pin or unpin a tab placement; pinned tabs sort first in their pane.
    SetTabPinned {
        surface: SurfaceId,
        pinned: bool,
    },
    MoveTabToWorkspace {
        surface: SurfaceId,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Drop a tab on a pane edge: a new split beside `pane` holding the tab.
    MoveTabToSplit {
        surface: SurfaceId,
        pane: PaneId,
        edge: String,
        #[serde(default)]
        ratio: Option<f32>,
        #[serde(default)]
        respawn: Option<SplitRespawnRequest>,
        /// `tab-split-keep-focus-v1`: the focused pane stays focused.
        #[serde(default)]
        keep_focus: bool,
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Drop a tab between strip columns: a new column holding the tab.
    MoveTabToColumn(tab_column::MoveTabToColumnParams),
    NewRow(rows::NewRowParams),
    SetRowHeights(rows::SetRowHeightsParams),
    /// Move a whole viewport column one place (`column-move-v1`).
    MoveColumn(column_move::MoveColumnParams),
    /// Drop a tab on the sidebar: a new workspace holding the tab.
    MoveTabToNewWorkspace {
        surface: SurfaceId,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveWorkspace {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        index: usize,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Set, clear (`null`), or keep (absent) a workspace's shared color,
    /// SF Symbol icon, and custom title, and set or keep its sidebar pin and manual unread mark.
    SetWorkspaceMetadata {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default, deserialize_with = "present_nullable")]
        color: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        icon: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        title: Option<Option<String>>,
        #[serde(default)]
        pinned: Option<bool>,
        #[serde(default)]
        marked_unread: Option<bool>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Every personal record of the home session (`profiles-v1`).
    ListPersonal,
    /// Browser profile records (`browser-profiles-v1`, server/browser_profiles.rs).
    CreateBrowserProfile(browser_profiles::CreateParams),
    UpdateBrowserProfile(browser_profiles::UpdateParams),
    MoveBrowserProfile(browser_profiles::MoveParams),
    DeleteBrowserProfile(browser_profiles::DeleteParams),
    /// Bookmark trees (`bookmarks-v1`, server/bookmarks.rs).
    ListBookmarks(bookmarks::ListParams),
    CreateBookmark(bookmarks::CreateParams),
    UpdateBookmark(bookmarks::UpdateParams),
    MoveBookmark(bookmarks::MoveParams),
    DeleteBookmark(bookmarks::DeleteParams),
    ImportBookmarks(bookmarks::ImportParams),
    /// The local feed owner (`feed-local-owner-v1`, server/feed_local.rs).
    FeedLocalList(feed_local::ListParams),
    FeedLocalRead(feed_local::ReadParams),
    FeedLocalHandoffBegin(feed_local::ItemParams),
    FeedLocalHandoffAbort(feed_local::ItemParams),
    FeedLocalHandoffDone(feed_local::DoneParams),
    /// Asset blobs for icons (`icon-assets-v1`, server/icon_assets.rs).
    PutBlob(icon_assets::PutParams),
    GetBlob(icon_assets::GetParams),
    /// Local conversations (`local-conversations-v1`, server/conversations.rs).
    ConversationList,
    ConversationCreate(conversations::CreateParams),
    ConversationSnapshot(conversations::SnapshotParams),
    ConversationHistory(conversations::HistoryParams),
    ConversationThread(conversations::ThreadParams),
    ConversationLinkResolve(conversations::LinkResolveParams),
    ConversationInboxOp(conversations::InboxOpParams),
    /// The Home list rows (`home-inbox-v1`, server/conversations.rs).
    HomeInbox(conversations::HomeInboxParams),
    ConversationSearch(conversations::SearchParams),
    /// The history search index (`history-search-v1`, server/history_search.rs).
    HistorySearch(history_search::HistorySearchParams),
    ConversationOp(conversations::OpParams),
    ConversationTyping(conversations::TypingParams),
    ConversationDraft(conversations::DraftParams),
    ConversationBind(conversations::BindParams),
    ConversationAgentToken(conversations::AgentTokenParams),
    /// Cloud conversations proxy and host replica (server/cloud_conversations.rs and so on).
    CloudSessionSet(cloud_conversations::SessionSetParams),
    CloudSessionClear,
    CloudSessionStatus,
    CloudHostReplicaSet(cloud_host_replica::HostReplicaSetParams),
    CloudHostReplicaClear(cloud_host_replica::HostReplicaClearParams),
    CloudHostReplicaStatus,
    /// `page-credential` (`page-credential-v1`, server/page_credential.rs).
    PageCredential(page_credential::PageCredentialParams),
    /// `ws-listen` (`ws-listen-v1`, server/page_listener.rs): open the owner's page listener.
    WsListen(page_listener::WsListenParams),
    CloudInboxList(cloud_conversations::InboxListParams),
    /// `cloud-requests-list`: the person's message requests (no fields).
    CloudRequestsList(cloud_conversations::NoParams),
    /// `cloud-selfhost-info` (`cloud-selfhost-v1`): the self-hosted chat
    /// server's identity of the person (no fields).
    CloudSelfhostInfo(cloud_conversations::NoParams),
    CloudConversationSnapshot(cloud_conversations::SnapshotParams),
    CloudConversationHistory(cloud_conversations::HistoryParams),
    CloudConversationThread(cloud_conversations::ThreadParams),
    CloudConversationRuns(cloud_conversations::RunsParams),
    CloudConversationRun(cloud_conversations::RunParams),
    CloudParticipantAvatarGet(cloud_conversations::AvatarParams),
    CloudConversationOp(cloud_conversations::OpParams),
    CloudInboxOp(cloud_conversations::InboxOpParams),
    CloudInboxSubscribe,
    CloudInboxUnsubscribe,
    CloudConversationSubscribe(cloud_conversations::TargetParams),
    CloudConversationUnsubscribe(cloud_conversations::TargetParams),
    CloudConversationLive(cloud_conversations::TargetParams),
    CloudConversationTyping(cloud_conversations::TypingParams),
    CloudConversationPresence(cloud_conversations::PresenceParams),
    /// The leased chief's MuxDO wake queue (`mux:<agent>`) and the ack of handled wakes.
    CloudMuxSubscribe(cloud_conversations::NoParams),
    CloudMuxUnsubscribe(cloud_conversations::NoParams),
    CloudMuxAck(cloud_conversations::MuxAckParams),
    /// Local conversation attachments (`local-attachments-v1`, server/conversation_attachments.rs).
    ConversationAttachmentUpload(conversation_attachments::UploadParams),
    ConversationAttachmentRead(conversation_attachments::ReadParams),
    ConversationAttachmentLink(conversation_attachments::LinkParams),
    /// Cloud conversations' attachments (`cloud-attachments-v1`, server/cloud_attachments.rs).
    CloudAttachmentUpload(conversation_attachments::UploadParams),
    CloudAttachmentRead(conversation_attachments::ReadParams),
    CloudAttachmentLink(conversation_attachments::LinkParams),
    ConversationRunAppend(conversation_runs::AppendParams),
    ConversationRuns(conversation_runs::RunsParams),
    ConversationRun(conversation_runs::RunParams),
    ConversationLivePublish(conversation_live::PublishParams),
    ConversationLive(conversation_live::LiveParams),
    ConversationImport(conversations::ImportParams),
    /// Create a room. A caller-chosen `profile` id makes a retry idempotent.
    CreateProfile {
        name: String,
        #[serde(default)]
        profile: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        icon: Option<String>,
        #[serde(default)]
        theme: Option<String>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        browser_profile_id: Option<String>,
        #[serde(default)]
        default_session_id: Option<String>,
        #[serde(default)]
        defaults: Option<Value>,
        #[serde(default)]
        follows: Option<Vec<String>>,
    },
    /// Update a room. An absent field is unchanged; JSON null clears it.
    UpdateProfile {
        profile: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default, deserialize_with = "present_nullable")]
        color: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        icon: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        theme: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        browser_profile_id: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        default_session_id: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        defaults: Option<Option<Value>>,
    },
    /// Move a room to an insertion index among rooms.
    MoveProfile {
        profile: String,
        index: usize,
    },
    /// Delete a room; its pins and groups move to `move_to` or are removed.
    DeleteProfile {
        profile: String,
        #[serde(default)]
        move_to: Option<String>,
    },
    /// Replace the sessions a room follows.
    SetProfileFollows {
        profile: String,
        session_ids: Vec<String>,
    },
    /// Pin a qualified workspace to one room (exclusive).
    PinWorkspace {
        session_id: String,
        workspace_key: String,
        profile: String,
    },
    UnpinWorkspace {
        session_id: String,
        workspace_key: String,
    },
    /// Record or refresh a session in the home session registry.
    PutSession {
        session_id: String,
        #[serde(default)]
        machine_name: Option<String>,
        #[serde(default)]
        session_name: Option<String>,
        transport: Value,
        #[serde(default)]
        capabilities: Option<Value>,
        #[serde(default)]
        follow_with: Option<String>,
    },
    ForgetSession {
        session_id: String,
        #[serde(default)]
        force: bool,
    },
    /// Set or clear a session's (machine's) icon (`session-icon-v1`).
    SetSessionIcon(personal::SetSessionIconParams),
    /// One-time copy of a remote session's shared groups and order.
    ImportSessionOrganization {
        session_id: String,
        #[serde(default)]
        groups: Vec<Value>,
        #[serde(default)]
        workspaces: Vec<Value>,
    },
    CreatePersonalGroup {
        name: String,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        profile: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        collapsed: bool,
        #[serde(default)]
        index: Option<usize>,
    },
    UpdatePersonalGroup {
        group: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default, deserialize_with = "present_nullable")]
        color: Option<Option<String>>,
        #[serde(default)]
        collapsed: Option<bool>,
        #[serde(default)]
        profile: Option<String>,
    },
    DeletePersonalGroup {
        group: String,
    },
    MovePersonalGroup {
        group: String,
        index: usize,
    },
    /// Create or update the personal row of a qualified workspace.
    SetPersonalWorkspace {
        session_id: String,
        workspace_key: String,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default, deserialize_with = "present_nullable")]
        group: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        browser_profile_id: Option<Option<String>>,
        #[serde(default, deserialize_with = "present_nullable")]
        theme: Option<Option<String>>,
        /// `personal-remote-localhost-v1`; null clears.
        #[serde(default, deserialize_with = "present_nullable")]
        remote_localhost: Option<Option<bool>>,
    },
    /// Set or clear (null) the own theme of a session-qualified terminal.
    SetPersonalTerminal {
        session_id: String,
        terminal_key: String,
        #[serde(default)]
        theme: Option<String>,
    },
    /// List sidebar workspace groups in order.
    ListWorkspaceGroups,
    /// Create a sidebar workspace group. A caller-chosen `group` id makes a retry idempotent.
    CreateWorkspaceGroup {
        name: String,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        collapsed: bool,
        #[serde(default)]
        index: Option<usize>,
    },
    /// Rename, recolor, or collapse a group. An absent field is unchanged;
    /// `color: null` clears the color.
    UpdateWorkspaceGroup {
        group: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default, deserialize_with = "present_nullable")]
        color: Option<Option<String>>,
        #[serde(default)]
        collapsed: Option<bool>,
    },
    /// Delete a group; its workspaces become ungrouped in place.
    DeleteWorkspaceGroup {
        group: String,
    },
    /// Move a group to an insertion index among groups.
    MoveWorkspaceGroup {
        group: String,
        index: usize,
    },
    /// Put a workspace in a group (`group: null` ungroups it), optionally at
    /// a final index among that section's members.
    MoveWorkspaceToGroup {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        group: Option<String>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    SetDefaultColors {
        #[serde(default)]
        fg: Option<String>,
        #[serde(default)]
        bg: Option<String>,
        #[serde(default)]
        cursor: Option<String>,
        #[serde(default)]
        selection_bg: Option<String>,
        #[serde(default)]
        selection_fg: Option<String>,
        #[serde(default)]
        cursor_style: Option<String>,
        #[serde(default)]
        cursor_blink: Option<bool>,
        #[serde(default)]
        palette: Option<BTreeMap<String, String>>,
        /// Complete frontend configuration replaces absent optional values;
        /// legacy CLI calls retain their historical sparse-overlay behavior.
        #[serde(default)]
        complete: bool,
    },
    /// Close one tab.
    CloseSurface {
        surface: SurfaceId,
    },
    /// Close several tab placements in one durable commit. With
    /// `end_terminals`, also end every terminal whose views all close and that is not kept.
    CloseTabs {
        surfaces: Vec<TabRef>,
        #[serde(default)]
        end_terminals: bool,
        #[serde(default)]
        transaction: Option<String>,
        /// `close-reason-v1`: `session_end` keeps the close out of closed history.
        #[serde(default)]
        reason: Option<crate::mux::CloseReason>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Close a pane and all its tabs.
    ClosePane {
        pane: PaneId,
        #[serde(default)]
        end_terminals: bool,
    },
    CloseScreen {
        screen: ScreenId,
        #[serde(default)]
        end_terminals: bool,
    },
    CloseWorkspace {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        end_terminals: bool,
        #[serde(default)]
        reason: Option<crate::mux::CloseReason>,
        /// `close-workspace-if-empty-v1`: close only a workspace with no tab
        /// at commit time (`workspace_not_empty` otherwise).
        #[serde(default)]
        if_empty: bool,
        /// With `end_terminals`: answer `closed_ids`, the closed groups the
        /// close stored. Opt-in: older raw decoders refuse an unknown result
        /// field (Python `unexpected fields`).
        #[serde(default)]
        report_closed_ids: bool,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Verifies that this provider frontend holds the authority provisioned
    /// before the mux accepted control clients.
    MarkWorkspacesProviderManaged {
        authority: String,
    },
    CloseProviderManagedWorkspace {
        workspace: WorkspaceId,
        key: String,
        authority: String,
    },
    RenamePane {
        pane: PaneId,
        /// Empty clears the name (falls back to the tab title).
        name: String,
    },
    RenameSurface {
        surface: SurfaceId,
        /// Empty clears the name (falls back to the generated tab label).
        name: String,
    },
    RenameScreen {
        screen: ScreenId,
        /// Empty clears the name (falls back to the screen number).
        name: String,
    },
    RenameWorkspace {
        #[serde(flatten)]
        request: cmd_workspaces::WorkspaceRenameRequest,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    RenameProviderManagedWorkspace {
        workspace: WorkspaceId,
        key: String,
        name: String,
        authority: String,
    },
    ResizeSurface {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// Resize one negotiated view attachment. The opaque lease prevents a
    /// delayed request from mutating a replacement view or another terminal.
    ///
    /// With `view` instead of `lease` it creates or updates a relay sub-view
    /// (a leaf behind this connection, such as a phone behind a Mac mirror)
    /// that participates in shared sizing with its own `identity`.
    ResizeAttachedView {
        surface: SurfaceId,
        #[serde(default)]
        lease: Option<String>,
        #[serde(default)]
        view: Option<String>,
        #[serde(default)]
        identity: Option<ClientIdentityWire>,
        cols: u16,
        rows: u16,
    },
    /// Stop this client from contributing a size for a surface while
    /// retaining its attach stream for cached rendering.
    ReleaseSurfaceSize {
        surface: SurfaceId,
    },
    /// Stop one negotiated view attachment from contributing geometry.
    ReleaseAttachedViewSize {
        surface: SurfaceId,
        #[serde(default)]
        lease: Option<String>,
        #[serde(default)]
        view: Option<String>,
    },
    /// Close one negotiated view attachment without affecting the terminal or
    /// any other placement or client view.
    DetachAttachedView {
        surface: SurfaceId,
        #[serde(default)]
        lease: Option<String>,
        #[serde(default)]
        view: Option<String>,
    },
    FocusPane {
        pane: PaneId,
    },
    /// Select a tab within a pane (default: the active pane).
    SelectTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Select a screen within the active workspace.
    SelectScreen {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    SelectWorkspace {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Report one client's focus: applied as the session focus and remembered
    /// per client id so that client's own reconnection restores it.
    ReportFocus {
        client_id: String,
        pane: PaneId,
        #[serde(default)]
        tab: Option<usize>,
    },
    /// The remembered focus for one client, if its pane is still alive.
    ClientFocus {
        client_id: String,
    },
    /// Stream mux events on this connection.
    Subscribe {
        #[serde(default)]
        tree_events: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        expected_generation: Option<String>,
        #[serde(default)]
        expected_terminal_id: Option<String>,
        #[serde(default)]
        mode: Option<String>,
        /// Optional initial viewer size. Supplying this pair makes the attach
        /// stream a sizing participant immediately, before its first frame is rendered.
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        #[serde(flatten)]
        snapshot: terminal_snapshot::SnapshotAttachParams,
    },
    /// One READY snapshot on the caller's snapshot attach (`terminal-snapshot-v1`).
    SnapshotRequest(terminal_snapshot::SnapshotRequestParams),
    /// GHOSTSNP history pages above a row marker (`terminal.history`).
    TerminalHistory(terminal_history::TerminalHistoryParams),
    /// Text or VT of a row-marker range (`terminal.read_range`).
    TerminalReadRange(terminal_history::TerminalReadRangeParams),
    /// Scroll a surface's viewport by a row delta (negative is up).
    ScrollSurface {
        surface: SurfaceId,
        delta: isize,
    },
}

impl Command {
    fn ordering_surface(&self) -> Option<SurfaceId> {
        match self {
            Self::PasteImage { surface, .. } => Some(*surface),
            Self::SetClientSizing { surface, .. }
            | Self::ReadScreen { surface }
            | Self::ClearHistory { surface, .. }
            | Self::ReadScrollback { surface, .. }
            | Self::WaitFor { surface, .. }
            | Self::SendKey { surface, .. }
            | Self::Copy { surface, .. }
            | Self::ReportAgent { surface, .. }
            | Self::VtState { surface }
            | Self::MintTerminalRenderer { surface, .. }
            | Self::BrowserFramePresented { surface, .. }
            | Self::BrowserMouse { surface, .. }
            | Self::BrowserMouseGuarded { surface, .. }
            | Self::BrowserWheel { surface, .. }
            | Self::BrowserWheelGuarded { surface, .. }
            | Self::BrowserKey { surface, .. }
            | Self::BrowserKeyPress { surface, .. }
            | Self::BrowserInsertText { surface, .. }
            | Self::BrowserNavigate { surface, .. }
            | Self::BrowserBack { surface }
            | Self::BrowserForward { surface }
            | Self::BrowserReload { surface }
            | Self::BrowserActivate { surface }
            | Self::ProcessInfo { surface }
            | Self::TerminalPorts { surface }
            | Self::MoveTab { surface, .. }
            | Self::MoveTabToWorkspace { surface, .. }
            | Self::CloseSurface { surface }
            | Self::RenameSurface { surface, .. }
            | Self::ResizeSurface { surface, .. }
            | Self::ResizeAttachedView { surface, .. }
            | Self::ReleaseSurfaceSize { surface }
            | Self::ReleaseAttachedViewSize { surface, .. }
            | Self::DetachAttachedView { surface, .. }
            | Self::SetSizeCounts { surface, .. }
            | Self::GetSizeState { surface }
            | Self::ReattachView { surface, .. }
            | Self::NoteSizeActivity { surface, .. }
            | Self::ScrollSurface { surface, .. } => Some(*surface),
            Self::Send(send) => send.surface,
            Self::AttachSurface { surface, .. }
            | Self::Notify { surface, .. }
            | Self::ListAgents { surface, .. }
            | Self::Subscribe { surface, .. }
            | Self::SetSizePolicy { surface, .. }
            | Self::GetHostSizePolicy { surface } => *surface,
            _ => None,
        }
    }

    fn is_clear_history(&self) -> bool {
        matches!(self, Self::ClearHistory { .. })
    }

    fn can_overtake_clear_barrier(&self) -> bool {
        matches!(
            self,
            Self::ClearHistory { .. }
                | Self::Send(_)
                | Self::SendKey { .. }
                | Self::BrowserFramePresented { .. }
                | Self::BrowserMouse { .. }
                | Self::BrowserMouseGuarded { .. }
                | Self::BrowserWheel { .. }
                | Self::BrowserWheelGuarded { .. }
                | Self::BrowserKey { .. }
                | Self::BrowserKeyPress { .. }
                | Self::BrowserInsertText { .. }
                | Self::BrowserNavigate { .. }
                | Self::BrowserBack { .. }
                | Self::BrowserForward { .. }
                | Self::BrowserReload { .. }
                | Self::BrowserActivate { .. }
                | Self::ScrollSurface { .. }
        )
    }
}

/// A tab named by its numeric surface id or its public `tab_...` id.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum TabRef {
    Surface(SurfaceId),
    Public(String),
}

/// A pane named by its numeric id or its public `pane_...` id.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum PaneRef {
    Id(PaneId),
    Public(String),
}

fn resolve_tab_refs(mux: &Mux, refs: &[TabRef]) -> anyhow::Result<Vec<SurfaceId>> {
    mux.with_state(|state| {
        refs.iter()
            .map(|reference| match reference {
                TabRef::Surface(surface) => Ok(*surface),
                TabRef::Public(id) => state
                    .resource_indexes
                    .tabs
                    .iter()
                    .find_map(|(tab, surface)| (tab.as_str() == id).then_some(*surface))
                    .ok_or_else(|| anyhow::anyhow!("unknown tab {id}")),
            })
            .collect()
    })
}

/// Upper bound on one `close-tabs` request; larger sets split into several.
const MAX_CLOSE_TABS_SURFACES: usize = 4096;

fn batch_close_terminals_json(outcome: &crate::mux::BatchCloseOutcome) -> Value {
    Value::Array(
        outcome
            .terminals()
            .into_iter()
            .map(|terminal| {
                json!({
                    "terminal_id": terminal.terminal_id,
                    "terminal_incarnation": terminal.terminal_incarnation,
                })
            })
            .collect(),
    )
}

/// A client transaction id: opaque, 1-128 printable ASCII characters.
fn validate_client_transaction(transaction: Option<&str>) -> anyhow::Result<()> {
    if let Some(transaction) = transaction {
        anyhow::ensure!(
            !transaction.is_empty()
                && transaction.len() <= 128
                && transaction.bytes().all(|byte| byte.is_ascii_graphic()),
            "bad request: transaction must be 1-128 printable ASCII characters"
        );
    }
    Ok(())
}

/// The pane that anchors a column drop: the given pane, or the active pane of the given screen.
fn column_anchor(
    mux: &Mux,
    pane: Option<PaneId>,
    screen: Option<ScreenId>,
) -> anyhow::Result<PaneId> {
    match (pane, screen) {
        (Some(pane), None) => Ok(pane),
        (None, Some(screen)) => mux
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter())
                    .find_map(|candidate| (candidate.id == screen).then_some(candidate.active_pane))
            })
            .ok_or_else(|| anyhow::anyhow!("unknown screen {screen}")),
        _ => anyhow::bail!("bad request: exactly one of pane or screen"),
    }
}

#[derive(Debug, Default, Deserialize)]
struct MutationRequest {
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    expected_generation: Option<String>,
    #[serde(default, alias = "expected_terminal_revision")]
    expected_revision: Option<u64>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum LayoutRequest {
    Leaf {
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        command: Option<Vec<String>>,
    },
    Split {
        dir: String,
        ratio: f32,
        a: Box<LayoutRequest>,
        b: Box<LayoutRequest>,
    },
    Stack {
        panes: Vec<PaneId>,
        expanded: PaneId,
    },
}

#[derive(Serialize)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_delivery: Option<ResponseErrorDelivery>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ResponseErrorDelivery {
    KnownNotDelivered,
    Ambiguous,
}

impl From<ClearHistoryDelivery> for ResponseErrorDelivery {
    fn from(delivery: ClearHistoryDelivery) -> Self {
        match delivery {
            ClearHistoryDelivery::KnownNotDelivered => Self::KnownNotDelivered,
            ClearHistoryDelivery::Ambiguous => Self::Ambiguous,
        }
    }
}

#[derive(Debug)]
struct DeliveryClassifiedError {
    error: anyhow::Error,
    delivery: ResponseErrorDelivery,
}

impl DeliveryClassifiedError {
    fn known_not_delivered(error: anyhow::Error) -> anyhow::Error {
        anyhow::Error::new(Self { error, delivery: ResponseErrorDelivery::KnownNotDelivered })
    }
}

impl From<ClearHistoryFailure> for DeliveryClassifiedError {
    fn from(failure: ClearHistoryFailure) -> Self {
        let delivery = failure.delivery().into();
        Self { error: failure.into_error(), delivery }
    }
}

impl std::fmt::Display for DeliveryClassifiedError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(formatter)
    }
}

impl std::error::Error for DeliveryClassifiedError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.error.source()
    }
}

/// Re-check bound for a writer blocked on a full stream queue. It runs only
/// while a stream is backpressured (active output), never while idle: the
/// writer thread notifies after every pop, and this bound covers a stream
/// closed by another thread while its queue stays full.
const BACKPRESSURE_RECHECK: Duration = Duration::from_millis(100);
/// First and longest pause after an accept error that can persist.
const ACCEPT_RETRY_INITIAL: Duration = Duration::from_millis(10);
const ACCEPT_RETRY_MAX: Duration = Duration::from_secs(1);
const STREAM_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const SHUTDOWN_ACK_FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(not(test))]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_SERVER_CONNECTIONS: usize = 64;
const WEBSOCKET_AUTH_MAX_BYTES: usize = 4 * 1024;
const WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES: usize = 4 * 1024 * 1024;
// One outbound render budget chain:
// 10,000,000 decoded image bytes -> 13,333,336 base64 bytes.
// 16,384 maximal placement objects -> 7,962,625 JSON bytes.
// Their 21,295,961-byte subtotal fits a 32 MiB attach message with
// 12,258,471 bytes left for image metadata, rows, and the JSON wrapper.
// Keep the TypeScript SDK and web decoder constants in sync.
const RENDER_GRAPHIC_MAX_DECODED_BYTES: usize = 10_000_000;
const RENDER_GRAPHIC_MAX_ENCODED_BYTES: usize = RENDER_GRAPHIC_MAX_DECODED_BYTES.div_ceil(3) * 4;
const RENDER_GRAPHIC_MAX_PLACEMENTS: usize = 16_384;
const RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES: usize = 485;
const RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES: usize = 2
    + RENDER_GRAPHIC_MAX_PLACEMENTS * RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES
    + (RENDER_GRAPHIC_MAX_PLACEMENTS - 1);
const RENDER_ATTACH_MAX_BYTES: usize = crate::REMOTE_SESSION_MESSAGE_MAX_BYTES;
// Share expensive image encoding across render clients without retaining an
// unbounded second copy of terminal pixel state process-wide.
const RENDER_GRAPHIC_BASE64_CACHE_MAX_BYTES: usize = RENDER_GRAPHIC_MAX_ENCODED_BYTES * 2;
const RENDER_GRAPHIC_BASE64_CACHE_MAX_ENTRIES: usize = 4_096;
const _: () = assert!(
    RENDER_GRAPHIC_MAX_ENCODED_BYTES + RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES
        < RENDER_ATTACH_MAX_BYTES
);
const OUTBOUND_CAPACITY: usize = 256;
// Browser projection updates are an ordered frame/state pair. Keep one pair
// writable without allowing a slow socket to accumulate an unbounded trail.
const OUTBOUND_BACKPRESSURED_STREAM_CAPACITY: usize = 2;
const OUTBOUND_CONTROL_RESERVE: usize = 256;
const OUTBOUND_BYTE_CAPACITY: usize = RENDER_ATTACH_MAX_BYTES;
// The synchronous `vt-state` command returns the same bounded replay as an
// attach, encoded as base64 inside its response envelope.
const OUTBOUND_CONTROL_BYTE_RESERVE: usize = RENDER_ATTACH_MAX_BYTES;
const OUTBOUND_GLOBAL_BYTE_CAPACITY: usize = OUTBOUND_BYTE_CAPACITY * 4;
const OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY: usize = OUTBOUND_CONTROL_BYTE_RESERVE * 4;
const _: () =
    assert!(crate::surface::VT_REPLAY_MAX_BYTES.div_ceil(3) * 4 < OUTBOUND_CONTROL_BYTE_RESERVE);
const OUTBOUND_CONNECTION_CAPACITY: usize = OUTBOUND_CAPACITY * 16;
const OUTBOUND_CONNECTION_BYTE_CAPACITY: usize = OUTBOUND_BYTE_CAPACITY * 8;
const CLIENT_DETACH_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const CONNECTION_SURFACE_QUEUE_CAPACITY: usize = 256;
const CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const CONNECTION_SURFACE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(3);
const SERVER_SURFACE_WORKER_CAPACITY: usize = 16;
const SERVER_SURFACE_RETAINED_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const RESOURCE_STREAMS_PER_CLIENT_CAPACITY: usize = 64;
const RESOURCE_STREAMS_SERVER_CAPACITY: usize = 256;
const RESOURCE_WAITS_PER_CLIENT_CAPACITY: usize = 8;
const RESOURCE_WAITS_SERVER_CAPACITY: usize = 64;

mod worker_admission;
pub(crate) use worker_admission::ServerSurfaceOperationAdmission;
use worker_admission::{
    ResourceWorkerAdmission, ResourceWorkerAdmissionError, ResourceWorkerPermit,
    ServerSurfaceAdmissionError, ServerSurfaceBytesPermit,
};

mod render_service;
use render_service::{
    BudgetedJsonWriter, BudgetedText, RenderService, json_error_to_io, write_base64_json_string,
    write_kitty_image_aliases_json, write_kitty_replay_state_json,
};
#[cfg(test)]
use render_service::{OutboundByteBudget, RenderGraphicBase64Cache};

mod message_writer;
use message_writer::{MessageSink, MessageWriter, OutboundStream};

mod connection_scheduler;
#[cfg(test)]
use connection_scheduler::ConnectionSurfaceState;
use connection_scheduler::{
    ConnectionCancellation, ConnectionSurfaceScheduler, PendingSurfaceRequest, run_pending_request,
};

mod bounded_outbound;
use bounded_outbound::{
    BoundedOutbound, ConnectionPermit, OutboundItem, QueuedSink, SinkControl,
    SynchronizedTcpStream, claim_connection, claim_watched_connection,
    claim_watched_terminal_connection, write_line_outbound_item,
};
#[cfg(test)]
use bounded_outbound::{
    ControlOutbound, MAX_TERMINAL_CONNECTIONS, claim_terminal_connection,
    claim_terminal_connection_from, websocket_server_frame_header,
};

mod client_registry;
pub(crate) use client_registry::ClientRegistry;
pub(crate) use client_registry::ClientSizeUpdate;
use client_registry::{
    ClientAnnouncement, ClientRecord, ClientTransport, DaemonHandoffReservation, DetachedSurface,
    RETIRED_VIEW_LEASE_CAPACITY, ResourceClientRecord, ResourceStreamInstallError,
    ResourceWaitCancel, ResourceWaitCancellation, ResourceWaitInstallError, ViewLeaseStatus,
    ViewReleasePreparation, ViewResizePreparation, clamp_client_label, mint_view_lease,
};

mod client_registry_views;

mod listen;
pub use listen::{
    BoundSocket, PendingServer, START_LOCK_DEADLINE, SocketStartLock, bind_session_socket,
    connect_session_socket, prepare_socket_parent, serve, serve_bound, serve_paused,
};
mod restoring;
mod terminal_sessions;
#[cfg(test)]
use listen::{prepare_runtime_socket_directory, socket_start_lock_retry_delay};
pub use restoring::RestoringServer;

#[cfg(test)]
use websocket_listener::handle_websocket_connection;
pub use websocket_listener::{
    WebSocketAccess, WebSocketServer, parse_websocket_origin, serve_websocket,
    serve_websocket_with_access, serve_websocket_with_keepalive, serve_websocket_with_pages,
};

#[cfg(test)]
mod test_dispatch;
#[cfg(test)]
use test_dispatch::{handle_connection, handle_message};

mod disconnect;
pub use disconnect::detach_control_client;
pub use disconnect::detach_size_participant;
use disconnect::{
    complete_daemon_shutdown_after_ack, detach_actor, detach_own_view, detached_event_json,
    disconnect_client, kick_client, own_view_detach_target, size_state_event_json,
    size_state_for_client,
};

mod journal_filter;
#[cfg(test)]
use journal_filter::JournalStreamFilter;
#[cfg(test)]
use journal_stream::run_session_journal_stream;
#[cfg(test)]
use session_event_stream::run_session_event_stream;

mod resource_waits;
use resource_waits::start_resource_wait;
mod resource_clients;
pub(crate) use resource_clients::public_client_id;
use resource_clients::{
    browser_cells_for_pixels, browser_pixels_for_cells, prepare_resource_client_detach,
    resource_browser_surface, resource_browser_viewer_release, resource_browser_viewer_resize,
    resource_client_cell_pixels_set, resource_client_get, resource_client_list,
    resource_client_metadata_update, resource_client_sizing_release, resource_client_sizing_set,
    resource_session_id, resource_session_snapshot, resource_terminal_surface,
    resource_terminal_viewer_release, resource_terminal_viewer_resize,
};
mod resource_attach;
#[cfg(test)]
use resource_attach::browser_resource_frame;
use resource_attach::{
    cleanup_resource_attach, cleanup_resource_stream, prepare_browser_resource_attach,
    prepare_sidebar_resource_attach, prepare_terminal_resource_attach, register_resource_outbound,
    resource_stream_id, resource_wait_install_error, send_resource_response,
    start_browser_resource_attach, start_sidebar_resource_attach, start_terminal_resource_attach,
};
mod session_event_stream;
use session_event_stream::{prepare_session_event_stream, start_session_event_stream};
mod journal_stream;
#[cfg(test)]
use journal_stream::journal_extension_error;
use journal_stream::{
    handle_journal_extension_request, prepare_session_journal_stream, start_session_journal_stream,
};

mod resource_connection;
use resource_connection::{
    handle_resource_connection_message, resource_stream_end, send_resource_stream_item,
};

mod connection_frame;
#[cfg(test)]
use connection_frame::write_vt_state_command_json;
use connection_frame::{
    auth_token, constant_time_eq, handle_connection_frame, handle_request,
    handle_request_with_cancellation, pairing_request, zeroize_string,
};

/// One layout node. `split_ids`: the public ids of the splits
/// (`State::resource_indexes`); a split with one carries it as `split_id`
/// (`split-client-split-id-v1`).
fn node_json(
    node: &Node,
    active_pane: PaneId,
    split_ids: &HashMap<SplitId, crate::resource::SplitPublicId>,
) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { id, dir, ratio, a, b } => {
            let mut value = json!({
                "type": "split",
                "split": id,
                "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
                "ratio": ratio,
                "a": node_json(a, active_pane, split_ids),
                "b": node_json(b, active_pane, split_ids),
            });
            if let Some(public_id) = split_ids.get(id) {
                value.set("split_id", json!(public_id));
            }
            value
        }
        Node::Stack { panes, expanded } => json!({
            "type": "stack",
            "panes": panes.as_slice(),
            "expanded": if panes.contains(&active_pane) {
                active_pane
            } else {
                *expanded
            },
        }),
    }
}

fn layout_request_to_spec(layout: LayoutRequest) -> anyhow::Result<LayoutSpec> {
    match layout {
        LayoutRequest::Leaf { cwd, command } => {
            Ok(LayoutSpec::Leaf(LayoutLeafSpec { cwd, command }))
        }
        LayoutRequest::Split { dir, ratio, a, b } => Ok(LayoutSpec::Split {
            dir: parse_split_dir(&dir)?,
            ratio,
            a: Box::new(layout_request_to_spec(*a)?),
            b: Box::new(layout_request_to_spec(*b)?),
        }),
        LayoutRequest::Stack { panes, expanded } => {
            if panes.is_empty() {
                anyhow::bail!("stack must contain at least one pane");
            }
            let Some(expanded_index) = panes.iter().position(|pane| *pane == expanded) else {
                anyhow::bail!("stack expanded pane must be a member");
            };
            Ok(LayoutSpec::Stack { pane_count: panes.len(), expanded_index })
        }
    }
}

mod tree_json;
pub(crate) use tree_json::tree_entity_json;
pub(crate) use tree_json::workspaces_json;
use tree_json::{pane_json, tree_delta_json};

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id)
        .filter(|surface| !surface.is_dead())
        .ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn surface_has_view_placement(mux: &Mux, id: SurfaceId) -> bool {
    mux.with_state(|state| state.pane_of(id).is_some())
}

fn require_pty(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Pty {
        Ok(())
    } else {
        anyhow::bail!("browser surface does not support PTY/VT socket commands")
    }
}

fn require_browser(mux: &Mux, surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Browser {
        mux.refuse_conversation_tab(surface)
    } else {
        anyhow::bail!("PTY surface is not a browser surface")
    }
}

mod terminal_colors;
use terminal_colors::terminal_colors_json;

mod render_messages;
use render_messages::{
    AttachWireShape, RenderClientState, VtStateMessage, browser_state_message,
    render_state_message, send_browser_attach_update, styled_run_json, write_pending_sequence_json,
};
#[cfg(test)]
use render_messages::{browser_frame_json, render_graphics_message};

mod attach_lifecycle;
use attach_lifecycle::{
    AttachWorkerCommit, MarkedClientAttach, attach_response, commit_client_attach_and_start_worker,
    detach_committed_attach, mark_client_attached, mark_resource_client_attached,
    rollback_failed_attach, spawn_attach_notification_stream, wait_for_initial_browser_resize,
};
#[cfg(test)]
use attach_lifecycle::{cleanup_failed_attach, commit_client_attach};

#[cfg(test)]
fn handle_command(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    handle_command_with_cancellation(mux, client, cmd, writer, None)
}

mod command_dispatch;
use command_dispatch::handle_command_with_cancellation;

/// The `list-workspaces` reply: the tree plus the registry identity it
/// belongs to. The launch snapshot stores the same value.
fn list_workspaces_reply(mux: &Mux) -> anyhow::Result<Value> {
    let notifications = mux.tree_decorations();
    let mut workspaces = mux.with_state(|state| workspaces_json(state, &notifications));
    let (registry_id, generation) = mux.registry_identity();
    workspaces.set("registry_id", json!(registry_id));
    workspaces.set("generation", json!(generation));
    workspaces.set("terminal_revision", json!(mux.terminal_registry_revision()?));
    Ok(workspaces)
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
#[path = "server/loopback_forward_tests.rs"]
mod loopback_forward_tests;

#[cfg(all(test, unix))]
#[path = "server/agent_session_attach_tests.rs"]
mod agent_session_attach_tests;

#[cfg(all(test, unix))]
#[path = "server/agent_inventory_tests.rs"]
mod agent_inventory_tests;

#[cfg(all(test, unix))]
#[path = "server/image_paste_tests.rs"]
mod image_paste_tests;

#[cfg(test)]
#[path = "server/orphan_shutdown_tests.rs"]
mod orphan_shutdown_tests;
#[cfg(test)]
#[path = "server/session_identity_tests.rs"]
mod session_identity_tests;
#[cfg(all(test, any(target_vendor = "apple", target_os = "linux")))]
#[path = "server/starter_exit_tests.rs"]
mod starter_exit_tests;

#[cfg(test)]
#[path = "server/personal_tests.rs"]
mod personal_tests;

#[cfg(test)]
#[path = "server/group_icon_raw_tests.rs"]
mod group_icon_raw_tests;

#[cfg(test)]
#[path = "server/device_kind_tests.rs"]
mod device_kind_tests;
#[cfg(test)]
#[path = "server/dock_columns_tests.rs"]
mod dock_columns_tests;
#[cfg(test)]
#[path = "server/pinned_columns_tests.rs"]
mod pinned_columns_tests;

#[cfg(test)]
#[path = "server/rows_tests.rs"]
mod rows_tests;

#[cfg(test)]
#[path = "server/column_left_tests.rs"]
mod column_left_tests;
#[cfg(test)]
#[path = "server/column_move_tests.rs"]
mod column_move_tests;

#[cfg(test)]
#[path = "server/pane_browser_kind_tests.rs"]
mod pane_browser_kind_tests;

#[cfg(test)]
#[path = "server/personal_terminal_tests.rs"]
mod personal_terminal_tests;

#[cfg(test)]
#[path = "server/browser_profile_tests.rs"]
mod browser_profile_tests;

#[cfg(test)]
mod tests;

#[cfg(unix)]
mod cloud_repos;
