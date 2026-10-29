//! The scriptable `cmux chief` verbs (plans/cmux-next/chief-tui.md): read
//! and drive Chief/Home chats with no terminal, so a coding agent can test
//! Chief behavior. `chats`, `read`, `send`, `react`, `amend`, `retract`,
//! `mark-read`, `wait` and `events`, each one call (or one stream) on the
//! session daemon through `backend::ChatClient`, for the local owner or
//! (`--cloud`) the cloud owners.

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::adapter::{UiEvent, adapt};
use super::backend::{self, CloudLease};
use super::chat::{Chat, Line};
use super::link::new_message_id;
use super::script_text::text;
use super::turn::TurnWatch;
use super::{ChatTarget, GlobalArgs, Input, Session, json_output};

/// The verbs this module runs (`cmux chief WORD`).
pub(super) const WORDS: [&str; 9] =
    ["chats", "read", "send", "react", "amend", "retract", "mark-read", "wait", "events"];

/// The tapback reaction names; any other reaction is an emoji.
const TAPBACKS: [&str; 6] = ["love", "like", "dislike", "laugh", "emphasize", "question"];

/// Messages the stream of `wait` and `send --wait` starts with.
const WAIT_TAIL: usize = 50;

/// `--chat`, `--cloud` and the cloud lease flags, as parsed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct TargetArgs {
    pub chat: Option<String>,
    pub cloud: bool,
    pub cloud_api: Option<String>,
    pub token_file: Option<PathBuf>,
    /// `--cloud-auth tailscale`.
    pub tailscale: bool,
}

impl TargetArgs {
    /// Takes one target flag; `value` reads its value.
    pub(super) fn flag(
        &mut self,
        flag: &str,
        value: &mut dyn FnMut() -> Result<String, String>,
    ) -> Result<(), String> {
        match flag {
            "--chat" => self.chat = Some(value()?),
            "--cloud" => self.cloud = true,
            "--cloud-api" => {
                self.cloud_api = Some(value()?);
                self.cloud = true;
            }
            "--cloud-token-file" => self.token_file = Some(value()?.into()),
            "--cloud-auth" => match value()?.as_str() {
                "tailscale" => self.tailscale = true,
                "token" | "bearer" => self.tailscale = false,
                _ => return Err(text().cloud_auth.into()),
            },
            other => return Err(format!("unknown argument {other}")),
        }
        Ok(())
    }

    /// The chat target, with the lease read from the token file or
    /// `CMUX_CLOUD_ACCESS_TOKEN` when `--cloud-api` names one.
    pub(super) fn resolve(&self) -> Result<ChatTarget, String> {
        let lease = match &self.cloud_api {
            None => None,
            Some(api) if self.tailscale => {
                Some(CloudLease { api_base_url: api.clone(), access_token: None })
            }
            Some(api) => {
                let token = match &self.token_file {
                    Some(path) => std::fs::read_to_string(path)
                        .map_err(|e| format!("{}: {e}", path.display()))?,
                    None => std::env::var("CMUX_CLOUD_ACCESS_TOKEN")
                        .map_err(|_| text().token_missing.to_owned())?,
                };
                let token = token.trim().to_owned();
                if token.is_empty() {
                    return Err(text().token_missing.into());
                }
                Some(CloudLease { api_base_url: api.clone(), access_token: Some(token) })
            }
        };
        Ok(ChatTarget { chat: self.chat.clone(), cloud: self.cloud, lease })
    }
}

/// Who `wait --from` waits for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) enum Author {
    /// The chat's Chief.
    #[default]
    Chief,
    /// The person (`user_local`, or anyone not an agent on the cloud).
    Me,
    /// Anyone but the person.
    Anyone,
    /// One participant id.
    Id(String),
}

/// One parsed verb.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Request {
    pub word: String,
    pub target: TargetArgs,
    pub chief_home: Option<PathBuf>,
    pub json: bool,
    pub help: bool,
    /// Words after the verb that are not flags.
    pub words: Vec<String>,
    pub last: Option<usize>,
    pub before: Option<u64>,
    pub thread: Option<String>,
    pub reply_to: Option<String>,
    pub attach: Vec<PathBuf>,
    pub wait: bool,
    pub no_wait_agents: bool,
    pub timeout_secs: Option<u64>,
    pub part: u32,
    pub remove: bool,
    pub after: Option<u64>,
    pub from: Author,
    pub contains: Option<String>,
    pub idle: bool,
    pub tail: Option<usize>,
    pub count: Option<usize>,
}

/// Parses `cmux chief WORD …`.
pub(super) fn parse(args: &[String]) -> Result<Request, String> {
    let mut request = Request {
        word: args.first().cloned().unwrap_or_default(),
        timeout_secs: Some(super::DEFAULT_TIMEOUT_SECS),
        ..Request::default()
    };
    let mut index = 1;
    let number = |flag: &str, text: &str| -> Result<u64, String> {
        text.parse().map_err(|_| format!("{flag} takes a number, not {text}"))
    };
    while let Some(arg) = args.get(index) {
        let arg = arg.as_str();
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg, None),
        };
        let mut value = || -> Result<String, String> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            index += 1;
            args.get(index).cloned().ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "-h" | "--help" => request.help = true,
            "--json" => request.json = true,
            "--chat" | "--cloud" | "--cloud-api" | "--cloud-token-file" | "--cloud-auth" => {
                request.target.flag(flag, &mut value)?;
            }
            "--chief-home" => request.chief_home = Some(value()?.into()),
            "--last" => request.last = Some(number(flag, &value()?)?.min(500) as usize),
            "--before" => request.before = Some(number(flag, &value()?)?),
            "--thread" => request.thread = Some(value()?),
            "--reply-to" => request.reply_to = Some(value()?),
            "--attach" => request.attach.push(value()?.into()),
            "--wait" => request.wait = true,
            "--no-wait-agents" => request.no_wait_agents = true,
            "--timeout" => {
                let secs = number(flag, &value()?)?;
                request.timeout_secs = (secs > 0).then_some(secs);
            }
            "--part" => request.part = number(flag, &value()?)? as u32,
            "--remove" => request.remove = true,
            "--after" => request.after = Some(number(flag, &value()?)?),
            "--from" => {
                request.from = match value()?.as_str() {
                    "chief" => Author::Chief,
                    "me" => Author::Me,
                    "any" | "anyone" => Author::Anyone,
                    id => Author::Id(id.to_owned()),
                }
            }
            "--text" => request.contains = Some(value()?),
            "--idle" => request.idle = true,
            "--tail" => request.tail = Some(number(flag, &value()?)?.min(500) as usize),
            "--count" => request.count = Some(number(flag, &value()?)? as usize),
            "-" => request.words.push("-".into()),
            other if other.starts_with("--") => return Err(format!("unknown argument {other}")),
            word => request.words.push(word.to_owned()),
        }
        index += 1;
    }
    Ok(request)
}

/// A message reference: `#SEQ` or a message id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum MessageRef {
    Seq(u64),
    Id(String),
}

/// Parses `#SEQ`, a bare SEQ, or `msg_…`, with an optional `:PART`.
pub(super) fn parse_ref(word: &str) -> Result<(MessageRef, Option<u32>), String> {
    let bad = || text().bad_ref.replace("{ref}", word);
    let (head, part) = match word.rsplit_once(':') {
        Some((head, part)) if part.chars().all(|c| c.is_ascii_digit()) && !part.is_empty() => {
            (head, Some(part.parse().map_err(|_| bad())?))
        }
        _ => (word, None),
    };
    if let Some(id) = head.strip_prefix("msg_")
        && !id.is_empty()
    {
        return Ok((MessageRef::Id(head.to_owned()), part));
    }
    let digits = head.strip_prefix('#').unwrap_or(head);
    match digits.parse::<u64>() {
        Ok(seq) if seq > 0 => Ok((MessageRef::Seq(seq), part)),
        _ => Err(bad()),
    }
}

/// The reaction `kind` of a word: a tapback name, or an emoji.
pub(super) fn reaction_kind(word: &str) -> Result<Value, String> {
    let word = word.trim();
    if word.is_empty() {
        return Err(text().needs_reaction.into());
    }
    if TAPBACKS.contains(&word) {
        return Ok(json!({"tapback": word}));
    }
    Ok(json!({"emoji": word}))
}

/// A message as scripts read it: the owner's message with its plain `text`.
pub(super) fn script_message(message: &Value) -> Value {
    let mut out = message.clone();
    if let Some(object) = out.as_object_mut() {
        object.insert("text".into(), json!(super::render::message_text(message)));
    }
    out
}

/// Whether `message` is one `wait` waits for.
pub(super) fn wait_matches(
    message: &Value,
    after: u64,
    from: &Author,
    chief: &str,
    contains: Option<&str>,
) -> bool {
    let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
    let author = message.get("author").and_then(Value::as_str).unwrap_or("");
    let person = author == "user_local" || author.starts_with("user_");
    let by = match from {
        Author::Chief => author == chief,
        Author::Me => person,
        Author::Anyone => !person,
        Author::Id(id) => author == id,
    };
    let text = super::render::message_text(message);
    seq > after && by && contains.is_none_or(|needle| text.contains(needle))
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let request = match parse(args) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", text().usage);
            return 2;
        }
    };
    if request.help {
        println!("{}", text().usage);
        return 0;
    }
    let json = request.json || json_output(global.output);
    let target = match request.target.resolve() {
        Ok(target) => target,
        Err(error) => {
            eprintln!("cmux: {error}");
            return 2;
        }
    };
    let mut session = match Session::connect(global, request.chief_home.as_deref(), &target) {
        Ok(session) => session,
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            return code;
        }
    };
    let result = match request.word.as_str() {
        "chats" => chats(&mut session, &target, json),
        word => match session.select(target.chat.as_deref()) {
            Err(error) => Err(error),
            Ok(()) => match word {
                "read" => read(&mut session, &request, json),
                "send" => send(&mut session, &request, json),
                "react" => react(&mut session, &request, json),
                "amend" => amend(&mut session, &request, json),
                "retract" => retract(&mut session, &request, json),
                "mark-read" => mark_read(&mut session, &request, json),
                "wait" => wait(&mut session, &request, json),
                "events" => events(&mut session, &request),
                _ => Err((2, text().usage.to_owned())),
            },
        },
    };
    match result {
        Ok(()) => 0,
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            code
        }
    }
}

type Outcome = Result<(), (i32, String)>;

fn print_json(value: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn print_lines(lines: &[Line]) {
    let mut out = std::io::stdout().lock();
    for (_, line) in lines {
        let _ = writeln!(out, "{line}");
    }
    let _ = out.flush();
}

/// A chat line of `chats`: its id, title, Chief, last seq and unread count.
pub(super) fn chat_row(summary: &Value, current: bool) -> Value {
    json!({
        "id": summary.get("id").cloned().unwrap_or(Value::Null),
        "title": summary.get("title").cloned().unwrap_or(json!("")),
        "owner": summary.get("owner").cloned().unwrap_or(json!("local")),
        "chief": backend::chief_of(summary),
        "last_seq": summary.get("last_seq").and_then(Value::as_u64).unwrap_or(0),
        "unread": backend::unread(summary),
        "default": current,
    })
}

/// The plain text of a `chats` row, numbered from 1.
pub(super) fn chat_row_text(number: usize, row: &Value) -> String {
    let field = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let mark = if row.get("default") == Some(&json!(true)) { "*" } else { " " };
    let number_of = |key: &str| row.get(key).and_then(Value::as_u64).unwrap_or(0);
    format!(
        "{mark}{number:>3}  {}  {}  {}  #{}  unread {}",
        field("id"),
        field("title"),
        field("chief"),
        number_of("last_seq"),
        number_of("unread"),
    )
}

/// Every chat with its row, the default chat marked.
pub(super) fn chat_rows(
    session: &mut Session,
    chat: Option<&str>,
) -> Result<Vec<Value>, (i32, String)> {
    let chats = session.client.chats().map_err(|e| session.failed(e))?;
    let default = super::pick_chat(&chats, chat, session.client.owner)
        .ok()
        .and_then(|c| c.get("id").and_then(Value::as_str).map(str::to_owned));
    Ok(chats
        .iter()
        .map(|c| {
            let id = c.get("id").and_then(Value::as_str);
            chat_row(c, id.is_some() && id == default.as_deref())
        })
        .collect())
}

fn chats(session: &mut Session, target: &ChatTarget, json: bool) -> Outcome {
    let rows = chat_rows(session, target.chat.as_deref())?;
    if json {
        print_json(&json!(rows));
    } else if rows.is_empty() {
        println!("{}", text().no_chats);
    } else {
        for (index, row) in rows.iter().enumerate() {
            println!("{}", chat_row_text(index + 1, row));
        }
    }
    Ok(())
}

/// The message `word` names in the current chat, read from the owner.
fn resolve(session: &mut Session, word: &str) -> Result<(Value, Option<u32>), (i32, String)> {
    let (reference, part) = parse_ref(word).map_err(|e| (2, e))?;
    let conversation = session.conversation.clone();
    let message = match reference {
        MessageRef::Seq(seq) => {
            let page =
                session.client.history(&conversation, seq + 1, 1).map_err(|e| session.failed(e))?;
            page.into_iter()
                .find(|m| m.get("seq").and_then(Value::as_u64) == Some(seq))
                .ok_or_else(|| (1, text().no_seq.replace("{seq}", &seq.to_string())))?
        }
        MessageRef::Id(id) => {
            // The thread read names any message of the chat by id; a reply is
            // refused as a root, so fall back to the id alone.
            match session.client.thread(&conversation, &id) {
                Ok(thread) => thread.get("root").cloned().unwrap_or_else(|| json!({"id": id})),
                Err(_) => json!({"id": id}),
            }
        }
    };
    Ok((message, part))
}

fn message_id(message: &Value) -> String {
    message.get("id").and_then(Value::as_str).unwrap_or("").to_owned()
}

fn seq_of(message: &Value) -> u64 {
    message.get("seq").and_then(Value::as_u64).unwrap_or(0)
}

/// A chat view for printing messages as the chat shows them.
fn printer(session: &Session) -> Chat {
    let participants =
        session.summary.get("participants").and_then(Value::as_array).cloned().unwrap_or_default();
    Chat {
        width: crossterm::terminal::size().map(|(w, _)| w as usize).unwrap_or(100).max(40),
        participants,
        chief: session.chief.clone(),
        ..Chat::default()
    }
}

fn read(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let conversation = session.conversation.clone();
    let messages = if let Some(root) = &request.thread {
        let (root, _) = resolve(session, root)?;
        let thread = session
            .client
            .thread(&conversation, &message_id(&root))
            .map_err(|e| session.failed(e))?;
        let mut all = vec![thread.get("root").cloned().unwrap_or(root)];
        all.extend(thread.get("replies").and_then(Value::as_array).cloned().unwrap_or_default());
        all
    } else {
        let last = request.last.unwrap_or(20).max(1);
        match request.before {
            Some(before) => session.client.history(&conversation, before, last),
            None => session.client.snapshot(&conversation, last).map(|(_, messages)| messages),
        }
        .map_err(|e| session.failed(e))?
    };
    if json {
        print_json(&json!(messages.iter().map(script_message).collect::<Vec<_>>()));
        return Ok(());
    }
    let mut chat = printer(session);
    let lines: Vec<Line> = messages.iter().flat_map(|m| chat.message(m)).collect();
    print_lines(&lines);
    Ok(())
}

/// The text `send` sends: its words, or stdin for `-`.
fn send_text(words: &[String]) -> Result<String, (i32, String)> {
    if words.len() == 1 && words.first().is_some_and(|w| w == "-") {
        let mut text = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)
            .map_err(|e| (2, e.to_string()))?;
        return Ok(text.trim_end_matches(['\n', '\r']).to_owned());
    }
    Ok(words.join(" "))
}

fn send(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let body = send_text(&request.words)?;
    if body.trim().is_empty() && request.attach.is_empty() {
        return Err((2, text().needs_text.into()));
    }
    let mut reply_to = match &request.reply_to {
        Some(word) => {
            let (parent, part) = resolve(session, word)?;
            Some(json!({"message_id": message_id(&parent), "part_index": part.unwrap_or(0)}))
        }
        None => None,
    };
    // `--thread MSG`: a reply in MSG's thread (its top root), to MSG itself
    // unless --reply-to names another parent.
    let thread_root = match &request.thread {
        Some(word) => {
            let (root, part) = resolve(session, word)?;
            let top = root.get("thread_root").and_then(Value::as_str).map(str::to_owned);
            if reply_to.is_none() {
                reply_to =
                    Some(json!({"message_id": message_id(&root), "part_index": part.unwrap_or(0)}));
            }
            Some(top.unwrap_or_else(|| message_id(&root)))
        }
        None => None,
    };
    let conversation = session.conversation.clone();
    let mut parts = Vec::new();
    for path in &request.attach {
        parts.push(session.client.upload(&conversation, path).map_err(|e| (1, e))?);
    }
    if !body.trim().is_empty() {
        parts.push(json!({"type": "text", "text": body}));
    }
    if request.wait {
        // The stream opens first, so no reply can come before it.
        session.reopen(WAIT_TAIL).map_err(|e| session.failed(e))?;
    }
    let (seq, id) = session
        .send_parts(parts, reply_to, thread_root.as_deref())
        .map_err(|e| session.failed(e))?;
    if !request.wait {
        if json {
            print_json(&json!({"id": id, "seq": seq, "conversation": conversation}));
        } else {
            println!("{}", text().sent.replace("{seq}", &seq.to_string()).replace("{id}", &id));
        }
        return Ok(());
    }
    let mut watch =
        TurnWatch::new(seq).of_chief(&session.chief).answering(&id, !request.no_wait_agents);
    let deadline = request.timeout_secs.map(|s| Instant::now() + Duration::from_secs(s));
    let mut printed = 0;
    let mut chat = printer(session);
    chat.last_seq = seq;
    while !watch.done {
        let input = match next_input(session, deadline) {
            Some(input) => input,
            None => {
                let secs = request.timeout_secs.unwrap_or_default().to_string();
                return Err((124, super::messages::messages().timed_out.replace("{secs}", &secs)));
            }
        };
        let Some(event) = stream_event(session, input)? else { continue };
        watch.on(&event);
        for reply in watch.replies.iter().skip(printed) {
            if !json {
                print_lines(&chat.message(reply));
            }
        }
        printed = watch.replies.len();
    }
    if json {
        let replies: Vec<Value> = watch.replies.iter().map(script_message).collect();
        print_json(
            &json!({"id": id, "seq": seq, "conversation": conversation, "replies": replies}),
        );
    }
    Ok(())
}

/// The next stream input before `deadline`; None at the deadline.
fn next_input(session: &Session, deadline: Option<Instant>) -> Option<Input> {
    loop {
        let wait = deadline
            .map_or(Duration::from_secs(3600), |d| d.saturating_duration_since(Instant::now()));
        match session.rx.recv_timeout(wait) {
            Ok(input) => return Some(input),
            Err(RecvTimeoutError::Timeout) if deadline.is_some_and(|d| Instant::now() >= d) => {
                return None;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Some(Input::Closed("closed".into())),
        }
    }
}

/// The chat event of one stream input; a gap reopens the stream (its
/// snapshot carries what was missed); a lost stream is an error.
fn stream_event(session: &mut Session, input: Input) -> Result<Option<UiEvent>, (i32, String)> {
    match input {
        Input::Daemon(item) => Ok(adapt(&item, &session.conversation)),
        Input::Closed(reason) if reason == "gap" => {
            session.reopen(WAIT_TAIL).map_err(|e| session.failed(e))?;
            Ok(None)
        }
        Input::Closed(reason) => {
            let lost = super::messages::messages().lost;
            Err((3, if reason == "closed" { lost.to_owned() } else { format!("{lost}: {reason}") }))
        }
        Input::Term(_) => Ok(None),
    }
}

fn react(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let [target, reaction, ..] = request.words.as_slice() else {
        return Err((
            2,
            if request.words.is_empty() { text().needs_message } else { text().needs_reaction }
                .into(),
        ));
    };
    let (message, part) = resolve(session, target)?;
    let kind = reaction_kind(reaction).map_err(|e| (2, e))?;
    let op_kind = if request.remove { "reaction.remove" } else { "reaction.add" };
    let part_index = part.unwrap_or(request.part);
    let op = json!({"kind": op_kind, "message_id": message_id(&message), "part_index": part_index,
                    "reaction": kind});
    let conversation = session.conversation.clone();
    let result =
        session.client.op(&conversation, &new_message_id(), op).map_err(|e| session.failed(e))?;
    let updated = backend::sent_message(&result);
    let seq = seq_of(&updated).max(seq_of(&message));
    if json {
        print_json(&script_message(&updated));
    } else {
        let template = if request.remove { text().unreacted } else { text().reacted };
        println!("{}", template.replace("{reaction}", reaction).replace("{seq}", &seq.to_string()));
    }
    Ok(())
}

fn amend(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let Some((target, rest)) = request.words.split_first() else {
        return Err((2, text().needs_message.into()));
    };
    let body = rest.join(" ");
    if body.trim().is_empty() {
        return Err((2, text().needs_text.into()));
    }
    let (message, _) = resolve(session, target)?;
    let op = json!({"kind": "message.edit", "message_id": message_id(&message),
                    "parts": [{"type": "text", "text": body}]});
    let conversation = session.conversation.clone();
    let result =
        session.client.op(&conversation, &new_message_id(), op).map_err(|e| session.failed(e))?;
    let updated = backend::sent_message(&result);
    if json {
        print_json(&script_message(&updated));
    } else {
        println!("{}", text().edited.replace("{seq}", &seq_of(&message).to_string()));
    }
    Ok(())
}

fn retract(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let Some(target) = request.words.first() else {
        return Err((2, text().needs_message.into()));
    };
    let (message, _) = resolve(session, target)?;
    let op = json!({"kind": "message.retract", "message_id": message_id(&message)});
    let conversation = session.conversation.clone();
    let result =
        session.client.op(&conversation, &new_message_id(), op).map_err(|e| session.failed(e))?;
    if json {
        print_json(&script_message(&backend::sent_message(&result)));
    } else {
        println!("{}", text().retracted.replace("{seq}", &seq_of(&message).to_string()));
    }
    Ok(())
}

fn mark_read(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let seq = match request.words.first() {
        Some(word) => match parse_ref(word).map_err(|e| (2, e))? {
            (MessageRef::Seq(seq), _) => seq,
            (MessageRef::Id(_), _) => seq_of(&resolve(session, word)?.0),
        },
        None => session.summary.get("last_seq").and_then(Value::as_u64).unwrap_or(0),
    };
    let conversation = session.conversation.clone();
    let op = json!({"kind": "read_cursor.set", "seq": seq});
    let result =
        session.client.op(&conversation, &new_message_id(), op).map_err(|e| session.failed(e))?;
    if json {
        print_json(&json!({"conversation": conversation, "seq": seq, "rev": result.get("rev")}));
    } else {
        println!("{}", text().marked.replace("{seq}", &seq.to_string()));
    }
    Ok(())
}

fn wait(session: &mut Session, request: &Request, json: bool) -> Outcome {
    let deadline = request.timeout_secs.map(|s| Instant::now() + Duration::from_secs(s));
    session.reopen(WAIT_TAIL).map_err(|e| session.failed(e))?;
    let mut after = request.after;
    let found = loop {
        let Some(input) = next_input(session, deadline) else {
            let secs = request.timeout_secs.unwrap_or_default().to_string();
            return Err((124, text().wait_timed_out.replace("{secs}", &secs)));
        };
        let Some(event) = stream_event(session, input)? else { continue };
        let candidates: Vec<Value> = match &event {
            UiEvent::Snapshot { summary, messages, typing } => {
                let chief_typing = typing.contains(&session.chief);
                // Without --after, wait for what comes after the chat's last message now.
                let after = *after.get_or_insert_with(|| {
                    summary
                        .get("last_seq")
                        .and_then(Value::as_u64)
                        .unwrap_or_else(|| messages.last().map(seq_of).unwrap_or(0))
                });
                if request.idle && !chief_typing {
                    break json!({"conversation": session.conversation, "idle": true, "after": after});
                }
                messages.clone()
            }
            UiEvent::Message(message) => vec![message.clone()],
            UiEvent::Typing { participant, on } if *participant == session.chief => {
                if request.idle && !on {
                    break json!({"conversation": session.conversation, "idle": true,
                                 "after": after.unwrap_or(0)});
                }
                Vec::new()
            }
            _ => Vec::new(),
        };
        if request.idle {
            continue;
        }
        let after_seq = after.unwrap_or(0);
        if let Some(message) = candidates.iter().find(|m| {
            wait_matches(m, after_seq, &request.from, &session.chief, request.contains.as_deref())
        }) {
            break script_message(message);
        }
    };
    if json {
        print_json(&found);
    } else if found.get("idle").is_some() {
        println!("idle");
    } else {
        let mut chat = printer(session);
        print_lines(&chat.message(&found));
    }
    Ok(())
}

fn events(session: &mut Session, request: &Request) -> Outcome {
    let deadline = request.timeout_secs.map(|s| Instant::now() + Duration::from_secs(s));
    session.reopen(request.tail.unwrap_or(20)).map_err(|e| session.failed(e))?;
    let mut seen = 0;
    while request.count.is_none_or(|count| seen < count) {
        let Some(input) = next_input(session, deadline) else {
            return Ok(());
        };
        match input {
            Input::Daemon(item) => {
                if adapt(&item, &session.conversation).is_some() {
                    print_json(&item);
                    seen += 1;
                }
            }
            other => {
                stream_event(session, other)?;
            }
        }
    }
    Ok(())
}
