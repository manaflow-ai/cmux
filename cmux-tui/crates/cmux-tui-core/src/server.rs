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
    PairingDecision, PaneId, Rgb, ScreenId, SplitDir, SplitId, SurfaceId, SurfaceKind,
    TerminalColors, TreeDecorations, ViewportWidthError, WorkspaceId, WorkspaceMutation, ZoomMode,
};
#[cfg(test)]
use ghostty_vt::KeyInput;

pub const ATTACH_INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";
#[cfg(unix)]
mod apps;
#[cfg(unix)]
pub use apps::start_apps_when_ready;
#[path = "server/image_paste.rs"]
mod image_paste;
#[cfg(unix)]
mod scripts;
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
mod agent_session_attach;
#[cfg(unix)]
pub use agent_session_attach::AGENT_SESSION_ATTACH_CAPABILITY;
mod app_trust;
pub use app_trust::{FrontendKey, frontend_proof, install_frontend_key, read_frontend_key};
mod client_hello;
mod command_args;
#[cfg(unix)]
mod fs_wire;
mod line_connection;
use command_args::{parse_direction, parse_split_dir, parse_zoom_mode, workspace_mutation};
mod origin_gate;
mod orphan_shutdown;
pub use orphan_shutdown::stop_orphaned_owner;
mod pending_handoff;
mod renderer_grant;
use line_connection::{handle_connection_with_permit, serve_line_connection};
mod bookmarks;
mod browser_host_command;
mod browser_profiles;
pub(crate) mod clipboard_read;
mod close_tabs_command;
mod cloud_conversations;
mod conversation_attachments;
mod conversation_resource;
mod resource_trust;
use resource_trust::{handles_resource_connection_operation, trusted_local_resource_client};
mod conversation_tabs_wire;
mod conversations;
mod frontend_browser_history;
mod home;
mod icon_assets;
mod launch_snapshot;
mod new_screen;
mod personal;
mod raw_tab;
#[cfg(unix)]
mod remote_entry;
mod remote_relay;
#[cfg(test)]
use remote_relay::handle_connection_message;
mod cmd_attach;
mod cmd_browser;
#[cfg(test)]
use cmd_browser::browser_provider_registration;
mod cmd_panes;
mod cmd_profiles;
mod cmd_screens;
mod cmd_server;
#[cfg(test)]
use cmd_server::{machine_listening_tcp_json, stamped_build_commit, stamped_ghostty_commit};
mod cmd_frontend;
mod cmd_sizing;
mod cmd_subscribe;
mod cmd_tabs;
mod cmd_terminal_io;
mod cmd_terminals;
mod cmd_workspaces;
mod responses;
mod rows;
mod screen_json;
mod server_stats;
mod session_stream;
mod split_kind;
mod split_respawn;
mod tab_column;
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
mod group_outcome_json;
use group_outcome_json::{
    screen_group_outcome_json, tab_drag_outcome_json, tab_group_outcome_json,
};
use split_respawn::{
    SplitRespawnRequest, frontend_shell, placement_spawn_options, shell_argv, split_tab,
};
mod terminal_create;
mod terminal_history;
mod terminal_resources;
mod terminal_snapshot;
use terminal_snapshot::{attach_overflow_json, handle_attach_send_error, report_attach_overflow};
mod capabilities;
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
mod chief_inspect;
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
/// A docked column marked permanent stays docked on its edge for every
/// client: `set-column-dock` takes `permanent`, and an undock, another edge,
/// a replacement or a close or move that would remove it answers
/// `dock-column-permanent`.
pub const PERMANENT_DOCK_CAPABILITY: &str = "permanent-dock-v1";
/// Top and bottom docks: `set-column-dock` and `move-tab-to-column` accept
/// edges `top` and `bottom`, sent back as `Screen.columns[].dock`.
pub const EDGE_DOCKS_CAPABILITY: &str = "edge-docks-v1";
/// `set-column-dock` and `move-tab-to-column` accept `role` (`agent_chat`),
/// kept with the pin and sent back as `Screen.columns[].dock.role`.
pub const DOCK_COLUMN_ROLE_CAPABILITY: &str = "dock-column-role-v1";
/// `new-row`, `set-row-heights` and `Screen.columns[].rows` (rows.md).
pub const ROWS_CAPABILITY: &str = "rows-v1";
/// `kind` (`pty` | `browser`) and `url` on `split` and `new-pane-right`.
pub const PANE_BROWSER_KIND_CAPABILITY: &str = "pane-browser-kind-v1";
pub const TAB_WORKSPACE_MOVE_CAPABILITY: &str = "tab-workspace-move-v1";
pub const LAYOUT_UNDO_CAPABILITY: &str = "layout-undo-v1";
pub const CLEAR_HISTORY_CAPABILITY: &str = "clear-history-v1";
/// Finished shell commands (OSC 133) journaled as `shell.command.finished`
/// when a trusted client turns it on with `set-terminal-command-history`.
pub const TERMINAL_COMMAND_JOURNAL_CAPABILITY: &str = "terminal-command-journal-v1";
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
/// Advertises `set-terminal-idle-policy` and the owner-side reaper that
/// closes a terminal once it has had no attached view for its policy.
pub const TERMINAL_IDLE_CLOSE_CAPABILITY: &str = "terminal-idle-close-v1";
/// Advertises the owner-side reaper that ends a terminal after it has had no
/// tab placement for the reap grace period, `set-terminal-keep`, the `keep`
/// field on `new-tab`, `split`, and `create-terminal`, the `terminal-reaped`
/// event, and `end_terminals` on `shutdown-daemon`.
pub const TERMINAL_REAP_CAPABILITY: &str = "terminal-reap-v1";
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
/// The sidebar workspace pin: `pinned` on `set-workspace-metadata` and the
/// `pinned` workspace field.
pub const WORKSPACE_PIN_CAPABILITY: &str = "workspace-pin-v1";
/// The manual workspace unread mark: `marked_unread` on
/// `set-workspace-metadata` and the `marked_unread` workspace field.
pub const NOTIFICATION_MARK_UNREAD_CAPABILITY: &str = "notification-mark-unread-v1";
/// Tab metadata in the raw tree: `set-tab-pinned` with pinned-first order,
/// `Tab.pinned`, `Tab.cwd`, `Tab.git_branch`, `Tab.git_detached`, and the `tab-changed` delta.
pub const TAB_METADATA_CAPABILITY: &str = "tab-metadata-v1";
/// Frontend-rendered browser tabs (WebKit or CEF): `new-frontend-browser-tab`,
/// `update-frontend-browser-tab`, and the `browser_renderer`,
/// `browser_engine`, `favicon_url`, and `browser_profile_id` tab fields.
pub const FRONTEND_BROWSER_TABS_CAPABILITY: &str = "frontend-browser-tabs-v1";
pub use frontend_browser_history::FRONTEND_BROWSER_HISTORY_CAPABILITY;
/// Tab drag outcomes as single atomic commands: `move-tab-to-split`,
/// `move-tab-to-column`, `move-tab-to-new-workspace`, layout undo for
/// same-screen drags, and a client `transaction` id echoed in `tab-changed`.
pub const TAB_DRAG_CAPABILITY: &str = "tab-drag-v1";
pub use split_respawn::TAB_SPLIT_RESPAWN_CAPABILITY;
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
/// Per-terminal themes in the home session's personal state:
/// `set-personal-terminal` and `list-personal.terminals`.
pub const PERSONAL_TERMINALS_CAPABILITY: &str = "personal-terminals-v1";
/// Browser profile records in personal state: `browser_profiles` in
/// `list-personal` and the `*-browser-profile` commands (plans/cmux-next/data-model.md section 5).
pub const BROWSER_PROFILES_CAPABILITY: &str = "browser-profiles-v1";
pub use bookmarks::BOOKMARKS_CAPABILITY;
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
mod protocol_key;
#[cfg(test)]
use protocol_key::PROTOCOL_KEY_TEXT_MAX_BYTES;
pub use protocol_key::ProtocolKeyInput;
pub(crate) use protocol_key::{
    decode_terminal_host_clear_history, encode_terminal_host_clear_history,
};

/// `machine-usage` result and `machine-usage-changed` payload body: `usage`
/// is the readout object or null when the daemon has none.
fn machine_usage_json(usage: Option<&MachineUsage>) -> Value {
    json!({
        "usage": usage.map(|usage| json!({
            "vm_id": usage.vm_id,
            "period_days": usage.period_days,
            "total_tokens": usage.total_tokens,
            "api_equivalent_usd": usage.api_equivalent_usd,
            "as_of": usage.as_of,
        })),
    })
}

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

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    Identify,
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
    /// Turn terminal command history on or off for this daemon
    /// (`terminal-command-journal-v1`). Off by default and after a restart;
    /// trusted local connections only.
    SetTerminalCommandHistory {
        enabled: bool,
    },
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
    Send {
        surface: SurfaceId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
        #[serde(default)]
        paste: bool,
    },
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
    UpdateFrontendBrowserTab(frontend_browser_history::UpdateTabParams),
    SetFrontendBrowserHistory(frontend_browser_history::SetParams),
    GetFrontendBrowserHistory(frontend_browser_history::GetParams),
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
        #[serde(default)]
        transaction: Option<String>,
    },
    /// Drop a tab between strip columns: a new column holding the tab.
    MoveTabToColumn(tab_column::MoveTabToColumnParams),
    NewRow(rows::NewRowParams),
    SetRowHeights(rows::SetRowHeightsParams),
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
    /// Asset blobs for icons (`icon-assets-v1`, server/icon_assets.rs).
    PutBlob(icon_assets::PutParams),
    GetBlob(icon_assets::GetParams),
    /// Local conversations (`local-conversations-v1`, server/conversations.rs).
    ConversationList,
    ConversationCreate(conversations::CreateParams),
    ConversationSnapshot(conversations::SnapshotParams),
    ConversationHistory(conversations::HistoryParams),
    ConversationSearch(conversations::SearchParams),
    ConversationOp(conversations::OpParams),
    ConversationTyping(conversations::TypingParams),
    ConversationBind(conversations::BindParams),
    ConversationAgentToken(conversations::AgentTokenParams),
    /// Cloud conversations proxy (`cloud-conversations-v1`,
    /// server/cloud_conversations.rs).
    CloudSessionSet(cloud_conversations::SessionSetParams),
    CloudSessionClear,
    CloudSessionStatus,
    CloudInboxList(cloud_conversations::InboxListParams),
    CloudConversationSnapshot(cloud_conversations::SnapshotParams),
    CloudConversationHistory(cloud_conversations::HistoryParams),
    CloudConversationOp(cloud_conversations::OpParams),
    CloudInboxSubscribe,
    CloudInboxUnsubscribe,
    CloudConversationSubscribe(cloud_conversations::TargetParams),
    CloudConversationUnsubscribe(cloud_conversations::TargetParams),
    /// The leased chief's MuxDO wake queue (`mux:<agent>`, agent from the
    /// chief token), and the ack of handled wakes.
    CloudMuxSubscribe(cloud_conversations::NoParams),
    CloudMuxUnsubscribe(cloud_conversations::NoParams),
    CloudMuxAck(cloud_conversations::MuxAckParams),
    /// Local conversation attachments (`local-attachments-v1`,
    /// server/conversation_attachments.rs).
    ConversationAttachmentUpload(conversation_attachments::UploadParams),
    ConversationAttachmentRead(conversation_attachments::ReadParams),
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
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        name: String,
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
            | Self::Send { surface, .. }
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
            Self::AttachSurface { surface, .. }
            | Self::Notify { surface, .. }
            | Self::ListAgents { surface, .. }
            | Self::Subscribe { surface, .. }
            | Self::SetSizePolicy { surface, .. } => *surface,
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
                | Self::Send { .. }
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

fn pane_tab_group_json(run: &crate::mux::PaneTabGroup, pane: Option<PaneId>) -> Value {
    let mut value = json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "start": run.start,
        "count": run.members.len(),
        "surfaces": run.members,
    });
    if let Some(pane) = pane {
        value["pane"] = json!(pane);
    }
    value
}

/// Deserialize a field whose absence and `null` mean different things:
/// absent is `None` (via `#[serde(default)]`), `null` is `Some(None)`.
fn present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

fn workspace_group_json(
    group: &crate::workspace_registry::WorkspaceGroupRecord,
    index: usize,
) -> Value {
    json!({
        "id": group.id,
        "name": group.name,
        "color": group.color,
        "collapsed": group.collapsed,
        "index": index,
    })
}

fn workspace_groups_json(presentation: &crate::workspace_registry::PresentationSnapshot) -> Value {
    json!(
        presentation
            .groups
            .iter()
            .enumerate()
            .map(|(index, group)| workspace_group_json(group, index))
            .collect::<Vec<_>>()
    )
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
    SynchronizedTcpStream, claim_connection, write_line_outbound_item,
};
#[cfg(test)]
use bounded_outbound::{ControlOutbound, websocket_server_frame_header};

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
    PendingServer, SocketStartLock, connect_session_socket, prepare_socket_parent, serve,
    serve_paused,
};
#[cfg(test)]
use listen::{prepare_runtime_socket_directory, socket_start_lock_retry_delay};

#[cfg(test)]
use websocket_listener::handle_websocket_connection;
pub use websocket_listener::{
    WebSocketAccess, WebSocketServer, parse_websocket_origin, serve_websocket,
    serve_websocket_with_access,
};

#[cfg(test)]
fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    handle_connection_with_permit(mux, stream, Arc::new(RenderService::new()), None);
}

fn json_line_payload_len(line: &str) -> usize {
    line.strip_suffix('\n').map_or(line.len(), str::len)
}

mod disconnect;
pub use disconnect::detach_control_client;
pub use disconnect::detach_size_participant;
use disconnect::{
    complete_daemon_shutdown_after_ack, detach_actor, detach_own_view, detached_event_json,
    disconnect_client, kick_client, own_view_detach_target, size_state_event_json,
    size_state_for_client,
};

#[cfg(test)]
fn handle_message(mux: &Arc<Mux>, client: u64, message: &str, writer: &MessageWriter) -> bool {
    match serde_json::from_str::<Request>(message) {
        Ok(request) => handle_request(mux, client, request, writer),
        Err(error) => send_bad_request(writer, message, &error),
    }
}

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

/// One frame of a connection. `transport` is the connection's own value
/// (not a registry lookup), so a remote-entry connection always takes the
/// remote path, also after its registry record is gone.
fn handle_connection_frame(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
) -> bool {
    // Keep an idle shutdown requester connected until owner cleanup closes
    // the transport, so lifecycle clients receive authoritative completion.
    // A pipelined message after the acknowledgement must not reach parsing or
    // dispatch; returning false makes the connection loop close that client.
    if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
        return false;
    }
    if matches!(transport, ClientTransport::Remote) || mux.is_remote_client(client) {
        return remote_relay::handle_frame(mux, client, message, writer);
    }
    // Before the acknowledgement the handoff can still fail (for example
    // while `end_terminals` awaits every host) and this daemon keeps
    // serving. Closing here would drop the requester's pending
    // `shutdown-daemon` reply along with its connection, so a message that
    // arrives meanwhile (a subscriber's snapshot refresh) is refused
    // without being executed and the connection stays open.
    if mux.daemon_handoff_in_progress() {
        return pending_handoff::reject_message_during_pending_handoff(message, writer);
    }
    if let Some(request) = crate::resource_router::parse_resource_line(message) {
        return origin_gate::handle_resource_line(mux, client, message, request, writer);
    }
    if let Some(keep_open) = loopback_forward::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = agent_session_attach::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = apps::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = scripts::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = fs_wire::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    let request = match serde_json::from_str::<Request>(message) {
        Ok(request) => request,
        Err(error) => return send_bad_request(writer, message, &error),
    };
    let mut pending = Some(request);
    match scheduler.dispatch(mux.clone(), client, &mut pending, message.len(), writer.clone()) {
        Some(keep_open) => keep_open,
        None => handle_request(mux, client, pending.take().unwrap(), writer),
    }
}

fn handle_request(mux: &Arc<Mux>, client: u64, request: Request, writer: &MessageWriter) -> bool {
    handle_request_with_cancellation(mux, client, request, writer, None)
}

fn handle_request_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> bool {
    let Request { id, cmd } = request;
    if let Command::UrlOpen { terminal_id, url } = cmd {
        return url_open::start(mux, client, id, terminal_id, url, writer);
    }
    if let Command::ChiefInspect(params) = cmd {
        return chief_inspect::start(mux, client, id, params, writer);
    }
    if cloud_conversations::is_network(&cmd) {
        return cloud_conversations::start(mux, client, id, cmd, writer);
    }
    if let Some(target) = cloud_conversations::subscribe_target(mux, &cmd) {
        return cloud_conversations::subscribe_then_announce(mux, client, id, cmd, target, writer);
    }
    if matches!(&cmd, Command::ShutdownDaemon { .. } | Command::ReloadConfig)
        && !mux.server_lifecycle_ready()
    {
        return send_request_error(writer, id, "server lifecycle is not ready");
    }
    if let Command::VtState { surface } = &cmd {
        return match send_vt_state_command_response(mux, id.clone(), *surface, writer) {
            Ok(()) => true,
            Err(error) => send_request_error(writer, id, &error.to_string()),
        };
    }

    let detach_self = match &cmd {
        Command::DetachClient { client: target, by, surface }
            if target.whole_client() == Some(client)
                && own_view_detach_target(mux, target, *surface).is_none() =>
        {
            Some(detach_actor(mux, client, by.clone()))
        }
        _ => None,
    };
    let shutdown_daemon = matches!(&cmd, Command::ShutdownDaemon { .. });
    let (mut reason, mut retryable, mut details) = (None, None, None);
    let response = match handle_command_with_cancellation(mux, client, cmd, writer, cancellation) {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => {
            reason = conversations::error_reason(&error)
                .or_else(|| cloud_conversations::error_reason(&error));
            retryable = cloud_conversations::error_retryable(&error);
            details = renderer_grant::error_details(&error);
            let error_code = response_error_code(&error);
            let error_delivery =
                error.downcast_ref::<DeliveryClassifiedError>().map(|error| error.delivery);
            Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code,
                error_delivery,
            }
        }
    };
    let (response, reason) = remote_relay::redact_response(mux, client, response, reason);
    let details = details.filter(|_| !mux.is_remote_client(client));
    let response_ok = response.ok;
    let sent = responses::send_response_with_details(writer, response, reason, retryable, details);
    // Flush the successful acknowledgement before making the owning loop
    // leave, so process teardown cannot race the response writer.
    if shutdown_daemon && response_ok {
        if sent {
            return complete_daemon_shutdown_after_ack(mux, client, writer);
        } else {
            mux.cancel_daemon_handoff(client);
        }
    }
    if let Some(by) = detach_self
        && response_ok
        && sent
    {
        kick_client(mux, client, by);
        return false;
    }
    sent
}

fn send_vt_state_command_response(
    mux: &Mux,
    id: Option<Value>,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> anyhow::Result<()> {
    // Reserve the entire wire-frame allowance before copying a replay or
    // starting its base64 encoder. The writer allocates only for actual
    // output and releases unused logical quota before the response is queued.
    let mut output = writer.render_service.reserved_control_writer()?;
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
        terminal
            .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .map(|replay| (terminal.cols(), terminal.rows(), replay))
    })??;

    write_vt_state_command_json(
        &mut output,
        id.as_ref(),
        cols,
        rows,
        &replay.self_contained_bytes(),
        &replay.kitty_image_aliases,
        replay.kitty_state,
    )?;
    writer.send_serialized_control(output.finish())?;
    Ok(())
}

fn write_vt_state_command_json(
    output: &mut BudgetedJsonWriter,
    id: Option<&Value>,
    cols: u16,
    rows: u16,
    replay: &[u8],
    kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    kitty_state: KittyReplayState,
) -> std::io::Result<()> {
    output.write_all(b"{")?;
    if let Some(id) = id {
        output.write_all(b"\"id\":")?;
        serde_json::to_writer(&mut *output, id).map_err(json_error_to_io)?;
        output.write_all(b",")?;
    }
    write!(output, "\"ok\":true,\"data\":{{\"cols\":{cols},\"rows\":{rows},\"data\":\"")?;
    {
        let mut encoder = base64::write::EncoderWriter::new(
            &mut *output,
            &base64::engine::general_purpose::STANDARD,
        );
        encoder.write_all(replay)?;
        encoder.finish()?;
    }
    output.write_all(b"\",\"kitty_image_aliases\":")?;
    write_kitty_image_aliases_json(output, kitty_image_aliases)?;
    output.write_all(b",\"kitty_graphics_state\":")?;
    write_kitty_replay_state_json(output, kitty_state)?;
    output.write_all(b"}}")?;
    Ok(())
}

fn auth_token(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

fn pairing_request(message: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

fn zeroize_string(value: &mut str) {
    // NUL remains valid UTF-8, so decoded control frames can be cleared in
    // place immediately after dispatch.
    value.zeroize();
}

fn node_json(node: &Node, active_pane: PaneId) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { id, dir, ratio, a, b } => json!({
            "type": "split",
            "split": id,
            "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
            "ratio": ratio,
            "a": node_json(a, active_pane),
            "b": node_json(b, active_pane),
        }),
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

fn optional_surface_size(cols: Option<u16>, rows: Option<u16>) -> Option<(u16, u16)> {
    cols.zip(rows).map(|(cols, rows)| (cols.max(1), rows.max(1)))
}

fn paired_surface_size(
    command: &str,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Option<(u16, u16)>> {
    match (cols, rows) {
        (Some(cols), Some(rows)) => Ok(Some((cols.max(1), rows.max(1)))),
        (None, None) => Ok(None),
        _ => anyhow::bail!("{command} cols and rows must be supplied together"),
    }
}

fn default_renderer_capability_ttl_ms() -> u64 {
    30_000
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

fn color_hex(color: Option<Rgb>) -> Option<String> {
    color.map(|color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b))
}

fn terminal_colors_json(colors: TerminalColors, include_overrides: bool) -> Value {
    let cursor_style = colors.cursor_style.map(|style| match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    });
    let palette = colors
        .palette
        .into_iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color_hex(color).map(|color| (index.to_string(), Value::String(color)))
        })
        .collect::<serde_json::Map<String, Value>>();
    let mut value = json!({
        "fg": color_hex(colors.fg),
        "bg": color_hex(colors.bg),
        "cursor": color_hex(colors.cursor),
        "selection_bg": color_hex(colors.selection_bg),
        "selection_fg": color_hex(colors.selection_fg),
        "palette": palette,
        "cursor_style": cursor_style,
        "cursor_blink": colors.cursor_blink,
    });
    // Older generated SDKs reject unknown fields. Only viewers that opted in
    // before attaching receive the additional provenance object.
    if include_overrides {
        value["overrides"] = json!({
            "fg": color_hex(colors.fg_override),
            "bg": color_hex(colors.bg_override),
            "cursor": color_hex(colors.cursor_override),
        });
    }
    value
}

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

fn handle_command_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> anyhow::Result<Value> {
    // Who a durable legacy command acts as (P8): read once per command.
    let actor = origin_gate::connection_actor(mux, client);
    if let Some(remote) = remote_relay::intercept(mux, client, &cmd, writer) {
        return remote;
    }
    match cmd {
        Command::SubscribeActivity => cmd_subscribe::subscribe_activity(mux, client, writer),
        cmd @ (Command::UrlOpenSubscribe { .. }
        | Command::UrlOpenClaim { .. }
        | Command::UrlOpenResult { .. }) => url_open::handle(mux, client, cmd, writer),
        cmd @ (Command::TerminalClipboardSubscribe { .. }
        | Command::TerminalClipboardReply { .. }) => {
            clipboard_read::handle(mux, client, cmd, writer)
        }
        Command::UrlOpen { .. } => {
            anyhow::bail!("URL opening requires the asynchronous request path")
        }
        Command::ChiefInspect(_) => {
            anyhow::bail!("chief-inspect requires the asynchronous request path")
        }
        Command::PasteImage {
            surface,
            terminal_id,
            lease,
            upload_id,
            op,
            mime,
            size,
            offset,
            data,
        } => cmd_terminal_io::paste_image(
            mux,
            client,
            surface,
            terminal_id,
            lease,
            upload_id,
            op,
            mime,
            size,
            offset,
            data,
        ),
        Command::SetTerminalCommandHistory { enabled } => {
            cmd_terminals::set_terminal_command_history(mux, client, enabled)
        }
        Command::ServerStats { include } => cmd_server::server_stats(mux, client, include),
        Command::BrowserHostProvider => cmd_browser::browser_host_provider(mux, client),
        Command::Identify => cmd_server::identify(mux),
        Command::ShutdownDaemon { pid, generation, force, end_terminals, keep_layout } => {
            cmd_server::shutdown_daemon(
                mux,
                client,
                pid,
                generation,
                force,
                end_terminals,
                keep_layout,
            )
        }
        Command::Ping => cmd_server::ping(),
        Command::SetClientInfo {
            name,
            kind,
            capabilities,
            user_id,
            display_name,
            device_kind,
            device_name,
            device_id,
        } => cmd_server::set_client_info(
            mux,
            client,
            name,
            kind,
            capabilities,
            user_id,
            display_name,
            device_kind,
            device_name,
            device_id,
        ),
        Command::ListClients => cmd_server::list_clients(mux, client),
        Command::MachineUsage => cmd_server::machine_usage(mux),
        Command::MachineListeningTcp => cmd_server::machine_listening_tcp(),
        Command::RegisterBrowserProvider {
            provider_id,
            endpoint,
            authentication,
            bearer_token,
            targets,
        } => cmd_browser::register_browser_provider(
            mux,
            client,
            provider_id,
            endpoint,
            authentication,
            bearer_token,
            targets,
        ),
        Command::GetBrowserProvider => cmd_browser::get_browser_provider(mux, client),
        Command::UnregisterBrowserProvider => cmd_browser::unregister_browser_provider(mux, client),
        Command::ListTerminals => cmd_terminals::list_terminals(mux),
        Command::TerminalEvents { after_revision } => {
            cmd_terminals::terminal_events(mux, after_revision)
        }
        Command::SetClientSizing { surface, client: target, enabled, exclusive } => {
            cmd_sizing::set_client_sizing(mux, client, surface, target, enabled, exclusive)
        }
        Command::PairingResponse { request, approve } => {
            cmd_server::pairing_response(mux, client, request, approve)
        }
        Command::DetachClient { client: target, by, surface } => {
            cmd_attach::detach_client(mux, client, target, by, surface)
        }
        Command::SetSizePolicy { surface, workspace, policy } => {
            cmd_sizing::set_size_policy(mux, client, surface, workspace, policy)
        }
        Command::SetSizeCounts { surface, client: target, lease, view, participant, counts } => {
            cmd_sizing::set_size_counts(
                mux,
                client,
                surface,
                target,
                lease,
                view,
                participant,
                counts,
            )
        }
        Command::NoteSizeActivity { surface, view } => {
            cmd_sizing::note_size_activity(mux, client, surface, view)
        }
        Command::ReattachView { surface, counts } => {
            cmd_attach::reattach_view(mux, client, surface, counts)
        }
        Command::GetSizeState { surface } => cmd_sizing::get_size_state(mux, client, surface),
        Command::ReloadConfig => cmd_server::reload_config(mux),
        Command::SetWindowTitle { title } => cmd_server::set_window_title(mux, title),
        Command::ClearWindowTitle => cmd_server::clear_window_title(mux),
        Command::ListWorkspaces => cmd_workspaces::list_workspaces(mux),
        Command::GetFrontendProjection { frontend, scope, subject_key } => {
            cmd_frontend::get_frontend_projection(mux, frontend, scope, subject_key)
        }
        Command::PutFrontendProjection {
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        } => cmd_frontend::put_frontend_projection(
            mux,
            client,
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        ),
        Command::JournalFrontendEvent { event } => {
            cmd_frontend::journal_frontend_event(mux, client, event)
        }
        Command::ExportLayout { screen } => cmd_panes::export_layout(mux, screen),
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            cmd_panes::apply_layout(mux, actor, workspace, name, layout, cols, rows)
        }
        Command::Send { surface, text, bytes, paste } => {
            cmd_terminal_io::send(mux, client, surface, text, bytes, paste)
        }
        Command::ReadScreen { surface } => cmd_terminal_io::read_screen(mux, surface),
        Command::ClearHistory { surface, fallback_key } => {
            cmd_terminal_io::clear_history(mux, surface, fallback_key)
        }
        Command::ReadScrollback { surface, start, count } => {
            cmd_terminal_io::read_scrollback(mux, surface, start, count)
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            cmd_frontend::sidebar_plugin(mux, cols, rows, relaunch)
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            cmd_terminal_io::wait_for(mux, cancellation, surface, pattern, timeout_ms)
        }
        Command::Run { argv, command, cwd, pane, new_workspace, key, name, cols, rows } => {
            cmd_terminal_io::run(
                mux,
                actor,
                argv,
                command,
                cwd,
                pane,
                new_workspace,
                key,
                name,
                cols,
                rows,
            )
        }
        Command::CreateSurfaceWithReceipt(request) => {
            cmd_frontend::create_surface_with_receipt_command(mux, client, request)
        }
        Command::SendKey { surface, keys } => cmd_terminal_io::send_key(mux, client, surface, keys),
        Command::Copy { surface, mode } => cmd_terminal_io::copy(mux, surface, mode),
        Command::Ids { kind } => cmd_frontend::ids(mux, kind),
        Command::Notify { title, body, level, surface, source } => {
            cmd_frontend::notify(mux, actor, title, body, level, surface, source)
        }
        Command::ListAgents { surface, state } => cmd_frontend::list_agents(mux, surface, state),
        Command::ReportAgent { surface, state, source, session } => {
            cmd_frontend::report_agent(mux, surface, state, source, session)
        }
        Command::VtState { .. } => unreachable!("vt-state uses its streaming response path"),
        Command::MintTerminalRenderer { surface, ttl_ms } => {
            cmd_terminals::mint_terminal_renderer(mux, client, surface, ttl_ms)
        }
        Command::MintTerminalRendererByTerminal { terminal, ttl_ms } => {
            cmd_terminals::mint_terminal_renderer_by_terminal(mux, client, terminal, ttl_ms)
        }
        Command::ResolveTerminal { terminal_id } => {
            cmd_terminals::resolve_terminal(mux, terminal_id)
        }
        Command::CloseTerminal { terminal_id, terminal_incarnation, mutation } => {
            cmd_terminals::close_terminal(mux, client, terminal_id, terminal_incarnation, mutation)
        }
        Command::SetTerminalIdlePolicy { surface, terminal_id, idle_close_seconds } => {
            cmd_terminals::set_terminal_idle_policy(mux, surface, terminal_id, idle_close_seconds)
        }
        Command::SetTerminalKeep { surface, terminal_id, keep } => {
            cmd_terminals::set_terminal_keep(mux, surface, terminal_id, keep)
        }
        Command::NewTab { pane, cwd, env, cols, rows, keep, terminal_id, shell_args } => {
            cmd_tabs::new_tab(
                mux,
                client,
                actor,
                pane,
                cwd,
                env,
                cols,
                rows,
                keep,
                terminal_id,
                shell_args,
            )
        }
        Command::NewConversationTab(params) => cmd_tabs::new_conversation_tab(mux, client, params),
        Command::BindConversationTabSession(params) => {
            cmd_tabs::bind_conversation_tab_session(mux, actor, params)
        }
        Command::NewFrontendBrowserTab(params) => {
            cmd_tabs::new_frontend_browser_tab(mux, client, params)
        }
        Command::UpdateFrontendBrowserTab(params) => {
            cmd_tabs::update_frontend_browser_tab(mux, actor, params)
        }
        Command::SetFrontendBrowserHistory(params) => frontend_browser_history::set(mux, params),
        Command::GetFrontendBrowserHistory(params) => frontend_browser_history::get(mux, params),
        Command::NewBrowserTab { url, pane, cols, rows } => {
            cmd_tabs::new_browser_tab(mux, actor, url, pane, cols, rows)
        }
        Command::GetCellPixels => cmd_sizing::get_cell_pixels(mux),
        Command::SetCellPixels { width_px, height_px } => {
            cmd_sizing::set_cell_pixels(mux, width_px, height_px)
        }
        Command::BrowserFramePresented { surface, frame_seq } => {
            cmd_browser::browser_frame_presented(mux, client, surface, frame_seq)
        }
        cmd @ (Command::BrowserMouse { .. }
        | Command::BrowserMouseGuarded { .. }
        | Command::BrowserWheel { .. }
        | Command::BrowserWheelGuarded { .. }
        | Command::BrowserKey { .. }
        | Command::BrowserKeyPress { .. }
        | Command::BrowserInsertText { .. }) => browser_input::handle(mux, client, cmd),
        Command::BrowserNavigate { surface, url } => {
            cmd_browser::browser_navigate(mux, surface, url)
        }
        Command::BrowserBack { surface } => cmd_browser::browser_back(mux, surface),
        Command::BrowserForward { surface } => cmd_browser::browser_forward(mux, surface),
        Command::BrowserReload { surface } => cmd_browser::browser_reload(mux, surface),
        Command::BrowserActivate { surface } => cmd_browser::browser_activate(mux, surface),
        Command::NewWorkspace { name, cols, rows } => {
            cmd_workspaces::new_workspace(mux, actor, name, cols, rows)
        }
        Command::CreateWorkspace { name, key, mutation } => {
            cmd_workspaces::create_workspace(mux, client, name, key, mutation)
        }
        Command::CreateTerminal {
            workspace,
            key,
            argv,
            shell_args,
            command,
            cwd,
            name,
            cols,
            rows,
            terminal_id,
            env,
            keep,
            mutation,
        } => cmd_terminals::create_terminal(
            mux,
            client,
            actor,
            workspace,
            key,
            argv,
            shell_args,
            command,
            cwd,
            name,
            cols,
            rows,
            terminal_id,
            env,
            keep,
            mutation,
        ),
        Command::NewScreen(params) => cmd_screens::new_screen(mux, client, params),
        Command::SetScreenMetadata { screen, color, icon } => {
            cmd_screens::set_screen_metadata(mux, actor, screen, color, icon)
        }
        Command::SetScreenPinned { screen, pinned } => {
            cmd_screens::set_screen_pinned(mux, actor, screen, pinned)
        }
        Command::MoveScreen { screen, index, workspace, new_workspace } => {
            cmd_screens::move_screen(mux, actor, screen, index, workspace, new_workspace)
        }
        Command::CreateScreenGroup { screens, name, color } => {
            cmd_screens::create_screen_group(mux, actor, screens, name, color)
        }
        Command::UpdateScreenGroup { group, name, color, collapsed } => {
            cmd_screens::update_screen_group(mux, actor, group, name, color, collapsed)
        }
        Command::AddScreensToScreenGroup { group, screens, index } => {
            cmd_screens::add_screens_to_screen_group(mux, actor, group, screens, index)
        }
        Command::RemoveScreensFromScreenGroup { screens } => {
            cmd_screens::remove_screens_from_screen_group(mux, actor, screens)
        }
        Command::MoveScreenGroup { group, index, workspace, new_workspace } => {
            cmd_screens::move_screen_group(mux, actor, group, index, workspace, new_workspace)
        }
        Command::UngroupScreenGroup { group } => {
            cmd_screens::ungroup_screen_group(mux, actor, group)
        }
        Command::CloseScreenGroup { group, end_terminals } => {
            cmd_screens::close_screen_group(mux, actor, group, end_terminals)
        }
        Command::ListSavedScreenGroups => cmd_screens::list_saved_screen_groups(mux),
        Command::SaveScreenGroup { group } => cmd_screens::save_screen_group(mux, actor, group),
        Command::UnsaveScreenGroup { group } => cmd_screens::unsave_screen_group(mux, group),
        Command::DeleteSavedScreenGroup { saved } => {
            cmd_screens::delete_saved_screen_group(mux, saved)
        }
        Command::ReopenSavedScreenGroup { saved, workspace } => {
            cmd_screens::reopen_saved_screen_group(mux, actor, saved, workspace)
        }
        Command::NewPane { pane, cols, rows, cwd, env, keep, terminal_id, shell_args } => {
            cmd_panes::new_pane(
                mux,
                client,
                actor,
                pane,
                cols,
                rows,
                cwd,
                env,
                keep,
                terminal_id,
                shell_args,
            )
        }
        Command::NewPaneRight(params) => cmd_panes::new_pane_right(mux, client, params),
        Command::Split(params) => cmd_panes::split(mux, client, params),
        Command::SetRatio { pane, dir, ratio } => {
            cmd_panes::set_ratio(mux, actor, pane, dir, ratio)
        }
        Command::SetSplitRatio { split, ratio, transaction } => {
            cmd_panes::set_split_ratio(mux, client, actor, split, ratio, transaction)
        }
        Command::SetViewportPaneWidth { pane, width, transaction } => {
            cmd_panes::set_viewport_pane_width(mux, client, actor, pane, width, transaction)
        }
        Command::SetColumnDock { pane, dock, edge, mode, role, permanent, transaction } => {
            cmd_panes::set_column_dock(
                mux,
                client,
                actor,
                pane,
                dock,
                edge,
                mode,
                role,
                permanent,
                transaction,
            )
        }
        Command::UndoLayout { pane, revision, confirm_close } => {
            cmd_panes::undo_layout(mux, actor, pane, revision, confirm_close)
        }
        Command::PaneNeighbor { pane, dir } => cmd_panes::pane_neighbor(mux, pane, dir),
        Command::FocusDirection { pane, dir } => cmd_panes::focus_direction(mux, actor, pane, dir),
        Command::SwapPane { pane, dir, target } => {
            cmd_panes::swap_pane(mux, actor, pane, dir, target)
        }
        Command::ZoomPane { pane, mode } => cmd_panes::zoom_pane(mux, actor, pane, mode),
        Command::ProcessInfo { surface } => cmd_terminals::process_info(mux, surface),
        Command::TerminalResources { surfaces } => cmd_terminals::terminal_resources(mux, surfaces),
        Command::MoveTerminal { terminal_id, workspace_key, terminal_incarnation, mutation } => {
            cmd_terminals::move_terminal(
                mux,
                client,
                terminal_id,
                workspace_key,
                terminal_incarnation,
                mutation,
            )
        }
        Command::MoveTabToWorkspace { surface, workspace, transaction } => {
            cmd_tabs::move_tab_to_workspace(mux, actor, surface, workspace, transaction)
        }
        Command::MoveTabToSplit { surface, pane, edge, ratio, respawn, transaction } => {
            cmd_tabs::move_tab_to_split(
                mux,
                client,
                surface,
                pane,
                edge,
                ratio,
                respawn,
                transaction,
            )
        }
        Command::MoveTabToColumn(params) => cmd_tabs::move_tab_to_column(mux, client, params),
        Command::NewRow(params) => cmd_panes::new_row(mux, client, params),
        Command::SetRowHeights(params) => cmd_panes::set_row_heights(mux, client, params),
        Command::MoveTabToNewWorkspace { surface, group, index, name, transaction } => {
            cmd_tabs::move_tab_to_new_workspace(
                mux,
                actor,
                surface,
                group,
                index,
                name,
                transaction,
            )
        }
        Command::MoveTab { surface, pane, index, transaction } => {
            cmd_tabs::move_tab(mux, actor, surface, pane, index, transaction)
        }
        Command::ListTabGroups => cmd_tabs::list_tab_groups(mux),
        Command::CreateTabGroup { surfaces, name, color, group, transaction } => {
            cmd_tabs::create_tab_group(mux, actor, surfaces, name, color, group, transaction)
        }
        Command::UpdateTabGroup { group, name, color, collapsed } => {
            cmd_tabs::update_tab_group(mux, actor, group, name, color, collapsed)
        }
        Command::AddTabsToTabGroup { group, surfaces, transaction } => {
            cmd_tabs::add_tabs_to_tab_group(mux, actor, group, surfaces, transaction)
        }
        Command::RemoveTabsFromTabGroup { surfaces, transaction } => {
            cmd_tabs::remove_tabs_from_tab_group(mux, actor, surfaces, transaction)
        }
        Command::MoveTabGroup { group, pane, index, transaction } => {
            cmd_tabs::move_tab_group(mux, actor, group, pane, index, transaction)
        }
        Command::MoveTabGroupToSplit { group, pane, edge, ratio, transaction } => {
            cmd_tabs::move_tab_group_to_split(mux, actor, group, pane, edge, ratio, transaction)
        }
        Command::MoveTabGroupToColumn { group, pane, screen, after_column, width, transaction } => {
            cmd_tabs::move_tab_group_to_column(
                mux,
                actor,
                group,
                pane,
                screen,
                after_column,
                width,
                transaction,
            )
        }
        Command::MoveTabGroupToNewWorkspace { group, workspace_group, index, transaction } => {
            cmd_tabs::move_tab_group_to_new_workspace(
                mux,
                actor,
                group,
                workspace_group,
                index,
                transaction,
            )
        }
        Command::UngroupTabGroup { group } => cmd_tabs::ungroup_tab_group(mux, actor, group),
        Command::CloseTabGroup { group, end_terminals } => {
            cmd_tabs::close_tab_group(mux, actor, group, end_terminals)
        }
        Command::ListSavedTabGroups => cmd_tabs::list_saved_tab_groups(mux),
        Command::SaveTabGroup { group } => cmd_tabs::save_tab_group(mux, actor, group),
        Command::UnsaveTabGroup { group } => cmd_tabs::unsave_tab_group(mux, actor, group),
        Command::DeleteSavedTabGroup { saved } => {
            cmd_tabs::delete_saved_tab_group(mux, actor, saved)
        }
        Command::ReopenSavedTabGroup { saved, pane, transaction } => {
            cmd_tabs::reopen_saved_tab_group(mux, actor, saved, pane, transaction)
        }
        Command::AckTabNotifications { surface } => cmd_tabs::ack_tab_notifications(mux, surface),
        Command::ListNotifications { limit } => cmd_frontend::list_notifications(mux, limit),
        Command::SetTabPinned { surface, pinned } => {
            cmd_tabs::set_tab_pinned(mux, actor, surface, pinned)
        }
        Command::MoveWorkspace { workspace, key, index, mutation } => {
            cmd_workspaces::move_workspace(mux, client, workspace, key, index, mutation)
        }
        Command::SetWorkspaceMetadata {
            workspace,
            key,
            color,
            icon,
            title,
            pinned,
            marked_unread,
            mutation,
        } => cmd_workspaces::set_workspace_metadata(
            mux,
            client,
            workspace,
            key,
            color,
            icon,
            title,
            pinned,
            marked_unread,
            mutation,
        ),
        Command::ListPersonal => cmd_profiles::list_personal(mux),
        Command::CreateBrowserProfile(params) => browser_profiles::create(mux, params),
        Command::UpdateBrowserProfile(params) => browser_profiles::update(mux, params),
        Command::MoveBrowserProfile(params) => browser_profiles::move_to(mux, params),
        Command::DeleteBrowserProfile(params) => browser_profiles::delete(mux, params),
        Command::ListBookmarks(params) => bookmarks::list(mux, params),
        Command::CreateBookmark(params) => bookmarks::create(mux, &actor, params),
        Command::UpdateBookmark(params) => bookmarks::update(mux, &actor, params),
        Command::MoveBookmark(params) => bookmarks::move_to(mux, &actor, params),
        Command::DeleteBookmark(params) => bookmarks::delete(mux, &actor, params),
        Command::ImportBookmarks(params) => bookmarks::import(mux, &actor, params),
        Command::PutBlob(params) => icon_assets::put(mux, params),
        Command::GetBlob(params) => icon_assets::get(mux, params),
        Command::ConversationList => conversations::list(mux, client),
        Command::ConversationCreate(params) => conversations::create(mux, client, params),
        Command::ConversationSnapshot(params) => conversations::snapshot(mux, client, params),
        Command::ConversationHistory(params) => conversations::history(mux, client, params),
        Command::ConversationSearch(params) => conversations::search(mux, client, params),
        Command::ConversationOp(params) => conversations::op(mux, client, params),
        Command::ConversationTyping(params) => conversations::typing(mux, client, params),
        Command::ConversationBind(params) => conversations::bind(mux, client, params),
        Command::ConversationAgentToken(params) => conversations::agent_token(mux, client, params),
        Command::CloudSessionSet(params) => cloud_conversations::session_set(mux, client, params),
        Command::CloudSessionClear => cloud_conversations::session_clear(mux, client),
        Command::CloudSessionStatus => cloud_conversations::session_status(mux, client),
        Command::CloudInboxList(params) => cloud_conversations::inbox_list(mux, client, params),
        Command::CloudConversationSnapshot(params) => {
            cloud_conversations::snapshot(mux, client, params)
        }
        Command::CloudConversationHistory(params) => {
            cloud_conversations::history(mux, client, params)
        }
        Command::CloudConversationOp(params) => cloud_conversations::op(mux, client, params),
        Command::CloudInboxSubscribe => cloud_conversations::subscribe(mux, client, None),
        Command::CloudMuxSubscribe(_) => cloud_conversations::mux_subscribe(mux, client),
        Command::CloudMuxUnsubscribe(_) => cloud_conversations::mux_unsubscribe(mux, client),
        Command::CloudMuxAck(params) => cloud_conversations::mux_ack(mux, client, params),
        Command::CloudInboxUnsubscribe => cloud_conversations::unsubscribe(mux, client, None),
        Command::CloudConversationSubscribe(params) => {
            cloud_conversations::subscribe(mux, client, Some(params))
        }
        Command::CloudConversationUnsubscribe(params) => {
            cloud_conversations::unsubscribe(mux, client, Some(params))
        }
        Command::ConversationAttachmentUpload(p) => conversation_attachments::put(mux, client, p),
        Command::ConversationAttachmentRead(p) => conversation_attachments::read(mux, client, p),
        Command::ConversationImport(params) => conversations::import(mux, client, params),
        Command::CreateProfile {
            name,
            profile,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults,
            follows,
        } => cmd_profiles::create_profile(
            mux,
            name,
            profile,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults,
            follows,
        ),
        Command::UpdateProfile {
            profile,
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
            defaults,
        } => cmd_profiles::update_profile(
            mux,
            profile,
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
            defaults,
        ),
        Command::MoveProfile { profile, index } => cmd_profiles::move_profile(mux, profile, index),
        Command::DeleteProfile { profile, move_to } => {
            cmd_profiles::delete_profile(mux, client, profile, move_to)
        }
        Command::SetProfileFollows { profile, session_ids } => {
            cmd_profiles::set_profile_follows(mux, profile, session_ids)
        }
        Command::PinWorkspace { session_id, workspace_key, profile } => {
            cmd_workspaces::pin_workspace(mux, session_id, workspace_key, profile)
        }
        Command::UnpinWorkspace { session_id, workspace_key } => {
            cmd_workspaces::unpin_workspace(mux, session_id, workspace_key)
        }
        Command::PutSession {
            session_id,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        } => cmd_profiles::put_session(
            mux,
            session_id,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        ),
        Command::ForgetSession { session_id, force } => {
            cmd_profiles::forget_session(mux, session_id, force)
        }
        Command::ImportSessionOrganization { session_id, groups, workspaces } => {
            cmd_profiles::import_session_organization(mux, session_id, groups, workspaces)
        }
        Command::CreatePersonalGroup { name, group, profile, color, collapsed, index } => {
            cmd_profiles::create_personal_group(mux, name, group, profile, color, collapsed, index)
        }
        Command::UpdatePersonalGroup { group, name, color, collapsed, profile } => {
            cmd_profiles::update_personal_group(mux, group, name, color, collapsed, profile)
        }
        Command::DeletePersonalGroup { group } => {
            cmd_profiles::delete_personal_group(mux, client, group)
        }
        Command::MovePersonalGroup { group, index } => {
            cmd_profiles::move_personal_group(mux, group, index)
        }
        Command::SetPersonalWorkspace {
            session_id,
            workspace_key,
            index,
            group,
            browser_profile_id,
            theme,
        } => cmd_profiles::set_personal_workspace(
            mux,
            session_id,
            workspace_key,
            index,
            group,
            browser_profile_id,
            theme,
        ),
        Command::SetPersonalTerminal { session_id, terminal_key, theme } => {
            cmd_profiles::set_personal_terminal(mux, session_id, terminal_key, theme)
        }
        Command::ListWorkspaceGroups => cmd_workspaces::list_workspace_groups(mux),
        Command::CreateWorkspaceGroup { name, group, color, collapsed, index } => {
            cmd_workspaces::create_workspace_group(mux, name, group, color, collapsed, index)
        }
        Command::UpdateWorkspaceGroup { group, name, color, collapsed } => {
            cmd_workspaces::update_workspace_group(mux, group, name, color, collapsed)
        }
        Command::DeleteWorkspaceGroup { group } => {
            cmd_workspaces::delete_workspace_group(mux, group)
        }
        Command::MoveWorkspaceGroup { group, index } => {
            cmd_workspaces::move_workspace_group(mux, group, index)
        }
        Command::MoveWorkspaceToGroup { workspace, key, group, index, mutation } => {
            cmd_workspaces::move_workspace_to_group(
                mux, client, workspace, key, group, index, mutation,
            )
        }
        Command::SetDefaultColors {
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
            complete,
        } => cmd_terminal_io::set_default_colors(
            mux,
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
            complete,
        ),
        Command::CloseSurface { surface } => cmd_tabs::close_surface(mux, actor, surface),
        Command::CloseTabs { surfaces, end_terminals, transaction, reason, mutation } => {
            cmd_tabs::close_tabs(
                mux,
                client,
                surfaces,
                end_terminals,
                transaction,
                reason,
                mutation,
            )
        }
        Command::ClosePane { pane, end_terminals } => {
            cmd_panes::close_pane(mux, actor, pane, end_terminals)
        }
        Command::CloseScreen { screen, end_terminals } => {
            cmd_screens::close_screen(mux, actor, screen, end_terminals)
        }
        Command::CloseWorkspace { workspace, key, end_terminals, mutation } => {
            cmd_workspaces::close_workspace(mux, client, workspace, key, end_terminals, mutation)
        }
        Command::MarkWorkspacesProviderManaged { authority } => {
            cmd_workspaces::mark_workspaces_provider_managed(mux, authority)
        }
        Command::CloseProviderManagedWorkspace { workspace, key, authority } => {
            cmd_workspaces::close_provider_managed_workspace(mux, actor, workspace, key, authority)
        }
        Command::RenamePane { pane, name } => cmd_panes::rename_pane(mux, actor, pane, name),
        Command::RenameSurface { surface, name } => {
            cmd_tabs::rename_surface(mux, actor, surface, name)
        }
        Command::RenameScreen { screen, name } => {
            cmd_screens::rename_screen(mux, actor, screen, name)
        }
        Command::RenameWorkspace { workspace, key, name, mutation } => {
            cmd_workspaces::rename_workspace(mux, client, workspace, key, name, mutation)
        }
        Command::RenameProviderManagedWorkspace { workspace, key, name, authority } => {
            cmd_workspaces::rename_provider_managed_workspace(
                mux, actor, workspace, key, name, authority,
            )
        }
        Command::ResizeSurface { surface, cols, rows } => {
            cmd_sizing::resize_surface(mux, client, surface, cols, rows)
        }
        Command::ResizeAttachedView { surface, lease, view, identity, cols, rows } => {
            cmd_sizing::resize_attached_view(
                mux, client, surface, lease, view, identity, cols, rows,
            )
        }
        Command::ReleaseSurfaceSize { surface } => {
            cmd_sizing::release_surface_size(mux, client, surface)
        }
        Command::ReleaseAttachedViewSize { surface, lease, view } => {
            cmd_sizing::release_attached_view_size(mux, client, surface, lease, view)
        }
        Command::DetachAttachedView { surface, lease, view } => {
            cmd_attach::detach_attached_view(mux, client, surface, lease, view)
        }
        Command::FocusPane { pane } => cmd_panes::focus_pane(mux, actor, pane),
        Command::SelectTab { pane, index, delta } => {
            cmd_tabs::select_tab(mux, actor, pane, index, delta)
        }
        Command::SelectScreen { index, delta } => {
            cmd_screens::select_screen(mux, actor, index, delta)
        }
        Command::SelectWorkspace { index, delta } => {
            cmd_workspaces::select_workspace(mux, actor, index, delta)
        }
        Command::ReportFocus { client_id, pane, tab } => {
            cmd_server::report_focus(mux, client_id, pane, tab)
        }
        Command::ClientFocus { client_id } => cmd_server::client_focus(mux, client_id),
        Command::SnapshotRequest(params) => cmd_terminal_io::snapshot_request(mux, client, params),
        Command::TerminalHistory(params) => cmd_terminals::terminal_history(mux, params),
        Command::TerminalReadRange(params) => cmd_terminals::terminal_read_range(mux, params),
        Command::ScrollSurface { surface, delta } => {
            cmd_terminal_io::scroll_surface(mux, surface, delta)
        }
        Command::Subscribe { tree_events, surface } => {
            cmd_subscribe::subscribe_command(mux, client, writer, tree_events, surface)
        }
        Command::AttachSurface {
            surface: surface_id,
            mode,
            cols,
            rows,
            expected_generation,
            expected_terminal_id,
            snapshot,
        } => cmd_attach::attach_surface(
            mux,
            client,
            writer,
            surface_id,
            mode,
            cols,
            rows,
            expected_generation,
            expected_terminal_id,
            snapshot,
        ),
    }
}

/// Validate the start options of a placement command.
/// The `list-workspaces` reply: the tree plus the registry identity it
/// belongs to. The launch snapshot stores the same value.
fn list_workspaces_reply(mux: &Mux) -> anyhow::Result<Value> {
    let notifications = mux.tree_decorations();
    let mut workspaces = mux.with_state(|state| workspaces_json(state, &notifications));
    let (registry_id, generation) = mux.registry_identity();
    workspaces["registry_id"] = json!(registry_id);
    workspaces["generation"] = json!(generation);
    workspaces["terminal_revision"] = json!(mux.terminal_registry_snapshot()?.revision);
    Ok(workspaces)
}

/// The reply of a placement command: the new view and the terminal it
/// shows, after applying `keep`.
fn placed_terminal_result(
    mux: &Mux,
    surface: &crate::Surface,
    keep: bool,
) -> anyhow::Result<Value> {
    let identity = mux.resource_terminal_host_identity(surface);
    if keep {
        keep_created_terminal(mux, identity.as_ref().map(|i| i.terminal_id.as_str()))?;
    }
    Ok(json!({
        "surface": surface.id,
        "terminal_id": identity.as_ref().map(|identity| &identity.terminal_id),
        "terminal_incarnation": identity.as_ref().map(|identity| &identity.incarnation),
    }))
}

/// Apply `keep: true` from a creating command. A terminal without a durable
/// host (an in-process test surface) has nothing to reap.
fn keep_created_terminal(mux: &Mux, terminal_id: Option<&str>) -> anyhow::Result<()> {
    match terminal_id {
        Some(terminal_id) => mux.set_terminal_keep(terminal_id, true),
        None => Ok(()),
    }
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
#[path = "server/image_paste_tests.rs"]
mod image_paste_tests;

#[cfg(test)]
#[path = "server/orphan_shutdown_tests.rs"]
mod orphan_shutdown_tests;
#[cfg(test)]
#[path = "server/session_identity_tests.rs"]
mod session_identity_tests;

#[cfg(test)]
#[path = "server/personal_tests.rs"]
mod personal_tests;

#[cfg(test)]
#[path = "server/device_kind_tests.rs"]
mod device_kind_tests;
#[cfg(test)]
#[path = "server/dock_columns_tests.rs"]
mod dock_columns_tests;

#[cfg(test)]
#[path = "server/rows_tests.rs"]
mod rows_tests;

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
