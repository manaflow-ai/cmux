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

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(test)]
use std::net::TcpListener;
use std::net::{Shutdown, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context;
use base64::Engine;
#[cfg(test)]
use ghostty_vt::{KeyAction, Mods, sys};
use ghostty_vt::{KeyEncoder, KeyInput, KittyReplayState, key_input_from_chord, rows_to_runs};
use regex::Regex;
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
use crate::JournalClass;
#[cfg(test)]
use crate::JournalSensitivity;
#[cfg(test)]
use crate::SurfaceRenderFrame;
#[cfg(test)]
use crate::browser::{BrowserAttachUpdate, BrowserFrameUpdate};
use crate::browser::{BrowserMouseDispatch, BrowserPointerOwner};
use crate::browser_provider::{
    BrowserProviderAuthentication, BrowserProviderRegistration, BrowserProviderSnapshot,
};
#[cfg(test)]
use crate::journal_kernel::JournalDocument;
use crate::model::{Screen, State, Workspace};
use crate::mux::ClientSizingIdentity;
use crate::mux::{DaemonHandoffRequest, clamp_terminal_size};
use crate::platform::{self, transport};
#[cfg(test)]
use crate::resource::BrowserPublicId;
use crate::resource::{
    ContentPublicId, RequestId as ResourceRequestId, ResourceError, ResourceOperation,
    StreamPublicId, TabPublicId, TerminalPublicId,
};
use crate::sizing_policy::{
    TerminalDetachActor, TerminalDeviceKind, TerminalSizingPolicy, TerminalSizingState,
    detach_reason,
};
use crate::stream_interrupt::{InterruptSet, StreamInterrupt};
use crate::surface::{AttachLifecycle, ClearHistoryDelivery, ClearHistoryFailure};
use crate::workspace_registry::TerminalLifecycle;
use crate::{
    AgentRecord, AgentSource, AgentState, DefaultColors, Direction, GraphicsStatus, LayoutLeafSpec,
    LayoutRatioError, LayoutSpec, MachineUsage, Mux, MuxEvent, Node, NotificationLevel,
    NotificationSource, PairingDecision, PaneId, RenderAttachFrame, Rgb, ScreenId,
    SidebarPluginStatus, SplitDir, SplitId, SurfaceId, SurfaceKind, TerminalColors,
    TreeDecorations, TreeDelta, TreeDeltaKind, ViewportWidthError, WorkspaceId, WorkspaceMutation,
    ZoomMode, assign_short_ids,
};

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
mod launch_snapshot;
mod new_screen;
mod personal;
mod raw_tab;
#[cfg(unix)]
mod remote_entry;
mod remote_relay;
#[cfg(test)]
use remote_relay::handle_connection_message;
mod cmd_panes;
mod cmd_screens;
mod cmd_tabs;
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

fn validate_client_focus_id(client_id: &str) -> anyhow::Result<()> {
    if client_id.is_empty()
        || client_id.len() > 128
        || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        anyhow::bail!("bad request: invalid client_id");
    }
    Ok(())
}

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

fn machine_listening_tcp_json() -> anyhow::Result<Value> {
    #[cfg(not(unix))]
    {
        anyhow::bail!("machine listening TCP inventory is not supported on this platform");
    }
    #[cfg(unix)]
    {
        const MAX_LISTING_BYTES: usize = 512 * 1024;
        // The Cloud daemon runs as cmux while containerd runs as root. Use the
        // guest's existing noninteractive sudo permission for this fixed read-only
        // inventory when available; otherwise preserve the unprivileged inventory.
        #[cfg(target_os = "linux")]
        let candidates: &[(&str, &[&str])] = &[
            ("sudo", &["-n", "ss", "-H", "-ltnp"]),
            ("sudo", &["-n", "netstat", "-ltnp"]),
            ("ss", &["-H", "-ltnp"]),
            ("netstat", &["-ltnp"]),
        ];
        // netstat's -p means protocol on BSD/macOS.
        #[cfg(not(target_os = "linux"))]
        let candidates: &[(&str, &[&str])] = &[("ss", &["-H", "-ltnp"]), ("netstat", &["-ltn"])];
        let mut failures = Vec::new();
        for &(program, arguments) in candidates {
            let output = match std::process::Command::new(program).args(arguments).output() {
                Ok(output) => output,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    failures.push(format!("{program}: {error}"));
                    continue;
                }
            };
            if !output.status.success() {
                failures.push(format!("{program}: exited with {}", output.status));
                continue;
            }
            if output.stdout.len() > MAX_LISTING_BYTES {
                anyhow::bail!("machine listening TCP inventory exceeded {MAX_LISTING_BYTES} bytes");
            }
            let stdout = String::from_utf8(output.stdout)
                .context("machine listening TCP inventory was not UTF-8")?;
            return Ok(json!({ "stdout": stdout }));
        }
        let detail = if failures.is_empty() {
            "neither ss nor netstat is installed".to_string()
        } else {
            failures.join("; ")
        };
        anyhow::bail!("machine listening TCP inventory failed: {detail}");
    }
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

fn detached_event_json(surface: SurfaceId, notice: &DetachNotice, view: Option<&str>) -> Value {
    let mut event = json!({"event": "detached", "surface": surface, "reason": notice.reason});
    if let Some(by) = notice.by.as_ref().filter(|by| !by.is_empty()) {
        event["by"] = json!(by);
    }
    if let Some(view) = view {
        event["view"] = json!(view);
    }
    event
}

/// The connection's own view that a `detach-client` target names, when that
/// connection opted into [`SIZING_VIEW_DETACH_CAPABILITY`]: the view leaves
/// and the connection stays. `None` keeps the whole-client kick.
fn own_view_detach_target(
    mux: &Mux,
    target: &DetachClientTarget,
    surface: Option<SurfaceId>,
) -> Option<(u64, SurfaceId)> {
    let DetachClientTarget::Participant(participant) = target else { return None };
    let (client, placement, view) = match surface {
        Some(surface) => mux.terminal_participant_member_on(surface, participant)?,
        None => mux.terminal_participant_member(participant)?,
    };
    (view.is_none()
        && mux.control_clients.supports_capability(client, SIZING_VIEW_DETACH_CAPABILITY))
    .then_some((client, placement))
}

/// `state` as `client` may read it (`open-device-kinds-v1`).
fn size_state_for_client(mux: &Mux, client: u64, state: &TerminalSizingState) -> Value {
    let open = mux.control_clients.supports_capability(client, OPEN_DEVICE_KINDS_CAPABILITY);
    json!(state.for_client(open))
}

/// A `size-state` event. Without a client it has only the kinds every
/// `shared-sizing-v1` client decodes.
fn size_state_event_json(
    surface: SurfaceId,
    runtime: SurfaceId,
    state: &TerminalSizingState,
    client: Option<(u64, bool)>,
) -> Value {
    let open = client.is_some_and(|(_, open)| open);
    let mut event =
        json!({"event": "size-state", "surface": surface, "state": state.for_client(open)});
    if let Some((client, _)) = client {
        let id = crate::mux::view_participant_id(runtime, surface, client);
        if state.participant(&id).is_some() {
            event["self_participant"] = json!(id);
        }
    }
    event
}

/// The actor recorded on a kick: the explicit `by`, else the requester's own identity.
fn detach_actor(mux: &Mux, requester: u64, by: Option<TerminalDetachActor>) -> TerminalDetachActor {
    by.unwrap_or_else(|| {
        let identity = mux.control_clients.sizing_identity(requester).unwrap_or_default();
        TerminalDetachActor {
            user_id: identity.user_id,
            display_name: identity.display_name,
            device_name: identity.device_name,
        }
    })
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

#[derive(Default)]
struct ResourceWorkerAdmissionState {
    active: usize,
    active_by_client: HashMap<u64, usize>,
}

struct ResourceWorkerAdmission {
    per_client_capacity: usize,
    server_capacity: usize,
    state: Mutex<ResourceWorkerAdmissionState>,
    changed: Condvar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceWorkerAdmissionError {
    ClientCapacity,
    ServerCapacity,
}

#[derive(Clone)]
struct ResourceWorkerPermit {
    _lease: Arc<ResourceWorkerPermitLease>,
}

struct ResourceWorkerPermitLease {
    admission: Arc<ResourceWorkerAdmission>,
    client: u64,
}

impl Drop for ResourceWorkerPermitLease {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.active = state.active.saturating_sub(1);
        let remove_client = state.active_by_client.get_mut(&self.client).is_some_and(|active| {
            *active = active.saturating_sub(1);
            *active == 0
        });
        if remove_client {
            state.active_by_client.remove(&self.client);
        }
        self.admission.changed.notify_all();
    }
}

impl ResourceWorkerAdmission {
    fn new(per_client_capacity: usize, server_capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            per_client_capacity,
            server_capacity,
            state: Mutex::new(ResourceWorkerAdmissionState::default()),
            changed: Condvar::new(),
        })
    }

    fn try_reserve(
        self: &Arc<Self>,
        client: u64,
    ) -> Result<ResourceWorkerPermit, ResourceWorkerAdmissionError> {
        let mut state = self.state.lock().unwrap();
        if state.active_by_client.get(&client).copied().unwrap_or_default()
            >= self.per_client_capacity
        {
            return Err(ResourceWorkerAdmissionError::ClientCapacity);
        }
        if state.active >= self.server_capacity {
            return Err(ResourceWorkerAdmissionError::ServerCapacity);
        }
        state.active += 1;
        *state.active_by_client.entry(client).or_default() += 1;
        Ok(ResourceWorkerPermit {
            _lease: Arc::new(ResourceWorkerPermitLease { admission: self.clone(), client }),
        })
    }

    #[cfg(test)]
    fn active(&self) -> usize {
        self.state.lock().unwrap().active
    }

    #[cfg(test)]
    fn wait_until_idle(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        while state.active != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.active != 0 {
                return false;
            }
        }
        true
    }
}

#[derive(Default)]
struct ServerSurfaceOperationState {
    workers: usize,
    retained_bytes: usize,
}

#[derive(Default)]
pub(crate) struct ServerSurfaceOperationAdmission {
    state: Mutex<ServerSurfaceOperationState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServerSurfaceAdmissionError {
    RetainedByteCapacity,
}

struct ServerSurfaceWorkerPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
}

impl Drop for ServerSurfaceWorkerPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.workers = state.workers.saturating_sub(1);
    }
}

struct ServerSurfaceBytesPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
    retained_bytes: usize,
}

impl Drop for ServerSurfaceBytesPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.retained_bytes = state.retained_bytes.saturating_sub(self.retained_bytes);
    }
}

impl ServerSurfaceOperationAdmission {
    fn try_reserve_worker(self: &Arc<Self>) -> Option<ServerSurfaceWorkerPermit> {
        let mut state = self.state.lock().unwrap();
        if state.workers >= SERVER_SURFACE_WORKER_CAPACITY {
            return None;
        }
        state.workers += 1;
        Some(ServerSurfaceWorkerPermit { admission: self.clone() })
    }

    fn try_reserve_bytes(
        self: &Arc<Self>,
        retained_bytes: usize,
    ) -> Result<ServerSurfaceBytesPermit, ServerSurfaceAdmissionError> {
        let mut state = self.state.lock().unwrap();
        if retained_bytes
            > SERVER_SURFACE_RETAINED_BYTE_CAPACITY.saturating_sub(state.retained_bytes)
        {
            return Err(ServerSurfaceAdmissionError::RetainedByteCapacity);
        }
        state.retained_bytes += retained_bytes;
        Ok(ServerSurfaceBytesPermit { admission: self.clone(), retained_bytes })
    }
}

struct PendingSurfaceRequest {
    request: Request,
    retained_bytes: usize,
    _bytes_permit: ServerSurfaceBytesPermit,
}

#[derive(Default)]
struct ConnectionSurfaceState {
    requests: VecDeque<PendingSurfaceRequest>,
    queued_bytes: usize,
    active_clear_surfaces: HashSet<SurfaceId>,
    /// Terminal creates handed to the terminal work pool and not yet answered (`terminal_create`).
    active_creations: usize,
    dispatcher_started: bool,
    dispatcher_done: bool,
    closed: bool,
}

/// Set when a connection's request scheduler closes. Request handlers that
/// wait (wait-for) register an interrupt instead of polling the flag.
#[derive(Default)]
struct ConnectionCancellation {
    flag: AtomicBool,
    interrupts: InterruptSet,
}

impl ConnectionCancellation {
    fn cancel(&self) {
        self.flag.store(true, Ordering::Release);
        self.interrupts.fire();
    }

    fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::Acquire)
    }

    fn register_interrupt(&self, interrupt: &Arc<StreamInterrupt>) {
        self.interrupts.register(interrupt);
    }
}

struct ConnectionSurfaceScheduler {
    state: Mutex<ConnectionSurfaceState>,
    changed: Condvar,
    admission: Arc<ServerSurfaceOperationAdmission>,
    cancelled: ConnectionCancellation,
    dispatcher: Mutex<Option<JoinHandle<()>>>,
    connection_permit: Mutex<Option<ConnectionPermit>>,
    creations: terminal_create::ConnectionCreations,
}

impl Default for ConnectionSurfaceScheduler {
    fn default() -> Self {
        Self::new(Arc::new(ServerSurfaceOperationAdmission::default()))
    }
}

impl ConnectionSurfaceScheduler {
    fn new(admission: Arc<ServerSurfaceOperationAdmission>) -> Self {
        Self::new_inner(admission, None)
    }

    #[cfg(test)]
    fn new_with_connection_permit(
        admission: Arc<ServerSurfaceOperationAdmission>,
        permit: ConnectionPermit,
    ) -> Self {
        Self::new_inner(admission, Some(permit))
    }

    fn new_inner(
        admission: Arc<ServerSurfaceOperationAdmission>,
        connection_permit: Option<ConnectionPermit>,
    ) -> Self {
        Self {
            state: Mutex::new(ConnectionSurfaceState::default()),
            changed: Condvar::new(),
            admission,
            cancelled: ConnectionCancellation::default(),
            dispatcher: Mutex::new(None),
            connection_permit: Mutex::new(connection_permit),
            creations: terminal_create::ConnectionCreations::default(),
        }
    }
}

mod render_service;
use render_service::{
    BudgetedJsonWriter, BudgetedText, RenderService, json_error_to_io, write_base64_json_string,
    write_kitty_image_aliases_json, write_kitty_replay_state_json,
};
#[cfg(test)]
use render_service::{OutboundByteBudget, RenderGraphicBase64Cache};

mod message_writer;
use message_writer::{MessageSink, MessageWriter, OutboundStream};

impl ConnectionSurfaceScheduler {
    fn dispatch(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        request: &mut Option<Request>,
        retained_bytes: usize,
        writer: MessageWriter,
    ) -> Option<bool> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Some(false);
        }
        let is_clear_history = request.as_ref().unwrap().cmd.is_clear_history();
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        if over_count || over_bytes {
            drop(state);
            return Some(send_request_error_with_delivery(
                &writer,
                request.take().unwrap().id,
                "surface request queue is full; request was not executed",
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        let request_id = request.as_ref().unwrap().id.clone();
        let bytes_permit = match self.admission.try_reserve_bytes(retained_bytes) {
            Ok(bytes) => bytes,
            Err(ServerSurfaceAdmissionError::RetainedByteCapacity) => {
                drop(state);
                let request_id = request.take().unwrap().id;
                return Some(if is_clear_history {
                    send_request_error_with_delivery(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                        Some(ResponseErrorDelivery::KnownNotDelivered),
                    )
                } else {
                    send_request_error(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                    )
                });
            }
        };
        let start_dispatcher = !state.dispatcher_started;
        state.dispatcher_started = true;
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(PendingSurfaceRequest {
            request: request.take().unwrap(),
            retained_bytes,
            _bytes_permit: bytes_permit,
        });
        self.changed.notify_all();
        drop(state);

        if start_dispatcher && let Err(error) = self.start_dispatcher(mux, client, writer.clone()) {
            self.finish_dispatcher();
            self.close();
            return Some(send_request_error_with_delivery(
                &writer,
                request_id,
                &format!("could not start connection request dispatcher: {error}"),
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        Some(true)
    }

    fn start_dispatcher(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        writer: MessageWriter,
    ) -> std::io::Result<()> {
        let scheduler = self.clone();
        let handle = std::thread::Builder::new()
            .name("mux-control-dispatch".into())
            .spawn(move || run_connection_surface_dispatcher(scheduler, mux, client, writer))?;
        *self.dispatcher.lock().unwrap() = Some(handle);
        Ok(())
    }

    fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        if state.active_clear_surfaces.is_empty() {
            return (!state.requests.is_empty()).then_some(0);
        }
        for (index, pending) in state.requests.iter().enumerate() {
            let surface = pending.request.cmd.ordering_surface()?;
            if state.active_clear_surfaces.contains(&surface) {
                continue;
            }
            if pending.request.cmd.can_overtake_clear_barrier() {
                return Some(index);
            }
            return None;
        }
        None
    }

    fn next_request(&self) -> Option<PendingSurfaceRequest> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(index) = Self::next_runnable_index(&state) {
                let pending = state.requests.remove(index).unwrap();
                state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
                if pending.request.cmd.is_clear_history() {
                    let surface = pending
                        .request
                        .cmd
                        .ordering_surface()
                        .expect("clear-history is ordered by surface");
                    let inserted = state.active_clear_surfaces.insert(surface);
                    assert!(inserted, "a clear worker cannot overlap its surface");
                }
                return Some(pending);
            }
            if state.closed && state.requests.is_empty() {
                state.dispatcher_done = true;
                self.changed.notify_all();
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn finish_clear(&self, surface: SurfaceId) {
        let mut state = self.state.lock().unwrap();
        state.active_clear_surfaces.remove(&surface);
        self.changed.notify_all();
    }

    fn finish_dispatcher(&self) {
        {
            let mut state = self.state.lock().unwrap();
            state.dispatcher_done = true;
            self.changed.notify_all();
        }
        self.connection_permit.lock().unwrap().take();
    }

    fn close(&self) {
        self.cancelled.cancel();
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.requests.clear();
        state.queued_bytes = 0;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().unwrap().take();
        }
    }

    fn finish(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().unwrap().take();
        }
    }

    fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        let deadline = timeout.map(|timeout| Instant::now() + timeout);
        let mut state = self.state.lock().unwrap();
        while !state.dispatcher_done
            || !state.active_clear_surfaces.is_empty()
            || state.active_creations != 0
        {
            if let Some(deadline) = deadline {
                if Instant::now() >= deadline {
                    break;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.changed.wait_timeout(state, remaining).unwrap();
                state = next;
            } else {
                state = self.changed.wait(state).unwrap();
            }
        }
        let drained = state.dispatcher_done
            && state.active_clear_surfaces.is_empty()
            && state.active_creations == 0;
        drop(state);
        if drained && let Some(dispatcher) = self.dispatcher.lock().unwrap().take() {
            let _ = dispatcher.join();
        }
        drained
    }

    fn finish_and_wait(&self) {
        self.finish();
        let drained = self.wait_for_completion(None);
        debug_assert!(drained, "unbounded graceful drain must settle");
    }

    fn close_and_wait(&self, timeout: Duration) -> bool {
        self.close();
        self.wait_for_completion(Some(timeout))
    }
}

struct ActiveClearGuard {
    scheduler: Arc<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
}

impl Drop for ActiveClearGuard {
    fn drop(&mut self) {
        self.scheduler.finish_clear(self.surface);
    }
}

struct ConnectionDispatcherGuard(Arc<ConnectionSurfaceScheduler>);

impl Drop for ConnectionDispatcherGuard {
    fn drop(&mut self) {
        self.0.finish_dispatcher();
    }
}

fn run_pending_request(
    scheduler: &ConnectionSurfaceScheduler,
    mux: &Arc<Mux>,
    client: u64,
    pending: PendingSurfaceRequest,
    writer: &MessageWriter,
) -> bool {
    let PendingSurfaceRequest { request, _bytes_permit, .. } = pending;
    handle_request_with_cancellation(mux, client, request, writer, Some(&scheduler.cancelled))
}

fn run_connection_surface_dispatcher(
    scheduler: Arc<ConnectionSurfaceScheduler>,
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
) {
    let _dispatcher = ConnectionDispatcherGuard(scheduler.clone());
    while writer.is_open() {
        let Some(pending) = scheduler.next_request() else { return };
        if pending.request.cmd.is_clear_history() {
            let surface = pending
                .request
                .cmd
                .ordering_surface()
                .expect("clear-history is ordered by surface");
            let Some(worker_permit) = scheduler.admission.try_reserve_worker() else {
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
                    id,
                    "too many clear-history operations are already in progress",
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
                continue;
            };
            let shared_pending = Arc::new(Mutex::new(Some(pending)));
            let worker_pending = shared_pending.clone();
            let worker_scheduler = scheduler.clone();
            let worker_mux = mux.clone();
            let worker_writer = writer.clone();
            let spawn =
                std::thread::Builder::new().name("mux-surface-control".into()).spawn(move || {
                    let _active = ActiveClearGuard { scheduler: worker_scheduler.clone(), surface };
                    // Drop the mux-wide permit before `_active` wakes the next
                    // request queued behind this surface barrier.
                    let _worker_permit = worker_permit;
                    let pending = worker_pending.lock().unwrap().take().unwrap();
                    if !run_pending_request(
                        &worker_scheduler,
                        &worker_mux,
                        client,
                        pending,
                        &worker_writer,
                    ) {
                        worker_scheduler.close();
                    }
                });
            if let Err(error) = spawn {
                let pending = shared_pending.lock().unwrap().take().unwrap();
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
                    id,
                    &format!("could not start clear-history worker: {error}"),
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
            }
        } else if pending.request.cmd.creates_terminal() {
            if !scheduler.submit_creation(&mux, client, pending, &writer) {
                scheduler.close();
                return;
            }
        } else if !run_pending_request(&scheduler, &mux, client, pending, &writer) {
            scheduler.close();
            return;
        }
    }
    scheduler.close();
}

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

fn disconnect_client(mux: &Arc<Mux>, client: u64, send_detached: bool) -> bool {
    disconnect_client_with_notice(mux, client, send_detached, None, &DetachNotice::network())
}

/// Disconnect a client because another participant (or the client itself)
/// asked. Its `detached` events carry `reason:"disconnected-by"` and `by`, so
/// the viewer does not reconnect automatically.
fn kick_client(mux: &Arc<Mux>, client: u64, by: TerminalDetachActor) -> bool {
    disconnect_client_with_notice(
        mux,
        client,
        true,
        None,
        &DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) },
    )
}

fn disconnect_client_with_notice(
    mux: &Arc<Mux>,
    client: u64,
    send_detached: bool,
    notice: Option<&str>,
    detach: &DetachNotice,
) -> bool {
    let record = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let Some(record) = mux.control_clients.remove(client) else { return false };
        mux.remove_size_client_from_attached_surfaces(client, record.attached.keys().copied());
        record
    };
    mux.unbind_conversation_principal(client);
    mux.release_cloud_conversation_client(client);
    // Provider capabilities are valid only for the control connection that
    // published them. Release before announcing detachment so waiters can
    // never observe a stale target after the owning client is gone.
    mux.unregister_browser_provider(client);
    #[cfg(unix)]
    mux.image_pastes.disconnect(client);
    if let Some(owner @ BrowserPointerOwner::Client(_)) = record.browser_pointer_owner {
        // Pointer commands do not require a frame-stream attachment, so any
        // browser worker may own this negotiated client. Disconnects are rare;
        // wake all browser workers after registry removal instead of polling
        // every idle worker forever.
        let surfaces = mux.with_state(|state| {
            state
                .surfaces
                .values()
                .filter(|surface| surface.kind() == SurfaceKind::Browser)
                .cloned()
                .collect::<Vec<_>>()
        });
        for surface in surfaces {
            surface.forget_browser_pointer_owner(owner);
            surface.wake_browser_pointer_cleanup();
        }
    }
    if send_detached {
        let _ = record.writer.set_write_timeout(Some(CLIENT_DETACH_WRITE_TIMEOUT));
        if let Some(event) = notice {
            let _ = record.writer.send_control(&json!({"event": event}));
            let _ = record.writer.flush_control(CLIENT_DETACH_WRITE_TIMEOUT);
        }
        for (surface, attached) in &record.attached {
            for stream in attached.streams.values() {
                let _ = record
                    .writer
                    .send_terminal(&detached_event_json(*surface, detach, None), stream);
            }
        }
        record.writer.close_after_control();
    } else {
        record.writer.close();
    }
    mux.emit(MuxEvent::ClientDetached(client));
    true
}

fn complete_daemon_shutdown_after_ack(
    mux: &Arc<Mux>,
    requesting_client: u64,
    writer: &MessageWriter,
) -> bool {
    if mux
        .commit_daemon_handoff_after_ack(requesting_client, || {
            writer.flush_control(SHUTDOWN_ACK_FLUSH_TIMEOUT)
        })
        .is_err()
    {
        mux.cancel_daemon_handoff(requesting_client);
        return false;
    }
    let requester_notice_sent = writer
        .send_control(&json!({"event": DAEMON_SHUTDOWN_EVENT}))
        .and_then(|()| writer.flush_control(SHUTDOWN_ACK_FLUSH_TIMEOUT))
        .is_ok();
    for peer in mux.control_clients.client_ids() {
        if peer != requesting_client {
            disconnect_client_with_notice(
                mux,
                peer,
                true,
                Some(DAEMON_SHUTDOWN_EVENT),
                &DetachNotice { reason: detach_reason::HOST_SHUTDOWN, by: None },
            );
        }
    }
    // Keep the owner alive until every detached client has received the
    // shutdown notice. The committed handoff reservation fences new work
    // while these notices are being flushed.
    mux.request_daemon_shutdown();
    requester_notice_sent
}

/// Detaches `owner`'s own view of `placement` and tells it with
/// `detached {scope:"view"}`; its connection and relay sub-views stay.
fn detach_own_view(mux: &Mux, owner: u64, placement: SurfaceId, by: TerminalDetachActor) {
    mux.detach_terminal_own_view(placement, owner);
    let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
    let mut event = detached_event_json(placement, &notice, None);
    event["scope"] = json!("view");
    mux.control_clients.send_surface_event(owner, placement, None, &event);
}

/// Disconnects one shared-sizing participant on behalf of `requester` (the
/// in-process frontend's `detach-client {client: <participant>}`): a relay
/// sub-view leaves alone and its relay forwards the notice; the own view of
/// a client with [`SIZING_VIEW_DETACH_CAPABILITY`] leaves alone and that
/// client stays; any other participant's whole client is kicked with `disconnected-by`.
pub fn detach_size_participant(
    mux: &Arc<Mux>,
    requester: u64,
    participant: &str,
    surface: Option<SurfaceId>,
) -> anyhow::Result<()> {
    let by = detach_actor(mux, requester, None);
    let target = DetachClientTarget::Participant(participant.to_string());
    if let Some((owner, placement)) = own_view_detach_target(mux, &target, surface) {
        detach_own_view(mux, owner, placement, by);
        return Ok(());
    }
    let member = match surface {
        Some(surface) => mux.terminal_participant_member_on(surface, participant),
        None => mux.terminal_participant_member(participant),
    };
    let Some((client, placement, view)) = member else {
        anyhow::bail!("unknown participant {participant}");
    };
    if let Some(view) = view {
        mux.detach_terminal_sub_view(placement, client, &view);
        let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
        mux.control_clients.send_surface_event(
            client,
            placement,
            None,
            &detached_event_json(placement, &notice, Some(&view)),
        );
        return Ok(());
    }
    anyhow::ensure!(client != requester, "cannot disconnect this client");
    anyhow::ensure!(kick_client(mux, client, by), "unknown client {client}");
    Ok(())
}

pub fn detach_control_client(mux: &Arc<Mux>, client: u64) -> bool {
    disconnect_client(mux, client, true)
}

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

fn handle_resource_session_shutdown(
    mux: &Arc<Mux>,
    client: u64,
    request: crate::resource_router::ParsedResourceRequest,
    id: ResourceRequestId,
    writer: &MessageWriter,
) -> bool {
    let operation = ResourceOperation::SessionShutdown;
    let force =
        request.fields["force"].as_bool().expect("catalog validates the shutdown force flag");
    let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
        mux.begin_daemon_handoff(client, DaemonHandoffRequest::unfenced(force)).map_err(|error| {
            ResourceError::operation_failed(
                "session.shutdown",
                error.to_string(),
                json!({"force":force}),
            )
        })
    });
    if let Err(error) = result {
        return send_resource_response(writer, id, operation, Err(error));
    }

    match crate::resource_router::commit_session_shutdown(mux, request) {
        Ok(result) => {
            let sent = send_resource_response(writer, id, operation, Ok(result));
            if sent {
                complete_daemon_shutdown_after_ack(mux, client, writer)
            } else {
                mux.cancel_daemon_handoff(client);
                false
            }
        }
        Err(error) => {
            mux.cancel_daemon_handoff(client);
            send_resource_response(writer, id, operation, Err(error))
        }
    }
}

/// Dispatches one request the origin gate admitted; `request` is the
/// gate's own parse of the line.
fn handle_resource_connection_message(
    mux: &Arc<Mux>,
    client: u64,
    request: crate::resource_router::ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if matches!(
        operation,
        ResourceOperation::SessionShutdown | ResourceOperation::SessionReloadConfig
    ) && !mux.server_lifecycle_ready()
    {
        let operation_name = match operation {
            ResourceOperation::SessionShutdown => "session.shutdown",
            ResourceOperation::SessionReloadConfig => "session.reload_config",
            _ => unreachable!("lifecycle readiness applies only to lifecycle operations"),
        };
        return send_resource_response(
            writer,
            id,
            operation,
            Err(ResourceError::new(
                "operation.failed",
                "server lifecycle is not ready",
                json!({
                    "operation": operation_name,
                    "reason": "lifecycle_not_ready",
                }),
                false,
            )),
        );
    }
    debug_assert_eq!(
        handles_resource_connection_operation(operation),
        crate::resource_router::requires_connection_context(operation)
    );
    match operation {
        operation if conversation_resource::handles(operation) => {
            conversation_resource::handle(mux, client, request, writer)
        }
        operation if chief_control::handles(operation) => {
            chief_control::handle(mux, client, request, writer)
        }
        ResourceOperation::SessionShutdown => {
            handle_resource_session_shutdown(mux, client, request, id, writer)
        }
        ResourceOperation::PairingRequestList | ResourceOperation::PairingRequestResolve => {
            let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
                crate::resource_router::handle_trusted_local_auxiliary(mux, request)
            });
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientList
        | ResourceOperation::ClientGet
        | ResourceOperation::ClientMetadataUpdate
        | ResourceOperation::ClientSizingSet
        | ResourceOperation::ClientSizingRelease
        | ResourceOperation::ClientCellPixelsSet
        | ResourceOperation::TerminalRendererGrantCreate
        | ResourceOperation::TerminalViewerResize
        | ResourceOperation::TerminalViewerRelease
        | ResourceOperation::BrowserViewerResize
        | ResourceOperation::BrowserViewerRelease => {
            let result = handle_resource_connection_control(mux, client, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientDetach => {
            let result = prepare_resource_client_detach(mux, client, &request);
            match result {
                Ok(target) if target == client => {
                    if !send_resource_response(writer, id, operation, Ok(json!({}))) {
                        return false;
                    }
                    false
                }
                Ok(target) => {
                    let result = if kick_client(mux, target, detach_actor(mux, client, None)) {
                        Ok(json!({}))
                    } else {
                        Err(ResourceError::not_found(
                            "client",
                            request.selectors.client.as_deref().unwrap_or("<missing>"),
                        ))
                    };
                    send_resource_response(writer, id, operation, result)
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::TerminalAttach => {
            match prepare_terminal_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_terminal_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::BrowserAttach => {
            match prepare_browser_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_browser_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SidebarViewAttach => {
            match prepare_sidebar_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_stream(mux, client, &start.stream_id);
                        return false;
                    }
                    start_sidebar_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionEvents => {
            match prepare_session_event_stream(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_event_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionJournalProducerList
        | ResourceOperation::SessionJournalProducerPut
        | ResourceOperation::SessionJournalAppend
        | ResourceOperation::SessionJournalHookList
        | ResourceOperation::SessionJournalHookPut
        | ResourceOperation::SessionJournalCheckpointCreate
        | ResourceOperation::SessionJournalCheckpointList
        | ResourceOperation::SessionJournalRestorePreview
        | ResourceOperation::SessionJournalSegmentList
        | ResourceOperation::SessionJournalSegmentSeal => {
            let result = trusted_local_resource_client(mux, client, operation)
                .and_then(|()| handle_journal_extension_request(mux, &request));
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::SessionJournalSubscribe => {
            let prepared = prepare_session_journal_stream(mux, client, writer, &request);
            match prepared {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_journal_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionSnapshot => {
            let result = resource_session_snapshot(mux, client, &request.selectors);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit => {
            start_resource_wait(mux.clone(), client, writer.clone(), request, id)
        }
        ResourceOperation::RequestCancel => {
            let result = cancel_resource_request(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::StreamCancel => {
            let result = cancel_resource_stream(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::OriginConfirmationIssue => {
            origin_gate::handle_issue(mux, client, &request, id, writer)
        }
        _ => {
            debug_assert!(
                !crate::resource_router::requires_connection_context(request.envelope.operation),
                "connection-owned operation fell through to the transport-independent router"
            );
            let operation = request.envelope.operation;
            match crate::resource_router::handle_parsed_resource_request(mux, request) {
                Ok(response) => {
                    activity::note_resource_input(mux, client, operation, &response);
                    writer.send_control(&response).is_ok()
                }
                // Only a response that cannot be encoded fails here.
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
    }
}

mod resource_waits;
use resource_waits::start_resource_wait;
fn handle_resource_connection_control(
    mux: &Arc<Mux>,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::ClientList => resource_client_list(mux, client, request),
        ResourceOperation::ClientGet => resource_client_get(mux, client, request),
        ResourceOperation::ClientMetadataUpdate => {
            resource_client_metadata_update(mux, client, request)
        }
        ResourceOperation::ClientSizingSet => resource_client_sizing_set(mux, client, request),
        ResourceOperation::ClientSizingRelease => {
            resource_client_sizing_release(mux, client, request)
        }
        ResourceOperation::ClientCellPixelsSet => {
            resource_client_cell_pixels_set(mux, client, request)
        }
        ResourceOperation::TerminalViewerResize => {
            resource_terminal_viewer_resize(mux, client, request)
        }
        ResourceOperation::TerminalViewerRelease => {
            resource_terminal_viewer_release(mux, client, request)
        }
        ResourceOperation::BrowserViewerResize => {
            resource_browser_viewer_resize(mux, client, request)
        }
        ResourceOperation::BrowserViewerRelease => {
            resource_browser_viewer_release(mux, client, request)
        }
        ResourceOperation::TerminalRendererGrantCreate => {
            renderer_grant::create(mux, client, request)
        }
        operation => unreachable!("connection handler received {operation:?}"),
    }
}

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

fn send_resource_stream_item(
    writer: &MessageWriter,
    outbound: &OutboundStream,
    stream_id: &StreamPublicId,
    sequence: u64,
    cursor: &Value,
    item: Value,
) -> bool {
    writer
        .send_stream_backpressured(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":sequence.to_string(),
                "cursor":cursor,
                "item":writer.project_conversation_tab_item(item),
            }),
            outbound,
        )
        .is_ok()
}

fn cancel_resource_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let route = crate::ResourceSelectors {
        machine: request.selectors.machine.clone(),
        session: request.selectors.session.clone(),
        ..Default::default()
    };
    mux.resolve_resource_path(crate::ResourceTarget::Session, &route)?;
    let stream_id: StreamPublicId = request
        .selectors
        .stream
        .as_deref()
        .ok_or_else(|| ResourceError::not_found("stream", "<missing>"))
        .and_then(|stream| StreamPublicId::parse(stream.to_string()))?;
    if let Some(stream) = mux.control_clients.take_resource_stream(client, &stream_id) {
        stream.canceled.store(true, Ordering::Release);
        let end = resource_stream_end(&stream_id, "canceled", None, None, None);
        writer
            .send_terminal(&end, &stream.outbound)
            .map_err(|_| ResourceError::transport_closed("could not end the canceled stream"))?;
    }
    Ok(json!({}))
}

fn cancel_resource_request(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let request_id = ResourceRequestId::parse(
        request.fields["request_id"].as_str().expect("catalog validates request cancellation ids"),
    )?;
    let canceled = match mux.control_clients.cancel_resource_wait(client, &request_id) {
        ResourceWaitCancel::Missing => false,
        ResourceWaitCancel::Canceled(lifecycle) => {
            lifecycle.wait_for_worker_finish();
            true
        }
        ResourceWaitCancel::Completing(lifecycle) => {
            if !lifecycle.wait_for_response_attempt() {
                writer.close();
                return Err(ResourceError::transport_closed(
                    "terminal wait completion ended before attempting its response",
                ));
            }
            false
        }
    };
    Ok(json!({"canceled":canceled}))
}

fn resource_stream_end(
    stream_id: &StreamPublicId,
    reason: &str,
    cursor: Option<Value>,
    recovery: Option<&str>,
    error: Option<(ResourceOperation, ResourceError)>,
) -> Value {
    let mut end = json!({
        "protocol":"cmux.protocol/2",
        "type":"stream_end",
        "stream_id":stream_id,
        "reason":reason,
    });
    if let Some(cursor) = cursor {
        end["cursor"] = cursor;
    }
    if let Some(recovery) = recovery {
        end["recovery"] = json!(recovery);
    }
    if let Some((operation, error)) = error {
        let error = crate::resource_router::validate_operation_error(operation, error);
        end["error"] = json!(error);
    }
    end
}

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

fn create_surface_with_receipt(
    mux: &Arc<Mux>,
    client: u64,
    request: CreateSurfaceWithReceiptRequest,
) -> anyhow::Result<Value> {
    let CreateSurfaceWithReceiptRequest {
        operation,
        origin,
        receipt,
        idempotency_key,
        selectors: supplied_selectors,
        selector_fallbacks,
        pane,
        workspace,
        argv,
        cwd,
        url,
        width,
        cols,
        rows,
    } = request;
    anyhow::ensure!(
        mux.control_clients.supports_capability(client, CREATION_RECEIPTS_CAPABILITY),
        "client did not negotiate {CREATION_RECEIPTS_CAPABILITY}"
    );
    anyhow::ensure!(
        idempotency_key.is_none()
            || mux.control_clients.supports_capability(client, CREATION_ATTEMPT_KEYS_CAPABILITY),
        "client did not negotiate {CREATION_ATTEMPT_KEYS_CAPABILITY}"
    );
    let actor = origin_gate::connection_actor(mux, client);
    let mutation =
        WorkspaceMutation::new(idempotency_key.unwrap_or_else(|| receipt.clone()), origin, actor)?;
    let size = paired_surface_size("create-surface-with-receipt", cols, rows)?;
    let mut fields = serde_json::Map::new();
    if let Some((cols, rows)) = size {
        fields.insert("cols".to_string(), json!(cols));
        fields.insert("rows".to_string(), json!(rows));
    }
    fields.insert("correlation_key".to_string(), json!(receipt));
    let session_selectors = || crate::ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..crate::ResourceSelectors::default()
    };
    let pane_selectors = |pane| {
        supplied_selectors.clone().map(Ok).unwrap_or_else(|| mux.resource_selectors_for_pane(pane))
    };
    let workspace_selectors = |workspace| {
        supplied_selectors
            .clone()
            .map(Ok)
            .unwrap_or_else(|| mux.resource_selectors_for_workspace(workspace))
    };
    let (resource_operation, selectors) = match operation.as_str() {
        "new-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && url.is_none() && width.is_none(),
                "new-tab received fields that belong to another creation operation"
            );
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::TabCreateTerminal, pane_selectors(pane)?)
        }
        "run-command" => {
            anyhow::ensure!(
                workspace.is_none() && url.is_none() && width.is_none(),
                "run-command received fields that belong to another creation operation"
            );
            let argv = argv
                .filter(|argv| !argv.is_empty())
                .ok_or_else(|| anyhow::anyhow!("run-command omitted argv"))?;
            fields.insert("argv".to_string(), json!(argv));
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::PaneRun, pane_selectors(pane)?)
        }
        "new-browser-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && width.is_none(),
                "new-browser-tab received fields that belong to another creation operation"
            );
            let url = url
                .filter(|url| !url.is_empty())
                .ok_or_else(|| anyhow::anyhow!("browser creation omitted URL"))?;
            fields.insert("url".to_string(), json!(url));
            if let Some((cols, rows)) = size {
                let (cell_width, cell_height) = mux.cell_pixel_size();
                fields.remove("cols");
                fields.remove("rows");
                fields
                    .insert("width_px".to_string(), json!(u64::from(cols) * u64::from(cell_width)));
                fields.insert(
                    "height_px".to_string(),
                    json!(u64::from(rows) * u64::from(cell_height)),
                );
            }
            (ResourceOperation::TabCreateBrowser, pane_selectors(pane)?)
        }
        "new-workspace" => {
            anyhow::ensure!(
                pane.is_none()
                    && workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-workspace received fields that belong to another creation operation"
            );
            fields.insert("initial_content".to_string(), json!("terminal"));
            (
                ResourceOperation::WorkspaceCreate,
                supplied_selectors.clone().unwrap_or_else(session_selectors),
            )
        }
        "new-screen" => {
            anyhow::ensure!(
                pane.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-screen received fields that belong to another creation operation"
            );
            (ResourceOperation::ScreenCreate, workspace_selectors(workspace)?)
        }
        "new-pane" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-pane received fields that belong to another creation operation"
            );
            (ResourceOperation::PaneCreate, pane_selectors(pane)?)
        }
        "new-pane-right" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && url.is_none(),
                "new-pane-right received fields that belong to another creation operation"
            );
            let width =
                width.ok_or_else(|| anyhow::anyhow!("new-pane-right omitted viewport width"))?;
            fields.insert("direction".to_string(), json!("right"));
            fields.insert("viewport_width".to_string(), json!(width));
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        "split-right" | "split-down" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "split creation received fields that belong to another creation operation"
            );
            fields.insert(
                "direction".to_string(),
                json!(if operation == "split-right" { "right" } else { "down" }),
            );
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        other => anyhow::bail!("unknown receipted creation operation {other:?}"),
    };
    anyhow::ensure!(
        selector_fallbacks.len() <= MAX_CREATION_SELECTOR_FALLBACKS,
        "creation accepts at most {MAX_CREATION_SELECTOR_FALLBACKS} selector fallbacks"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || mux
                .control_clients
                .supports_capability(client, CREATION_SELECTOR_FALLBACKS_CAPABILITY),
        "client did not negotiate {CREATION_SELECTOR_FALLBACKS_CAPABILITY}"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || matches!(
                resource_operation,
                ResourceOperation::PaneSplit
                    | ResourceOperation::PaneCreate
                    | ResourceOperation::PaneRun
                    | ResourceOperation::TabCreateTerminal
                    | ResourceOperation::TabCreateBrowser
            ),
        "selector fallbacks require a pane-targeted creation"
    );
    let mut selector_candidates = Vec::with_capacity(1 + selector_fallbacks.len());
    selector_candidates.push(selectors);
    for fallback in selector_fallbacks {
        if !selector_candidates.contains(&fallback) {
            selector_candidates.push(fallback);
        }
    }
    let (surface, replayed) =
        mux.receipted_surface_creation(resource_operation, selector_candidates, fields, &mutation)?;
    Ok(json!({"surface": surface, "replayed": replayed}))
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

fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &HashMap<u64, String>,
    notifications: &TreeDecorations,
) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    let tab_groups = crate::mux::pane_tab_groups(state, &notifications.presentation, id);
    let group_of = |surface: &SurfaceId| {
        tab_groups.iter().find(|run| run.members.contains(surface)).map(|run| run.group.id.as_str())
    };
    json!({
        "id": id,
        "resource_id": state.resource_indexes.pane_ids.get(&id),
        "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
        "name": pane.name,
        "active_tab": pane.active_tab,
        "focused_at": pane.focused_at,
        "tab_groups": tab_groups.iter().map(|run| pane_tab_group_json(run, None)).collect::<Vec<_>>(),
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            let terminal_identity = surface.and_then(|surface| surface.terminal_host_identity());
            let terminal_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .and_then(|identity| match &identity.content_id {
                    ContentPublicId::Terminal(id) => Some(id),
                    ContentPublicId::Browser(_) => None,
                });
            // A kept-layout tab (`end-terminals-keep-layout-v1`) has no
            // runtime surface after a restart; its identity is the index's.
            let tab_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| &identity.tab_id)
                .or_else(|| state.resource_indexes.tab_ids.get(sid));
            // A restored tab with no runtime surface (an ended terminal after
            // a restart) keeps its content id in the index, like its tab id.
            let content_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| identity.content_id.as_str())
                .or_else(|| state.resource_indexes.content_ids.get(sid).map(|content| content.as_str()));
            let directory = notifications.directories.get(sid);
            let frontend_browser = surface
                .and_then(|surface| surface.resource_identity())
                .and_then(|identity| match &identity.content_id {
                    ContentPublicId::Browser(id) => {
                        notifications.presentation.frontend_browsers.get(id.as_str())
                    }
                    ContentPublicId::Terminal(_) => None,
                });
            let conversation = content_resource_id
                .and_then(|id| notifications.presentation.conversation_tabs.get(id));
            let pinned = state.resource_indexes.tab_ids.get(sid).is_some_and(|tab| {
                notifications.presentation.pinned_tabs.contains(tab.as_str())
            });
            // `end-terminals-keep-layout-v1`: a kept tab whose terminal has
            // ended, to restart a shell in. After a restart it has no surface,
            // so its name and last title come from the record; a live
            // terminal's own title always wins.
            let kept = state
                .resource_indexes
                .tab_ids
                .get(sid)
                .filter(|_| surface.is_none_or(|surface| surface.is_dead()))
                .and_then(|tab| notifications.presentation.kept_tabs.get(tab.as_str()));
            let relaunch = kept.map(|kept| json!({"cwd": kept.cwd}));
            // R41: a terminal tab with no runtime surface is dead only when
            // its terminal really ended; a host still being adopted, or one
            // this build cannot adopt, keeps running its shell.
            let content_terminal = state.resource_indexes.content_ids.get(sid).and_then(|content| {
                match content {
                    ContentPublicId::Terminal(id) => Some(id.as_str()),
                    ContentPublicId::Browser(_) => None,
                }
            });
            let pending_terminal = surface
                .is_none()
                .then(|| content_terminal.and_then(|id| notifications.pending_terminals.get(id)))
                .flatten();
            let is_terminal_tab = surface.map_or(content_terminal.is_some(), |surface| {
                surface.kind() == SurfaceKind::Pty
            });
            let dead = surface.map(|s| s.is_dead()).unwrap_or(pending_terminal.is_none());
            let terminal_state = match (pending_terminal, is_terminal_tab) {
                (Some(pending), _) => Some(pending.state()),
                (None, false) => None,
                (None, true) if dead => Some("exited"),
                (None, true) => Some(
                    match surface.and_then(|surface| surface.terminal_host_connection_state()) {
                        Some(crate::surface::TerminalHostConnectionState::Reconnecting) => "reconnecting",
                        Some(crate::surface::TerminalHostConnectionState::Failed) => "failed",
                        _ => "running",
                    },
                ),
            };
            let host_record_version = match pending_terminal {
                Some(crate::mux::PendingTerminal::Unadoptable { record_version }) => *record_version,
                _ => None,
            };
            // Why a dead terminal ended: its runtime's end, else the durable
            // receipt of a terminal that has no runtime here.
            let end = if !dead || !is_terminal_tab {
                None
            } else {
                surface
                    .and_then(|surface| surface.terminal_end())
                    .map(|end| end.wire_json())
                    .or_else(|| content_terminal.and_then(|id| notifications.terminal_ends.get(id).cloned()))
                    .map(|end| notifications.with_loss_cause(content_terminal, end))
            };
            let mut tab = json!({
                "surface": sid,
                "tab_resource_id": tab_resource_id,
                "terminal_state": terminal_state,
                "host_record_version": host_record_version,
                "group": group_of(sid),
                "pinned": pinned,
                "relaunch": relaunch,
                "cwd": directory.and_then(|directory| directory.cwd.as_deref()),
                "git_branch": directory.and_then(|directory| directory.git_branch.as_deref()),
                "git_detached": directory.is_some_and(|directory| directory.git_detached),
                "content_resource_id": content_resource_id,
                "terminal_id": terminal_identity.as_ref().map(|identity| &identity.terminal_id),
                "terminal_resource_id": terminal_resource_id,
                "terminal_incarnation": terminal_identity
                    .as_ref()
                    .map(|identity| &identity.incarnation),
                "short_id": short_ids.get(sid).cloned().unwrap_or_default(),
                "supports_clear_history_key_fallback": surface
                    .is_some_and(|surface| surface.supports_clear_history_key_fallback()),
                "notification": notifications.get(sid).copied().map(|n| {
                    json!({
                        "notification": n.notification,
                        "unread": n.unread,
                        "level": n.level.as_str(),
                        "source": n.source.as_str(),
                    })
                }),
                "name": surface
                    .and_then(|s| s.name())
                    .or_else(|| kept.and_then(|k| k.name.clone())),
                "title": surface
                    .map(|s| s.title())
                    .filter(|title| !title.is_empty())
                    .or_else(|| kept.and_then(|k| k.title.clone()))
                    .unwrap_or_default(),
                "size": surface.map(|s| {
                    let (c, r) = s.size();
                    json!({"cols": c, "rows": r})
                }),
                "dead": dead,
                // Why a dead terminal ended (R41, terminal-state-v1).
                "end": end,
            });
            raw_tab::merge_browser_fields(&mut tab, surface, frontend_browser, conversation);
            tab
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn workspaces_json(state: &State, notifications: &TreeDecorations) -> Value {
    let short_ids = tree_short_ids(state);
    json!({
        "workspace_revision": state.workspace_revision,
        "pane_revision": state.pane_revision,
        "groups": workspace_groups_json(&notifications.presentation),
        "workspaces": state.workspaces.iter().enumerate().map(|(index, workspace)| {
            workspace_json(state, workspace, index, &short_ids, notifications)
        }).collect::<Vec<_>>(),
    })
}

fn tree_short_ids(state: &State) -> HashMap<u64, String> {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    assign_short_ids(ids)
}

fn workspace_json(
    state: &State,
    workspace: &Workspace,
    index: usize,
    short_ids: &HashMap<u64, String>,
    notifications: &TreeDecorations,
) -> Value {
    let presentation = notifications.presentation.workspace(&workspace.key);
    let screen_groups =
        crate::mux::workspace_screen_groups(workspace, &notifications.presentation.screens);
    let group_of = |screen: ScreenId| {
        screen_groups
            .iter()
            .find(|run| run.members.contains(&screen))
            .map(|run| run.group.id.as_str())
    };
    json!({
        "id": workspace.id,
        "resource_id": workspace.public_id,
        "key": workspace.key,
        "short_id": short_ids.get(&workspace.id).cloned().unwrap_or_default(),
        "name": workspace.name,
        "group": presentation.and_then(|presentation| presentation.group.as_deref()),
        "color": presentation.and_then(|presentation| presentation.color.as_deref()),
        "icon": presentation.and_then(|presentation| presentation.icon.as_deref()),
        "title": presentation.and_then(|presentation| presentation.title.as_deref()),
        "pinned": presentation.is_some_and(|presentation| presentation.pinned),
        "marked_unread": presentation.is_some_and(|presentation| presentation.marked_unread),
        "kind": home::raw_workspace_kind(&notifications.presentation, &workspace.key),
        "unread_count": workspace_unread_count(state, workspace, notifications),
        "active": index == state.active_workspace,
        "screens": workspace.screens.iter().enumerate().map(|(screen_index, screen)| {
            screen_json(
                state,
                screen,
                screen_index == workspace.active_screen,
                group_of(screen.id),
                short_ids,
                notifications,
            )
        }).collect::<Vec<_>>(),
        "screen_groups": screen_groups.iter().map(screen_group_run_json).collect::<Vec<_>>(),
    })
}

fn screen_group_run_json(run: &crate::mux::WorkspaceScreenGroup) -> Value {
    json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "start": run.start,
        "count": run.members.len(),
        "screens": run.members,
    })
}

/// Tabs in a workspace whose content has an unread notification marker.
fn workspace_unread_count(
    state: &State,
    workspace: &Workspace,
    notifications: &TreeDecorations,
) -> usize {
    workspace
        .screens
        .iter()
        .flat_map(|screen| screen.root.pane_ids_vec())
        .filter_map(|pane| state.panes.get(&pane))
        .flat_map(|pane| pane.tabs.iter())
        .filter(|surface| notifications.get(surface).is_some_and(|marker| marker.unread))
        .count()
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    if matches!(
        kind,
        TreeDeltaKind::WorkspaceAdded
            | TreeDeltaKind::WorkspaceClosed
            | TreeDeltaKind::WorkspaceRenamed
            | TreeDeltaKind::WorkspaceMoved
            | TreeDeltaKind::WorkspaceChanged
    ) {
        let short_ids = tree_short_ids(state);
        let index = state.workspace_index(id)?;
        let workspace = state.workspaces.get(index)?;
        return Some(workspace_json(state, workspace, index, &short_ids, notifications));
    }
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved
        | TreeDeltaKind::WorkspaceChanged => unreachable!("workspace deltas returned above"),
        TreeDeltaKind::ScreenAdded
        | TreeDeltaKind::ScreenClosed
        | TreeDeltaKind::ScreenRenamed
        | TreeDeltaKind::ScreenChanged => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::TabAdded
        | TreeDeltaKind::TabClosed
        | TreeDeltaKind::TabRenamed
        | TreeDeltaKind::TabChanged => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten())
            .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))
            .cloned(),
    }
}

fn tree_delta_json(delta: &TreeDelta, mux: &Mux) -> Value {
    let mut value = json!({
        "event": delta.kind.as_str(),
        "workspace": delta.workspace,
        "entity": delta.entity,
    });
    if let Some(screen) = delta.screen {
        value["screen"] = json!(screen);
    }
    if let Some(pane) = delta.pane {
        value["pane"] = json!(pane);
    }
    if let Some(surface) = delta.surface {
        value["surface"] = json!(surface);
    }
    if let Some(index) = delta.index {
        value["index"] = json!(index);
    }
    if let Some(transaction) = &delta.transaction {
        value["transaction"] = json!(transaction.as_ref());
    }
    if let Some(revision) = delta.workspace_revision {
        value["workspace_revision"] = json!(revision);
        if let Ok(Some(event)) = mux.workspace_registry_event(revision) {
            value["origin"] = json!(event.origin);
            value["mutation_id"] = json!(event.mutation_id);
        }
        let (registry_id, generation) = mux.registry_identity();
        value["registry_id"] = json!(registry_id);
        value["generation"] = json!(generation);
    }
    value
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind
        && !allowed.contains(&kind)
    {
        anyhow::bail!("bad kind {kind}");
    }
    let mut raw = Vec::new();
    for ws in &state.workspaces {
        raw.push(("workspace", ws.id));
        for screen in &ws.screens {
            raw.push(("screen", screen.id));
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                raw.push(("pane", pane));
            }
        }
    }
    raw.extend(state.surfaces.keys().copied().map(|id| ("surface", id)));
    let short_ids = assign_short_ids(raw.iter().map(|(_, id)| *id));
    Ok(json!({
        "ids": raw
            .into_iter()
            .filter(|(item_kind, _)| kind.is_none_or(|kind| kind == *item_kind))
            .map(|(kind, id)| json!({
                "kind": kind,
                "id": id,
                "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
            }))
            .collect::<Vec<_>>()
    }))
}

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id)
        .filter(|surface| !surface.is_dead())
        .ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn surface_has_view_placement(mux: &Mux, id: SurfaceId) -> bool {
    mux.with_state(|state| state.pane_of(id).is_some())
}

fn sidebar_plugin_status_json(status: SidebarPluginStatus) -> Value {
    let retry_after_ms = status.retry_after.map(|duration| duration.as_millis() as u64);
    json!({
        "surface": status.surface,
        "error": status.error,
        "retry_after_ms": retry_after_ms,
    })
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

fn browser_provider_registration(
    provider_id: String,
    endpoint: String,
    authentication: String,
    bearer_token: Option<String>,
    targets: Vec<BrowserProviderTargetRequest>,
) -> anyhow::Result<BrowserProviderRegistration> {
    anyhow::ensure!(
        !provider_id.is_empty()
            && provider_id.len() <= 128
            && provider_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-._:".contains(&byte)),
        "browser provider id must contain 1..128 ASCII identifier characters"
    );
    anyhow::ensure!(endpoint.len() <= 2_048, "browser provider endpoint is too long");
    let parsed = url::Url::parse(&endpoint).context("invalid browser provider endpoint")?;
    anyhow::ensure!(parsed.scheme() == "ws", "browser provider endpoint must use ws://");
    anyhow::ensure!(
        parsed.username().is_empty() && parsed.password().is_none(),
        "browser provider endpoint must not contain URL credentials"
    );
    anyhow::ensure!(parsed.port().is_some(), "browser provider endpoint must include a port");
    anyhow::ensure!(
        parsed.fragment().is_none(),
        "browser provider endpoint must not have a fragment"
    );
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("browser provider endpoint must include a host"))?;
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|address| address.is_loopback());
    anyhow::ensure!(
        loopback,
        "browser provider endpoint must be loopback; use an authenticated local gateway"
    );

    let authentication = match authentication.as_str() {
        "none" => {
            anyhow::ensure!(
                bearer_token.is_none(),
                "bearer_token is only valid with bearer authentication"
            );
            BrowserProviderAuthentication::None
        }
        "bearer" => {
            let token = bearer_token
                .filter(|token| !token.is_empty())
                .ok_or_else(|| anyhow::anyhow!("bearer authentication requires bearer_token"))?;
            anyhow::ensure!(
                token.len() <= 4_096 && token.bytes().all(|byte| byte.is_ascii_graphic()),
                "browser provider bearer token must contain 1..4096 visible ASCII characters"
            );
            BrowserProviderAuthentication::Bearer(token)
        }
        other => anyhow::bail!("unsupported browser provider authentication {other:?}"),
    };

    anyhow::ensure!(targets.len() <= 16_384, "too many browser provider targets");
    let mut parsed_targets = BTreeMap::new();
    for target in targets {
        let tab_id =
            TabPublicId::parse(target.tab_id).context("invalid browser provider tab_id")?;
        anyhow::ensure!(
            !target.target_id.is_empty()
                && target.target_id.len() <= 512
                && !target.target_id.chars().any(char::is_control),
            "browser provider target_id must contain 1..512 non-control characters"
        );
        anyhow::ensure!(
            parsed_targets.insert(tab_id, target.target_id).is_none(),
            "duplicate browser provider tab_id"
        );
    }
    Ok(BrowserProviderRegistration {
        provider_id,
        endpoint: parsed.to_string(),
        authentication,
        targets: parsed_targets,
    })
}

fn browser_provider_json(snapshot: Option<BrowserProviderSnapshot>) -> Value {
    let Some(snapshot) = snapshot else {
        return json!({"available":false,"revision":0,"targets":[]});
    };
    let targets = snapshot
        .targets
        .into_iter()
        .map(|(tab_id, target_id)| json!({"tab_id":tab_id,"target_id":target_id}))
        .collect::<Vec<_>>();
    json!({
        "available":true,
        "provider_id":snapshot.provider_id,
        "endpoint":snapshot.endpoint,
        "authentication":snapshot.authentication.name(),
        "revision":snapshot.revision,
        "clients":snapshot.clients,
        "targets":targets,
    })
}

fn handle_browser_frame_presented(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    frame_seq: u64,
) -> anyhow::Result<Value> {
    if !mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY) {
        anyhow::bail!(
            "browser frame presentation requires client capability \
             {GUARDED_BROWSER_POINTER_CAPABILITY}"
        );
    }
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    let owner = mux.control_clients.browser_pointer_owner(client)?;
    let accepted = surface.browser_acknowledge_pointer_frame_from(owner, frame_seq);
    Ok(json!({ "accepted": accepted }))
}

fn parse_notification_level(level: &str) -> anyhow::Result<NotificationLevel> {
    match level {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("bad level {other}"),
    }
}

fn parse_agent_state(state: &str) -> anyhow::Result<AgentState> {
    match state {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("bad state {other}"),
    }
}

fn parse_agent_source(source: &str) -> anyhow::Result<AgentSource> {
    match source {
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("bad source {other}; raw report-agent accepts only socket or hook"),
    }
}

fn agent_json(record: &AgentRecord) -> Value {
    json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
        "agent": record.agent,
        "updated_at_ms": record.updated_at_ms,
    })
}

fn parse_hex_color(value: &str) -> anyhow::Result<Rgb> {
    let bytes = value.as_bytes();
    if bytes.len() != 7 || bytes[0] != b'#' {
        anyhow::bail!("bad color {value:?} (want \"#rrggbb\")");
    }
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        Ok((nibble(bytes[idx])? << 4) | nibble(bytes[idx + 1])?)
    };
    Ok(Rgb { r: hex(1)?, g: hex(3)?, b: hex(5)? })
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

fn spawn_attach_notification_stream(
    mux: Arc<Mux>,
    surface_id: SurfaceId,
    writer: MessageWriter,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    let events = mux.subscribe_attached_surface(surface_id);
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            let interrupt = StreamInterrupt::new();
            writer.register_interrupt(&interrupt);
            outbound_stream.register_interrupt(&interrupt);
            lifecycle.register_interrupt(&interrupt);
            events.wake_on(&interrupt);
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                let event = match events.recv_until_interrupted(&interrupt) {
                    Ok(event) => event,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                let value = match event {
                    MuxEvent::Notification(notification)
                        if notification.surface == Some(surface_id) =>
                    {
                        json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        })
                    }
                    MuxEvent::ScrollChanged { surface, offset, at_bottom }
                        if surface == surface_id =>
                    {
                        json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        })
                    }
                    _ => continue,
                };
                if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            if events.overflowed() {
                lifecycle.mark_overflow();
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
        })
        .map(|_| ())
}

struct MarkedClientAttach {
    lease: Option<String>,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
    client_changed: Option<(Option<String>, Option<String>)>,
    resize_reservation: Option<u64>,
    resize_completion: Option<std::sync::mpsc::Receiver<Result<(), Arc<str>>>>,
}

fn mark_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, false)
}

fn mark_resource_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, true)
}

fn mark_client_attached_with_lease_policy(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
    require_lease: bool,
) -> anyhow::Result<MarkedClientAttach> {
    let lease = if require_lease {
        Some(mux.control_clients.attach_surface_with_required_lease(
            client,
            surface,
            stream.clone(),
        )?)
    } else {
        mux.control_clients.attach_surface(client, surface, stream.clone())?
    };
    if let Some((cols, rows)) = initial_size {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let is_browser = mux.surface(surface).is_some_and(|surface| surface.as_browser().is_some());
        let (completion_tx, completion_rx) = std::sync::mpsc::sync_channel(1);
        let mut previous_view_size = None;
        let resize = if let Some(lease) = lease.as_deref() {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.prepare_view_resize(client, surface, lease, (cols, rows))? {
                ViewResizePreparation::GeometryOwner { update, previous_view_size: previous } => {
                    previous_view_size = Some(previous);
                    mux.resize_surface_for_prepared_control_client_with_completion(
                        surface,
                        client,
                        (cols, rows),
                        is_browser.then_some(completion_tx),
                        Some(update),
                    )
                }
                ViewResizePreparation::Passive { changed, name, kind } => {
                    return Ok(MarkedClientAttach {
                        lease: Some(lease.to_string()),
                        size_rollback: None,
                        client_changed: changed.then_some((name, kind)),
                        resize_reservation: None,
                        resize_completion: None,
                    });
                }
                ViewResizePreparation::Superseded => {
                    anyhow::bail!("view attachment was superseded before initial sizing");
                }
            }
        } else {
            mux.resize_surface_for_control_client_with_completion(
                surface,
                client,
                cols,
                rows,
                is_browser.then_some(completion_tx),
            )
        }
        .inspect_err(|_| {
            if let (Some(lease), Some(previous)) = (lease.as_deref(), previous_view_size) {
                mux.control_clients.restore_view_size(client, surface, lease, previous);
            }
            cleanup_failed_attach(mux, client, surface, stream.id);
        })?;
        let Some((changed, name, kind, _)) = resize.attached else {
            cleanup_failed_attach(mux, client, surface, stream.id);
            anyhow::bail!("client {client} is not attached to surface {surface}");
        };
        let mut resize_reservation = resize.reservation_id;
        let mut resize_completion = is_browser.then_some(completion_rx);
        let effective_size = resize.effective_size;
        let rollback = resize.rollback;
        if resize_reservation.is_none()
            && let Some((effective_cols, effective_rows)) = effective_size
        {
            let Some(attached_surface) = mux.surface(surface) else {
                rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                anyhow::bail!("surface {surface} disappeared while sizing before attach");
            };
            match attached_surface.pending_resize_completion(effective_cols, effective_rows) {
                Ok(Some(pending)) => {
                    resize_reservation = Some(pending.reservation);
                    resize_completion = Some(pending.completion);
                }
                Ok(None) => {}
                Err(error) => {
                    rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                    return Err(error);
                }
            }
        }
        return Ok(MarkedClientAttach {
            lease,
            size_rollback: Some(rollback),
            client_changed: changed.then_some((name, kind)),
            resize_reservation,
            resize_completion,
        });
    }
    Ok(MarkedClientAttach {
        lease,
        size_rollback: None,
        client_changed: None,
        resize_reservation: None,
        resize_completion: None,
    })
}

fn wait_for_initial_browser_resize(
    completion: &std::sync::mpsc::Receiver<Result<(), Arc<str>>>,
    surface: SurfaceId,
    reservation: u64,
) -> anyhow::Result<()> {
    match completion.recv_timeout(INITIAL_BROWSER_RESIZE_TIMEOUT) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => {
            anyhow::bail!(
                "failed to size browser surface {surface} before attach (reservation {reservation}): {error}"
            )
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            anyhow::bail!("timed out sizing browser surface {surface} before attach");
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            anyhow::bail!(
                "browser resize completion disconnected before attach (surface {surface}, reservation {reservation})"
            )
        }
    }
}

fn announce_client_attached(mux: &Mux, client: u64) -> anyhow::Result<bool> {
    if let Some((transport, name, kind)) = mux.control_clients.announce_attached(client)? {
        mux.emit(MuxEvent::ClientAttached { client, transport, name, kind });
        return Ok(true);
    }
    Ok(false)
}

/// `attach-surface` result: the view lease when negotiated and, for a
/// `shared-sizing-v1` client on a terminal, this view's host participant id
/// and the current size state.
fn attach_response(mux: &Mux, surface: SurfaceId, client: u64, lease: Option<String>) -> Value {
    let mut response = json!({});
    if let Some(lease) = lease {
        response["lease"] = json!(lease);
    }
    if mux.control_clients.supports_capability(client, SHARED_SIZING_CAPABILITY)
        && let Some(participant) = mux.terminal_view_participant_id(surface, client)
        && let Some(state) = mux.terminal_size_state(surface)
    {
        response["participant"] = json!(participant);
        response["size_state"] = size_state_for_client(mux, client, &state);
    }
    response
}

fn validate_relay_view(view: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !view.is_empty() && view.len() <= 128 && !view.chars().any(char::is_control),
        "bad request: view must be 1-128 printable characters"
    );
    Ok(())
}

fn commit_client_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    changed: Option<(Option<String>, Option<String>)>,
    rollback: Option<crate::mux::ClientSizeRollback>,
) -> anyhow::Result<()> {
    mux.control_clients.commit_surface(client, surface, stream, rollback)?;
    // Attaching is activity: the view joins the terminal's sizing engine and,
    // once it has a viewport, takes the grid under the default policy. The
    // attaching client reads the resulting state from the attach response.
    mux.sync_terminal_client_view(surface, client);
    let newly_announced = announce_client_attached(mux, client)?;
    if !newly_announced && let Some((name, kind)) = changed {
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(())
}

struct AttachWorkerCommit {
    start: std::sync::mpsc::SyncSender<()>,
    lifecycle: AttachLifecycle,
    changed: Option<(Option<String>, Option<String>)>,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
}

fn commit_client_attach_and_start_worker(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    worker: AttachWorkerCommit,
) -> anyhow::Result<()> {
    if let Err(error) =
        commit_client_attach(mux, client, surface, stream, worker.changed, worker.size_rollback)
    {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        return Err(error);
    }
    if worker.start.send(()).is_err() {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        anyhow::bail!("attach output worker exited before stream {stream} was committed");
    }
    Ok(())
}

fn cleanup_failed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    }
}

fn rollback_failed_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
) {
    let detached = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        mux.control_clients.detach_surface(client, surface, stream)
    };
    if detached.final_stream {
        // A failed first attach is one transaction: restore the geometry that
        // preceded its provisional size report before removing the report.
        // Final-stream detach has no surviving view to promote, so the
        // generic geometry-replacement marker must not suppress this rollback.
        if let Some(size_rollback) = detached.rollback.or(size_rollback) {
            mux.rollback_surface_size_client(surface, client, size_rollback);
        }
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(size_rollback) = detached.rollback.or(size_rollback) {
        mux.rollback_surface_size_client(surface, client, size_rollback);
    }
}

fn detach_committed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(rollback) = detached.rollback {
        // Rollback performs its own report-order-checked lifecycle transaction.
        // Release this transaction first so legacy multi-stream clients cannot
        // recursively acquire the non-reentrant lifecycle mutex.
        drop(lifecycle);
        mux.rollback_surface_size_client(surface, client, rollback);
    }
}

fn apply_view_geometry_replacement(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    replacement: Option<(u16, u16)>,
) {
    if let Some((cols, rows)) = replacement {
        let _ = mux.resize_surface_for_client_with_reservation(surface, client, cols, rows);
    } else {
        mux.remove_surface_size_client(surface, client);
    }
}

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
        Command::SubscribeActivity => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("subscribe-activity requires a trusted local connection");
            }
            mux.activity.subscribe(mux, client, writer)
        }
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
        } => image_paste::ImagePasteRequest {
            surface,
            terminal_id,
            lease,
            upload_id,
            op,
            mime,
            size,
            offset,
            data,
        }
        .handle(mux, client),
        Command::SetTerminalCommandHistory { enabled } => {
            cmd_terminals::set_terminal_command_history(mux, client, enabled)
        }
        Command::ServerStats { include } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("server stats requires a trusted local connection");
            }
            Ok(serde_json::to_value(server_stats::server_stats(mux, include.as_deref()))?)
        }
        Command::BrowserHostProvider => browser_host_command::run(mux, client),
        Command::Identify => {
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "app": "cmux-tui",
                "version": env!("CARGO_PKG_VERSION"),
                "build_commit": stamped_build_commit(),
                "ghostty_commit": stamped_ghostty_commit(),
                "protocol": PROTOCOL_VERSION,
                "capabilities": identify_capabilities(mux),
                "session": mux.session,
                "pid": std::process::id(),
                "session_id": registry_id,
                "machine_name": crate::machine_name::machine_name(),
                "registry_id": registry_id,
                "generation": generation,
                "workspace_revision": mux.with_state(|state| state.workspace_revision),
                "terminal_revision": mux.terminal_registry_snapshot()?.revision,
                "daemon_handoff": 1,
                "lifecycle_ready": mux.server_lifecycle_ready(),
                "launch_snapshot_path": mux.launch_snapshot_path(),
            }))
        }
        Command::ShutdownDaemon { pid, generation, force, end_terminals, keep_layout } => {
            anyhow::ensure!(
                end_terminals || !keep_layout,
                "bad request: keep_layout requires end_terminals"
            );
            let actual_identity = mux.begin_daemon_handoff(
                client,
                DaemonHandoffRequest::fenced(pid, generation, force),
            )?;
            // The fenced handoff reservation is held, so no second shutdown
            // can start while the hosts end. A failure releases it and keeps
            // this daemon serving.
            let ended_terminals = if end_terminals {
                let ended = if keep_layout {
                    mux.end_all_terminals_keeping_layout()
                } else {
                    mux.end_all_terminals()
                };
                match ended {
                    Ok(ended) => Some(ended.len()),
                    Err(error) => {
                        mux.cancel_daemon_handoff(client);
                        return Err(error);
                    }
                }
            } else {
                None
            };
            Ok(json!({
                "accepted": true,
                "pid": actual_identity.pid,
                "generation": actual_identity.generation,
                "ended_terminals": ended_terminals,
            }))
        }
        Command::Ping => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "build_commit": stamped_build_commit(),
            "ghostty_commit": stamped_ghostty_commit(),
            "protocol": PROTOCOL_VERSION,
        })),
        Command::SetClientInfo {
            name,
            kind,
            capabilities,
            user_id,
            display_name,
            device_kind,
            device_name,
            device_id,
        } => {
            let identity =
                ClientIdentityWire { user_id, display_name, device_kind, device_name, device_id };
            let identity_changed = !identity.is_empty();
            let (name, kind) = mux.control_clients.set_info(client, name, kind, capabilities)?;
            if identity_changed {
                mux.control_clients.set_sizing_identity(client, identity);
            }
            mux.refresh_terminal_client_identity(client);
            mux.emit(MuxEvent::ClientChanged { client, name, kind });
            Ok(json!({}))
        }
        Command::ListClients => Ok(mux.control_clients_json(client)),
        Command::MachineUsage => Ok(machine_usage_json(mux.machine_usage().as_ref())),
        Command::MachineListeningTcp => machine_listening_tcp_json(),
        Command::RegisterBrowserProvider {
            provider_id,
            endpoint,
            authentication,
            bearer_token,
            targets,
        } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider registration requires a trusted local connection");
            }
            let registration = browser_provider_registration(
                provider_id,
                endpoint,
                authentication,
                bearer_token,
                targets,
            )?;
            let snapshot = mux.register_browser_provider(client, registration)?;
            Ok(browser_provider_json(Some(snapshot)))
        }
        Command::GetBrowserProvider => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider discovery requires a trusted local connection");
            }
            Ok(browser_provider_json(mux.browser_provider_snapshot()))
        }
        Command::UnregisterBrowserProvider => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider registration requires a trusted local connection");
            }
            Ok(json!({"removed":mux.unregister_browser_provider(client)}))
        }
        Command::ListTerminals => cmd_terminals::list_terminals(mux),
        Command::TerminalEvents { after_revision } => {
            cmd_terminals::terminal_events(mux, after_revision)
        }
        Command::SetClientSizing { surface, client: target, enabled, exclusive } => {
            if exclusive && !enabled {
                anyhow::bail!("exclusive client sizing must be enabled");
            }
            get_surface(mux, surface)?;
            if exclusive && target.is_none() {
                mux.use_only_client_size(surface, client).ok_or_else(|| {
                    anyhow::anyhow!(
                        "client {client} is not attached with a reported size for surface {surface}"
                    )
                })?;
                return Ok(json!({}));
            }
            if let Some(target) = target {
                if exclusive {
                    mux.use_only_client_size(surface, target).ok_or_else(|| {
                        anyhow::anyhow!(
                            "client {target} is not attached with a reported size for surface {surface}"
                        )
                    })?;
                } else {
                    mux.set_client_size_participation(surface, target, enabled).ok_or_else(
                        || anyhow::anyhow!("client {target} is not attached to surface {surface}"),
                    )?;
                }
            } else if enabled {
                mux.use_all_client_sizes(surface)
                    .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            } else {
                anyhow::bail!("client is required when disabling sizing");
            }
            Ok(json!({}))
        }
        Command::PairingResponse { request, approve } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("pairing decisions require a trusted local connection");
            } else if approve && !origin_gate::may_approve_pairing(mux, client) {
                anyhow::bail!(origin_gate::PAIRING_APPROVAL_NEEDS_HUMAN);
            }
            if !mux.respond_pairing(request, approve) {
                anyhow::bail!("unknown or expired pairing request {request}");
            }
            Ok(json!({}))
        }
        Command::DetachClient { client: target, by, surface } => {
            let by = detach_actor(mux, client, by);
            if let Some((owner, placement)) = own_view_detach_target(mux, &target, surface) {
                // The view leaves; the connection, its stream and its relay
                // sub-views stay (docs/shared-terminal-sizing.md).
                detach_own_view(mux, owner, placement, by);
                return Ok(json!({"scope": "view"}));
            }
            if let DetachClientTarget::Participant(participant) = &target
                && let Some((relay, placement, Some(view))) = match surface {
                    Some(surface) => mux.terminal_participant_member_on(surface, participant),
                    None => mux.terminal_participant_member(participant),
                }
            {
                // A relay sub-view leaves alone; its relay stays attached and
                // forwards the notice to that leaf only.
                mux.detach_terminal_sub_view(placement, relay, &view);
                let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
                mux.control_clients.send_surface_event(
                    relay,
                    placement,
                    None,
                    &detached_event_json(placement, &notice, Some(&view)),
                );
                return Ok(json!({}));
            }
            let target_client = match &target {
                DetachClientTarget::Client(target) => Some(*target),
                DetachClientTarget::Participant(participant) => {
                    target.whole_client().or_else(|| {
                        mux.terminal_participant_member(participant).map(|member| member.0)
                    })
                }
            };
            let Some(target_client) = target_client else {
                match target {
                    DetachClientTarget::Participant(participant) => {
                        anyhow::bail!("unknown participant {participant}")
                    }
                    DetachClientTarget::Client(target) => anyhow::bail!("unknown client {target}"),
                }
            };
            if target_client == client {
                if !mux.control_clients.contains(target_client) {
                    anyhow::bail!("unknown client {target_client}");
                }
            } else if !kick_client(mux, target_client, by) {
                anyhow::bail!("unknown client {target_client}");
            }
            Ok(json!({}))
        }
        Command::SetSizePolicy { surface, workspace, policy } => match (surface, workspace) {
            (Some(surface), None) => {
                get_surface(mux, surface)?;
                let state = mux
                    .set_terminal_size_policy(surface, policy)
                    .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
                Ok(json!({"state": size_state_for_client(mux, client, &state)}))
            }
            (None, Some(workspace)) => {
                mux.set_workspace_size_policy(workspace, policy)?;
                Ok(json!({}))
            }
            _ => anyhow::bail!(
                "bad request: set-size-policy needs exactly one of surface or workspace"
            ),
        },
        Command::SetSizeCounts { surface, client: target, lease, view, participant, counts } => {
            get_surface(mux, surface)?;
            let selectors = usize::from(target.is_some())
                + usize::from(lease.is_some())
                + usize::from(view.is_some())
                + usize::from(participant.is_some());
            anyhow::ensure!(
                selectors <= 1,
                "bad request: set-size-counts takes at most one of client, lease, view or participant"
            );
            let participant = if let Some(participant) = participant {
                participant
            } else if let Some(view) = view {
                crate::mux::sub_view_participant_id(client, &view)
            } else {
                if let Some(lease) = &lease {
                    match mux.control_clients.view_lease_status(client, surface, lease)? {
                        ViewLeaseStatus::Current { .. } => {}
                        ViewLeaseStatus::Superseded => return Ok(json!({"outcome": "superseded"})),
                    }
                }
                mux.terminal_view_participant_id(surface, target.unwrap_or(client))
                    .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?
            };
            let changed = mux
                .set_terminal_size_counts(surface, &participant, counts)
                .ok_or_else(|| anyhow::anyhow!("unknown participant {participant}"))?;
            Ok(json!({"outcome": "applied", "changed": changed, "participant": participant}))
        }
        Command::NoteSizeActivity { surface, view } => {
            anyhow::ensure!(
                mux.control_clients.supports_capability(client, SHARED_SIZING_CAPABILITY),
                "note-size-activity requires client capability {SHARED_SIZING_CAPABILITY}"
            );
            get_surface(mux, surface)?;
            let participant = match view.as_deref() {
                Some(view) => crate::mux::sub_view_participant_id(client, view),
                None => mux
                    .terminal_view_participant_id(surface, client)
                    .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?,
            };
            let changed = mux
                .note_terminal_activity(surface, client, view.as_deref())
                .ok_or_else(|| anyhow::anyhow!("unknown participant {participant}"))?;
            Ok(json!({"participant": participant, "changed": changed}))
        }
        Command::ReattachView { surface, counts } => {
            get_surface(mux, surface)?;
            let participant = mux.reattach_terminal_own_view(surface, client, counts)?;
            let state = mux
                .terminal_size_state(surface)
                .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
            Ok(json!({
                "participant": participant,
                "state": size_state_for_client(mux, client, &state),
            }))
        }
        Command::GetSizeState { surface } => {
            get_surface(mux, surface)?;
            let state = mux
                .terminal_size_state(surface)
                .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
            let self_participant = mux
                .terminal_view_participant_id(surface, client)
                .filter(|id| state.participant(id).is_some());
            Ok(json!({
                "state": size_state_for_client(mux, client, &state),
                "self_participant": self_participant,
            }))
        }
        Command::ReloadConfig => {
            mux.request_config_reload()?;
            Ok(json!({
                "reloaded": true,
                "path": platform::config_path().map(|path| path.display().to_string()),
            }))
        }
        Command::SetWindowTitle { title } => {
            mux.emit(MuxEvent::WindowTitleRequested(title));
            Ok(json!({}))
        }
        Command::ClearWindowTitle => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            Ok(json!({}))
        }
        Command::ListWorkspaces => cmd_workspaces::list_workspaces(mux),
        Command::GetFrontendProjection { frontend, scope, subject_key } => {
            let projection = mux.get_frontend_projection(&frontend, &scope, &subject_key)?;
            Ok(match projection {
                Some(projection) => serde_json::to_value(projection)?,
                None => json!({
                    "frontend": frontend,
                    "scope": scope,
                    "subject_key": subject_key,
                    "schema_version": 0,
                    "projection_revision": 0,
                    "projection": null,
                }),
            })
        }
        Command::PutFrontendProjection {
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        } => {
            let workspace_mutation = workspace_mutation(mux, client, &mutation)?;
            let commit = mux.put_frontend_projection(
                &workspace_mutation,
                &frontend,
                &scope,
                &subject_key,
                schema_version,
                expected_projection_revision,
                &projection,
            )?;
            let mut value = serde_json::to_value(commit.projection)?;
            value["replayed"] = json!(commit.replayed);
            Ok(value)
        }
        Command::JournalFrontendEvent { event } => {
            let session_id = mux.session_public_id();
            let principal_id = public_client_id(&session_id, client)?.to_string();
            mux.journal_frontend_event(principal_id, event)?;
            Ok(json!({"committed":true}))
        }
        Command::ExportLayout { screen } => cmd_panes::export_layout(mux, screen),
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            cmd_panes::apply_layout(mux, actor, workspace, name, layout, cols, rows)
        }
        Command::Send { surface, text, bytes, paste } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            if paste {
                let mut payload = text.unwrap_or_default().into_bytes();
                if let Some(b64) = bytes {
                    payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
                }
                surface.write_paste(&payload)?;
            } else {
                if let Some(text) = text {
                    surface.write_bytes(text.as_bytes())?;
                }
                if let Some(b64) = bytes {
                    let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                    surface.write_bytes(&raw)?;
                }
            }
            mux.note_terminal_input(surface.id, client);
            Ok(json!({}))
        }
        Command::ReadScreen { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = surface.try_with_terminal(|t| t.viewport_text())??;
            Ok(json!({ "text": text }))
        }
        Command::ClearHistory { surface, fallback_key } => {
            let surface =
                get_surface(mux, surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
            require_pty(&surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
            let fallback_key = fallback_key
                .map(KeyInput::try_from)
                .transpose()
                .map_err(DeliveryClassifiedError::known_not_delivered)?;
            surface
                .clear_history_or_encode_key_classified(fallback_key.as_ref())
                .map_err(DeliveryClassifiedError::from)?;
            Ok(json!({}))
        }
        Command::ReadScrollback { surface, start, count } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let count = u16::try_from(count).map_err(|_| anyhow::anyhow!("count out of range"))?;
            let (start, total, epoch, rows) = surface.try_with_terminal(|term| {
                let total = term.history_rows();
                let start = start.min(total);
                let epoch = term.history_epoch();
                term.styled_history_rows(start, count).map(|rows| (start, total, epoch, rows))
            })??;
            let runs = rows_to_runs(&rows);
            let rows = runs
                .iter()
                .enumerate()
                .map(|(row, runs)| {
                    json!({
                        "row": row as u16,
                        "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({ "rows": rows, "start": start, "total": total, "epoch": epoch }))
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            Ok(sidebar_plugin_status_json(mux.ensure_sidebar_plugin(cols, rows, relaunch)))
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            let cancelled = || cancellation.is_some_and(ConnectionCancellation::is_cancelled);
            if cancelled() {
                anyhow::bail!("connection closed while waiting for pattern");
            }
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
            let start = Instant::now();
            let check = || -> anyhow::Result<Option<String>> {
                let text = surface.try_with_terminal(|t| t.viewport_text())??;
                Ok(regex.is_match(&text).then_some(text))
            };
            if timeout_ms == 0 {
                if let Some(text) = check()? {
                    return Ok(json!({
                        "matched": true,
                        "text": text,
                        "elapsed_ms": start.elapsed().as_millis() as u64,
                    }));
                }
                anyhow::bail!("timeout waiting for pattern");
            }
            let deadline = start + Duration::from_millis(timeout_ms);
            let attach = surface.attach_stream()?;
            // The wait ends on output, the deadline, or the connection
            // closing; it used to wake every 100 ms to check the last.
            let interrupt = StreamInterrupt::new();
            if let Some(cancellation) = cancellation {
                cancellation.register_interrupt(&interrupt);
            }
            attach.stream.wake_on(&interrupt);
            if let Some(text) = check()? {
                return Ok(json!({
                    "matched": true,
                    "text": text,
                    "elapsed_ms": start.elapsed().as_millis() as u64,
                }));
            }
            loop {
                if cancelled() {
                    anyhow::bail!("connection closed while waiting for pattern");
                }
                let now = Instant::now();
                if now >= deadline {
                    anyhow::bail!("timeout waiting for pattern");
                }
                match attach.stream.recv_interruptible(&interrupt, Some(deadline)) {
                    Ok(_) => {
                        if let Some(text) = check()? {
                            return Ok(json!({
                                "matched": true,
                                "text": text,
                                "elapsed_ms": start.elapsed().as_millis() as u64,
                            }));
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if Instant::now() >= deadline {
                            anyhow::bail!("timeout waiting for pattern");
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                }
            }
        }
        Command::Run { argv, command, cwd, pane, new_workspace, key, name, cols, rows } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => argv,
                (None, Some(command)) if !command.is_empty() => {
                    vec![platform::default_shell(), "-lc".to_string(), command]
                }
                _ => anyhow::bail!("argv or command is required"),
            };
            if new_workspace && pane.is_some() {
                anyhow::bail!("pane and new_workspace are mutually exclusive");
            }
            if key.is_some() && !new_workspace {
                anyhow::bail!("key requires new_workspace");
            }
            let result = mux.run_command_result_with_options_as(
                &actor,
                argv,
                crate::mux::RunCommandOptions {
                    pane,
                    new_workspace,
                    workspace_key: key,
                    cwd,
                    name,
                    size: optional_surface_size(cols, rows),
                },
            )?;
            let placement = result.placement;
            let already_exited = result.terminal.lifecycle == TerminalLifecycle::Exited;
            Ok(json!({
                "surface": placement.as_ref().map(|placement| placement.surface),
                "terminal_id": result.terminal.terminal_id,
                "terminal_incarnation": result.terminal.incarnation,
                "pane": placement.as_ref().map(|placement| placement.pane),
                "screen": placement.as_ref().map(|placement| placement.screen),
                "workspace": placement.as_ref().map(|placement| placement.workspace),
                "lifecycle": result.terminal.lifecycle,
                "exit": result.terminal.exit,
                "terminal_revision": result.terminal_revision,
                "already_exited": already_exited,
            }))
        }
        Command::CreateSurfaceWithReceipt(request) => {
            create_surface_with_receipt(mux, client, *request)
        }
        Command::SendKey { surface, keys } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
            if keys.is_empty() {
                anyhow::bail!("bad request: keys must be non-empty");
            }
            let mut encoder = KeyEncoder::new()?;
            let mut encoded = Vec::new();
            surface.scroll_to_bottom()?;
            surface.try_with_terminal(|term| {
                encoder.sync_from_terminal(term);
                for key in &keys {
                    let Some(input) = key_input_from_chord(key) else {
                        return Err(anyhow::anyhow!("unknown key {key}"));
                    };
                    encoder.encode(&input, &mut encoded).map_err(anyhow::Error::from)?;
                }
                Ok::<(), anyhow::Error>(())
            })??;
            surface.write_bytes(&encoded)?;
            mux.note_terminal_input(surface.id, client);
            Ok(json!({}))
        }
        Command::Copy { surface, mode } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = match mode.as_str() {
                "screen" => surface.try_with_terminal(|t| t.viewport_text())??,
                "scrollback" => surface.try_with_terminal(|t| t.plain_text())??,
                "selection" => {
                    surface.selection_text().ok_or_else(|| anyhow::anyhow!("no selection"))?
                }
                other => anyhow::bail!("bad mode {other}"),
            };
            Ok(json!({ "text": text, "mode": mode }))
        }
        Command::Ids { kind } => mux.with_state(|state| ids_json(state, kind.as_deref())),
        Command::Notify { title, body, level, surface, source } => {
            if title.is_empty() {
                anyhow::bail!("title is required");
            }
            let level = parse_notification_level(level.as_deref().unwrap_or("info"))?;
            let source = match source.as_deref() {
                None => NotificationSource::Cli,
                Some(source) => NotificationSource::parse(source)
                    .ok_or_else(|| anyhow::anyhow!("bad source {source}"))?,
            };
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let notification =
                mux.post_notification_as(&actor, title, body, level, surface, source)?;
            Ok(json!({ "notification": notification }))
        }
        Command::ListAgents { surface, state } => {
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let state = match state {
                Some(state) => Some(parse_agent_state(&state)?),
                None => None,
            };
            let agents = mux.list_agents(surface, state).iter().map(agent_json).collect::<Vec<_>>();
            Ok(json!({ "agents": agents }))
        }
        Command::ReportAgent { surface, state, source, session } => {
            get_surface(mux, surface)?;
            let state = parse_agent_state(&state)?;
            let source = parse_agent_source(&source)?;
            let record = mux.report_agent(surface, state, source, session)?;
            Ok(json!({
                "surface": record.surface,
                "state": record.state.as_str(),
                "source": record.source.as_str(),
                "session": record.session,
            }))
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
        Command::GetCellPixels => {
            let (width_px, height_px) = mux.cell_pixel_creation_size();
            let surfaces = mux.with_state(|state| {
                state
                    .surfaces
                    .values()
                    .map(|surface| {
                        let (width_px, height_px) = surface.cell_pixel_size();
                        json!({
                            "surface": surface.id,
                            "width_px": width_px,
                            "height_px": height_px,
                        })
                    })
                    .collect::<Vec<_>>()
            });
            Ok(json!({
                "width_px": width_px,
                "height_px": height_px,
                "surfaces": surfaces,
            }))
        }
        Command::SetCellPixels { width_px, height_px } => {
            let update = mux.set_cell_pixel_size(width_px, height_px);
            let resizes = update
                .resizes
                .into_iter()
                .map(|(surface, (cols, rows), reservation_id)| {
                    json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "reservation_id": reservation_id,
                    })
                })
                .collect::<Vec<_>>();
            let failures = update
                .failures
                .into_iter()
                .map(|failure| {
                    json!({
                        "surface": failure.surface,
                        "error": failure.error,
                        "deferred": failure.deferred,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"resizes": resizes, "failures": failures}))
        }
        Command::BrowserFramePresented { surface, frame_seq } => {
            handle_browser_frame_presented(mux, client, surface, frame_seq)
        }
        cmd @ (Command::BrowserMouse { .. }
        | Command::BrowserMouseGuarded { .. }
        | Command::BrowserWheel { .. }
        | Command::BrowserWheelGuarded { .. }
        | Command::BrowserKey { .. }
        | Command::BrowserKeyPress { .. }
        | Command::BrowserInsertText { .. }) => browser_input::handle(mux, client, cmd),
        Command::BrowserNavigate { surface, url } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            mux.navigate_browser_surface(&surface, &url)?;
            Ok(json!({}))
        }
        Command::BrowserBack { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_back()?;
            Ok(json!({}))
        }
        Command::BrowserForward { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_forward()?;
            Ok(json!({}))
        }
        Command::BrowserReload { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_reload()?;
            Ok(json!({}))
        }
        Command::BrowserActivate { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_activate()?;
            Ok(json!({}))
        }
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
        Command::ListNotifications { limit } => {
            let rows = mux.notification_rows(limit.unwrap_or(256).min(256))?;
            Ok(json!({
                "notifications": rows
                    .iter()
                    .map(|(row, acknowledged)| {
                        json!({
                            "id": row.id,
                            "title": row.title,
                            "subtitle": row.subtitle,
                            "body": row.body,
                            "level": row.level.as_str(),
                            "terminal_id": row.terminal_id,
                            "surface": row.surface,
                            "created_at_ms": row.created_at_ms,
                            "source": row.source.as_str(),
                            "acknowledged": acknowledged,
                        })
                    })
                    .collect::<Vec<_>>(),
            }))
        }
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
        Command::ListPersonal => personal::list(mux),
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
        } => personal::create_profile(
            mux,
            crate::workspace_registry::ProfileInput {
                id: profile,
                name,
                color,
                icon,
                theme,
                index,
                browser_profile_id,
                default_session_id,
                defaults,
                follows,
            },
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
        } => personal::update_profile(
            mux,
            &profile,
            crate::workspace_registry::ProfileUpdate {
                name,
                color,
                icon,
                theme,
                browser_profile_id,
                default_session_id,
                defaults,
            },
        ),
        Command::MoveProfile { profile, index } => personal::move_profile(mux, &profile, index),
        Command::DeleteProfile { profile, move_to } => {
            personal::delete_profile(mux, client, &profile, move_to.as_deref())
        }
        Command::SetProfileFollows { profile, session_ids } => {
            personal::set_profile_follows(mux, &profile, &session_ids)
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
        } => personal::put_session(
            mux,
            &session_id,
            machine_name.as_deref(),
            session_name.as_deref(),
            &transport,
            capabilities.as_ref(),
            follow_with.as_deref(),
        ),
        Command::ForgetSession { session_id, force } => {
            personal::forget_session(mux, &session_id, force)
        }
        Command::ImportSessionOrganization { session_id, groups, workspaces } => {
            personal::import_session_organization(mux, &session_id, groups, workspaces)
        }
        Command::CreatePersonalGroup { name, group, profile, color, collapsed, index } => {
            personal::create_group(
                mux,
                group,
                profile.as_deref(),
                &name,
                color.as_deref(),
                collapsed,
                index,
            )
        }
        Command::UpdatePersonalGroup { group, name, color, collapsed, profile } => {
            personal::update_group(
                mux,
                &group,
                name.as_deref(),
                color,
                collapsed,
                profile.as_deref(),
            )
        }
        Command::DeletePersonalGroup { group } => personal::delete_group(mux, client, &group),
        Command::MovePersonalGroup { group, index } => personal::move_group(mux, &group, index),
        Command::SetPersonalWorkspace {
            session_id,
            workspace_key,
            index,
            group,
            browser_profile_id,
            theme,
        } => personal::set_workspace(
            mux,
            &session_id,
            &workspace_key,
            crate::workspace_registry::PersonalWorkspaceUpdate {
                index,
                group,
                browser_profile_id,
                theme,
            },
        ),
        Command::SetPersonalTerminal { session_id, terminal_key, theme } => {
            personal::set_terminal(mux, &session_id, &terminal_key, theme.as_deref())
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
        } => {
            let current = mux.default_colors();
            let base = if complete { DefaultColors::default() } else { current };
            let palette = match palette {
                Some(entries) => {
                    let mut palette = [None; 256];
                    for (index, value) in entries {
                        let index = index
                            .parse::<u8>()
                            .map_err(|_| anyhow::anyhow!("invalid palette index {index}"))?;
                        palette[index as usize] = Some(parse_hex_color(&value)?);
                    }
                    palette
                }
                None => base.palette,
            };
            let colors = DefaultColors {
                fg: match fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.fg,
                },
                bg: match bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.bg,
                },
                cursor: match cursor {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.cursor,
                },
                selection_bg: match selection_bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.selection_bg,
                },
                selection_fg: match selection_fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.selection_fg,
                },
                cursor_style: match cursor_style.as_deref() {
                    Some("block") => Some(ghostty_vt::CursorShape::Block),
                    Some("underline") => Some(ghostty_vt::CursorShape::Underline),
                    Some("bar") => Some(ghostty_vt::CursorShape::Bar),
                    Some(value) => anyhow::bail!("invalid cursor style {value}"),
                    None => base.cursor_style,
                },
                cursor_blink: cursor_blink.or(base.cursor_blink),
                palette,
            };
            mux.set_default_colors(colors);
            Ok(json!({}))
        }
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
            let (cols, rows) = clamp_terminal_size(cols, rows);
            if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
                || (!surface_has_view_placement(mux, surface)
                    && mux
                        .control_clients
                        .surface_attachment_is_current_or_retired(client, surface))
            {
                return Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "superseded",
                }));
            }
            // Every live control connection participates through the same
            // client-size reducer. An unattached one-shot resize is removed
            // when its connection closes, so it cannot bypass visible viewers.
            // Recording and reducing happen under the sizing lock so a
            // concurrent detach cannot finish cleanup before this lease exists.
            let resize = match mux
                .resize_surface_for_control_client_with_reservation(surface, client, cols, rows)
            {
                Ok(resize) => resize,
                Err(_)
                    if mux
                        .control_clients
                        .surface_attachment_is_retired_without_current(client, surface)
                        || (!surface_has_view_placement(mux, surface)
                            && mux
                                .control_clients
                                .surface_attachment_is_current_or_retired(client, surface)) =>
                {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                Err(error) => return Err(error),
            };
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({
                "accepted": resize.accepted,
                "reservation_id": resize.reservation_id,
                "outcome": "applied",
            }))
        }
        Command::ResizeAttachedView { surface, lease, view, identity, cols, rows } => {
            let (cols, rows) = clamp_terminal_size(cols, rows);
            let lease = match (lease, view) {
                (Some(lease), None) => lease,
                (None, Some(view)) => {
                    validate_relay_view(&view)?;
                    let (participant, accepted) = mux.report_terminal_sub_view(
                        surface,
                        client,
                        &view,
                        identity.map(ClientIdentityWire::into_identity),
                        Some((cols, rows)),
                    )?;
                    return Ok(json!({
                        "accepted": accepted,
                        "reservation_id": null,
                        "outcome": "applied",
                        "participant": participant,
                    }));
                }
                _ => anyhow::bail!(
                    "bad request: resize-attached-view needs exactly one of lease or view"
                ),
            };
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.view_lease_status(client, surface, &lease)? {
                ViewLeaseStatus::Superseded => {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                ViewLeaseStatus::Current { .. } => {}
            }
            match mux.control_clients.prepare_view_resize(client, surface, &lease, (cols, rows))? {
                ViewResizePreparation::Superseded => Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "superseded",
                })),
                ViewResizePreparation::Passive { .. } => Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "passive",
                })),
                ViewResizePreparation::GeometryOwner { update, previous_view_size } => {
                    let resize = match mux
                        .resize_surface_for_prepared_control_client_with_completion(
                            surface,
                            client,
                            (cols, rows),
                            None,
                            Some(update),
                        ) {
                        Ok(resize) => resize,
                        Err(error) => {
                            mux.control_clients.restore_view_size(
                                client,
                                surface,
                                &lease,
                                previous_view_size,
                            );
                            if !surface_has_view_placement(mux, surface) {
                                return Ok(json!({
                                    "accepted": false,
                                    "reservation_id": null,
                                    "outcome": "superseded",
                                }));
                            }
                            return Err(error);
                        }
                    };
                    if let Some((true, name, kind, _)) = resize.attached {
                        mux.emit(MuxEvent::ClientChanged { client, name, kind });
                    }
                    Ok(json!({
                        "accepted": resize.accepted,
                        "reservation_id": resize.reservation_id,
                        "outcome": "applied",
                    }))
                }
            }
        }
        Command::ReleaseSurfaceSize { surface } => {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
                || (!surface_has_view_placement(mux, surface)
                    && mux
                        .control_clients
                        .surface_attachment_is_current_or_retired(client, surface))
            {
                return Ok(json!({"outcome": "superseded"}));
            }
            let attached = mux.control_clients.clear_size(client, surface);
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            let attached_changed = attached.as_ref().is_some_and(|(changed, _, _)| *changed);
            if attached_changed || (attached.is_none() && had_report) {
                let (name, kind) = attached
                    .map(|(_, name, kind)| (name, kind))
                    .or_else(|| mux.control_clients.client_info(client))
                    .unwrap_or((None, None));
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({"outcome": "applied"}))
        }
        Command::ReleaseAttachedViewSize { surface, lease, view } => {
            let lease = match (lease, view) {
                (Some(lease), None) => lease,
                (None, Some(view)) => {
                    return Ok(match mux.release_terminal_sub_view(surface, client, &view) {
                        Some(_) => json!({"outcome": "applied"}),
                        None => json!({"outcome": "superseded"}),
                    });
                }
                _ => anyhow::bail!(
                    "bad request: release-attached-view-size needs exactly one of lease or view"
                ),
            };
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.view_lease_status(client, surface, &lease)? {
                ViewLeaseStatus::Superseded => {
                    return Ok(json!({"outcome": "superseded"}));
                }
                ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
                    return Ok(json!({"outcome": "superseded"}));
                }
                ViewLeaseStatus::Current { .. } => {}
            }
            match mux.control_clients.release_view_size(client, surface, &lease)? {
                ViewReleasePreparation::Superseded => Ok(json!({"outcome": "superseded"})),
                ViewReleasePreparation::Passive => Ok(json!({"outcome": "passive"})),
                ViewReleasePreparation::GeometryOwner { changed, name, kind } => {
                    let had_report = mux.client_surface_size(surface, client).is_some();
                    if had_report {
                        mux.remove_surface_size_client(surface, client);
                    }
                    if changed || had_report {
                        mux.emit(MuxEvent::ClientChanged { client, name, kind });
                    }
                    Ok(json!({"outcome": "applied"}))
                }
            }
        }
        Command::DetachAttachedView { surface, lease, view } => {
            let lease = match (lease, view) {
                (Some(lease), None) => lease,
                (None, Some(view)) => {
                    return Ok(match mux.detach_terminal_sub_view(surface, client, &view) {
                        Some(_) => json!({"outcome": "applied"}),
                        None => json!({"outcome": "superseded"}),
                    });
                }
                _ => anyhow::bail!(
                    "bad request: detach-attached-view needs exactly one of lease or view"
                ),
            };
            let Some((stream, outbound)) =
                mux.control_clients.view_stream(client, surface, &lease)?
            else {
                return Ok(json!({"outcome": "superseded"}));
            };
            // Closing the stream stops every producer immediately. Removing
            // its attachment state synchronously makes the command response a
            // cleanup fence; the attach worker's eventual duplicate detach is
            // intentionally idempotent.
            outbound.close();
            detach_committed_attach(mux, client, surface, stream);
            Ok(json!({"outcome": "applied"}))
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
            validate_client_focus_id(&client_id)?;
            if !mux.with_state(|state| state.panes.contains_key(&pane)) {
                anyhow::bail!("unknown pane {pane}");
            }
            // A report only writes memory (the session's last reported focus
            // and this client's own record). It never moves the live shared
            // focus, so other attached clients stay where they are.
            mux.record_session_focus(pane, tab);
            mux.remember_client_focus(client_id, pane, tab);
            Ok(json!({}))
        }
        Command::ClientFocus { client_id } => {
            validate_client_focus_id(&client_id)?;
            Ok(match mux.client_focus(&client_id).or_else(|| mux.session_focus()) {
                Some((pane, tab)) => json!({"pane": pane, "tab": tab}),
                None => json!({"pane": null, "tab": null}),
            })
        }
        Command::SnapshotRequest(params) => terminal_snapshot::handle_request(mux, client, params),
        Command::TerminalHistory(params) => cmd_terminals::terminal_history(mux, params),
        Command::TerminalReadRange(params) => cmd_terminals::terminal_read_range(mux, params),
        Command::ScrollSurface { surface, delta } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            mux.scroll_surface_viewport(&surface, delta)?;
            Ok(json!({}))
        }
        Command::Subscribe { tree_events, surface } => {
            let tree_deltas = match tree_events.as_deref().unwrap_or("coarse") {
                "coarse" => false,
                "deltas" => true,
                other => anyhow::bail!("bad request: unsupported tree_events {other:?}"),
            };
            let events = match surface {
                Some(surface) => mux
                    .subscribe_surface_session(surface)
                    .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?,
                None => mux.subscribe(),
            };
            let event_mux = mux.clone();
            let trusted_pairing_client = mux.control_clients.is_unix(client);
            let pending_pairings =
                if trusted_pairing_client { mux.pending_pairings() } else { Vec::new() };
            let writer = writer.clone();
            let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                let mut transport_overflow = false;
                for challenge in pending_pairings {
                    let value = json!({
                        "event": "pairing-requested",
                        "request": challenge.id,
                        "code": challenge.code,
                        "peer": challenge.peer,
                        "expires_in": challenge.expires_in,
                    });
                    if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                let interrupt = StreamInterrupt::new();
                writer.register_interrupt(&interrupt);
                outbound_stream.register_interrupt(&interrupt);
                events.wake_on(&interrupt);
                while writer.is_open() && outbound_stream.is_open() {
                    let event = match events.recv_until_interrupted(&interrupt) {
                        Ok(event) => event,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let value = match &event {
                        MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                            if !trusted_pairing_client =>
                        {
                            continue;
                        }
                        MuxEvent::Conversation(event) if event.is_draft() => continue,
                        MuxEvent::Conversation(_) | MuxEvent::CloudConversation(_)
                            if !trusted_pairing_client =>
                        {
                            continue;
                        }
                        MuxEvent::PairingRequested(challenge) => json!({
                            "event": "pairing-requested",
                            "request": challenge.id,
                            "code": challenge.code,
                            "peer": challenge.peer,
                            "expires_in": challenge.expires_in,
                        }),
                        MuxEvent::PairingResolved { request } => json!({
                            "event": "pairing-resolved",
                            "request": request,
                        }),
                        MuxEvent::TreeDelta(delta) if tree_deltas => {
                            tree_delta_json(delta, &event_mux)
                        }
                        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
                        MuxEvent::TreeSelectionChanged if tree_deltas => {
                            json!({"event": "tree-changed"})
                        }
                        MuxEvent::TreeSelectionChanged => continue,
                        MuxEvent::SizeStateChanged { surface, runtime, state } => {
                            if !event_mux
                                .control_clients
                                .supports_capability(client, SHARED_SIZING_CAPABILITY)
                            {
                                continue;
                            }
                            let open = event_mux
                                .control_clients
                                .supports_capability(client, OPEN_DEVICE_KINDS_CAPABILITY);
                            size_state_event_json(*surface, *runtime, state, Some((client, open)))
                        }
                        _ => subscribed_event_json(&event),
                    };
                    if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                if events.overflowed() || transport_overflow {
                    let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
                }
            })?;
            Ok(json!({}))
        }
        Command::AttachSurface {
            surface: surface_id,
            mode,
            cols,
            rows,
            expected_generation,
            expected_terminal_id,
            snapshot,
        } => {
            let initial_size = match (cols, rows) {
                (Some(cols), Some(rows)) => Some((cols, rows)),
                (None, None) => None,
                _ => anyhow::bail!("attach-surface cols and rows must be supplied together"),
            };
            let surface_id = match surface_id {
                Some(surface) => surface,
                None => {
                    let generation = expected_generation.as_deref().ok_or_else(|| {
                        anyhow::anyhow!(
                            "attachment identity requires generation and terminal together"
                        )
                    })?;
                    anyhow::ensure!(
                        mux.registry_identity().1 == generation,
                        "attachment_generation_mismatch"
                    );
                    let terminal = expected_terminal_id.as_deref().ok_or_else(|| {
                        anyhow::anyhow!(
                            "attachment identity requires generation and terminal together"
                        )
                    })?;
                    let terminal = TerminalPublicId::parse(terminal)
                        .map_err(|_| anyhow::anyhow!("attachment_terminal_mismatch"))?;
                    mux.resource_surface_for_terminal(&terminal)
                        .ok_or_else(|| anyhow::anyhow!("attachment_terminal_mismatch"))?
                }
            };
            let surface = get_surface(mux, surface_id)?;
            anyhow::ensure!(
                !mux.is_frontend_browser_surface(&surface),
                "surface {surface_id} is a frontend-rendered browser and has no daemon stream"
            );
            match (expected_generation, expected_terminal_id) {
                (Some(generation), Some(terminal)) => {
                    anyhow::ensure!(
                        mux.registry_identity().1 == generation,
                        "attachment_generation_mismatch"
                    );
                    anyhow::ensure!(
                        surface.terminal_public_id().map(|id| id.as_str())
                            == Some(terminal.as_str()),
                        "attachment_terminal_mismatch"
                    );
                }
                (None, None) => {}
                _ => anyhow::bail!("attachment identity requires generation and terminal together"),
            }
            if surface.kind() == SurfaceKind::Browser {
                let guarded_owner = mux
                    .control_clients
                    .supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY)
                    && mux.control_clients.browser_pointer_owner(client)?
                        == BrowserPointerOwner::Client(client);
                if !guarded_owner {
                    anyhow::bail!(
                        "browser attach requires client capability \
                         {GUARDED_BROWSER_POINTER_CAPABILITY} before the first browser pointer \
                         command; upgrade or restart the cmux-tui client"
                    );
                }
            }
            if surface.kind() == SurfaceKind::Pty
                && mode.as_deref().unwrap_or("bytes") == "bytes"
                && snapshot.wants_snapshot()?
            {
                return snapshot.attach(mux, client, surface, writer, initial_size);
            }
            let lifecycle = AttachLifecycle::default();
            let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
            let render_mode = match mode.as_deref().unwrap_or("bytes") {
                "bytes" => false,
                "render" => true,
                other => anyhow::bail!("bad attach mode {other}"),
            };
            if render_mode {
                require_pty(&surface)?;
                let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
                    mark_client_attached(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.clone(),
                        initial_size,
                    )?;
                let attach = match surface.attach_render_stream() {
                    Ok(attach) => attach,
                    Err(error) => {
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error.into());
                    }
                };
                if let Err(error) = writer.send_initial(
                    &render_state_message(&writer.render_service, surface_id, &attach.initial),
                    &outbound_stream,
                ) {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned = std::thread::Builder::new()
                    .name("mux-render-attach-out".into())
                    .spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        let mut state =
                            RenderClientState::new(writer.render_service.clone(), &attach.initial);
                        let interrupt = StreamInterrupt::new();
                        writer.register_interrupt(&interrupt);
                        outbound_stream.register_interrupt(&interrupt);
                        lifecycle.register_interrupt(&interrupt);
                        attach.stream.wake_on(&interrupt);
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            let send_result = match attach.stream.recv_until_interrupted(&interrupt)
                            {
                                Ok(RenderAttachFrame::Frame(frame)) => {
                                    let message = state.delta_message(surface_id, &frame);
                                    writer.send_stream_backpressured(&message, &outbound_stream)
                                }
                                Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                                    writer.send_stream_backpressured(
                                        &json!({
                                            "event": "scroll-changed",
                                            "surface": surface_id,
                                            "offset": offset,
                                            "at_bottom": at_bottom,
                                        }),
                                        &outbound_stream,
                                    )
                                }
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                            };
                            if let Err(error) = send_result {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        if writer.is_open() && !lifecycle.overflowed() {
                            let _ = writer.send_stream_backpressured(
                                &json!({"event": "detached", "surface": surface_id}),
                                &outbound_stream,
                            );
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(attach_response(mux, surface_id, client, lease));
            }
            if surface.kind() == SurfaceKind::Browser {
                let MarkedClientAttach {
                    lease,
                    size_rollback,
                    client_changed,
                    resize_reservation,
                    resize_completion,
                } = mark_client_attached(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.clone(),
                    initial_size,
                )?;
                if let Some(reservation) = resize_reservation
                    && let Err(error) = wait_for_initial_browser_resize(
                        resize_completion
                            .as_ref()
                            .expect("sized browser attach has a completion receiver"),
                        surface_id,
                        reservation,
                    )
                {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error);
                }
                let (state, frames) = match surface.attach_frames() {
                    Ok(attach) => attach,
                    Err(error) => {
                        lifecycle.cancel();
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error);
                    }
                };
                if let Err(error) = writer.send_initial(
                    &browser_state_message(surface_id, &state, true),
                    &outbound_stream,
                ) {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                if let Err(error) = spawn_attach_notification_stream(
                    mux.clone(),
                    surface_id,
                    writer.clone(),
                    lifecycle.clone(),
                    outbound_stream.clone(),
                ) {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned =
                    std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        let interrupt = StreamInterrupt::new();
                        writer.register_interrupt(&interrupt);
                        outbound_stream.register_interrupt(&interrupt);
                        lifecycle.register_interrupt(&interrupt);
                        frames.notify.wake_on(&interrupt);
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            match frames.notify.recv_until_interrupted(&interrupt) {
                                Ok(()) => {}
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                    lifecycle.cancel();
                                    if writer.is_open() {
                                        let _ = writer.send_stream_backpressured(
                                            &json!({"event": "detached", "surface": surface_id}),
                                            &outbound_stream,
                                        );
                                    }
                                    break;
                                }
                            }
                            let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                            // A frame event applies its bitmap and authority
                            // atomically. Publish it before a paired state
                            // snapshot can expose the same positive token.
                            if let Err(error) = send_browser_attach_update(
                                &writer,
                                surface_id,
                                update,
                                &outbound_stream,
                            ) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(attach_response(mux, surface_id, client, lease));
            }
            let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
                mark_client_attached(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.clone(),
                    initial_size,
                )?;
            lifecycle.set_resumes_pending_sequence(
                mux.control_clients
                    .supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
            );
            let attach = match surface.attach_stream_with_lifecycle(lifecycle.clone()) {
                Ok(attach) => attach,
                Err(error) => {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
            };
            let shape = AttachWireShape {
                color_overrides: mux
                    .control_clients
                    .supports_capability(client, TERMINAL_COLOR_OVERRIDES_CAPABILITY),
                pending_sequence: mux
                    .control_clients
                    .supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
            };
            let (replay, pending_sequence) = if shape.pending_sequence
                || attach.pending_sequence.is_empty()
            {
                (attach.replay.clone(), attach.pending_sequence.clone())
            } else {
                (Arc::from([&*attach.replay, &*attach.pending_sequence].concat()), Arc::from([]))
            };
            let initial = VtStateMessage {
                surface: surface_id,
                cols: attach.cols,
                rows: attach.rows,
                replay,
                kitty_image_aliases: attach.kitty_image_aliases.clone(),
                kitty_state: attach.kitty_state,
                colors: terminal_colors_json(attach.colors, shape.color_overrides),
                pending_sequence,
            };
            if let Err(error) = writer.send_initial_vt_state(&initial, &outbound_stream) {
                handle_attach_send_error(&lifecycle, &error);
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            if let Err(error) = spawn_attach_notification_stream(
                mux.clone(),
                surface_id,
                writer.clone(),
                lifecycle.clone(),
                outbound_stream.clone(),
            ) {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            let worker_writer = writer.clone();
            let worker_mux = mux.clone();
            let worker_stream = outbound_stream.clone();
            let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
            let spawned =
                std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                    let writer = worker_writer;
                    let mux = worker_mux;
                    let outbound_stream = worker_stream;
                    if worker_committed.recv().is_err() {
                        return;
                    }
                    let interrupt = StreamInterrupt::new();
                    writer.register_interrupt(&interrupt);
                    outbound_stream.register_interrupt(&interrupt);
                    attach.lifecycle.register_interrupt(&interrupt);
                    attach.stream.wake_on(&interrupt);
                    while writer.is_open()
                        && outbound_stream.is_open()
                        && !attach.lifecycle.is_canceled()
                    {
                        let frame = match attach.stream.recv_interruptible(&interrupt, None) {
                            Ok(frame) => frame,
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                attach.lifecycle.cancel();
                                if writer.is_open() {
                                    let _ = writer.send_stream_backpressured(
                                        &json!({"event": "detached", "surface": surface_id}),
                                        &outbound_stream,
                                    );
                                }
                                break;
                            }
                        };
                        if let Err(error) = writer.send_attach_frame_backpressured(
                            surface_id,
                            &frame,
                            shape,
                            &outbound_stream,
                        ) {
                            handle_attach_send_error(&attach.lifecycle, &error);
                            break;
                        }
                    }
                    report_attach_overflow(
                        &writer,
                        surface_id,
                        &attach.lifecycle,
                        &outbound_stream,
                    );
                    detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                });
            if let Err(error) = spawned {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            commit_client_attach_and_start_worker(
                mux,
                client,
                surface_id,
                outbound_stream.id,
                AttachWorkerCommit {
                    start: worker_start,
                    lifecycle,
                    changed: client_changed,
                    size_rollback,
                },
            )?;
            Ok(attach_response(mux, surface_id, client, lease))
        }
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

fn stamped_build_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .filter(|commit| !commit.is_empty())
}

fn stamped_ghostty_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty())
}

fn subscribed_event_json(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::SurfaceOutput(id) => json!({"event": "surface-output", "surface": id}),
        MuxEvent::SurfaceResized { surface, cols, rows, reservation_id } => json!({
            "event": "surface-resized",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceResizeFailed {
            surface,
            cols,
            rows,
            error,
            retry_after_ms,
            reservation_id,
        } => json!({
            "event": "surface-resize-failed",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "error": error.as_ref(),
            "retry_after_ms": retry_after_ms,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceExited(id) => json!({"event": "surface-exited", "surface": id}),
        MuxEvent::SizeStateChanged { surface, runtime, state } => {
            size_state_event_json(*surface, *runtime, state, None)
        }
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
        }
        MuxEvent::AgentChanged { surface, state, source, session, agent, updated_at_ms } => json!({
            "event": "agent-changed",
            "surface": surface,
            "state": state.as_ref(),
            "source": source.as_ref(),
            "session": session.as_deref(),
            "agent": agent.as_deref(),
            "updated_at_ms": updated_at_ms,
        }),
        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
        MuxEvent::Notification(notification) => json!({
            "event": "notification",
            "notification": notification.notification,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "surface": notification.surface,
            "source": notification.source.as_str(),
        }),
        MuxEvent::GraphicsStatus(status) => match status {
            GraphicsStatus::KittyImageBudgetWorkerStartFailed { error } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-worker-start-failed",
                "error": error.as_ref(),
            }),
            GraphicsStatus::KittyImageBudgetUpdateFailed { retry_exhausted, summary } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-update-failed",
                "retry_exhausted": retry_exhausted,
                "summary": summary.as_ref(),
            }),
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts,
                remaining,
                cell_pixels,
            } => json!({
                "event": "graphics-status",
                "kind": "cell-pixel-update-retries-exhausted",
                "attempts": attempts,
                "remaining": remaining,
                "cell_width": cell_pixels.0,
                "cell_height": cell_pixels.1,
            }),
        },
        MuxEvent::Status(message) => json!({"event": "status", "message": message}),
        MuxEvent::MachineUsageChanged(usage) => {
            let mut payload = machine_usage_json(usage.as_ref());
            payload["event"] = json!("machine-usage-changed");
            payload
        }
        MuxEvent::ConfigReloadRequested => json!({"event": "config-reload-requested"}),
        MuxEvent::WindowTitleRequested(title) => {
            json!({"event": "window-title-requested", "title": title})
        }
        MuxEvent::ScrollChanged { surface, offset, at_bottom } => json!({
            "event": "scroll-changed",
            "surface": surface,
            "offset": offset,
            "at_bottom": at_bottom,
        }),
        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeSelectionChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
        MuxEvent::FrontendProjectionChanged {
            frontend,
            scope,
            subject_key,
            projection_revision,
            origin,
            mutation_id,
        } => json!({
            "event": "frontend-projection-changed",
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "projection_revision": projection_revision,
            "origin": origin,
            "mutation_id": mutation_id,
        }),
        MuxEvent::PersonalChanged { personal_revision } => json!({
            "event": "personal-changed",
            "personal_revision": personal_revision,
        }),
        MuxEvent::Conversation(event) => event.wire_json(),
        MuxEvent::CloudConversation(event) => event.wire_json(),
        MuxEvent::BookmarksChanged(change) => json!({
            "event": "bookmarks-changed",
            "browser_profile_id": change.browser_profile_id,
            "bookmarks_revision": change.bookmarks_revision,
        }),
        MuxEvent::TerminalRegistryChanged { registry_id, generation, terminal_revision } => json!({
            "event":"terminal-registry-changed",
            "registry_id":registry_id,
            "generation":generation,
            "terminal_revision":terminal_revision,
            "refetch":"terminal-events-or-list-terminals",
        }),
        MuxEvent::TerminalReaped { terminal_id, terminal, grace_ms } => json!({
            "event": "terminal-reaped",
            "terminal_id": terminal_id,
            "terminal": terminal,
            "grace_ms": grace_ms,
        }),
        MuxEvent::LayoutChanged(screen) => json!({"event": "layout-changed", "screen": screen}),
        MuxEvent::ClientAttached { client, transport, name, kind } => json!({
            "event": "client-attached",
            "client": client,
            "transport": transport,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientChanged { client, name, kind } => json!({
            "event": "client-changed",
            "client": client,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientDetached(client) => {
            json!({"event": "client-detached", "client": client})
        }
        MuxEvent::ClientListInvalidated => json!({"event": "client-list-invalidated"}),
        MuxEvent::PairingRequested(challenge) => json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        }),
        MuxEvent::PairingResolved { request } => {
            json!({"event": "pairing-resolved", "request": request})
        }
        MuxEvent::Empty => json!({"event": "empty"}),
    }
}

fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
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
