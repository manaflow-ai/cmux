//! Part of `Peer` (`peer.rs`). What the peer said at its last handshake it serves (its
//! `initialize` reply's `_meta.acpmux.features`), read before a request that needs it is
//! forwarded (`server/peer_forward.rs`).

use super::Peer;
use crate::no_panic::LockExt;
use std::sync::atomic::Ordering;

/// One peer-link feature: an id a daemon lists in its `initialize` reply's
/// `_meta.acpmux.features`, and the wire names a link may send that daemon only once it listed the
/// id. A name is a protocol registry method or notification (`protocol::registry`), or a
/// `kind:`-prefixed wire name (`field:_meta.acpmux#key`, `param:<method>#key`) for a key the
/// feature adds to a message both sides already know. An empty list is a behavior the feature
/// names (an answer's shape, a handshake's order) with no name of its own on the wire.
///
/// The one place a feature says what it gates: the wire manifest (`spec/wire/acpmux.json`,
/// `tests/wire_lockstep.rs`) is generated from it, and its ids are exactly what `initialize`
/// lists (`peer_features_tests.rs`). A new feature gets its row here in the change that adds it.
#[derive(Debug)]
pub struct PeerFeature {
    pub id: &'static str,
    pub gates: &'static [&'static str],
}

use crate::rpc::method as m;

/// Every feature `initialize` can list (`server/requests.rs`), in its order; the last five are
/// listed only on some connections (`listStream`, `listPages`, `linkControls`, `listHubRows`) or
/// added after (`queueGet`, `server/requests/queued.rs`).
pub const PEER_FEATURES: &[PeerFeature] = &[
    PeerFeature { id: crate::hub::presence::PEER_FEATURE, gates: &[] },
    PeerFeature { id: "promptAccepted", gates: &[m::MUX_PROMPT_ACCEPTED] },
    PeerFeature { id: "turnIds", gates: &[] },
    PeerFeature { id: "eventPaging", gates: &[] },
    PeerFeature { id: "eventKinds", gates: &[] },
    PeerFeature { id: "eventStream", gates: &[] },
    PeerFeature { id: "cancelRequest", gates: &[m::CANCEL_REQUEST] },
    PeerFeature { id: "messageSuperseded", gates: &[] },
    PeerFeature { id: "turnErrorText", gates: &[] },
    PeerFeature {
        id: "permissionGroups",
        gates: &[
            m::MUX_PERMISSION_GROUPS,
            m::MUX_PERMISSION_GROUP_RESPOND,
            m::MUX_PERMISSION_CHAT_REVOKE,
        ],
    },
    PeerFeature { id: "trustGate", gates: &[m::ACP_TRUST_GET, m::ACP_TRUST_SET] },
    PeerFeature { id: "chiefBuiltinPresets", gates: &[] },
    PeerFeature { id: crate::config::chief_builtins::BRAIN_PRESETS_FEATURE, gates: &[] },
    PeerFeature { id: "personChallenge", gates: &[m::MUX_PERSON_PROVE] },
    PeerFeature { id: "queueEdit", gates: &[m::MUX_QUEUE_EDIT, m::MUX_QUEUE_REMOVE] },
    PeerFeature {
        id: crate::author::QUEUE_APPROVAL_FEATURE,
        gates: &[m::MUX_QUEUE_APPROVE, m::MUX_QUEUE_DECLINE],
    },
    PeerFeature { id: "steerInterrupt", gates: &["field:_meta.acpmux#interrupt"] },
    PeerFeature { id: "personHolds", gates: &[m::MUX_PERSON_HOLDS] },
    // A chat moved between machines (`hub/transfer*.rs`); its requests predate the feature.
    PeerFeature { id: "sessionTransfer", gates: &[] },
    PeerFeature { id: "approverDecisions", gates: &["field:_meta.acpmux#approverDecisions"] },
    PeerFeature { id: "toolInventory", gates: &[] },
    PeerFeature { id: "promptWithdraw", gates: &[m::MUX_PROMPT_WITHDRAW, m::MUX_STEER_WITHDRAW] },
    PeerFeature {
        id: "processes",
        gates: &[
            m::MUX_PROCESS_LIST,
            m::MUX_PROCESS_TAIL,
            m::MUX_PROCESS_KILL,
            m::MUX_PROCESS_BACKGROUND,
            m::MUX_PROCESS_UPDATE,
        ],
    },
    PeerFeature {
        id: "worktreeCare",
        gates: &[m::MUX_WORKTREE_REPORT, m::MUX_WORKTREE_CLEAN, m::MUX_WORKTREE_RESTORE],
    },
    PeerFeature { id: "harnessInventory", gates: &[m::MUX_HARNESS_INVENTORY] },
    // `server/inventory_watch.rs` `FEATURE` (private to the server).
    PeerFeature { id: "harnessInventoryWatch", gates: &[m::MUX_HARNESS_INVENTORY_WATCH] },
    PeerFeature {
        id: crate::harness_health::INVENTORY_REFRESH_FEATURE,
        gates: &[m::MUX_HARNESS_INVENTORY_REFRESH],
    },
    PeerFeature {
        id: crate::harness_health::UPDATE_PLAN_FEATURE,
        gates: &[m::MUX_HARNESS_UPDATE_PLAN],
    },
    PeerFeature {
        id: crate::harness_health::UPDATE_PREPARE_FEATURE,
        gates: &[m::MUX_HARNESS_UPDATE_PREPARE],
    },
    PeerFeature { id: "surfaces", gates: &[] },
    PeerFeature { id: crate::hub::FILE_PUT_FEATURE, gates: &[m::MUX_FILE_PUT] },
    PeerFeature {
        id: crate::hub::file_uploads::CHUNKS_FEATURE,
        gates: &[
            m::MUX_FILE_PUT_BEGIN,
            m::MUX_FILE_PUT_CHUNK,
            m::MUX_FILE_PUT_FINISH,
            m::MUX_FILE_PUT_CANCEL,
        ],
    },
    PeerFeature {
        id: crate::hub::journal_restore::PAGES_FEATURE,
        gates: &["field:_meta.acpmux#throughSeq"],
    },
    PeerFeature {
        id: crate::hub::MEDIA_READ_FEATURE,
        gates: &[m::MUX_MEDIA_OPEN, m::MUX_MEDIA_RANGE],
    },
    PeerFeature {
        id: crate::hub::SUBAGENT_TRANSCRIPT_FEATURE,
        gates: &[m::MUX_SUBAGENT_TRANSCRIPT],
    },
    PeerFeature { id: crate::hub::NATIVE_HISTORY_FEATURE, gates: &[m::MUX_NATIVE_HISTORY] },
    PeerFeature { id: crate::attach::FEATURE, gates: &[] },
    PeerFeature { id: crate::prompt_uploads::FEATURE, gates: &[] },
    PeerFeature { id: crate::hub::file_uploads::RESUME_FEATURE, gates: &[m::MUX_FILE_PUT_STATUS] },
    PeerFeature {
        id: crate::server::upload_frames::FEATURE,
        gates: &[m::MUX_FILE_PUT_DATA, m::MUX_FILE_PUT_STATUS],
    },
    PeerFeature {
        id: crate::peer_states::STATE_EVENTS_FEATURE,
        gates: &[m::MUX_PEER_STATE_CHANGED],
    },
    PeerFeature { id: crate::hub::session_auth::FEATURE, gates: &[m::MUX_SESSION_AUTH] },
    PeerFeature {
        id: crate::agent_login::FEATURE,
        gates: &[
            m::MUX_AGENT_LOGIN_START,
            m::MUX_AGENT_LOGIN_FINISH,
            m::MUX_AGENT_LOGIN_CANCEL,
            m::MUX_AGENT_LOGIN_API_KEY,
        ],
    },
    PeerFeature {
        id: crate::hub::cancel::PERSON_STOP_FEATURE,
        gates: &["field:_meta.acpmux#personStop"],
    },
    PeerFeature { id: crate::hub::stop_if_idle::FEATURE, gates: &["param:_acpmux/kill#ifIdle"] },
    PeerFeature { id: crate::hub::pause::FEATURE, gates: &[m::MUX_PAUSE, m::MUX_WAKE] },
    PeerFeature {
        id: crate::hub::session_hold::FEATURE,
        gates: &[m::MUX_SESSION_HOLD, m::MUX_FLEET_HOLD],
    },
    PeerFeature { id: crate::hub::release_to_watch::FEATURE, gates: &[m::MUX_RELEASE_TO_WATCH] },
    PeerFeature { id: crate::server::SESSION_RESUME_FEATURE, gates: &[m::SESSION_RESUME] },
    // A durable `_acpmux/dispatch` (`server/requests/workflow_dispatch.rs`): the method predates it.
    PeerFeature { id: crate::server::DURABLE_DISPATCH_FEATURE, gates: &[] },
    PeerFeature { id: crate::peer::HANDSHAKE_PIPELINE_FEATURE, gates: &[] },
    PeerFeature { id: crate::server::dual_requests::FEATURE, gates: &[] },
    // `_meta.acpmux.requireAsking` and `.createKey`: keys `AcpmuxRequestMeta` does not declare.
    PeerFeature { id: crate::hub::require_asking::FEATURE, gates: &[] },
    PeerFeature { id: crate::hub::create_key::FEATURE, gates: &[] },
    PeerFeature { id: crate::sender_token::FEATURE, gates: &["field:_meta.acpmux#senderToken"] },
    PeerFeature { id: crate::hub::register::AUTO_FEATURE, gates: &[] },
    PeerFeature { id: crate::request_cancel::FEATURE, gates: &[m::CANCEL_REQUEST] },
    // `server/fork_through.rs` `RETARGET_FEATURE` (private to the server).
    PeerFeature { id: "sessionForkRetarget", gates: &[] },
    PeerFeature { id: crate::hub::fork_subagent::FEATURE, gates: &[] },
    // Sent to a link that listed it in its own `initialize` (`server/client_features.rs`).
    PeerFeature { id: crate::server::client_features::UNSENT_FEATURE, gates: &[m::MUX_UNSENT] },
    PeerFeature { id: crate::link_v2::FEATURE, gates: &[m::MUX_V2] },
    PeerFeature { id: acpmux_core::hub::PEER_PAGES_FEATURE, gates: &[] },
    // `_acpmux/controls` and `_acpmux/control` (`server/controls.rs`), not in the registry.
    PeerFeature {
        id: crate::server::controls::FEATURE,
        gates: &["method:_acpmux/controls", "notify:_acpmux/control"],
    },
    PeerFeature { id: crate::hub::list_tee::HUB_ROWS_FEATURE, gates: &[] },
    PeerFeature { id: crate::author::QUEUE_GET_FEATURE, gates: &[m::MUX_QUEUE_GET] },
    // A session move's wait handoff (`server/bg_rearm.rs`).
    PeerFeature { id: crate::server::bg_rearm::FEATURE, gates: &[m::MUX_BG_REARM] },
];

/// The features of [`PEER_FEATURES`] that gate request or notification `method` (a registry name,
/// or its `method:`/`notify:` wire form): a peer may be sent it only once it listed one of them.
/// Empty: no feature gates it.
pub fn gating(method: &str) -> Vec<&'static str> {
    PEER_FEATURES
        .iter()
        .filter(|f| {
            f.gates.iter().any(|g| {
                let name = g.strip_prefix("method:").or_else(|| g.strip_prefix("notify:"));
                name.unwrap_or(g) == method
            })
        })
        .map(|f| f.id)
        .collect()
}

impl Peer {
    pub fn supports_trust_gate(&self) -> bool {
        self.trust_gate.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it takes `_acpmux/file_put`.
    pub fn supports_file_put(&self) -> bool {
        self.file_put.load(Ordering::SeqCst)
    }

    /// Whether the peer takes uploads in chunks (`file_put_begin`/`_chunk`/`_finish`/`_cancel`).
    pub fn supports_file_put_chunks(&self) -> bool {
        self.file_put_chunks.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves the media reader.
    pub fn supports_media_read(&self) -> bool {
        self.media_read.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves subagent transcripts.
    pub fn supports_subagent_transcript(&self) -> bool {
        self.subagent_transcript.load(Ordering::SeqCst)
    }

    /// Whether the peer listed `feature` at its last handshake (none before it answered): it
    /// saves a message's attachments (`attach::FEATURE`), reads uploaded files a message names
    /// (`prompt_uploads::FEATURE`), answers upload status (`file_uploads::RESUME_FEATURE`), or
    /// holds a prompt for the owner (`author::QUEUE_APPROVAL_FEATURE`).
    pub fn lists(&self, feature: &str) -> bool {
        self.features.lock_or_recover().iter().any(|f| f == feature)
    }

    /// The link that listed `feature` (`lists`), for a request that may go only to a peer that
    /// listed it: sent on that link (`request_on`), it never reaches a reconnected one. The epoch
    /// is read first and a link's end clears the list first (`link_ended`).
    pub fn lists_on(&self, feature: &str) -> Option<u64> {
        let epoch = self.link_epoch();
        self.lists(feature).then_some(epoch)
    }

    /// Whether the peer said at its last handshake that it pages a chat's native history.
    pub fn supports_native_history(&self) -> bool {
        self.native_history.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it saves a message's attachments.
    pub fn supports_send_attach(&self) -> bool {
        self.lists(crate::attach::FEATURE)
    }

    /// Whether the peer said at its last handshake that it reads uploaded files a message names.
    pub fn supports_prompt_uploads(&self) -> bool {
        self.lists(crate::prompt_uploads::FEATURE)
    }

    /// Whether the peer said at its last handshake that it answers upload status and checks a
    /// finish's `sha256` (`hub/file_uploads.rs`).
    pub fn supports_upload_resume(&self) -> bool {
        self.lists(crate::hub::file_uploads::RESUME_FEATURE)
    }

    /// Whether the peer said at its last handshake that it answers `_acpmux/session/auth`.
    pub fn supports_session_auth(&self) -> bool {
        self.session_auth.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that its prompt acceptances name the message
    /// they kept (`capabilities::SESSION_MESSAGES`).
    pub fn supports_session_messages(&self) -> bool {
        self.session_messages.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves agent byte channels
    /// (`server/channels.rs`, `agent-channels-v1`).
    pub fn agent_channels(&self) -> bool {
        self.agent_channels.load(Ordering::SeqCst)
    }

    /// Integration-test stand-in for a peer from before `agent-channels-v1`: until the next
    /// handshake, as though it had not listed it.
    #[doc(hidden)]
    pub fn forget_agent_channels_for_tests(&self) {
        self.agent_channels.store(false, Ordering::SeqCst);
    }

    /// Integration-test stand-in for a peer from before `session-messages-v1`: until the next
    /// handshake, as though it had not listed it.
    #[doc(hidden)]
    pub fn forget_session_messages_for_tests(&self) {
        self.session_messages.store(false, Ordering::SeqCst);
    }

    /// Integration-test stand-in for a peer from before `feature` (an older build): until the
    /// next handshake, as though it had not listed it (`lists`).
    #[doc(hidden)]
    pub fn forget_feature_for_tests(&self, feature: &str) {
        self.features.lock_or_recover().retain(|f| f != feature);
    }

    /// The link is up and its handshake finished: a caller's request may go out on it, as
    /// `request_on` checks.
    pub fn ready(&self) -> bool {
        self.connected.load(Ordering::SeqCst) && !self.admitting.load(Ordering::SeqCst)
    }

    /// The link on which the peer said at its handshake that its `session/resume` replays no
    /// history (`server/requests/session_open.rs`), while that link is still the current one.
    /// A resume goes on that link alone (`request_on`): a reconnect to an older build, which
    /// replays the chat as for a load, fails it as not sent rather than taking it.
    pub fn session_resume_link(&self) -> Option<u64> {
        let listed = self.session_resume_link.load(Ordering::SeqCst).checked_sub(1)?;
        (listed == self.link_epoch()).then_some(listed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Codex review of #27795: a peer that listed `sessionResume` on a link that has since
    /// ended has not said it of the next one, which may be an older build.
    #[tokio::test]
    async fn a_resume_link_is_only_the_current_link_that_listed_it() {
        let (tx, _notices) = tokio::sync::mpsc::channel(4);
        let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        assert_eq!(peer.session_resume_link(), None);
        let link = peer.link_epoch();
        peer.session_resume_link.store(link + 1, Ordering::SeqCst);
        assert_eq!(peer.session_resume_link(), Some(link));
        peer.link_ended();
        assert_eq!(peer.session_resume_link(), None);
        // A peer that is not up is not ready, whatever it listed.
        assert!(!peer.ready());
    }
}
