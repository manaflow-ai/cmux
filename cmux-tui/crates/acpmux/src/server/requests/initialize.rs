//! `initialize`: what this daemon offers a new connection (`_meta.acpmux`: its extensions, its
//! features, its origin and proofs), and what the connection's `initialize` sets on it for the
//! requests after it (`note_initialize`).
//!
//! EXTENSIONS and FEATURES hold one entry per line in alphabetical order, so two pull requests
//! that each add one touch different lines and merge without a conflict. Before they were one
//! line each inside the `initialize` arm of `dispatch_request_with_identity`, which made that arm
//! the place most of `requests.rs`'s merge conflicts were (15 of 28 replayed in 14 days).

use super::*;

/// The extension methods every connection is offered; `initialize` adds the ones only some
/// connections or builds have.
#[rustfmt::skip]
const EXTENSIONS: &[&str] = &[
    method::CHAT_FIX_FROM_LINK,
    method::CHAT_FIX_FROM_LINK_PREPARE,
    method::MUX_AGENT_HOME,
    method::MUX_AGENT_HOME_RESOLVE,
    method::MUX_ARCHIVE,
    method::MUX_ASK,
    method::MUX_ATTACH,
    method::MUX_ATTACHMENT,
    method::MUX_AUTO_SESSION_LEFTOVER,
    method::MUX_AUTO_SESSION_MOVE,
    method::MUX_AUTO_SESSION_SET,
    method::MUX_AUTO_SESSION_TRANSCRIPT,
    method::MUX_AUTO_SESSION_WAKE,
    method::MUX_BG_REARM,
    method::MUX_BOOKMARK_GET,
    method::MUX_BOOKMARK_SET,
    method::MUX_BRIEFS,
    method::MUX_BTW,
    method::MUX_CALLERS,
    method::MUX_CHAT_MOVE,
    method::MUX_CHAT_SECRETS_CLEAR,
    method::MUX_CHAT_SECRETS_LIST,
    method::MUX_CHAT_SECRETS_SET,
    method::MUX_COLD_ARCHIVE,
    method::MUX_COMPOSERS,
    method::MUX_COMPOSER_SET,
    method::MUX_CUSTOMIZE_RUN,
    method::MUX_DELETED,
    method::MUX_DETACH,
    method::MUX_DETACH_PARENT,
    method::MUX_DISPATCH,
    method::MUX_DRAFT_GET,
    method::MUX_DRAFT_SET,
    method::MUX_EVENTS,
    method::MUX_EXPORT,
    method::MUX_FELT_SNAPSHOT,
    method::MUX_WATCHDOG_HOLD,
    method::MUX_FILE_PUT,
    method::MUX_FILE_PUT_BEGIN,
    method::MUX_FILE_PUT_CANCEL,
    method::MUX_FILE_PUT_CHUNK,
    method::MUX_FILE_PUT_FINISH,
    method::MUX_FILE_PUT_STATUS,
    method::MUX_FLEET_HOLD,
    method::MUX_GITHUB_ACTION,
    method::MUX_GITHUB_APP_LEASE,
    method::MUX_GITHUB_REST,
    method::MUX_HARNESSES,
    method::MUX_HARNESS_INVENTORY_REFRESH,
    method::MUX_HARNESS_INVENTORY_WATCH,
    method::MUX_HARNESS_UPDATE_PLAN,
    method::MUX_HARNESS_UPDATE_PREPARE,
    method::MUX_HISTORY_DELETE,
    method::MUX_HISTORY_OFFLOAD,
    method::MUX_HERE,
    method::MUX_HERE_BEAT,
    method::MUX_IMPORT,
    method::MUX_INBOX_RELAY,
    method::MUX_INFO,
    method::MUX_KEEP,
    method::MUX_KILL,
    method::MUX_LIFECYCLE,
    method::MUX_MACHINE_INFO,
    method::MUX_MAIL_ACK,
    method::MUX_MAIL_READ,
    method::MUX_MAIL_SEND,
    method::MUX_MAIL_WAIT,
    method::MUX_MARK_READ,
    method::MUX_MARK_UNREAD,
    method::MUX_MCP_RECONNECT,
    method::MUX_MEDIA_OPEN,
    method::MUX_MEDIA_RANGE,
    method::MUX_MEMORY_RESOLVE,
    method::MUX_MESH_CONTROL,
    method::MUX_NATIVE_HISTORY,
    method::MUX_PAUSE,
    method::MUX_PAUSED_FILES,
    method::MUX_PERF,
    method::MUX_PERMISSION_RESPOND,
    method::MUX_PIN,
    method::MUX_PLACE_CHAT,
    method::MUX_PREWARM,
    method::MUX_PROCESS_BACKGROUND,
    method::MUX_PROCESS_CENSUS,
    method::MUX_PROCESS_KILL,
    method::MUX_PROCESS_LIST,
    method::MUX_PROCESS_TAIL,
    method::MUX_PROJECT_NEW,
    method::MUX_PROMPTS_DELETE,
    method::MUX_PROMPTS_LIST,
    method::MUX_PROMPTS_SAVE,
    method::MUX_PROMPT_COACH,
    method::MUX_QUEUE_APPROVE,
    method::MUX_QUEUE_DECLINE,
    method::MUX_QUEUE_EDIT,
    method::MUX_QUEUE_REMOVE,
    method::MUX_QUEUE_TEXT,
    method::MUX_REGISTER,
    method::MUX_RELOAD_CONFIG,
    method::MUX_RENAME,
    method::MUX_REPORT,
    method::MUX_RESOLVE,
    method::MUX_RETENTION,
    method::MUX_ROLE,
    method::MUX_ROWS,
    method::MUX_SEEN,
    method::MUX_SEND_FANOUT,
    method::MUX_SESSIONS,
    method::MUX_SESSION_AUTH,
    method::MUX_SESSION_FILES,
    method::MUX_SESSION_HOLD,
    method::MUX_SET_DIRECTORIES,
    method::MUX_SET_POLICY,
    method::MUX_SET_TOOLS,
    method::MUX_SHUTDOWN,
    method::MUX_SIDE,
    method::MUX_STASH_DROP,
    method::MUX_STASH_GET,
    method::MUX_STASH_LIST,
    method::MUX_STASH_MOVE,
    method::MUX_STASH_PUSH,
    method::MUX_STATUS,
    method::MUX_STEER,
    method::MUX_SUBAGENT_LIST,
    method::MUX_SUBAGENT_TRANSCRIPT,
    method::MUX_SUCCEED,
    method::MUX_SYNC_PULL,
    method::MUX_SYNC_PUSH,
    method::MUX_TASKS,
    method::MUX_TASK_NEW,
    method::MUX_TEAM_ACK,
    method::MUX_TEAM_CUSTOMIZATION,
    method::MUX_TEAM_CUSTOMIZE,
    method::MUX_TEAM_HANDOFF,
    method::MUX_TEAM_INBOX,
    method::MUX_TEAM_LISTEN,
    method::MUX_TEAM_NAVIGATOR,
    method::MUX_TEAM_PICK,
    method::MUX_TEAM_READ,
    method::MUX_TEAM_SEND,
    method::MUX_TEAM_SESSION_INFO,
    method::MUX_TRANSCRIPT_OFFLOAD,
    method::MUX_TURN_FRAMES,
    method::MUX_TURN_SHOTS,
    method::MUX_LIVE,
    method::MUX_LIVE_LIST,
    method::MUX_ROOMS,
    method::MUX_FOLLOW,
    method::MUX_TYPING,
    method::MUX_UNDELETE,
    method::MUX_UPLOADS_KEEP,
    method::MUX_USAGE,
    method::MUX_V2,
    method::MUX_VIEW,
    method::MUX_WAKE,
    method::MUX_WARM,
    method::MUX_WATCH,
    method::MUX_WHO_ELSE,
    method::MUX_WORKFLOWS,
    method::MUX_WORKTREE_CLEAN,
    method::MUX_WORKTREE_REPORT,
    method::MUX_WORKTREE_RESTORE,
    method::SESSION_SIGNATURE,
    super::super::peer_forward::TRUST_PEER_EXTENSION,
];

/// The features every connection is offered; `initialize` adds the ones only some connections
/// have.
#[rustfmt::skip]
const FEATURES: &[&str] = &[
    "approverDecisions",
    "cancelRequest",
    "chiefBuiltinPresets",
    "eventKinds",
    "eventPaging",
    "eventStream",
    "harnessInventory",
    "messageSuperseded",
    "permissionGroups",
    "personChallenge",
    "personHolds",
    "processes",
    "promptAccepted",
    "promptWithdraw",
    "queueEdit",
    "sessionTransfer",
    "steerInterrupt",
    "surfaces",
    "toolInventory",
    "trustGate",
    "turnErrorText",
    "turnIds",
    "worktreeCare",
    SESSION_RESUME_FEATURE,
    crate::agent_login::FEATURE,
    crate::attach::FEATURE,
    crate::author::QUEUE_APPROVAL_FEATURE,
    crate::config::chief_builtins::BRAIN_PRESETS_FEATURE,
    crate::harness_health::INVENTORY_REFRESH_FEATURE,
    crate::harness_health::UPDATE_PLAN_FEATURE,
    crate::harness_health::UPDATE_PREPARE_FEATURE,
    crate::hub::FILE_PUT_FEATURE,
    crate::hub::MEDIA_READ_FEATURE,
    crate::hub::NATIVE_HISTORY_FEATURE,
    crate::hub::SUBAGENT_TRANSCRIPT_FEATURE,
    crate::hub::cancel::PERSON_STOP_FEATURE,
    crate::hub::create_key::FEATURE,
    crate::hub::file_uploads::CHUNKS_FEATURE,
    crate::hub::file_uploads::RESUME_FEATURE,
    crate::hub::file_uploads::window::FEATURE,
    crate::hub::fork_subagent::FEATURE,
    crate::hub::journal_restore::PAGES_FEATURE,
    crate::hub::pause::FEATURE,
    crate::hub::presence::PEER_FEATURE,
    crate::hub::register::AUTO_FEATURE,
    crate::hub::release_to_watch::FEATURE,
    crate::hub::require_asking::FEATURE,
    crate::hub::session_auth::FEATURE,
    crate::hub::session_hold::FEATURE,
    crate::hub::stop_if_idle::FEATURE,
    crate::peer::HANDSHAKE_PIPELINE_FEATURE,
    crate::peer_states::STATE_EVENTS_FEATURE,
    crate::prompt_uploads::FEATURE,
    crate::request_cancel::FEATURE,
    crate::sender_token::FEATURE,
    super::super::bg_rearm::FEATURE,
    super::super::client_features::UNSENT_FEATURE,
    super::super::dual_requests::FEATURE,
    super::super::fork_through::FORK_REQUEST_FEATURE,
    super::super::fork_through::RETARGET_FEATURE,
    super::super::inventory_watch::FEATURE,
    super::super::upload_frames::FEATURE,
    workflow_dispatch::FEATURE,
];

/// The `initialize` reply for this connection.
pub(super) fn initialize(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    // A hello that names an ABI range this build shares nothing with is refused, typed, before
    // anything is noted (`protocol/range.rs`); one that names none is a client from before the
    // field and is served as before.
    if params.pointer("/_meta/acpmux/abi").is_some() {
        let (ours, theirs) = (
            crate::protocol::range::AbiRange::ours(),
            crate::protocol::range::AbiRange::of(params),
        );
        if ours.common(theirs).is_none() {
            return Err(crate::protocol::range::refusal(ours, theirs));
        }
    }
    // Also set in order before the next request runs (`note_initialize`).
    note_initialize(conn, params);
    // A client that only observes (cmux-tui's chat notices watch) keeps no daemon whose
    // owner app exited (`daemon/unused_exit.rs`, R-LIFECYCLE ORPHANS).
    if params.pointer("/_meta/acpmux/observer").and_then(Value::as_bool) == Some(true) {
        conn.presence.observes();
    }
    let capabilities = crate::capabilities::ids_for_connection(matches!(
        conn.transport,
        Transport::LocalStream { .. }
    ));
    #[allow(unused_mut)]
    let mut reply = json!({
        "protocolVersion": 1,
        "agentInfo": {"name": "acpmux", "title": "acpmux", "version": VERSION},
        "agentCapabilities": {
            "loadSession": true,
            "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
            "sessionCapabilities": {"list": {}, "fork": {}, "resume": {}, "close": {}, "delete": {}},
        },
        "authMethods": [],
        "_meta": {"acpmux": {"version": VERSION, "abi": crate::protocol::ABI, "abiMin": crate::protocol::range::ABI_MIN, "build": crate::hub::build(), "capabilities": capabilities,
        // `local`: the unix socket or the proven local app
        // (`local_app.rs`), which the session pool serves.
        "origin": match conn.origin { Origin::Web => "remote", Origin::Peer => "peer", _ => "local" },
        // The proof this connection presented (`conn_auth.rs`).
        "auth": conn.auth.as_str(),
        // This connection is the peer principal whose `dualId` this daemon takes
        // (`dual_requests.rs`): known only once its peer token was checked. A peer link
        // sends on two paths only when both say so (`peer_dual.rs`).
        "dualPrincipal": conn.dual_principal.is_some(),
        // A paired device's Full-access setting covers it now (`crate::pairing`):
        // a phone offers the modes that do not ask by it. Read again per request.
        "fullAccess": conn.device.as_deref().is_some_and(|d| conn.auth == ConnAuth::Device && hub.pairing.full_access(d)),
        // This connection is the person (`hub/person.rs`): never yet,
        // as the proof comes after this reply.
        "person": conn.is_person(),
        // Only a verified first-initialize caller token supplies this ID.
        "callerSessionId": conn.caller(),
        // The challenge a local connection proves the person key against.
        "personChallenge": if conn.challengeable() {
            json!({"nonce": conn.nonce, "connection": conn.id, crate::hub::person::REPROVE_FIELD: true})
        } else {
            Value::Null
        },
        // The daemon run decision proofs bind (`hub/person.rs`).
        "personInstance": hub.person.instance(),
        "extensions": EXTENSIONS, "operations": crate::hub::HANDOFF_OPERATIONS.iter().chain(crate::hub::PERMISSION_GROUP_OPERATIONS.iter()).chain(super::super::fork_through::FORK_OPERATIONS.iter()).collect::<Vec<_>>(), "handoff": {"maxCapsuleBytes": crate::hub::MAX_CAPSULE_BYTES},
        "features": FEATURES, "trustGate": true}}
    });
    // This link carries the v2 list stream (`link_v2.rs`): the one change `peers` makes
    // to what v1 sends a link.
    if conn.list_stream
        && let Some(features) =
            reply.pointer_mut("/_meta/acpmux/features").and_then(Value::as_array_mut)
    {
        features.push(json!(crate::link_v2::FEATURE));
        features.push(json!(acpmux_core::hub::PEER_PAGES_FEATURE));
    }
    if super::super::controls::offered(hub, conn) {
        if let Some(features) =
            reply.pointer_mut("/_meta/acpmux/features").and_then(Value::as_array_mut)
        {
            features.push(json!(super::super::controls::FEATURE));
        }
        if let Some(extensions) =
            reply.pointer_mut("/_meta/acpmux/extensions").and_then(Value::as_array_mut)
        {
            extensions.push(json!(super::super::controls::METHOD));
        }
    }
    // The daemon's v2 list holds the hub machines' rows (`hub/list_tee.rs`): a fact of
    // its index, named on every connection.
    if hub.v2_lists_hub_rows()
        && let Some(features) =
            reply.pointer_mut("/_meta/acpmux/features").and_then(Value::as_array_mut)
    {
        features.push(json!(crate::hub::list_tee::HUB_ROWS_FEATURE));
    }
    // Large messages go compressed from here on (`frame_compress.rs`).
    if conn.wire.as_ref().is_some_and(|wire| wire.enabled()) {
        reply.set_path(&["_meta", "acpmux", "compression"], json!(crate::frame_compress::ZLIB));
    }
    // Only a local client can use the app launcher's bundled CLI.
    if conn.origin == Origin::Local
        && let Ok(path) = std::env::var(crate::login_env::BUNDLED_CLI_ENV)
        && std::path::Path::new(&path).is_absolute()
        && bundled_cli_is_executable(std::path::Path::new(&path))
    {
        reply.set_path(&["_meta", "acpmux", "cliPath"], json!(path));
    }
    if matches!(conn.origin, Origin::Local | Origin::LocalApp) {
        hub.mark_local_ready();
    }
    // Advertised only where they work; other builds answer `not_built`.
    #[cfg(all(unix, feature = "tailnet"))]
    if let Some(extensions) =
        reply.pointer_mut("/_meta/acpmux/extensions").and_then(Value::as_array_mut)
    {
        extensions.extend(
            [
                method::MUX_TAILNET_START,
                method::MUX_TAILNET_LOGIN,
                method::MUX_TAILNET_STATE,
                method::MUX_TAILNET_LOGOUT,
                method::MUX_TAILNET_PLACEMENT,
                method::MUX_TAILNET_JOIN,
            ]
            .map(Value::from),
        );
    }
    Ok(queued::advertised(reply))
}

#[cfg(unix)]
fn bundled_cli_is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn bundled_cli_is_executable(path: &std::path::Path) -> bool {
    path.is_file()
}

/// `ACPMUX_PEER_SEND_WINDOW_KB`: the bytes of a peer link's bulk lane its transport may hold
/// (`outbound.rs` `Outbound::set_window`). Unset or 0: [`super::super::outbound::BULK_WINDOW`],
/// as every connection before it.
fn peer_send_window() -> Option<usize> {
    let kb = std::env::var("ACPMUX_PEER_SEND_WINDOW_KB").ok()?.trim().parse::<usize>().ok()?;
    kb.checked_mul(1024).filter(|&bytes| bytes > 0)
}

/// What an `initialize` sets on its connection for the requests after it: the client's name,
/// and whether a Mac lends this machine its GitHub login. Set in order, before the next request
/// on the connection is spawned (`server/mod.rs`), so a peer link's `_acpmux/watch` sent with
/// `initialize` sees them (`peer::HANDSHAKE_PIPELINE_FEATURE`).
pub(in crate::server) fn note_initialize(conn: &Conn, params: &Value) {
    if let Some(name) = params.pointer("/clientInfo/name").and_then(Value::as_str) {
        *conn.name.lock_or_recover() = name.to_owned();
        let link = conn.origin == Origin::Peer || name == crate::peer::CLIENT_NAME;
        conn.out.describe(
            format!("{} {name} {}", super::super::origin_usage_key(conn.origin), conn.id),
            !link,
        );
        if link && let Some(bytes) = peer_send_window() {
            conn.out.set_window(bytes);
        }
    }
    // Only over a link that read this machine's peer token over ssh, never a paired device's
    // (`hub/github_owner.rs`). It counts from its `_acpmux/watch`, once the Mac's side of the
    // handshake is done.
    let lends = conn.origin == Origin::Peer
        && conn.auth.peer_daemon()
        && params.pointer("/_meta/acpmux/githubBroker").and_then(Value::as_bool) == Some(true);
    conn.client_requests.lends_github.store(lends, Ordering::SeqCst);
    // Opt-in: a client that does not ask hears every peer row's `session_changed`, as before.
    let batches = params.pointer("/_meta/acpmux/peerRowBatches").and_then(Value::as_bool);
    conn.peer_row_batches.store(batches == Some(true), Ordering::SeqCst);
    // The features it reads (`client_features.rs`); none listed: a client from before the list.
    conn.client_features.note(params);
    // Opt-in too (`chunk_deltas.rs`): a client that does not ask hears every chunk's whole event.
    // A peer's link reads text masked (`peer_text.rs`), so it is never sent the compact form.
    let deltas = params.pointer("/_meta/acpmux/chunkDeltas").and_then(Value::as_bool);
    conn.chunk_deltas.set_enabled(deltas == Some(true) && conn.raw_text);
    // Opt-in too: a client that does not ask hears each change as the whole row, as before. A
    // masked connection (a peer's link) gets patches of the masked row (`session_patch.rs`).
    conn.session_delta.store(super::super::session_patch::allowed(params), Ordering::SeqCst);
    // Opt-in too (`time_breakdown_gate.rs`): a client that does not ask keeps every breakdown.
    let omit = params.pointer("/_meta/acpmux/omitTimeBreakdown").and_then(Value::as_bool);
    conn.omit_time_breakdown.store(omit == Some(true), Ordering::SeqCst);
    *conn.sent_rows.lock_or_recover() = super::super::session_patch::SentRows::bounded(
        super::super::session_patch::bound(conn.raw_text),
    );
}
