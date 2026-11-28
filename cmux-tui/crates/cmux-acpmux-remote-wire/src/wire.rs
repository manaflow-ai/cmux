//! The state machine of one remote chat's wire. See the crate docs for the shape: inputs in,
//! [`Effect`]s out, run in order by the app. Every call the machine asks for carries a `task`
//! number; the app answers it with [`Wire::done`] (the daemon's JSON as text, or a [`Failure`]).

use crate::parse;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::hash::{BuildHasher, Hasher};

/// JSON-RPC `code` of a refused method; `data.code` carries the names below.
pub const UNSUPPORTED_CODE: i64 = -32601;
pub const UNSUPPORTED: &str = "remote.unsupported";
pub const READ_ONLY: &str = "agent_session.read_only";
/// A sign-in step acpmux refused (its reason in `data.reason`).
pub const LOGIN_REFUSED: &str = "agent_login.refused";
/// A side question acpmux refused (its reason in `data.reason`).
pub const BTW_REFUSED: &str = "btw.refused";
/// The relay's mark on a Trust answer for a home folder the person chose there.
pub const HOME_CHOSEN_PARAM: &str = "cmuxHomeChosen";
pub const SIDE_CHAT_METHOD: &str = "_acpmux/side_chat";

/// What the app's wire was made with.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    /// The chat's session (its store record) when the wire starts with a daemon attachment;
    /// `None` for a new chat that has no session until its first `session/new`.
    pub session: Option<String>,
    /// The attachment observes without permission to prompt, cancel or answer.
    pub read_only: bool,
    pub host: Option<String>,
    pub links_alias: Option<String>,
    /// The app can answer the folder trust question (`acp.trust.get`/`set`).
    pub trust: bool,
    /// The app can say whether the machine is the person's own Cloud VM.
    pub owner_cloud: bool,
    /// The app can start a chat there (a new chat's wire).
    pub start: bool,
    /// The app wants the send timeline's milestones.
    pub milestone: bool,
    pub serves_login: bool,
    pub serves_side: bool,
    /// False for a Cloud machine: it holds no provider login, so no on-machine sign-in is offered.
    pub machine_sign_in: bool,
    /// The app can sign a sessionless chat's agent in on its machine.
    pub machine_login: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            session: None,
            read_only: false,
            host: None,
            links_alias: None,
            trust: false,
            owner_cloud: false,
            start: false,
            milestone: false,
            serves_login: false,
            serves_side: false,
            machine_sign_in: true,
            machine_login: false,
        }
    }
}

/// A refused daemon call: its stable `error_code` (`agent_session.*`) and text.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Failure {
    pub code: String,
    pub message: String,
    /// The folder a refused start named (`agent_session.untrusted_folder`).
    pub folder: Option<String>,
    /// A refused start's typed facts for the page's `data`, never words.
    pub facts: BTreeMap<String, String>,
}

/// One push of the daemon's attachment; `data` is the daemon's own JSON text.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Event {
    Record { data: String },
    Permission { data: String },
    Changed { data: String },
    Presence { data: String },
    Closed { reason: String },
}

/// What the app does, in order.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Effect {
    /// Send `frame` to the page.
    Emit { frame: String },
    /// Call a verb of the chat's daemon client; answer with `done(task, json text or failure)`.
    /// `cancel`, `detach`, `typing`, `view` and `permission` answer `{}`.
    Call { task: u64, verb: &'static str, args: Value },
    /// Read what `initialize` names: `owned` (the Cloud owner answer), `login` and `side` (the
    /// client's `servesLogin` and `servesSide`), each only when asked; answer `{owned, login, side}`.
    Probe { task: u64, owner_cloud: bool, login: bool, side: bool },
    /// Start the chat on that machine; answer `{session, surface, read_only?}`.
    Start { task: u64, cwd: Option<String>, harness: Option<String>, model: Option<String> },
    /// The folder trust question or answer; answer with acpmux's reply JSON.
    Trust { task: u64, cwd: String, level: Option<String>, home_chosen: bool },
    /// One sign-in step of a sessionless chat on its machine.
    MachineLogin { task: u64, op: String, fields: BTreeMap<String, String> },
    /// Decode the base64 `data` as an image and answer `{"src": ...}`.
    DecodeImage { task: u64, data: String },
    /// Note the parents of daemon-listed children (under `host`, and `alias` as one daemon).
    NoteLinks { summaries: Vec<Value>, host: Option<String>, alias: Option<String> },
    /// Note a side chat as `parent`'s child under each host; the effects after it wait for it.
    NoteSide { side: String, parent: String, hosts: Vec<Option<String>> },
    /// A milestone of the send timeline, once each.
    Tell { step: &'static str },
    /// End the daemon attachment and its connection.
    CloseClient,
    /// The page's path ended by itself.
    ClosePage { code: i64, reason: String },
}

/// The answer to one page frame: whether the wire took it, and what to do.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Step {
    pub accepted: bool,
    pub effects: Vec<Effect>,
}

type Id = Option<String>;

/// How the answer of a task becomes the page's reply.
#[derive(Debug)]
enum Kind {
    Init {
        id: Id,
        extensions: Vec<&'static str>,
        sessionless: bool,
    },
    /// The daemon's JSON as the result.
    Plain(Id),
    /// An empty `{}` result.
    Unit(Id),
    Prompt {
        id: Id,
        session: String,
        prompt: String,
    },
    Attach {
        id: Id,
        watch: bool,
    },
    Children {
        id: Id,
        summary: Option<Value>,
    },
    Events(Id),
    Image(Id),
    Login {
        id: Id,
        code: &'static str,
        what: &'static str,
    },
    Side {
        id: Id,
        parent: String,
        prompted: bool,
    },
    Start {
        id: Id,
        cwd: Option<String>,
    },
}

/// One remote chat's wire.
pub struct Wire {
    cfg: Config,
    closed: bool,
    has_client: bool,
    read_only: bool,
    session: Option<String>,
    resolved: Option<String>,
    starting: bool,
    told: HashSet<&'static str>,
    next_task: u64,
    tasks: HashMap<u64, (Kind, bool)>,
    /// A model, mode or option pick is with the daemon: the next waits, so picks reach it in order.
    pick_busy: bool,
    picks: VecDeque<(u64, &'static str, Value)>,
    ids: u64,
}

impl Wire {
    pub fn new(mut cfg: Config) -> Self {
        let has_client = cfg.session.is_some();
        if has_client {
            cfg.start = false;
            cfg.milestone = false;
            cfg.serves_login = false;
            cfg.serves_side = false;
            cfg.machine_login = false;
        } else {
            // A Cloud machine holds no provider login, so it never offers the on-machine sign-in.
            cfg.serves_login = cfg.serves_login && cfg.machine_sign_in;
            cfg.machine_login = cfg.machine_login && cfg.machine_sign_in;
        }
        Self {
            closed: false,
            has_client,
            read_only: has_client && cfg.read_only,
            session: cfg.session.clone(),
            resolved: None,
            starting: false,
            told: HashSet::new(),
            next_task: 1,
            tasks: HashMap::new(),
            pick_busy: false,
            picks: VecDeque::new(),
            ids: 0,
            cfg,
        }
    }

    // MARK: Inputs

    /// One frame of the page, already checked by the host.
    pub fn frame(&mut self, text: &str) -> Step {
        let mut fx = Vec::new();
        if self.closed {
            return Step::default();
        }
        let Ok(Value::Object(frame)) = serde_json::from_str::<Value>(text) else {
            return Step::default();
        };
        let Some(method) = frame.get("method").and_then(Value::as_str) else {
            return Step::default();
        };
        let id: Id = frame.get("id").map(Value::to_string);
        let empty = Map::new();
        let params = frame.get("params").and_then(Value::as_object).unwrap_or(&empty);
        self.dispatch(&mut fx, id, method, params);
        Step { accepted: true, effects: fx }
    }

    /// One push of the daemon's attachment.
    pub fn event(&mut self, event: Event) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            Event::Record { data } => self.forward(&mut fx, "_acpmux/event", &data),
            Event::Permission { data } => {
                self.forward(&mut fx, "_acpmux/permission_pending", &data)
            }
            Event::Changed { data } => {
                let Some(change) = structured(&data) else { return fx };
                // A child's change (the daemon streams only this session's descendants): a new
                // child joins the chat's Subagents summary and the sidebar's tree.
                if let Some(object) = change.as_object()
                    && let Some(session) = object.get("session").filter(|s| s.is_object())
                    && let Some(id) = object.get("sessionId").and_then(Value::as_str)
                    && !self.names_str(id)
                {
                    self.note_links(&mut fx, vec![session.clone()]);
                }
                self.notify(&mut fx, "_acpmux/session_changed", &data);
            }
            Event::Presence { data } => {
                // Only this chat's set (the daemon streams no other's).
                let Some(Value::Object(presence)) = structured(&data) else { return fx };
                if self.names(presence.get("sessionId")) {
                    self.notify(&mut fx, "_acpmux/presence", &data);
                }
            }
            Event::Closed { reason } => {
                // The page reconnects (a fresh wire and daemon connection) and replays from the
                // newest seq it holds; this attachment's connection ends now.
                if self.close() && self.has_client {
                    fx.push(Effect::CloseClient);
                    fx.push(Effect::ClosePage { code: 1012, reason });
                }
            }
        }
        fx
    }

    /// The page's path ends (the host's decision).
    pub fn cancel(&mut self) -> Vec<Effect> {
        if self.close() && self.has_client { vec![Effect::CloseClient] } else { Vec::new() }
    }

    /// The answer of the call, probe or start `task` asked for.
    pub fn done(&mut self, task: u64, outcome: Result<String, Failure>) -> Vec<Effect> {
        let mut fx = Vec::new();
        let Some((kind, serial)) = self.tasks.remove(&task) else { return fx };
        self.finish(&mut fx, kind, outcome);
        if serial {
            self.pick_busy = false;
            if let Some((next, verb, args)) = self.picks.pop_front() {
                self.pick_busy = true;
                fx.push(Effect::Call { task: next, verb, args });
            }
        }
        fx
    }

    // MARK: Frames

    fn dispatch(
        &mut self,
        fx: &mut Vec<Effect>,
        id: Id,
        method: &str,
        params: &Map<String, Value>,
    ) {
        let sid = params.get("sessionId");
        match method {
            "initialize" => self.initialize(fx, id),
            "_acpmux/status" => self.reply(fx, &id, &json!({"peers": []})),
            "session/new" => self.start_chat(fx, id, params),
            "acp.trust.get" | "acp.trust.set" => {
                let level = params.get("level").and_then(Value::as_str);
                let cwd = params.get("cwd").and_then(Value::as_str).filter(|c| c.starts_with('/'));
                let (true, Some(cwd)) = (self.cfg.trust && (sid.is_none() || self.names(sid)), cwd)
                else {
                    return self.refuse(fx, &id, method);
                };
                if (method == "acp.trust.get") != level.is_none() {
                    return self.refuse(fx, &id, method);
                }
                let home_chosen =
                    params.get(HOME_CHOSEN_PARAM).and_then(Value::as_str) == Some("true");
                let task = self.task(Kind::Plain(id), false);
                fx.push(Effect::Trust {
                    task,
                    cwd: cwd.to_owned(),
                    level: level.map(str::to_owned),
                    home_chosen,
                });
            }
            "session/cancel" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                self.call(fx, Kind::Unit(id), "cancel", json!({}), false);
            }
            "_acpmux/detach" => self.call(fx, Kind::Unit(id), "detach", json!({}), false),
            "_acpmux/typing" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let Some(on) =
                    params.get("on").and_then(Value::as_bool).filter(|_| self.names(sid))
                else {
                    return self.refuse(fx, &id, method);
                };
                self.call(fx, Kind::Unit(id), "typing", json!({"on": on}), false);
            }
            "_acpmux/view" => {
                let Some(visible) =
                    params.get("visible").and_then(Value::as_bool).filter(|_| self.names(sid))
                else {
                    return self.refuse(fx, &id, method);
                };
                let attending = params.get("attending").and_then(Value::as_bool);
                let seen_seq = params.get("seenSeq").and_then(parse::uint);
                let args =
                    json!({"visible": visible, "attending": attending, "seen_seq": seen_seq});
                self.call(fx, Kind::Unit(id), "view", args, false);
            }
            "_acpmux/watch" if !self.has_client => {
                // A new chat before its first send: no session on that machine yet.
                self.reply(fx, &id, &json!({"sessions": []}));
            }
            "_acpmux/watch" | "_acpmux/attach" | "_acpmux/events" => {
                let watch = method == "_acpmux/watch";
                if !watch && !self.names(sid) {
                    return self.refuse(fx, &id, method);
                }
                let page = json!({"page": parse::page(params, watch)});
                match method {
                    "_acpmux/events" => self.call(fx, Kind::Events(id), "events", page, false),
                    _ => self.call(fx, Kind::Attach { id, watch }, "attach", page, false),
                }
            }
            "link.inspect" => {
                // Remote paths are classified by the host that owns the chat. Image paths are
                // deliberately marked readable so the reply starts `image.load`; ordinary path
                // chips stay outside this machine's roots.
                let mut paths = Map::new();
                if let Some(list) = params.get("paths").and_then(Value::as_array)
                    && list.iter().all(Value::is_string)
                {
                    for path in list.iter().filter_map(Value::as_str) {
                        let place = if parse::remote_image_path(path).is_some() {
                            "root"
                        } else {
                            "outside"
                        };
                        paths.insert(path.to_owned(), json!({"place": place, "folder": false}));
                    }
                }
                let policy = json!({"outsideRoots": "text", "remoteImages": "always", "clickFreeImageHosts": []});
                self.reply(fx, &id, &json!({"paths": paths, "sites": {}, "policy": policy}));
            }
            "session/prompt" => self.prompt(fx, id, params),
            "_acpmux/queue_approve" | "_acpmux/queue_decline" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let prompt_id =
                    params.get("promptId").and_then(Value::as_str).filter(|p| !p.is_empty());
                let Some(prompt_id) = prompt_id.filter(|_| self.names(sid)) else {
                    return self.refuse(fx, &id, method);
                };
                if method == "_acpmux/queue_decline" {
                    return self.call(
                        fx,
                        Kind::Plain(id),
                        "queue_decline",
                        json!({"prompt_id": prompt_id}),
                        false,
                    );
                }
                let turn = params.get("turnId").and_then(Value::as_str);
                let revision = params.get("revision").and_then(parse::uint);
                let (Some(turn), Some(revision)) = (turn, revision) else {
                    return self.refuse(fx, &id, method);
                };
                let args = json!({"prompt_id": prompt_id, "turn_id": turn, "revision": revision});
                self.call(fx, Kind::Plain(id), "queue_approve", args, false);
            }
            "image.load" => {
                let path =
                    params.get("src").and_then(Value::as_str).and_then(parse::remote_image_path);
                let Some(path) = path else { return self.refuse(fx, &id, method) };
                // The bytes are read by the daemon attached to the chat's host, never from this Mac.
                self.call(fx, Kind::Image(id), "media", json!({"path": path}), false);
            }
            "session/set_model" | "session/set_mode" | "session/set_config_option" => {
                // The person's pick (the host checked its gesture and full-access rule): that
                // machine's daemon sends it to acpmux on this chat's session only.
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let setting = parse::setting(method, params).filter(|_| self.names(sid));
                let Some((verb, args)) = setting else { return self.refuse(fx, &id, method) };
                self.call(fx, Kind::Plain(id), verb, args, true);
            }
            "_acpmux/context" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                if !self.names(sid) {
                    return self.refuse(fx, &id, method);
                }
                self.call(fx, Kind::Plain(id), "context", json!({}), false);
            }
            "_acpmux/context_override" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let optional = |key: &str| {
                    matches!(params.get(key), None | Some(Value::Null | Value::String(_)))
                };
                let scope = params.get("scope").and_then(Value::as_str);
                let Some(scope) =
                    scope.filter(|_| self.names(sid) && optional("text") && optional("partId"))
                else {
                    return self.refuse(fx, &id, method);
                };
                // The daemon pins the project directory from the attached session, never the page.
                let text = params.get("text").and_then(Value::as_str);
                let part = params.get("partId").and_then(Value::as_str);
                let args = json!({"scope": scope, "text": text, "part_id": part});
                self.call(fx, Kind::Plain(id), "context_override", args, true);
            }
            "_acpmux/agent_login/start"
            | "_acpmux/agent_login/finish"
            | "_acpmux/agent_login/api_key"
            | "_acpmux/agent_login/cancel" => self.agent_login(fx, id, method, params),
            "_acpmux/btw" => {
                // `/btw <question>` on this chat, answered inline on its machine; a side session to
                // open beside the chat (no `inline`) has no pane here, so only the inline form is served.
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let absent = |key: &str| matches!(params.get(key), None | Some(Value::Null));
                let question =
                    params.get("question").and_then(Value::as_str).filter(|q| !q.trim().is_empty());
                // A guest's second opinion (`targetHarness`) needs another harness the daemon's
                // verb never starts: refused, not answered by this chat's own harness.
                let served = self.names(sid)
                    && params.get("inline").and_then(Value::as_bool) == Some(true)
                    && absent("model")
                    && absent("targetHarness")
                    && self.has_client;
                let Some(question) = question.filter(|_| served) else {
                    return self.refuse(fx, &id, method);
                };
                let kind = Kind::Login { id, code: BTW_REFUSED, what: "side question" };
                self.call(fx, kind, "btw", json!({"question": question}), false);
            }
            SIDE_CHAT_METHOD => self.side_chat(fx, id, params),
            "_acpmux/permission_respond" => {
                if self.read_only {
                    return self.refuse_read_only(fx, &id, method);
                }
                let permission = params.get("permissionId").and_then(Value::as_str);
                let option = params.get("optionId").and_then(Value::as_str);
                let (Some(permission), Some(option)) = (permission, option) else {
                    return self.refuse(fx, &id, method);
                };
                if !self.names(sid) {
                    return self.refuse(fx, &id, method);
                }
                // The decision proof the host added (never the page): acpmux on that machine decides.
                let decision = params.get("_meta").and_then(|m| m.get("acpmux"));
                let proof = |key: &str| decision.and_then(|d| d.get(key)).and_then(Value::as_str);
                // A question's answers and annotations go along unchanged: that machine's acpmux
                // checks them and the proof over them.
                let raw =
                    |key: &str| params.get(key).filter(|v| !v.is_null()).map(Value::to_string);
                let args = json!({
                    "id": permission, "option": option, "answers": raw("answers"), "annotations": raw("annotations"),
                    "decision_nonce": proof("decisionNonce"), "person_decision": proof("personDecision"),
                });
                self.call(fx, Kind::Unit(id), "permission", args, false);
            }
            _ => self.refuse(fx, &id, method),
        }
    }

    fn initialize(&mut self, fx: &mut Vec<Effect>, id: Id) {
        // `acp.trust.set` listed: the person answers the folder question here (acpmux never
        // lists it, so a remote browser's page still cannot).
        let extensions = if self.cfg.trust { vec!["acp.trust.set"] } else { Vec::new() };
        // A new chat has no client yet: its machine's daemon read stands in (`serves_login`).
        if !self.cfg.owner_cloud && !self.has_client {
            let result = initialized(
                &extensions,
                false,
                self.cfg.serves_login,
                self.cfg.serves_side,
                self.cfg.machine_login,
            );
            return self.reply(fx, &id, &result);
        }
        // `agent_login_machine`: a chat with no session yet signs its agent in on its machine.
        let sessionless = !self.has_client && self.cfg.machine_login;
        let task = self.task(Kind::Init { id, extensions, sessionless }, false);
        fx.push(Effect::Probe {
            task,
            owner_cloud: self.cfg.owner_cloud,
            login: self.has_client && self.cfg.machine_sign_in,
            side: self.has_client,
        });
    }

    fn prompt(&mut self, fx: &mut Vec<Effect>, id: Id, params: &Map<String, Value>) {
        if self.read_only {
            return self.refuse_read_only(fx, &id, "session/prompt");
        }
        self.tell(fx, "prompt");
        let blocks = params.get("prompt").and_then(Value::as_array).filter(|b| !b.is_empty());
        let Some(blocks) = blocks.filter(|_| self.names(params.get("sessionId"))) else {
            return self.refuse(fx, &id, "session/prompt");
        };
        let meta = params.get("_meta").and_then(|m| m.get("acpmux"));
        let prompt = match meta.and_then(|m| m.get("promptId")).and_then(Value::as_str) {
            Some(p) => p.to_owned(),
            None => self.fresh_id(),
        };
        // The page's steer into the running turn: the owner's or a Cloud team member's.
        let steer = meta.and_then(|m| m.get("steer")).and_then(Value::as_bool) == Some(true);
        let text = parse::text_blocks(blocks);
        let content = Value::Array(blocks.clone()).to_string();
        let session = self.session.clone().unwrap_or_default();
        let args = json!({"id": prompt, "text": text, "content": content, "steer": steer});
        self.call(fx, Kind::Prompt { id, session, prompt }, "prompt", args, false);
    }

    fn agent_login(
        &mut self,
        fx: &mut Vec<Effect>,
        id: Id,
        method: &str,
        params: &Map<String, Value>,
    ) {
        // A Cloud chat's own sign-in on its machine (the failed turn's card): the host already
        // checked the person's click for a start or a key. The daemon pins the chat's session.
        if self.read_only {
            return self.refuse_read_only(fx, &id, method);
        }
        // A new chat with no session yet (its start refused because its agent is not signed in
        // there): a step that names no chat signs the agent in on its machine itself.
        let sessionless =
            !self.has_client && !params.contains_key("sessionId") && self.cfg.machine_login;
        let parsed = if sessionless {
            parse::login(method, params, |v| v.is_none())
        } else {
            parse::login(method, params, |v| self.names(v))
        };
        let Some((op, fields)) = parsed else { return self.refuse(fx, &id, method) };
        let kind = Kind::Login { id, code: LOGIN_REFUSED, what: "sign-in" };
        if self.has_client {
            self.call(fx, kind, "login", json!({"op": op, "fields": fields}), false);
        } else if sessionless {
            let task = self.task(kind, false);
            fx.push(Effect::MachineLogin { task, op: op.to_owned(), fields });
        } else if let Kind::Login { id, .. } = kind {
            self.refuse(fx, &id, method);
        }
    }

    /// New side chat and `/side [prompt]` of this chat, served where the initialize answer named
    /// `side_chat`. The page names this chat and the fork's boundary.
    fn side_chat(&mut self, fx: &mut Vec<Effect>, id: Id, params: &Map<String, Value>) {
        if self.read_only {
            return self.refuse_read_only(fx, &id, SIDE_CHAT_METHOD);
        }
        let request = parse::side_request(params)
            .filter(|_| self.names(params.get("sessionId")) && self.has_client);
        let Some((through_seq, prompt)) = request else {
            return self.refuse(fx, &id, SIDE_CHAT_METHOD);
        };
        // acpmux's id of the chat, as the page and the host name it.
        let parent = self.resolved.clone().or_else(|| self.session.clone()).unwrap_or_default();
        let prompted = prompt.is_some();
        let prompt_id = self.fresh_id();
        let args = json!({"through_seq": through_seq, "prompt": prompt, "prompt_id": prompt_id});
        self.call(fx, Kind::Side { id, parent, prompted }, "side", args, false);
    }

    /// A new chat's `session/new` (its first send): starts the chat on that machine once. Refused
    /// on a wire that already has a session, while a start runs, and for an adopt (an outside
    /// chat of this Mac never moves there). A refused start leaves no session, so the next send
    /// may start again; nothing retries by itself.
    fn start_chat(&mut self, fx: &mut Vec<Effect>, id: Id, params: &Map<String, Value>) {
        let acpmux = params.get("_meta").and_then(|m| m.get("acpmux"));
        let adopt = acpmux.and_then(|m| m.get("adopt")).is_some();
        if !self.cfg.start || adopt || self.closed || self.has_client || self.starting {
            return self.refuse(fx, &id, "session/new");
        }
        self.starting = true;
        let cwd = params
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|c| c.starts_with('/'))
            .map(str::to_owned);
        let pick = |key: &str| {
            acpmux
                .and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        let (harness, model) = (pick("harness"), pick("model"));
        let task = self.task(Kind::Start { id, cwd: cwd.clone() }, false);
        fx.push(Effect::Start { task, cwd, harness, model });
    }

    // MARK: Answers

    fn finish(&mut self, fx: &mut Vec<Effect>, kind: Kind, outcome: Result<String, Failure>) {
        match kind {
            Kind::Plain(id) => self.answer(fx, &id, outcome),
            Kind::Unit(id) => match outcome {
                Ok(_) => self.reply(fx, &id, &json!({})),
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
            },
            Kind::Init { id, extensions, sessionless } => {
                let probed = outcome.ok().and_then(|raw| structured(&raw)).unwrap_or(Value::Null);
                let flag = |key: &str, fallback: bool| {
                    probed.get(key).and_then(Value::as_bool).unwrap_or(fallback)
                };
                let login = flag("login", self.cfg.serves_login);
                let side = flag("side", self.cfg.serves_side);
                let result =
                    initialized(&extensions, flag("owned", false), login, side, sessionless);
                self.reply(fx, &id, &result);
            }
            Kind::Prompt { id, session, prompt } => match outcome {
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
                Ok(raw) => {
                    let accepted = structured(&raw).unwrap_or(Value::Null);
                    let field = |key: &str| accepted.get(key);
                    let turn = field("turn_id").cloned().unwrap_or(Value::Null);
                    let mut notice = json!({
                        "sessionId": session, "promptId": prompt, "turnId": turn,
                        "queued": field("queued").cloned().unwrap_or(json!(false)),
                    });
                    if let (Some(state), Some(object)) =
                        (field("state").and_then(Value::as_str), notice.as_object_mut())
                    {
                        object.insert("state".to_owned(), json!(state));
                        if field("awaiting_owner").and_then(Value::as_bool) == Some(true) {
                            object.insert("awaitingOwner".to_owned(), json!(true));
                        }
                    } else if field("awaiting_owner").and_then(Value::as_bool) == Some(true)
                        && let Some(object) = notice.as_object_mut()
                    {
                        object.insert("awaitingOwner".to_owned(), json!(true));
                    }
                    self.notify(fx, "_acpmux/prompt_accepted", &notice.to_string());
                    self.reply(
                        fx,
                        &id,
                        &json!({"_meta": {"acpmux": {"promptId": prompt, "turnId": turn}}}),
                    );
                }
            },
            Kind::Attach { id, watch } => match outcome {
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
                Ok(raw) => {
                    let object = structured(&raw).unwrap_or(Value::Null);
                    let summary = object.get("session").filter(|s| s.is_object()).cloned();
                    if let Some(resolved) =
                        summary.as_ref().and_then(|s| s.get("sessionId")).and_then(Value::as_str)
                    {
                        self.resolved = Some(resolved.to_owned());
                    }
                    if !watch {
                        return self.answer(fx, &id, Ok(raw));
                    }
                    let task = self.task(Kind::Children { id, summary }, false);
                    fx.push(Effect::Call { task, verb: "children", args: json!({}) });
                }
            },
            Kind::Children { id, summary } => {
                let listed = outcome.ok().and_then(|raw| structured(&raw)).unwrap_or(Value::Null);
                let children: Vec<Value> = listed
                    .get("sessions")
                    .and_then(Value::as_array)
                    .map(|all| {
                        all.iter()
                            .filter(|c| c.is_object())
                            .filter(|c| {
                                c.get("sessionId")
                                    .and_then(Value::as_str)
                                    .is_some_and(|s| !self.names_str(s))
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default();
                self.note_links(fx, children.clone());
                let resolved =
                    summary.as_ref().and_then(|s| s.get("sessionId")).and_then(Value::as_str);
                let tab_session = resolved.filter(|r| !r.is_empty()).map(str::to_owned);
                let mut sessions: Vec<Value> = summary.into_iter().collect();
                sessions.extend(children);
                let mut reply = json!({"sessions": sessions});
                if let (Some(tab), Some(object)) = (tab_session, reply.as_object_mut()) {
                    // The session the tab is bound to on that machine now, by acpmux's id: the page
                    // may hold another name for it and opens this one (direct.ts `tabSession`).
                    object.insert("tabSessionId".to_owned(), json!(tab));
                }
                self.reply(fx, &id, &reply);
            }
            Kind::Events(id) => {
                let outcome = outcome.map(|raw| with_more(&raw));
                self.answer(fx, &id, outcome);
            }
            Kind::Image(id) => match outcome {
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
                Ok(raw) => {
                    let data = structured(&raw)
                        .and_then(|o| o.get("data").and_then(Value::as_str).map(str::to_owned));
                    let Some(data) = data else {
                        let message = "the remote image could not be decoded";
                        return self.fail(fx, &id, UNSUPPORTED, message, Map::new());
                    };
                    let task = self.task(Kind::Plain(id), false);
                    fx.push(Effect::DecodeImage { task, data });
                }
            },
            Kind::Login { id, code, what } => match outcome {
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
                Ok(raw) => {
                    let object = structured(&raw);
                    let Some(refused) =
                        object.as_ref().and_then(|o| o.get("refused")).and_then(Value::as_object)
                    else {
                        return self.answer(fx, &id, Ok(raw));
                    };
                    // acpmux's reason, as a JSON-RPC error the card words (`data.reason`).
                    let reason = refused.get("reason").and_then(Value::as_str).unwrap_or("failed");
                    let mut data = Map::new();
                    data.insert("reason".to_owned(), json!(reason));
                    self.fail(fx, &id, code, &format!("{what} refused: {reason}"), data);
                }
            },
            Kind::Side { id, parent, prompted } => match outcome {
                Err(e) => self.fail(fx, &id, &e.code, &e.message, Map::new()),
                Ok(raw) => {
                    let object = structured(&raw).unwrap_or(Value::Null);
                    let Some(side) =
                        object.get("sessionId").and_then(Value::as_str).filter(|s| !s.is_empty())
                    else {
                        return self.fail(
                            fx,
                            &id,
                            "agent_session.refused",
                            "no side chat opened",
                            Map::new(),
                        );
                    };
                    // The daemon's answer, never the page's: under the tab's host and the daemon's own.
                    let alias =
                        self.cfg.links_alias.clone().filter(|a| Some(a) != self.cfg.host.as_ref());
                    let mut hosts = vec![self.cfg.host.clone()];
                    hosts.extend(alias.map(Some));
                    fx.push(Effect::NoteSide { side: side.to_owned(), parent, hosts });
                    let mut reply = json!({"sessionId": side});
                    if prompted && object.get("prompted").and_then(Value::as_bool) != Some(true) {
                        // acpmux did not take the prompt; the page opens the side chat and keeps it.
                        let not_sent = object
                            .get("notSent")
                            .and_then(Value::as_str)
                            .unwrap_or("agent_session.refused");
                        if let Some(map) = reply.as_object_mut() {
                            map.insert("notSent".to_owned(), json!(not_sent));
                        }
                    }
                    self.reply(fx, &id, &reply);
                }
            },
            Kind::Start { id, cwd } => {
                self.starting = false;
                match outcome {
                    Err(e) => {
                        // An untrusted folder is the page's folder trust question, answered here when
                        // the wire can; a refusal's typed facts (an agent not signed in) go along.
                        let mut data = Map::new();
                        if e.code == "agent_session.untrusted_folder" && self.cfg.trust {
                            data.insert("reason".to_owned(), json!("trust.pending"));
                            data.insert(
                                "cwd".to_owned(),
                                json!(e.folder.or(cwd).unwrap_or_default()),
                            );
                        } else {
                            data.extend(e.facts.iter().map(|(k, v)| (k.clone(), json!(v))));
                        }
                        self.fail(fx, &id, &e.code, &e.message, data);
                    }
                    Ok(raw) => {
                        let started = structured(&raw).unwrap_or(Value::Null);
                        let session = started
                            .get("session")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned();
                        // The page reconnects with a new wire, which finds the started chat.
                        if self.closed {
                            return fx.push(Effect::CloseClient);
                        }
                        self.has_client = true;
                        self.read_only =
                            started.get("read_only").and_then(Value::as_bool) == Some(true);
                        self.session = Some(session.clone());
                        self.reply(fx, &id, &json!({"sessionId": session}));
                    }
                }
            }
        }
    }

    // MARK: Output

    fn answer(&mut self, fx: &mut Vec<Effect>, id: &Id, outcome: Result<String, Failure>) {
        match outcome {
            Ok(raw) => {
                if let Some(id) = id {
                    self.emit(fx, format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{raw}}}"#));
                }
            }
            Err(e) => self.fail(fx, id, &e.code, &e.message, Map::new()),
        }
    }

    fn reply(&mut self, fx: &mut Vec<Effect>, id: &Id, result: &Value) {
        if let Some(id) = id {
            self.emit(fx, format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{result}}}"#));
        }
    }

    fn fail(
        &mut self,
        fx: &mut Vec<Effect>,
        id: &Id,
        code: &str,
        message: &str,
        mut data: Map<String, Value>,
    ) {
        let Some(id) = id else { return };
        data.insert("code".to_owned(), json!(code));
        let error = json!({"code": UNSUPPORTED_CODE, "message": message, "data": data});
        self.emit(fx, format!(r#"{{"jsonrpc":"2.0","id":{id},"error":{error}}}"#));
    }

    fn refuse(&mut self, fx: &mut Vec<Effect>, id: &Id, method: &str) {
        let message = format!("{method} is not available for a chat on another machine");
        self.fail(fx, id, UNSUPPORTED, &message, Map::new());
    }

    fn refuse_read_only(&mut self, fx: &mut Vec<Effect>, id: &Id, method: &str) {
        let message = format!("{method} is not available on a read-only agent session");
        self.fail(fx, id, READ_ONLY, &message, Map::new());
    }

    /// A notification whose params are the daemon's own JSON `params` (checked to be JSON).
    fn forward(&mut self, fx: &mut Vec<Effect>, method: &str, params: &str) {
        if structured(params).is_some() {
            self.notify(fx, method, params);
        }
    }

    fn notify(&mut self, fx: &mut Vec<Effect>, method: &str, params: &str) {
        self.emit(fx, format!(r#"{{"jsonrpc":"2.0","method":"{method}","params":{params}}}"#));
    }

    fn emit(&mut self, fx: &mut Vec<Effect>, frame: String) {
        let first_token = self.cfg.milestone
            && !self.told.contains("first token")
            && parse::is_first_token(&frame);
        if !self.closed {
            fx.push(Effect::Emit { frame });
        }
        if first_token {
            self.tell(fx, "first token");
        }
    }

    fn tell(&mut self, fx: &mut Vec<Effect>, step: &'static str) {
        if self.cfg.milestone && self.told.insert(step) {
            fx.push(Effect::Tell { step });
        }
    }

    /// The parents of the children the daemon listed or changed, for the sidebar's session tree.
    /// A wire with a host notes even an empty list, so that daemon has a map of its own; a hostless
    /// wire notes into the hostless map. The tab's host and the daemon's store host are noted as
    /// aliases of one daemon.
    fn note_links(&mut self, fx: &mut Vec<Effect>, summaries: Vec<Value>) {
        if self.cfg.host.is_none() && summaries.is_empty() {
            return;
        }
        let alias = self.cfg.links_alias.clone().filter(|a| Some(a) != self.cfg.host.as_ref());
        fx.push(Effect::NoteLinks { summaries, host: self.cfg.host.clone(), alias });
    }

    // MARK: State

    fn task(&mut self, kind: Kind, serial: bool) -> u64 {
        let task = self.next_task;
        self.next_task = self.next_task.wrapping_add(1);
        self.tasks.insert(task, (kind, serial));
        task
    }

    /// A daemon call whose answer becomes `kind`'s reply. A new chat before its first send has no
    /// attachment: nothing to page, cancel or detach, so it answers `{}`. A `serial` call (a pick)
    /// starts once the pick sent before it has answered.
    fn call(
        &mut self,
        fx: &mut Vec<Effect>,
        kind: Kind,
        verb: &'static str,
        args: Value,
        serial: bool,
    ) {
        if !self.has_client {
            let id = match kind {
                Kind::Plain(id) | Kind::Unit(id) | Kind::Events(id) | Kind::Image(id) => id,
                Kind::Prompt { id, .. }
                | Kind::Attach { id, .. }
                | Kind::Login { id, .. }
                | Kind::Side { id, .. } => id,
                Kind::Init { id, .. } | Kind::Children { id, .. } | Kind::Start { id, .. } => id,
            };
            return self.reply(fx, &id, &json!({}));
        }
        let task = self.task(kind, serial);
        if serial && self.pick_busy {
            self.picks.push_back((task, verb, args));
            return;
        }
        self.pick_busy = self.pick_busy || serial;
        fx.push(Effect::Call { task, verb, args });
    }

    fn close(&mut self) -> bool {
        !std::mem::replace(&mut self.closed, true)
    }

    /// True when `value` names this chat's session (the tab's, or acpmux's id for it).
    fn names(&self, value: Option<&Value>) -> bool {
        value.and_then(Value::as_str).is_some_and(|name| self.names_str(name))
    }

    fn names_str(&self, name: &str) -> bool {
        self.session.as_deref().is_some_and(|s| name == s || self.resolved.as_deref() == Some(name))
    }

    /// A fresh random id in UUID spelling (lowercase), for a prompt or side chat the page named none for.
    fn fresh_id(&mut self) -> String {
        let mut word = || {
            self.ids = self.ids.wrapping_add(1);
            let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
            hasher.write_u64(self.ids);
            u128::from(hasher.finish())
        };
        let bits = (word() << 64 | word()) & !(0xf << 76) & !(0x3 << 62) | (4 << 76) | (0x2 << 62);
        let part = |shift: u32, width: u32| {
            let mask = 1u128.checked_shl(width).map_or(u128::MAX, |m| m.wrapping_sub(1));
            bits.checked_shr(shift).unwrap_or(0) & mask
        };
        format!(
            "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
            part(96, 32),
            part(80, 16),
            part(64, 16),
            part(48, 16),
            part(0, 48)
        )
    }
}

/// The `initialize` answer: always `origin: "remote"`; `ownerCloud` only on the person's own Cloud
/// VM; the `agent_login` feature where that machine's daemon relays the chat's own sign-in, and
/// `agent_login_machine` where a chat with no session yet signs its agent in on its machine.
pub fn initialized(
    extensions: &[&str],
    owner_cloud: bool,
    login: bool,
    side: bool,
    machine_login: bool,
) -> Value {
    let mut acpmux = Map::new();
    acpmux.insert("origin".to_owned(), json!("remote"));
    acpmux.insert("extensions".to_owned(), json!(extensions));
    if owner_cloud {
        acpmux.insert("ownerCloud".to_owned(), json!(true));
    }
    // A feature, not `capabilities`: a remote chat names no acpmux capability list, and the page
    // reads an absent list as "try the method". `btw_inline`: the page asks `/btw` here, inline.
    let mut features: Vec<&str> = Vec::new();
    if login {
        features.push("agent_login");
    }
    features.push("btw_inline");
    if side {
        features.push("side_chat");
    }
    if machine_login {
        features.push("agent_login_machine");
    }
    acpmux.insert("features".to_owned(), json!(features));
    json!({"protocolVersion": 1, "agentCapabilities": {}, "_meta": {"acpmux": acpmux}})
}

/// The daemon's JSON when it is an object or array (a bare scalar is no record).
fn structured(raw: &str) -> Option<Value> {
    serde_json::from_str::<Value>(raw).ok().filter(|v| v.is_object() || v.is_array())
}

/// acpmux answers `hasMore`; the page's replay loop reads `more`, so both are set.
fn with_more(raw: &str) -> String {
    let Some(Value::Object(mut object)) = structured(raw) else { return raw.to_owned() };
    if object.contains_key("more") {
        return raw.to_owned();
    }
    let more = object.get("hasMore").cloned().unwrap_or(json!(false));
    object.insert("more".to_owned(), more);
    Value::Object(object).to_string()
}
