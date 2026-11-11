//! The params of the methods that take a fixed set of keys and no serde type: each a closed
//! object of the keys its handler reads, every value open (`true`). The Swift pane's own list
//! (`AcpmuxPaneMethods+Params.swift` `knownParams`) is checked against these
//! (`scripts/ci/check-swift-acpmux-protocol.py`), so a key the app sends that acpmux never reads
//! fails CI. Every request also takes `_meta` ([`RequestMeta`]): the local app's token and the
//! person's key ride on any of them (`server/local_app.rs`, `hub/person.rs`).

use std::borrow::Cow;

use schemars::generate::SchemaGenerator;
use schemars::{JsonSchema, Schema};
use serde_json::{Map, Value, json};

/// A closed object of `keys` plus `_meta`, each value any JSON.
fn closed(generator: &mut SchemaGenerator, keys: &[&str]) -> Schema {
    let mut properties: Map<String, Value> =
        keys.iter().map(|key| ((*key).to_owned(), Value::Bool(true))).collect();
    properties.insert("_meta".into(), generator.subschema_for::<RequestMeta>().to_value());
    Schema::try_from(
        json!({"type": "object", "properties": properties, "additionalProperties": false}),
    )
    .unwrap_or_default()
}

macro_rules! keyed {
    ($($(#[$doc:meta])* $name:ident: [$($key:literal),* $(,)?];)*) => {$(
        $(#[$doc])*
        pub struct $name;

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(generator: &mut SchemaGenerator) -> Schema {
                closed(generator, &[$($key),*])
            }
        }
    )*};
}

/// A request's `_meta`: open to other vendors' keys, with acpmux's own under `acpmux`.
pub struct RequestMeta;

impl JsonSchema for RequestMeta {
    fn schema_name() -> Cow<'static, str> {
        "RequestMeta".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        let acpmux = generator.subschema_for::<AcpmuxRequestMeta>().to_value();
        Schema::try_from(json!({"type": "object", "properties": {"acpmux": acpmux}}))
            .unwrap_or_default()
    }
}

/// Every key acpmux reads from a request's `params._meta.acpmux`, on any method. Not here: the
/// keys of a reply's or a notification's `_meta.acpmux` (`features`, `ownerCloud`), and a content
/// block's own (`upload`, `uploadPath`, `context: true` on a block).
pub struct AcpmuxRequestMeta;

impl JsonSchema for AcpmuxRequestMeta {
    fn schema_name() -> Cow<'static, str> {
        "AcpmuxRequestMeta".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        let properties: Map<String, Value> =
            ACPMUX_REQUEST_META.iter().map(|key| ((*key).to_owned(), Value::Bool(true))).collect();
        Schema::try_from(
            json!({"type": "object", "properties": properties, "additionalProperties": false}),
        )
        .unwrap_or_default()
    }
}

/// [`AcpmuxRequestMeta`]'s keys.
pub const ACPMUX_REQUEST_META: &[&str] = &[
    "adopt",
    "agentSessionId",
    "answeredBy",
    "approverDecision",
    "approverDecisions",
    "argv",
    "author",
    "beforePromptId",
    "callerKind",
    "callerProtocol",
    "callerSession",
    "cancelToken",
    "class",
    "cliHost",
    "compression",
    "context",
    "createdBy",
    "cwd",
    "decisionNonce",
    "disallowedTools",
    "dispatchSource",
    "effort",
    "env",
    "ephemeral",
    "forceAdmit",
    "forwardProjection",
    "fromAgent",
    "fromHarness",
    "fromSessionId",
    "githubBroker",
    "harness",
    "harnessFrom",
    "host",
    "inlineParts",
    "interrupt",
    "localAppToken",
    "mcpServers",
    "messageId",
    "messageSender",
    "mode",
    "model",
    "name",
    "notice",
    "observer",
    "parent",
    "peer",
    "peerHops",
    "personDecision",
    "personKey",
    "personStop",
    "policy",
    "pr",
    "preset",
    "promptFileText",
    "promptId",
    "promptSuggestion",
    "provenance",
    "reportTo",
    "requestId",
    "requireFullAccess",
    "resend",
    "route",
    "senderHarness",
    "senderHarnessChecked",
    "senderToken",
    "spawnToolCallId",
    "startLater",
    "steer",
    "steerNow",
    "steerOnly",
    "supersede",
    "surface",
    "tags",
    "teamMessage",
    "throughSeq",
    "topic",
    "via",
    "vmBoundary",
    "waitStart",
    "workflowAllowedTools",
    "workspaceId",
    "worktree",
];

keyed! {
    /// `_acpmux/agent_hold`.
    AgentHoldParams: ["sessionId", "held"];
    /// `_acpmux/agent_login/api_key`.
    AgentLoginApiKeyParams: ["agent", "key", "sessionId"];
    /// `_acpmux/agent_login/cancel`.
    AgentLoginCancelParams: ["loginId", "sessionId"];
    /// `_acpmux/agent_login/finish`.
    AgentLoginFinishParams: ["loginId", "code", "sessionId"];
    /// `_acpmux/agent_login/start`.
    AgentLoginStartParams: ["agent", "sessionId"];
    /// `_acpmux/agent_pair_resume`.
    AgentPairResumeParams: ["sessionId", "peerSessionId"];
    /// `_acpmux/app_reply`.
    AppReplyParams: ["sessionId", "to", "replyTo", "threadId", "text", "replyId"];
    /// `_acpmux/archive`.
    ArchiveParams: ["sessionId", "archived"];
    /// `_acpmux/attachment`.
    AttachmentParams: ["sessionId", "id"];
    /// `_acpmux/bookmark_get`.
    BookmarkGetParams: ["sessionId"];
    /// `_acpmux/bookmark_set`.
    BookmarkSetParams: ["sessionId", "seq", "bookmarked"];
    /// `_acpmux/memory_resolve`.
    MemoryResolveParams: ["sessionId", "offerId", "file", "accept", "dismiss"];
    /// `_acpmux/prompt_coach`.
    PromptCoachParams: ["sessionId", "coachId"];
    /// `_acpmux/btw`.
    BtwParams: ["sessionId", "question", "model", "inline", "targetHarness"];
    /// `_acpmux/chat/route.set`.
    ChatRouteSetParams: ["sessionId", "routeId", "when"];
    /// `_acpmux/draft_get`.
    DraftGetParams: ["sessionId"];
    /// `_acpmux/draft_set`.
    DraftSetParams: ["sessionId", "text"];
    /// `_acpmux/forum/rules`.
    ForumRulesParams: [];
    /// `_acpmux/handoff_discard`.
    HandoffDiscardParams: ["handoffId"];
    /// `_acpmux/handoff_draft`.
    HandoffDraftParams: ["handoffId", "revision", "draftKey", "capsule", "checkpoint"];
    /// `_acpmux/handoff_get`.
    HandoffGetParams: ["sessionId", "handoffId"];
    /// `_acpmux/handoff_prepare`.
    HandoffPrepareParams: ["sessionId", "harness", "handoffKey", "memoryRefs"];
    /// `_acpmux/handoff_start`.
    HandoffStartParams: ["handoffId", "revision", "promptId", "capsule", "checkpoint"];
    /// `_acpmux/harness_enable`.
    HarnessEnableParams: ["folder", "id"];
    /// `_acpmux/harness/health`.
    HarnessHealthParams: ["refresh", "rescan", "checkLatest", "autoUpdate", "view"];
    /// `_acpmux/harnesses`.
    HarnessesParams: ["cwd"];
    /// `_acpmux/inbox_thread`.
    InboxThreadParams: ["sessionId", "threadId", "markRead"];
    /// `initialize`.
    InitializeParams: ["protocolVersion", "clientCapabilities", "clientInfo"];
    /// `_acpmux/kill`.
    KillParams: ["sessionId", "purge", "cancelFork", "cancelToken"];
    /// `_acpmux/mcp/reconnect`.
    McpReconnectParams: ["sessionId", "server"];
    /// `_acpmux/models`.
    ModelsParams: ["refresh", "probe", "localOnly"];
    /// `_acpmux/native_history`.
    NativeHistoryParams: ["sessionId", "before", "mark"];
    /// `_acpmux/offer_respond`.
    OfferRespondParams: ["sessionId", "offerId", "outcome", "childSessionId"];
    /// `_acpmux/peer_reconnect`.
    PeerReconnectParams: ["name", "wait", "force"];
    /// `_acpmux/peer_snapshot`.
    PeerSnapshotParams: ["sessionId", "host", "limit", "maxBytes"];
    /// `_acpmux/peers`.
    PeersParams: [];
    /// `_acpmux/prewarm`.
    PrewarmParams: ["harness", "cwd", "release"];
    /// `_acpmux/process/kill`.
    ProcessKillParams: ["sessionId", "processId", "signal"];
    /// `_acpmux/process/list`.
    ProcessListParams: ["sessionId", "cursor", "limit"];
    /// `_acpmux/process/tail`.
    ProcessTailParams: ["sessionId", "processId", "fromByte", "maxBytes"];
    /// `_acpmux/queue_approve`.
    QueueApproveParams: ["sessionId", "promptId", "turnId", "revision"];
    /// `_acpmux/queue_decline`.
    QueueDeclineParams: ["sessionId", "promptId"];
    /// `_acpmux/queue_edit`.
    QueueEditParams: ["sessionId", "promptId", "op", "text", "images", "index"];
    /// `_acpmux/queue_get`.
    QueueGetParams: ["sessionId", "promptId"];
    /// `_acpmux/queue_remove`.
    QueueRemoveParams: ["sessionId", "promptId"];
    /// `_acpmux/resolve`.
    ResolveParams: ["query", "sessionId", "exactSessionId"];
    /// `_acpmux/route/list`.
    RouteListParams: ["sessionId"];
    /// `_acpmux/secret_submit`.
    SecretSubmitParams: ["sessionId", "secretId", "value"];
    /// `session/cancel`.
    SessionCancelParams: ["sessionId"];
    /// `session/new`.
    SessionNewParams: ["cwd", "mcpServers", "additionalDirectories"];
    /// `session/prompt`.
    SessionPromptParams: ["sessionId", "prompt", "steer"];
    /// `session/set_config_option`.
    SessionSetConfigOptionParams: ["sessionId", "configId", "value"];
    /// `session/set_mode`.
    SessionSetModeParams: ["sessionId", "modeId"];
    /// `session/set_model`.
    SessionSetModelParams: ["sessionId", "modelId"];
    /// `_acpmux/set_tools`.
    SetToolsParams: ["sessionId", "id", "enabled"];
    /// `_acpmux/side`.
    SideParams: ["sessionId", "chat"];
    /// `_acpmux/start_mode`.
    StartModeParams: ["harness", "preset", "cwd"];
    /// `_acpmux/status`.
    StatusParams: [];
    /// `_acpmux/subagent_stop`.
    SubagentStopParams: ["sessionId", "subagentSessionId"];
    /// `_acpmux/subagent_transcript`.
    SubagentTranscriptParams: ["sessionId", "runId", "agentId", "before", "after", "limit"];
    /// `_acpmux/subsession/limits`.
    SubsessionLimitsParams: ["sessionId", "maxRunning", "workspaceId"];
    /// `acp.trust.get`.
    TrustGetParams: ["cwd", "sessionId", "peer"];
    /// `acp.trust.set`.
    TrustSetParams: ["cwd", "level", "sessionId", "peer"];
    /// `_acpmux/warm`.
    WarmParams: ["sessionIds", "limit"];
    /// `_acpmux/watch_take_over`.
    WatchTakeOverParams: ["sessionId", "ifLive"];
}
