//! acpmux event-log lines, as acpmux's `EventRecord` serializes them: `{"seq","at","dir","kind","msg"
//! [,"hostSeq"]}` with `msg` keys in serde_json's sorted order. The payload shapes are the ones acpmux and
//! the chat UI parse: ACP `session/update` notifications (`params.update.sessionUpdate`), the harness's raw
//! lines (`claude.*` stdout objects, `codex.*` app-server notifications), JSON-RPC requests and replies,
//! and acpmux's own `mux` records. Each template has one slot where filler text grows the line to its
//! drawn size; a template with no natural text field gets `_meta.coordSim` (ACP's extension field) only
//! when the line is short of its size by more than that field costs.

use std::fmt::Write as _;

/// One rendered line: `head` + filler + `tail` + `\n`, the filler `fill` bytes long.
#[derive(Debug, Default)]
pub struct Line {
    pub buf: String,
    pub slot: usize,
    pub fill: u64,
}

impl Line {
    pub fn head(&self) -> &str {
        self.buf.get(..self.slot).unwrap_or("")
    }
    pub fn tail(&self) -> &str {
        self.buf.get(self.slot..).unwrap_or("")
    }
    /// The whole line's length with its newline.
    pub fn len(&self) -> u64 {
        self.buf.len() as u64 + self.fill + 1
    }
}

/// What a coordinator's lines refer to, so a chat reads as one conversation: its turn, prompt, open tool
/// calls, subagents and request ids.
#[derive(Debug, Clone)]
pub struct Ctx {
    pub harness: &'static str,
    pub session_id: String,
    pub agent_session: String,
    pub name: String,
    /// The coordinator a `mux:queued` about to render came from.
    pub peer: String,
    pub turn: u64,
    pub turn_seq: u64,
    pub msg: u64,
    pub rpc: u64,
    pub host_seq: u64,
    pub tool: u64,
    pub sub: u64,
    pub task: u64,
    pub uuid: u64,
    pub tool_kinds: Vec<(String, u64)>,
    pub tool_kind_pick: u64,
    /// Images the next `user_message` names: (sha256 id, mime, name).
    pub images: Vec<(String, String, String)>,
}

impl Ctx {
    pub fn new(
        harness: &'static str,
        session_id: String,
        agent_session: String,
        name: String,
    ) -> Ctx {
        Ctx {
            harness,
            session_id,
            agent_session,
            name,
            peer: String::new(),
            turn: 0,
            turn_seq: 0,
            msg: 0,
            rpc: 0,
            host_seq: 0,
            tool: 0,
            sub: 0,
            task: 0,
            uuid: 0,
            tool_kinds: Vec::new(),
            tool_kind_pick: 0,
            images: Vec::new(),
        }
    }

    fn turn_id(&self) -> String {
        format!("turn-{}", self.turn)
    }
    fn prompt_id(&self) -> String {
        format!("prompt-{}", self.turn)
    }
    fn tool_id(&self) -> String {
        format!("toolu_sim{:08}", self.tool.max(1))
    }
    fn sub_id(&self) -> String {
        format!("{}-sub-{}", self.agent_session, self.sub.max(1))
    }
    fn next_uuid(&mut self) -> String {
        self.uuid += 1;
        format!("00000000-0000-4000-8000-{:012x}", self.uuid)
    }
    fn next_rpc(&mut self) -> u64 {
        self.rpc += 1;
        self.rpc
    }
    fn tool_kind(&self) -> &str {
        let total: u64 = self.tool_kinds.iter().map(|k| k.1).sum();
        if total == 0 {
            return "execute";
        }
        let mut pick = self.tool_kind_pick % total;
        for (k, w) in &self.tool_kinds {
            if pick < *w {
                return k;
            }
            pick -= w;
        }
        "execute"
    }
}

/// The record kind acpmux writes for a shape key: the probe prints kinds that are not protocol
/// identifiers as `other`; these are the ones it saw there.
pub fn record_kind(key: &str) -> (&str, &str) {
    let (dir, kind) = key.split_once(':').unwrap_or(("in", key));
    let kind = match (dir, kind) {
        ("in", "other") => "_acpmux/claude/tool_gate",
        ("out", "other") => "_acpmux/claude/background_tasks",
        ("mux", "other") => "_acpmux/message",
        _ => kind,
    };
    (dir, kind)
}

/// Marks the filler slot.
struct W<'a> {
    s: &'a mut String,
    slot: &'a mut Option<usize>,
}

impl W<'_> {
    fn p(&mut self, t: &str) -> &mut Self {
        self.s.push_str(t);
        self
    }
    fn f(&mut self) -> &mut Self {
        *self.slot = Some(self.s.len());
        self
    }
    /// A JSON string value (the caller's text is ASCII without quotes or backslashes).
    fn q(&mut self, t: &str) -> &mut Self {
        self.s.push('"');
        self.s.push_str(t);
        self.s.push('"');
        self
    }
    fn n(&mut self, v: u64) -> &mut Self {
        let _ = write!(self.s, "{v}");
        self
    }
    /// `"_meta":{"coordSim":"<fill>"},` when `pad`.
    fn meta(&mut self, pad: bool) -> &mut Self {
        if pad {
            self.p("\"_meta\":{\"coordSim\":\"").f().p("\"},");
        }
        self
    }
}

/// Renders the `msg` of one record. `pad`: add the `_meta` slot when the template has no natural one.
/// `update_kinds`: the ACP `sessionUpdate` values (shape `session_update_bytes`).
fn msg(dir: &str, kind: &str, ctx: &mut Ctx, at: u64, pad: bool, is_update: bool, w: &mut W<'_>) {
    if dir == "in" && is_update {
        let su = kind.strip_suffix(".replay").unwrap_or(kind);
        w.p("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":")
            .q(&ctx.agent_session.clone())
            .p(",\"update\":{");
        update(su, ctx, pad, w);
        w.p("}}}");
        return;
    }
    match dir {
        "in" => msg_in(kind, ctx, at, pad, w),
        "out" => msg_out(kind, ctx, pad, w),
        _ => msg_mux(kind, ctx, at, pad, w),
    }
}

fn update(su: &str, ctx: &mut Ctx, pad: bool, w: &mut W<'_>) {
    let text_content = |w: &mut W<'_>| {
        w.p("\"content\":{\"text\":\"").f().p("\",\"type\":\"text\"}");
    };
    match su {
        "agent_message_chunk" => {
            text_content(w);
            let m = format!("msg-{}", ctx.msg);
            w.p(",\"messageId\":").q(&m).p(",\"sessionUpdate\":\"agent_message_chunk\"");
        }
        "agent_thought_chunk" | "user_message_chunk" => {
            text_content(w);
            w.p(",\"sessionUpdate\":").q(su);
        }
        "tool_call" => {
            ctx.tool += 1;
            ctx.tool_kind_pick =
                ctx.tool_kind_pick.wrapping_mul(6364136223846793005).wrapping_add(ctx.tool);
            let k = ctx.tool_kind().to_owned();
            let id = ctx.tool_id();
            w.p("\"kind\":").q(&k).p(",\"rawInput\":{\"command\":\"").f().p("\"},\"sessionUpdate\":\"tool_call\",\"status\":\"pending\",\"title\":\"Bash\",\"toolCallId\":").q(&id);
        }
        "tool_call_update" => {
            if ctx.tool == 0 {
                ctx.tool = 1;
            }
            let id = ctx.tool_id();
            w.p("\"content\":[{\"content\":{\"text\":\"").f().p("\",\"type\":\"text\"},\"type\":\"content\"}],\"sessionUpdate\":\"tool_call_update\",\"status\":\"completed\",\"toolCallId\":").q(&id);
        }
        "plan" => {
            w.p("\"entries\":[{\"content\":\"").f().p("\",\"priority\":\"medium\",\"status\":\"in_progress\"}],\"sessionUpdate\":\"plan\"");
        }
        "available_commands_update" => {
            w.p("\"availableCommands\":[{\"description\":\"")
                .f()
                .p("\",\"name\":\"coord-sim\"}],\"sessionUpdate\":\"available_commands_update\"");
        }
        "compaction_summary" => {
            w.p("\"sessionUpdate\":\"compaction_summary\",\"text\":\"").f().p("\"");
        }
        "prompt_suggestion" => {
            w.p("\"sessionUpdate\":\"prompt_suggestion\",\"suggestion\":\"").f().p("\"");
        }
        "subagent_spawned" => {
            ctx.sub += 1;
            let id = ctx.sub_id();
            let name = format!("sub-{}", ctx.sub);
            w.p("\"capabilities\":{},\"name\":")
                .q(&name)
                .p(",\"sessionUpdate\":\"subagent_spawned\",\"subagentSessionId\":")
                .q(&id)
                .p(",\"task\":\"")
                .f()
                .p("\"");
        }
        "background_task_update" => {
            ctx.task += 1;
            let task = format!("task-{}", ctx.task);
            let tool = ctx.tool_id();
            w.p("\"command\":\"").f().p("\",\"description\":\"coord-sim task\",\"origin\":\"auto_backgrounded\",\"sessionUpdate\":\"background_task_update\",\"state\":\"running\",\"taskId\":").q(&task).p(",\"toolCallId\":").q(&tool);
        }
        "usage_update" => {
            w.meta(pad)
                .p("\"sessionUpdate\":\"usage_update\",\"size\":1000000,\"used\":")
                .n(20_000 + (ctx.msg % 900_000));
        }
        "current_mode_update" => {
            w.meta(pad)
                .p("\"currentModeId\":\"default\",\"sessionUpdate\":\"current_mode_update\"");
        }
        "compaction" => {
            w.meta(pad).p("\"sessionUpdate\":\"compaction\",\"state\":\"completed\"");
        }
        "subagent_progress" => {
            let id = ctx.sub_id();
            w.meta(pad).p("\"action\":\"Bash\",\"elapsedMs\":1000,\"sessionUpdate\":\"subagent_progress\",\"subagentSessionId\":").q(&id).p(",\"tokens\":1000,\"toolUses\":1");
        }
        "subagent_state_update" => {
            let id = ctx.sub_id();
            w.meta(pad).p("\"sessionUpdate\":\"subagent_state_update\",\"state\":\"running\",\"subagentSessionId\":").q(&id);
        }
        // config_option_update, session_info_update and any other: no field of their own is free text.
        other => {
            w.meta(pad).p("\"sessionUpdate\":").q(other);
        }
    }
}

fn msg_in(kind: &str, ctx: &mut Ctx, at: u64, _pad: bool, w: &mut W<'_>) {
    let sid = ctx.agent_session.clone();
    if kind == "codex.response" {
        let id = ctx.next_rpc();
        w.p("{\"jsonrpc\":\"2.0\",\"method\":\"codex.response\",\"params\":{\"id\":")
            .n(id)
            .p(",\"result\":{\"coordSim\":\"")
            .f()
            .p("\"}}}");
        return;
    }
    if let Some(m) = kind.strip_prefix("codex.") {
        w.p("{\"jsonrpc\":\"2.0\",\"method\":")
            .q(kind)
            .p(",\"params\":{\"emittedAtMs\":")
            .n(at)
            .p(",\"method\":")
            .q(m)
            .p(",\"params\":{\"coordSim\":\"")
            .f()
            .p("\",\"threadId\":")
            .q(&sid)
            .p("}}}");
        return;
    }
    if let Some(c) = kind.strip_prefix("claude.") {
        let uuid = ctx.next_uuid();
        let (ty, sub) = c.split_once('.').unwrap_or((c, ""));
        match ty {
            "assistant" | "user" => {
                ctx.msg += 1;
                w.p("{\"message\":{\"content\":[{\"text\":\"").f().p("\",\"type\":\"text\"}],");
                if ty == "assistant" {
                    let id = format!("msg_sim{:08}", ctx.msg);
                    w.p("\"id\":").q(&id).p(
                        ",\"model\":\"claude-sim\",\"role\":\"assistant\",\"type\":\"message\"},",
                    );
                } else {
                    w.p("\"role\":\"user\"},");
                }
                w.p("\"parent_tool_use_id\":null,\"session_id\":")
                    .q(&sid)
                    .p(",\"type\":")
                    .q(ty)
                    .p(",\"uuid\":")
                    .q(&uuid)
                    .p("}");
            }
            "stream_event" => {
                w.p("{\"event\":{\"delta\":{\"text\":\"").f().p("\",\"type\":\"text_delta\"},\"index\":0,\"type\":\"content_block_delta\"},\"parent_tool_use_id\":null,\"session_id\":").q(&sid).p(",\"type\":\"stream_event\",\"uuid\":").q(&uuid).p("}");
            }
            "result" => {
                w.p("{\"is_error\":false,\"result\":\"")
                    .f()
                    .p("\",\"session_id\":")
                    .q(&sid)
                    .p(",\"subtype\":")
                    .q(sub)
                    .p(",\"type\":\"result\",\"uuid\":")
                    .q(&uuid)
                    .p("}");
            }
            "control_request" => {
                let rid = format!("req-{}", ctx.next_rpc());
                w.p("{\"request\":{\"callback_id\":\"coord-sim\",\"input\":{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"").f().p("\"},\"tool_name\":\"Bash\"},\"subtype\":\"hook_callback\"},\"request_id\":").q(&rid).p(",\"type\":\"control_request\"}");
            }
            "control_response" => {
                let rid = format!("req-{}", ctx.rpc);
                w.p("{\"response\":{\"request_id\":")
                    .q(&rid)
                    .p(",\"response\":{\"coordSim\":\"")
                    .f()
                    .p("\"},\"subtype\":\"success\"},\"type\":\"control_response\"}");
            }
            _ => {
                w.p("{\"coordSim\":\"").f().p("\",\"session_id\":").q(&sid);
                if !sub.is_empty() {
                    w.p(",\"subtype\":").q(sub);
                }
                w.p(",\"type\":").q(ty).p(",\"uuid\":").q(&uuid).p("}");
            }
        }
        return;
    }
    match kind {
        "response" => {
            let id = ctx.rpc;
            w.p("{\"id\":")
                .n(id)
                .p(",\"jsonrpc\":\"2.0\",\"result\":{\"_meta\":{\"coordSim\":\"")
                .f()
                .p("\"},\"stopReason\":\"end_turn\"}}");
        }
        "session/request_permission" | "_acpmux/claude/tool_gate" => {
            let id = 1_000_000 + ctx.next_rpc();
            let tool = ctx.tool_id();
            w.p("{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"method\":").q(kind).p(",\"params\":{\"options\":[{\"kind\":\"allow_once\",\"name\":\"Allow\",\"optionId\":\"allow_once\"}],\"sessionId\":").q(&sid).p(",\"toolCall\":{\"kind\":\"execute\",\"rawInput\":{\"command\":\"").f().p("\"},\"status\":\"pending\",\"title\":\"Bash\",\"toolCallId\":").q(&tool).p("}}}");
        }
        _ => {
            w.p("{\"jsonrpc\":\"2.0\",\"method\":")
                .q(kind)
                .p(",\"params\":{\"_meta\":{\"coordSim\":\"")
                .f()
                .p("\"},\"sessionId\":")
                .q(&sid)
                .p("}}");
        }
    }
}

fn msg_out(kind: &str, ctx: &mut Ctx, pad: bool, w: &mut W<'_>) {
    let sid = ctx.agent_session.clone();
    match kind {
        "session/prompt" => {
            let id = ctx.next_rpc();
            w.p("{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"text\":\"").f().p("\",\"type\":\"text\"}],\"sessionId\":").q(&sid).p("}}");
        }
        "response" => {
            let id = 1_000_000 + ctx.rpc;
            w.p("{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"result\":{");
            w.meta(pad);
            w.p("\"decision\":\"none\"}}");
        }
        "claude.stdin" => {
            w.p("{\"message\":{\"content\":[{\"text\":\"").f().p("\",\"type\":\"text\"}],\"role\":\"user\"},\"parent_tool_use_id\":null,\"session_id\":\"\",\"type\":\"user\"}");
        }
        "codex.stdin" => {
            let id = ctx.next_rpc();
            w.p("{\"jsonrpc\":\"2.0\",\"method\":\"codex.stdin\",\"params\":{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"method\":\"turn/steer\",\"params\":{\"input\":[{\"text\":\"").f().p("\",\"type\":\"text\"}],\"threadId\":").q(&sid).p("}}}");
        }
        "initialize" => {
            let id = ctx.next_rpc();
            w.p("{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{");
            w.meta(pad);
            w.p("\"clientInfo\":{\"name\":\"acpmux\",\"version\":\"1.0.0\"},\"protocolVersion\":1}}");
        }
        _ => {
            let id = ctx.next_rpc();
            w.p("{\"id\":").n(id).p(",\"jsonrpc\":\"2.0\",\"method\":").q(kind).p(",\"params\":{");
            w.meta(pad);
            w.p("\"sessionId\":").q(&sid).p("}}");
        }
    }
}

fn msg_mux(kind: &str, ctx: &mut Ctx, at: u64, pad: bool, w: &mut W<'_>) {
    let (turn, prompt) = (ctx.turn_id(), ctx.prompt_id());
    match kind {
        "user_message" => {
            w.p("{\"_meta\":{\"origin\":{\"actor\":\"person\",\"verified\":true}},\"client\":\"coord-sim\",\"control\":\"local\",");
            if !ctx.images.is_empty() {
                w.p("\"images\":[");
                let images = std::mem::take(&mut ctx.images);
                for (i, (id, mime, name)) in images.iter().enumerate() {
                    if i > 0 {
                        w.p(",");
                    }
                    w.p("{\"id\":")
                        .q(id)
                        .p(",\"mimeType\":")
                        .q(mime)
                        .p(",\"name\":")
                        .q(name)
                        .p("}");
                }
                w.p("],");
            }
            w.p("\"promptId\":")
                .q(&prompt)
                .p(",\"text\":\"")
                .f()
                .p("\",\"trustGate\":false,\"turnId\":")
                .q(&turn)
                .p("}");
        }
        "turn_started" => {
            w.p("{\"client\":\"coord-sim\",\"control\":\"local\",\"persons\":true,\"prompt\":\"")
                .f()
                .p("\",\"promptId\":")
                .q(&prompt)
                .p(",\"trigger\":false,\"trustGate\":false,\"turnId\":")
                .q(&turn)
                .p("}");
        }
        "queued" => {
            ctx.msg += 1;
            let p = format!("peer-prompt-{}", ctx.msg);
            w.p("{\"class\":\"result\",\"client\":\"coord-sim-peer\",\"control\":\"peer\",\"fromAgent\":").q(&ctx.peer.clone()).p(",\"promptId\":").q(&p).p(",\"text\":\"").f().p("\",\"trustGate\":false,\"turnId\":").q(&turn).p("}");
        }
        "_acpmux/message" => {
            ctx.msg += 1;
            let m = format!("message-{}", ctx.msg);
            let sid = ctx.session_id.clone();
            w.p("{\"at\":")
                .n(at)
                .p(",\"messageId\":")
                .q(&m)
                .p(",\"sender\":{\"label\":\"coord-sim\",\"name\":\"coord-sim\",\"sessionId\":")
                .q(&sid)
                .p("},\"sessionId\":")
                .q(&sid)
                .p(",\"text\":\"")
                .f()
                .p("\"}");
        }
        "inbox" => {
            w.p("{\"class\":\"result\",\"from\":\"coord-sim\",\"kind\":\"action\",\"prompt\":[{\"text\":\"").f().p("\",\"type\":\"text\"}],\"promptId\":").q(&prompt).p(",\"text\":\"coord-sim\",\"threadId\":\"from:coord-sim\"}");
        }
        "stderr" | "recap" | "titled" | "stopping" => {
            let field = if kind == "titled" { "title" } else { "text" };
            w.p("{\"").p(field).p("\":\"").f().p("\"}");
        }
        "process_update" => {
            ctx.task += 1;
            let id = format!("proc-{}", ctx.task);
            let sid = ctx.session_id.clone();
            let h = ctx.harness;
            w.p("{\"process\":{\"command\":\"").f().p("\",\"cwd\":\"/tmp\",\"description\":\"coord-sim\",\"endedAt\":null,\"exitCode\":null,\"harness\":").q(h).p(",\"id\":").q(&id).p(",\"origin\":\"auto_backgrounded\",\"outputBytes\":null,\"reason\":null,\"sessionId\":").q(&sid).p(",\"signal\":null,\"startedAt\":").n(at).p("}}");
        }
        "permission_auto" => {
            let tool = ctx.tool_id();
            let sid = ctx.agent_session.clone();
            w.p("{\"chatAllowance\":false,\"fullAccess\":\"bypassPermissions\",\"optionId\":\"allow_once\",\"permissionId\":\"perm-").n(ctx.rpc).p("\",\"policy\":\"approve-all\",\"request\":{\"options\":[{\"kind\":\"allow_once\",\"name\":\"Allow\",\"optionId\":\"allow_once\"}],\"sessionId\":").q(&sid).p(",\"toolCall\":{\"kind\":\"execute\",\"rawInput\":{\"command\":\"").f().p("\"},\"status\":\"pending\",\"title\":\"Bash\",\"toolCallId\":").q(&tool).p("}},\"rule\":null}");
        }
        "permission_decision" => {
            w.p("{");
            w.meta(pad);
            w.p("\"outcome\":{\"outcome\":\"cancelled\"},\"permissionId\":\"perm-")
                .n(ctx.rpc)
                .p("\"}");
        }
        "turn_end" => {
            ctx.turn_seq += 1;
            w.p("{");
            w.meta(pad);
            w.p("\"stopReason\":\"end_turn\",\"turnId\":")
                .q(&turn)
                .p(",\"turnSeq\":")
                .n(ctx.turn_seq)
                .p("}");
        }
        "turn_result" => {
            w.p("{");
            w.meta(pad);
            w.p("\"model\":\"sim\",\"promptId\":")
                .q(&prompt)
                .p(",\"status\":\"completed\",\"stopReason\":\"end_turn\"}");
        }
        "dequeued" | "steer_read" => {
            w.p("{");
            w.meta(pad);
            w.p("\"promptId\":").q(&prompt);
            if kind == "dequeued" {
                w.p(",\"queued\":0");
            }
            w.p(",\"turnId\":").q(&turn).p("}");
        }
        "status" => {
            w.p("{");
            w.meta(pad);
            w.p("\"status\":\"ready\"}");
        }
        "created" => {
            w.p("{");
            w.meta(pad);
            w.p("\"harness\":").q(ctx.harness).p(",\"preset\":null}");
        }
        "mode" => {
            w.p("{");
            w.meta(pad);
            w.p("\"modeId\":\"default\"}");
        }
        "stopped" => {
            w.p("{");
            w.meta(pad);
            w.p("\"code\":0,\"hibernated\":true}");
        }
        "resumed" => {
            w.p("{");
            w.meta(pad);
            w.p("\"level\":\"exact\",\"wake\":true}");
        }
        "turn_silent" | "turn_heard" => {
            w.p("{");
            w.meta(pad);
            if kind == "turn_silent" {
                w.p("\"silentMs\":90000,");
            }
            w.p("\"turnId\":").q(&turn).p("}");
        }
        "turn_error" | "turn_retrying" => {
            w.p("{\"code\":-32603,\"error\":\"").f().p("\",\"turnId\":").q(&turn).p("}");
        }
        "background_turn" => {
            w.p("{");
            w.meta(pad);
            w.p("\"id\":\"bg-").n(ctx.turn).p("\",\"state\":\"started\",\"trigger\":\"system\"}");
        }
        "subagents_running" => {
            w.p("{");
            w.meta(pad);
            w.p("\"count\":1}");
        }
        "subagents_working" => {
            w.p("{");
            w.meta(pad);
            w.p("\"since\":").n(at).p("}");
        }
        "host_started" | "host_adopted" => {
            w.p("{");
            w.meta(pad);
            w.p("\"hostBuild\":\"coord-sim\",\"incarnation\":\"coord-sim\"}");
        }
        // Any other mux record: its fields are acpmux's own and none is read back from a static log.
        _ => {
            w.p("{\"text\":\"").f().p("\"}");
        }
    }
}

/// Renders one record of shape key `key` at `seq` and `at`, sized to `target` bytes (newline included)
/// when the template allows it.
pub fn render(key: &str, seq: u64, at: u64, target: u64, is_update: bool, ctx: &mut Ctx) -> Line {
    let (dir, kind) = record_kind(key);
    let host = dir != "mux";
    if host {
        ctx.host_seq += 1;
    }
    let build = |pad: bool, ctx: &mut Ctx| {
        let mut s = String::with_capacity(256);
        let mut slot = None;
        let _ =
            write!(s, "{{\"seq\":{seq},\"at\":{at},\"dir\":\"{dir}\",\"kind\":\"{kind}\",\"msg\":");
        {
            let mut w = W { s: &mut s, slot: &mut slot };
            msg(dir, kind, ctx, at, pad, is_update, &mut w);
        }
        if host {
            let _ = write!(s, ",\"hostSeq\":{}", ctx.host_seq);
        }
        s.push('}');
        (s, slot)
    };
    // The template's ids move on as it renders: render on a copy first when it may be rendered twice.
    let saved = ctx.clone();
    let (mut s, mut slot) = build(false, ctx);
    if slot.is_none() && target > s.len() as u64 + 1 + 24 {
        *ctx = saved;
        (s, slot) = build(true, ctx);
    }
    let slot_at = slot.unwrap_or(s.len());
    let fill = match slot {
        Some(_) => target.saturating_sub(s.len() as u64 + 1),
        None => 0,
    };
    let _ = &mut s;
    Line { buf: s, slot: slot_at, fill }
}

/// A user turn starts: the turn and prompt ids the next records name.
pub fn begin_turn(ctx: &mut Ctx) {
    ctx.turn += 1;
}

#[cfg(test)]
#[path = "render_tests.rs"]
mod tests;
