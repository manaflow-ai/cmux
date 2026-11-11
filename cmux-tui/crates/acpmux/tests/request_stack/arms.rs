//! Every request kind `dispatch_request` (`src/server/requests.rs`) has an arm for, and how
//! `request_stack` sends it: the smallest params that pass the arm's own checks, so the request
//! runs as deep into its work as a hermetic in-process hub allows.
//!
//! Rows run in this order on one connection, after one chat (`$S`) was made and prompted. Some
//! rows need an earlier one: `steer` and `report` need `dispatch`'s brief `brief-t1`, the harness
//! rows need `harness/add`, the route rows `route/add`; `view`, `typing`
//! and `mail/send` need the connection still attached, so `detach` comes after them. A row whose
//! params name `$T` ends or deletes a chat, and gets a new chat of its own. `$CWD` is the
//! process's temp folder and `$FAKE` the stand-in agent.
//!
//! A new arm fails `the_table_names_every_request_kind_of_dispatch_request` until it has a row
//! here: `Run` with the params it needs, `Any` when the arm refuses this hub or this connection by
//! design (with why), or `Skip` when it must not run in a test (with why).

use acpmux::rpc::method;
use serde_json::{Value, json};

/// How the test sends one request kind.
pub enum Ask {
    /// Sent with these params; the reply may be an error, but not invalid params or method not
    /// found (it reached the arm's work).
    Run(Value),
    /// Sent with these params; any reply is right, for the reason given.
    Any(Value, &'static str),
    /// Not sent, for the reason given.
    Skip(&'static str),
}

use Ask::{Any, Run, Skip};

/// One row per method name, in the order the test sends them.
pub fn table() -> Vec<(&'static str, Ask)> {
    vec![
        (
            method::MUX_MESH_CONTROL,
            Run(json!({"to": {"sessionId": "$S"}, "op": "resume", "idempotencyKey": "k1"})),
        ),
        (
            method::MUX_DISPATCH,
            Run(json!({"brief": "hello", "briefId": "brief-t1", "host": "local", "cwd": "$CWD"})),
        ),
        (method::MUX_STEER, Run(json!({"briefId": "brief-t1", "text": "hello"}))),
        (method::MUX_BRIEFS, Run(json!({}))),
        (method::MUX_REPORT, Run(json!({"briefId": "brief-t1", "summary": "done"}))),
        (method::MUX_TASK_NEW, Run(json!({"sessionId": "$S", "title": "t"}))),
        (method::MUX_TASKS, Run(json!({"all": true}))),
        // A topic passes the query check for any caller; `peers: false` asks no peer (network).
        (method::MUX_WHO_ELSE, Run(json!({"topic": "lso", "peers": false}))),
        (method::MUX_RESOLVE, Run(json!({"query": "$S"}))),
        (method::INITIALIZE, Run(json!({"protocolVersion": 1}))),
        (method::AUTHENTICATE, Run(json!({}))),
        (
            method::MUX_GITHUB_APP_LEASE,
            Any(json!({}), "a connection that is not the person is refused"),
        ),
        (
            method::MUX_GITHUB_ACTION,
            Any(
                json!({"action": "read", "repo": "o/r"}),
                "denied: the connection names no caller chat",
            ),
        ),
        // A valid issue link and a picked folder that does not exist (so no Git checkout, whatever
        // the temp folder is): the arm parses the link, runs `git rev-parse` and stops at the
        // checkout (not found), before trust, a worktree or a GitHub request.
        (
            method::CHAT_FIX_FROM_LINK_PREPARE,
            Run(json!({"url": "https://github.com/o/r/issues/1", "cwd": "$CWD/no-such-checkout"})),
        ),
        (
            method::CHAT_FIX_FROM_LINK,
            Run(json!({"url": "https://github.com/o/r/issues/1", "cwd": "$CWD/no-such-checkout"})),
        ),
        (
            method::MUX_PERSON_PROVE,
            Any(json!({}), "refused: the connection has no proof of the person"),
        ),
        (method::MUX_APPROVERS_SET, Any(json!({}), "the person check refuses this connection")),
        (method::MUX_APPROVERS, Any(json!({}), "the person check refuses this connection")),
        (method::MUX_MAC_APPROVER_SET, Any(json!({}), "the person check refuses this connection")),
        (method::MUX_MAC_APPROVERS, Run(json!({}))),
        (
            method::MUX_WORKSPACE_ROOTS_SET,
            Any(json!({}), "the person check refuses this connection"),
        ),
        (
            method::MUX_NEW_CHAT_PICKS_SET,
            Any(json!({}), "the person check refuses this connection"),
        ),
        (
            method::MUX_PERSON_HOLDS,
            Run(
                json!({"nonce": "0000000000000000000000000000000000000000000000000000000000000000"}),
            ),
        ),
        (
            method::MUX_PERSON_ENROLL,
            Run(json!({"key": "0000000000000000000000000000000000000000000000000000000000000000"})),
        ),
        (
            method::MUX_COMPUTER_USE_ENROLL,
            Any(
                json!({"socket": "$CWD/cua.sock", "agentToken": "t"}),
                "an unsigned build refuses (invalid params) before it reads the socket",
            ),
        ),
        (method::SESSION_NEW, Run(json!({"cwd": "$CWD", "mcpServers": []}))),
        (method::SESSION_LOAD, Run(json!({"sessionId": "$S"}))),
        (method::SESSION_RESUME, Run(json!({"sessionId": "$S"}))),
        (method::SESSION_LIST, Run(json!({}))),
        (
            method::SESSION_PROMPT,
            Run(json!({"sessionId": "$S", "prompt": [{"type": "text", "text": "hello"}]})),
        ),
        (method::SESSION_CANCEL, Run(json!({"sessionId": "$S"}))),
        (method::SESSION_FORK, Run(json!({"sessionId": "$S"}))),
        (
            method::SESSION_SET_MODE,
            Any(
                json!({"sessionId": "$S", "modeId": "normal"}),
                "the person check refuses: the fake harness has no asking modes",
            ),
        ),
        (
            method::SESSION_SET_CONFIG_OPTION,
            Run(json!({"sessionId": "$S", "configId": "model", "value": "m1"})),
        ),
        (method::SESSION_SET_MODEL, Run(json!({"sessionId": "$S", "modelId": "m1"}))),
        (method::MUX_SET_TOOLS, Run(json!({"sessionId": "$S", "id": "mcp:x", "enabled": true}))),
        (method::MUX_MCP_RECONNECT, Run(json!({"sessionId": "$S", "server": "x"}))),
        (method::MUX_SET_DIRECTORIES, Run(json!({"sessionId": "$S", "additionalDirectories": []}))),
        (
            method::MUX_TAILNET_START,
            Skip("starts the embedded tailnet node (network, a real account)"),
        ),
        (
            method::MUX_TAILNET_LOGIN,
            Skip("signs the embedded tailnet in (network, a real account)"),
        ),
        (method::MUX_TAILNET_STATE, Any(json!({}), "the person check refuses this connection")),
        (
            method::MUX_TAILNET_LOGOUT,
            Any(json!({}), "the person check refuses this connection before any tailnet work"),
        ),
        (method::MUX_STATUS, Run(json!({}))),
        (method::MUX_SESSIONS, Run(json!({"usage": true}))),
        (
            method::MUX_WEB_MODES,
            Run(json!({"sessionId": "$S", "configId": "model", "value": "m1"})),
        ),
        (
            method::MUX_WEB_TOKEN_ROTATE,
            Any(json!({}), "this hub has no web listener (invalid params)"),
        ),
        (method::MUX_WARM, Run(json!({"sessionIds": ["$S"], "limit": 1}))),
        (method::MUX_PREWARM, Run(json!({"cwd": "$CWD"}))),
        (method::MUX_START_MODE, Run(json!({"harness": "fake", "cwd": "$CWD"}))),
        ("_acpmux/set_default_policy", Run(json!({"policy": "ask"}))),
        ("_acpmux/peers", Run(json!({}))),
        ("_acpmux/host_health", Run(json!({}))),
        ("_acpmux/peer_status", Run(json!({}))),
        ("_acpmux/vm_host", Run(json!({}))),
        ("_acpmux/host_notice", Run(json!({"text": "test notice"}))),
        ("_acpmux/peer_snapshot", Run(json!({"sessionId": "nopeer/x1"}))),
        ("_acpmux/place", Run(json!({}))),
        ("_acpmux/peer_snapshots_clear", Run(json!({}))),
        ("_acpmux/directories", Run(json!({"cwd": "$CWD"}))),
        ("_acpmux/models", Run(json!({}))),
        ("catalog.get", Run(json!({}))),
        ("catalog.refresh", Run(json!({}))),
        ("_acpmux/peer_add", Skip("dials the peer URL and keeps a reconnecting link (network)")),
        ("_acpmux/peer_lease", Skip("starts a leased peer link (network)")),
        ("_acpmux/peer_reconnect", Run(json!({"name": "nopeer"}))),
        ("_acpmux/peer_remove", Run(json!({"name": "nopeer"}))),
        (method::MUX_HARNESSES, Run(json!({"cwd": "$CWD"}))),
        (
            method::MUX_RELOAD_CONFIG,
            Any(json!({}), "an in-memory config has no file to reload (invalid params)"),
        ),
        (method::MUX_DEFAULTS, Run(json!({"family": "fake", "set": {"model": "m1"}}))),
        (method::MUX_PRESETS, Run(json!({"name": "p1", "set": {"harness": "fake"}}))),
        (method::MUX_INFO, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_MACHINE_INFO,
            Any(json!({"sessionId": "$S"}), "only the chat's own agent or the person reads it"),
        ),
        (method::MUX_SESSION_FILES, Run(json!({"sessionId": "$S"}))),
        (method::MUX_CONTEXT, Run(json!({"sessionId": "$S"}))),
        // The test config has no file (`Config.path` is not read from JSON), so the save writes nothing.
        (
            method::MUX_CONTEXT_OVERRIDE,
            Run(json!({"sessionId": "$S", "scope": "user", "text": null})),
        ),
        (method::MUX_WAIT, Run(json!({"sessions": ["$S"], "until": ["ready"], "timeoutMs": 2000}))),
        (method::MUX_WATCH_ADD, Run(json!({"to": "$S", "sessions": ["nosuch"]}))),
        (method::MUX_WATCH_LS, Run(json!({}))),
        (method::MUX_WATCH_RM, Run(json!({"id": "nosuch"}))),
        (method::MUX_SCHEMA, Run(json!({}))),
        (method::MUX_PROTOCOL, Run(json!({}))),
        (method::MUX_HISTORY, Run(json!({"sessionId": "$S", "limit": 5}))),
        (method::MUX_SESSION_SEARCH, Run(json!({"sessionId": "$S", "query": "echo"}))),
        // This connection is `Origin::Local`, so the brief folds the chat's own log.
        (method::MUX_REVIEW_BRIEF, Run(json!({"sessionId": "$S"}))),
        (method::MUX_DRAFT_GET, Run(json!({"sessionId": "$S"}))),
        (method::MUX_DRAFT_SET, Run(json!({"sessionId": "$S", "text": "lso draft"}))),
        (
            method::MUX_COMPOSER_SET,
            Run(
                json!({"sessionId": "$S", "surface": {"id": "lso", "name": "LSO test"}, "text": "hi"}),
            ),
        ),
        (method::MUX_COMPOSERS, Run(json!({"sessionId": "$S"}))),
        (method::MUX_BOOKMARK_GET, Run(json!({"sessionId": "$S"}))),
        (method::MUX_BOOKMARK_SET, Run(json!({"sessionId": "$S", "seq": 1, "bookmarked": false}))),
        (method::MUX_ASK, Run(json!({"sessionId": "$S", "text": "what did you say?"}))),
        (
            method::MUX_BTW,
            Any(
                json!({"sessionId": "$S", "question": "what did you say?"}),
                "the fake harness has no read-only asking mode (invalid params)",
            ),
        ),
        (method::MUX_TAG, Run(json!({"sessionId": "$S", "set": {"lso": "1"}}))),
        (method::MUX_DETACH_PARENT, Run(json!({"sessionId": "$S"}))),
        (method::MUX_ARCHIVE, Run(json!({"sessionId": "$S", "archived": false}))),
        // `archived: false` brings a log back: an in-memory store has no archive file, so the
        // chat `$S` stays as it is for the rows after this one.
        (method::MUX_COLD_ARCHIVE, Run(json!({"sessionId": "$S", "archived": false}))),
        (method::MUX_SIDE, Run(json!({"sessionId": "$S", "chat": "lso-no-such-chat"}))),
        (
            method::MUX_HARNESS_ENABLE,
            Any(
                json!({"folder": "$CWD", "id": "fake"}),
                "an in-process hub has no home, so folder profiles are off (invalid params)",
            ),
        ),
        // Makes `~/Projects/lso-project` with `git init` and trusts it: this process's HOME is
        // its hermetic scratch home (`support/daemon_env.rs`), never the person's.
        (method::MUX_PROJECT_NEW, Run(json!({"name": "lso-project"}))),
        (method::MUX_AGENT_LOGIN_START, Skip("starts a real claude or codex sign-in")),
        (
            method::MUX_AGENT_LOGIN_FINISH,
            Any(
                json!({"loginId": "lso-none"}),
                "no sign-in can start here, so the id is unknown (invalid params)",
            ),
        ),
        (method::MUX_AGENT_LOGIN_CANCEL, Run(json!({"loginId": "lso-none"}))),
        (
            method::MUX_AGENT_LOGIN_API_KEY,
            Skip("writes the agent's credential store or runs a real codex login"),
        ),
        (
            method::MUX_HARNESS_ADD,
            Run(json!({"command": "python3", "id": "lso-probe", "args": ["$FAKE"]})),
        ),
        (method::MUX_HARNESS_REMOVE, Run(json!({"id": "lso-probe"}))),
        (method::MUX_HARNESS_RESTORE, Run(json!({"backup": "lso-probe-0.toml"}))),
        (method::MUX_HARNESS_DOCTOR, Run(json!({"id": "fake", "prompt": false, "timeoutSecs": 5}))),
        (
            method::MUX_HARNESS_SECRET_SET,
            Skip("a known harness id writes the OS keychain, outside the hermetic HOME"),
        ),
        (method::MUX_HARNESS_ICON, Run(json!({"id": "lso-probe", "clear": true}))),
        (method::MUX_REGISTRY, Skip("fetches the ACP Registry (network)")),
        (method::MUX_HARNESS_HEALTH, Run(json!({"view": "inventory"}))),
        (
            method::MUX_HARNESS_INVENTORY_REFRESH,
            Skip("may ask package managers for versions (network)"),
        ),
        (method::MUX_HARNESS_UPDATE_PLAN, Run(json!({"cli": "claude"}))),
        (
            method::MUX_HARNESS_UPDATE_PREPARE,
            Skip("asks the CLI's package manager for its update (network)"),
        ),
        (method::MUX_HARNESS_UPDATE, Skip("runs the CLIs' own updaters (npm, brew, self-update)")),
        (method::MUX_SESSIONS_RESTART_HARNESS, Run(json!({"sessions": ["$S"]}))),
        (method::MUX_ROUTE_LIST, Run(json!({}))),
        (method::MUX_ROUTE_SHOW, Run(json!({"id": "lso-route"}))),
        (method::MUX_ROUTE_ADD, Run(json!({"id": "lso-route", "kind": "direct-subscription"}))),
        (method::MUX_ROUTE_EDIT, Run(json!({"id": "lso-route", "notes": "edited"}))),
        (method::MUX_ROUTE_REMOVE, Run(json!({"id": "lso-route"}))),
        (method::MUX_ROUTE_RESTORE, Run(json!({"backup": "lso-route.toml"}))),
        (method::MUX_ROUTE_TEST, Run(json!({"id": "lso-route"}))),
        (method::MUX_ROUTE_DEFAULT_SET, Run(json!({"scope": "global"}))),
        (method::MUX_CHAT_ROUTE_SET, Run(json!({"sessionId": "$S"}))),
        (method::MUX_ACCOUNTS, Run(json!({}))),
        (method::MUX_ACCOUNT_SET, Run(json!({"id": "lso-route", "enabled": true}))),
        (
            method::MUX_ACCOUNT_USAGE,
            Skip("starts the account's `codex app-server`, which asks ChatGPT"),
        ),
        (method::ACP_TRUST_GET, Run(json!({"cwd": "$CWD"}))),
        (method::ACP_TRUST_SET, Run(json!({"cwd": "$CWD", "level": "trusted"}))),
        (
            method::MUX_SET_RULES,
            Any(
                json!({"sessionId": "$S", "rules": {"default": "ask"}}),
                "the person check refuses: the chat runs approve-all, which does not ask",
            ),
        ),
        (
            method::AGENT_SESSION_TURN_PREPARE,
            Any(
                json!({"sessionId": "$S", "prompt_id": "lso-p1"}),
                "no Cloud workspace is configured (invalid params)",
            ),
        ),
        (
            method::AGENT_SESSION_TURN_ABANDON,
            Run(
                json!({"sessionId": "$S", "prompt_id": "lso-p1", "generation": 1, "attempt_id": "lso-a1"}),
            ),
        ),
        (method::MUX_INBOX_THREADS, Run(json!({"sessionId": "$S"}))),
        (method::MUX_INBOX_THREAD, Run(json!({"sessionId": "$S", "threadId": "lso-thread"}))),
        (
            method::MUX_INBOX_REPLY,
            Any(
                json!({"sessionId": "$S", "threadId": "lso-thread", "text": "hi"}),
                "the chat has no inbox thread from another chat (invalid params)",
            ),
        ),
        (method::MUX_SET_TURN_CAP, Run(json!({"sessionId": "$S", "turnCapMs": null}))),
        (method::MUX_ATTACH, Run(json!({"sessionId": "$S"}))),
        (method::MUX_VIEW, Run(json!({"sessionId": "$S", "visible": true}))),
        (method::MUX_TYPING, Run(json!({"sessionId": "$S", "on": true}))),
        (method::MUX_MARK_UNREAD, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_APP_REPLY,
            Any(
                json!({"sessionId": "$S", "to": "$S", "replyTo": "m1", "threadId": "t1", "text": "hi", "replyId": "r1"}),
                "only the app (Origin::LocalApp) may reply in place (invalid params)",
            ),
        ),
        (method::MUX_HARNESS_INVENTORY_WATCH, Run(json!({"enabled": true}))),
        (method::MUX_WATCH, Run(json!({}))),
        (method::MUX_EVENTS, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_ATTACHMENT,
            Run(
                json!({"sessionId": "$S", "id": "0000000000000000000000000000000000000000000000000000000000000000"}),
            ),
        ),
        (method::MUX_QUEUE_TEXT, Run(json!({"sessionId": "$S", "promptId": "p1"}))),
        (
            method::MUX_MAIL_SEND,
            Run(json!({"id": "m1", "sender": "$S", "target": "reports:test", "body": "hi"})),
        ),
        (method::MUX_DETACH, Run(json!({"sessionId": "$S"}))),
        (method::MUX_MAIL_READ, Run(json!({"recipient": "reports:test"}))),
        (method::MUX_MAIL_WAIT, Run(json!({"recipient": "reports:test", "timeoutMs": 100}))),
        (
            method::MUX_MAIL_ACK,
            Any(
                json!({"recipient": "$S", "receipt": {"hostId": "local", "muxSessionId": "$S", "generation": 0}, "messageId": "m1"}),
                "needs the chat's session receipt, which the table does not read (invalid params)",
            ),
        ),
        (
            method::MUX_TEAM_SEND,
            Any(
                json!({"to": "@team/role", "body": "hi"}),
                "team messaging is off without a mesh relay (invalid params)",
            ),
        ),
        (
            method::MUX_TEAM_INBOX,
            Any(json!({}), "team messaging is off without a mesh relay (invalid params)"),
        ),
        (
            method::MUX_TEAM_READ,
            Any(json!({"id": "x"}), "team messaging is off without a mesh relay (invalid params)"),
        ),
        (
            method::MUX_TEAM_ACK,
            Any(json!({"id": "x"}), "team messaging is off without a mesh relay (invalid params)"),
        ),
        (
            method::MUX_REGISTER,
            Any(
                json!({"name": "lso-register"}),
                "taken only from the unix socket, by the peer's pid (invalid params)",
            ),
        ),
        (method::MUX_RENAME, Run(json!({"sessionId": "$S", "newName": "renamed-s"}))),
        (
            method::MUX_KEEP,
            Any(
                json!({"sessionId": "$S"}),
                "the chat is not an ephemeral chat of this connection (invalid params)",
            ),
        ),
        (
            method::MUX_WATCH_TAKE_OVER,
            Any(json!({"sessionId": "$S"}), "the chat watches no conversation (invalid params)"),
        ),
        (method::MUX_QUEUE_EDIT, Run(json!({"sessionId": "$S", "op": "resume"}))),
        (method::MUX_QUEUE_REMOVE, Run(json!({"sessionId": "$S", "promptId": "p1"}))),
        (
            method::MUX_QUEUE_APPROVE,
            Run(json!({"sessionId": "$S", "promptId": "p1", "turnId": "t1", "revision": 0})),
        ),
        (method::MUX_QUEUE_DECLINE, Run(json!({"sessionId": "$S", "promptId": "p1"}))),
        (method::MUX_QUEUE_GET, Run(json!({"sessionId": "$S", "promptId": "p1"}))),
        (
            method::MUX_SEND_QUEUE,
            Run(
                json!({"request": {"sessionId": "$S", "prompt": [{"type": "text", "text": "hi"}]}}),
            ),
        ),
        (
            method::MUX_SEND_STATUS,
            Any(
                json!({"deliveryId": "0190a000-0000-7000-8000-000000000000", "waitMs": 0}),
                "needs a delivery id from an earlier send (invalid params)",
            ),
        ),
        (method::MUX_SESSION_AUTH, Run(json!({"sessionId": "$S"}))),
        (method::MUX_PROMPT_WITHDRAW, Run(json!({"sessionId": "$S", "promptId": "p-none"}))),
        (
            method::MUX_AGENT_PAIR_RESUME,
            Any(json!({"sessionId": "$S"}), "a connection that is not the person is refused"),
        ),
        (
            method::MUX_AGENT_HOLD,
            Any(
                json!({"sessionId": "$S", "held": false}),
                "a connection that is not the person is refused",
            ),
        ),
        (
            method::MUX_RETRY,
            Any(
                json!({"sessionId": "$S"}),
                "the turn that send_queue started still runs (invalid params: retry.busy)",
            ),
        ),
        (method::MUX_INBOX_DIGEST, Run(json!({"sessionId": "$S", "dryRun": true}))),
        (method::MUX_PERMISSION_GROUPS, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_PERMISSION_GROUP_RESPOND,
            Run(
                json!({"sessionId": "$S", "groupId": "g1", "decisionKey": "k1", "decision": "deny", "revision": 0}),
            ),
        ),
        (method::MUX_PERMISSION_CHAT_REVOKE, Run(json!({"sessionId": "$S"}))),
        (method::MUX_PERMISSION_RESPOND, Run(json!({"sessionId": "$S", "permissionId": "p1"}))),
        (method::MUX_SET_POLICY, Run(json!({"sessionId": "$S", "policy": "ask"}))),
        (method::MUX_EXPORT, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_IMPORT,
            Any(json!({"path": "$CWD/no-such-bundle"}), "no bundle at the path (invalid params)"),
        ),
        (
            method::MUX_FILE_PUT,
            Run(json!({"sessionId": "$S", "fileName": "a.txt", "data": "aGk="})),
        ),
        (
            method::MUX_FILE_PUT_BEGIN,
            Run(json!({"sessionId": "$S", "fileName": "a.txt", "size": 2})),
        ),
        (
            method::MUX_FILE_PUT_CHUNK,
            Any(
                json!({"sessionId": "$S", "uploadId": "0190a000-0000-7000-8000-000000000000", "offset": 0, "data": "aGk="}),
                "needs an upload id from file_put_begin (invalid params)",
            ),
        ),
        (
            method::MUX_FILE_PUT_FINISH,
            Any(
                json!({"sessionId": "$S", "uploadId": "0190a000-0000-7000-8000-000000000000", "fileName": "a.txt", "size": 2}),
                "needs an upload id from file_put_begin (invalid params)",
            ),
        ),
        (
            method::MUX_FILE_PUT_CANCEL,
            Run(json!({"sessionId": "$S", "uploadId": "0190a000-0000-7000-8000-000000000000"})),
        ),
        (
            method::MUX_FILE_PUT_STATUS,
            Any(
                json!({"sessionId": "$S", "uploadId": "0190a000-0000-7000-8000-000000000000"}),
                "needs an upload id from file_put_begin (invalid params)",
            ),
        ),
        (method::MUX_UPLOADS_KEEP, Run(json!({"sessionId": "$S", "keep": true}))),
        (method::MUX_WORKFLOWS, Run(json!({}))),
        (
            method::MUX_MEDIA_OPEN,
            Any(
                json!({"sessionId": "$S", "path": "$CWD/a.txt"}),
                "the file does not exist (invalid params)",
            ),
        ),
        (
            method::MUX_MEDIA_RANGE,
            Any(
                json!({"sessionId": "$S", "handle": "h1", "offset": 0, "length": 1}),
                "needs a handle from media_open (invalid params)",
            ),
        ),
        (
            method::MUX_SUBAGENT_TRANSCRIPT,
            Any(
                json!({"sessionId": "$S", "agentId": "a1"}),
                "only a Claude Code chat has subagent transcripts (invalid params)",
            ),
        ),
        (
            method::MUX_NATIVE_HISTORY,
            Any(
                json!({"sessionId": "$S", "before": 1}),
                "only a Claude Code chat has a native history (invalid params)",
            ),
        ),
        (method::MUX_SHUTDOWN, Skip("stops the hub")),
        (
            method::MUX_HANDOFF_PREPARE,
            Any(
                json!({"sessionId": "$S", "harness": "fake", "handoffKey": "k1"}),
                "a handoff needs a second harness, and this hub has only fake (invalid params)",
            ),
        ),
        (method::MUX_HANDOFF_GET, Run(json!({"sessionId": "$S"}))),
        (
            method::MUX_HANDOFF_DRAFT,
            Run(
                json!({"handoffId": "h1", "revision": 1, "draftKey": "d1", "capsule": {"text": "x"}}),
            ),
        ),
        (method::MUX_HANDOFF_START, Run(json!({"handoffId": "h1"}))),
        (method::MUX_HANDOFF_DISCARD, Run(json!({"handoffId": "h1"}))),
        (method::SESSION_CLOSE, Run(json!({"sessionId": "$T"}))),
        (method::SESSION_DELETE, Run(json!({"sessionId": "$T"}))),
        (method::MUX_KILL, Run(json!({"sessionId": "$T"}))),
    ]
}
