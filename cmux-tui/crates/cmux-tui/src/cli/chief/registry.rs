//! `cmux chief list|new|adopt|edit|delete|history|undo`: the person's Chiefs, through the
//! daemon's Chief registry (`chief.profile.list`, `chief.profile.create`, `chief.profile.adopt`, `chief.profile.update`,
//! `chief.profile.delete`, `chief.profile.avatar.set`, `chief.profile.history`, `chief.profile.undo`). One call per command on the Chief
//! home's owner, as `cmux chief engine` finds it; nothing is started. A
//! CHIEF argument is an id or a display name that names one Chief.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};

use super::link::{Link, LinkError};
use super::{GlobalArgs, Target};
use crate::cli::OutputMode;

/// The largest picture the daemon takes.
const MAX_AVATAR_BYTES: u64 = 1024 * 1024;

/// The registry words `cmux chief` takes first.
pub(super) const WORDS: [&str; 8] =
    ["list", "get", "new", "adopt", "edit", "delete", "history", "undo"];

#[derive(Debug, Default, PartialEq, Eq)]
struct Request {
    word: String,
    chief: Option<String>,
    fields: Map<String, Value>,
    avatar: Option<PathBuf>,
    clear_avatar: bool,
    chief_home: Option<PathBuf>,
    /// `cmux chief undo --to-rev N`.
    to_rev: Option<u64>,
    /// `cmux chief history --limit N`.
    limit: Option<u64>,
    help: bool,
    /// `--json` after the word (the global flag works too).
    json: bool,
}

struct Text {
    usage: &'static str,
    needs_name: &'static str,
    needs_chief: &'static str,
    no_such: &'static str,
    ambiguous: &'static str,
    created: &'static str,
    needs_agent: &'static str,
    adopted: &'static str,
    updated: &'static str,
    deleted: &'static str,
    default_mark: &'static str,
    unsupported: &'static str,
    picture_not_set: &'static str,
    restored: &'static str,
    no_history: &'static str,
    agent_refused: &'static str,
    control_refused: &'static str,
}

static ENGLISH: Text = Text {
    usage: "usage: cmux chief list\n       cmux chief get CHIEF\n       cmux chief new --name NAME [PROFILE]\n       cmux chief adopt AGENT [PROFILE]\n       cmux chief edit CHIEF [PROFILE] [--clear-avatar]\n       cmux chief delete CHIEF\n       cmux chief history CHIEF [--limit N]\n       cmux chief undo CHIEF [--to-rev N]\n\n  Your Chiefs: each has its own name, role, picture, personality, instructions,\n  tools, backend and memory. CHIEF is an id (agent_...) or a name.\n  history lists every change to a Chief (who made it, when); undo restores the\n  version before the last change, or revision N, as a new change.\n  adopt makes AGENT, an agent already in your conversations (agent_...), a Chief\n  under its own id: its conversations and history stay; it gets a new Chief's defaults.\n\n  PROFILE:\n  --name NAME              1 to 100 characters\n  --role TEXT              one line, for example \"Release captain\"\n  --personality TEXT       tone and style\n  --instructions TEXT      added to the Chief's system prompt (after the base rules)\n  --instructions-file F    the same, read from file F\n  --avatar FILE            a PNG, JPEG, GIF or WebP picture, at most 1 MiB\n  --tools a,b              from browser, chiefs, cloud_vms, memory_import, spawn, tell, workspaces\n  --harnesses a,b          the harnesses its subagents may use (empty: all)\n  --self-edit a,b          what the Chief may change itself: avatar, display_name, engine, instructions, personality, role (default: all)\n  --harness H --model M --effort E   its backend: an acpmux harness (claude, codex, claude-sr2, opencode, unii for UniiChat after `unii login` on this Mac,\n                                     or your own: cmux harness add), model and effort\n  --lock / --unlock        only you may change it (no Chief can, itself included)\n  --chief-home DIR         an isolated Chief home",
    needs_name: "cmux chief new needs --name NAME",
    needs_chief: "give the Chief: an id (agent_...) or its name; cmux chief list shows them",
    no_such: "no Chief is named {chief}; cmux chief list shows them",
    ambiguous: "more than one Chief is named {chief}; use its id",
    created: "created {name} ({id})",
    needs_agent: "cmux chief adopt needs the agent: its participant id (agent_...)",
    adopted: "adopted {name} ({id}) as a Chief",
    updated: "updated {name} ({id}, rev {rev})",
    deleted: "deleted {name} ({id})",
    default_mark: "default",
    unsupported: "this needs a newer cmux daemon (the chief.profile.list operation); stop it and run the command again",
    picture_not_set: "the picture was not set",
    restored: "restored {name} ({id}) to an earlier version, now rev {rev}",
    no_history: "no changes are kept for this Chief yet",
    agent_refused: "cmux chief {what} is refused for an agent caller ({marker} is set); only the person makes, changes and deletes Chiefs; a Chief changes its own profile with its profile tool",
    control_refused: "{what} is refused for an agent caller ({marker} is set); only the person writes a Chief's profile, engine or turn; a Chief changes its own profile with its profile tool and its own engine with its chief engine tool",
};

static JAPANESE: Text = Text {
    usage: "使い方: cmux chief list\n       cmux chief get CHIEF\n       cmux chief new --name NAME [PROFILE]\n       cmux chief adopt AGENT [PROFILE]\n       cmux chief edit CHIEF [PROFILE] [--clear-avatar]\n       cmux chief delete CHIEF\n       cmux chief history CHIEF [--limit N]\n       cmux chief undo CHIEF [--to-rev N]\n\n  あなたの Chief たち。それぞれに名前、役割、画像、性格、指示、ツール、バックエンド、記憶があります。\n  CHIEF は id (agent_...) または名前です。\n  history は Chief への変更の一覧 (誰がいつ) を表示し、undo は直前の変更の前の版\n  (または版 N) を新しい変更として戻します。\n  adopt は会話にすでにいるエージェント AGENT (agent_...) を、その id のまま Chief にします。\n  会話と履歴はそのまま残り、新しい Chief の既定値が付きます。\n\n  PROFILE:\n  --name NAME              1 から 100 文字\n  --role TEXT              1 行。例: \"リリース担当\"\n  --personality TEXT       口調とスタイル\n  --instructions TEXT      Chief のシステムプロンプトに追加 (基本ルールの後)\n  --instructions-file F    同じ内容をファイル F から読む\n  --avatar FILE            PNG、JPEG、GIF または WebP の画像 (1 MiB まで)\n  --tools a,b              browser, chiefs, cloud_vms, memory_import, spawn, tell, workspaces から\n  --harnesses a,b          サブエージェントが使えるハーネス (空ならすべて)\n  --self-edit a,b          Chief が自分で変えられる項目: avatar, display_name, engine, instructions, personality, role (既定: すべて)\n  --harness H --model M --effort E   バックエンド: acpmux のハーネス (claude, codex, claude-sr2, opencode、UniiChat の unii (この Mac での `unii login` が必要)、\n                                     または cmux harness add で追加したもの)、モデル、推論の強さ\n  --lock / --unlock        あなただけが変更できるようにする (Chief 自身を含め、どの Chief も変更できません)\n  --chief-home DIR         独立した Chief ホーム",
    needs_name: "cmux chief new には --name NAME が必要です",
    needs_chief: "Chief を指定してください: id (agent_...) または名前。cmux chief list で一覧を表示します",
    no_such: "{chief} という名前の Chief はいません。cmux chief list で一覧を表示します",
    ambiguous: "{chief} という名前の Chief が複数います。id を使ってください",
    created: "{name} を作成しました ({id})",
    needs_agent: "cmux chief adopt にはエージェントの参加者 id (agent_...) が必要です",
    adopted: "{name} ({id}) を Chief にしました",
    updated: "{name} を更新しました ({id}、rev {rev})",
    deleted: "{name} を削除しました ({id})",
    default_mark: "既定",
    unsupported: "これには新しい cmux デーモン (chief.profile.list 操作) が必要です。デーモンを停止してから、もう一度実行してください",
    picture_not_set: "画像は設定されていません",
    restored: "{name} ({id}) を以前の版に戻しました。現在 rev {rev}",
    no_history: "この Chief の変更履歴はまだありません",
    agent_refused: "エージェントからの呼び出しでは cmux chief {what} を使えません ({marker} が設定されています)。Chief の作成、変更、削除は本人だけが行います。Chief は自分のプロフィールを profile ツールで変更します",
    control_refused: "エージェントからの呼び出しでは {what} を使えません ({marker} が設定されています)。Chief のプロフィール、エンジン、ターンを変えられるのは本人だけです。Chief は自分のプロフィールを profile ツールで、自分のエンジンを chief engine ツールで変更します",
};

fn text() -> &'static Text {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}

fn parse(args: &[String]) -> Result<Request, String> {
    let mut request = Request { word: args[0].clone(), ..Request::default() };
    let mut index = 1;
    while index < args.len() {
        let arg = args[index].as_str();
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
        let list = |text: String| -> Value {
            Value::Array(
                text.split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|s| json!(s))
                    .collect(),
            )
        };
        match flag {
            "-h" | "--help" => request.help = true,
            "--json" => request.json = true,
            "--name" => {
                request.fields.insert("display_name".into(), json!(value()?));
            }
            "--role" | "--personality" | "--instructions" | "--harness" | "--model"
            | "--effort" => {
                let key = flag.trim_start_matches("--").to_owned();
                request.fields.insert(key, json!(value()?));
            }
            "--instructions-file" => {
                let path = value()?;
                let text =
                    cmux_blocking::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
                request.fields.insert("instructions".into(), json!(text));
            }
            "--tools" | "--harnesses" | "--self-edit" => {
                let key = flag.trim_start_matches("--").replace('-', "_");
                request.fields.insert(key, list(value()?));
            }
            "--lock" => {
                request.fields.insert("locked".into(), json!(true));
            }
            "--unlock" => {
                request.fields.insert("locked".into(), json!(false));
            }
            "--to-rev" | "--limit" => {
                let text = value()?;
                let number: u64 =
                    text.parse().map_err(|_| format!("{flag} needs a number, got {text}"))?;
                if flag == "--to-rev" {
                    request.to_rev = Some(number);
                } else {
                    request.limit = Some(number);
                }
            }
            "--avatar" => request.avatar = Some(value()?.into()),
            "--clear-avatar" => request.clear_avatar = true,
            "--chief-home" => request.chief_home = Some(value()?.into()),
            other if !other.starts_with('-') && request.chief.is_none() => {
                request.chief = Some(other.to_owned());
            }
            other => return Err(format!("unknown argument {other}")),
        }
        index += 1;
    }
    let word = request.word.as_str();
    if word == "get"
        && (request.chief.is_none() || !request.fields.is_empty() || request.avatar.is_some())
    {
        return Err("cmux chief get takes only the Chief".into());
    }
    if word == "list" && (request.chief.is_some() || !request.fields.is_empty()) {
        return Err("cmux chief list takes no Chief or profile".into());
    }
    if word == "adopt" && !request.help && request.chief.is_none() {
        return Err(text().needs_agent.into());
    }
    if word == "new" && request.chief.is_some() {
        return Err("cmux chief new takes --name, not a Chief".into());
    }
    if word == "delete" && (!request.fields.is_empty() || request.avatar.is_some()) {
        return Err("cmux chief delete takes only the Chief".into());
    }
    if matches!(word, "history" | "undo")
        && !request.help
        && (request.chief.is_none() || !request.fields.is_empty() || request.avatar.is_some())
    {
        return Err(format!("cmux chief {word} takes only the Chief"));
    }
    if request.to_rev.is_some() && word != "undo" {
        return Err("--to-rev goes with cmux chief undo".into());
    }
    if request.limit.is_some() && word != "history" {
        return Err("--limit goes with cmux chief history".into());
    }
    if request.avatar.is_some() && request.clear_avatar {
        return Err("give --avatar or --clear-avatar, not both".into());
    }
    if word != "edit" && request.clear_avatar {
        return Err("--clear-avatar goes with cmux chief edit".into());
    }
    if word == "list" && request.avatar.is_some() {
        return Err("cmux chief list takes no --avatar".into());
    }
    if word == "edit"
        && !request.help
        && request.fields.is_empty()
        && request.avatar.is_none()
        && !request.clear_avatar
    {
        return Err("cmux chief edit needs at least one change".into());
    }
    Ok(request)
}

impl Request {
    /// The registry writes that a Chief turn must relay through its own host.
    /// A person-authorized agent may use the CLI for the same owner operation;
    /// the Chief-turn relay is the separate guard that keeps a Chief from
    /// changing another Chief without its `chiefs` grant.
    fn write(&self) -> Option<&str> {
        match self.word.as_str() {
            "new" | "adopt" | "edit" | "delete" | "undo" => Some(self.word.as_str()),
            _ => None,
        }
    }
}

/// The typed refusal of a Chief write for an agent caller: the
/// `origin.forbidden` shape of `--all-sessions` (cli/federation.rs). The
/// marker check is cooperative: it stops a model that tries, not a process
/// that clears its env (the daemon cannot tell the turn's unbound
/// connection from the person's; layer 2 is #13742).
fn agent_refused(what: &str, marker: &str) -> Value {
    json!({
        "code": "origin.forbidden",
        "message": text().agent_refused.replace("{what}", what).replace("{marker}", marker),
        "details": {"reason": "agent_caller", "marker": marker, "refused": what},
        "retryable": false,
    })
}

/// The `chief.*` operations an agent caller may call: the reads. Every other
/// `chief.*` operation (a profile write, `chief.engine.set`, `chief.stop`,
/// and any later one) is a write the person makes, so a new daemon `chief.*`
/// read must be added here too.
const AGENT_READS: [&str; 5] = [
    "chief.engine.get",
    "chief.profile.list",
    "chief.profile.get",
    "chief.profile.avatar.get",
    "chief.profile.history",
];

/// The refusal of a Chief write that an agent caller sends by another path
/// than `cmux chief new|edit|delete` (cx-ebm.60.9 layer 1, hq-6d
/// 2026-10-14): `cmux chief engine` with a change and `cmux chief stop`
/// (`refused` the word), and `cmux raw operation|command` naming a `chief.*`
/// write (`refused` the operation). `None` for a read or a person.
pub(in crate::cli) fn agent_control_refusal(command: &str, refused: &str) -> Option<Value> {
    let marker = super::super::federation::agent_marker(super::super::caller_env::var)?;
    Some(json!({
        "code": "origin.forbidden",
        "message": text().control_refused.replace("{what}", command).replace("{marker}", marker),
        "details": {"reason": "agent_caller", "marker": marker, "refused": refused},
        "retryable": false,
    }))
}

/// [`agent_control_refusal`] for a raw request that names `operation`.
pub(in crate::cli) fn agent_operation_refusal(operation: &str) -> Option<Value> {
    if !operation.starts_with("chief.") || AGENT_READS.contains(&operation) {
        return None;
    }
    agent_control_refusal(&format!("cmux raw operation {operation}"), operation)
}

/// The app actions that write a Chief through the app's own connection:
/// their ids and their CLI names (`cmux action run` takes either).
const APP_ACTIONS: [&str; 6] = [
    "home.archiveChief",
    "home.deleteChief",
    "home.stopChief",
    "home.stopAllAgents",
    "home archive-chief",
    "home delete-chief",
];

/// [`agent_control_refusal`] for an app action (`cmux action run ID`,
/// `cmux home new-chief`) that still controls a live Chief. New Chief is
/// intentionally available to a person-authorized agent and is handled by the
/// app's owner connection.
pub(in crate::cli) fn agent_app_action_refusal(action: &str) -> Option<Value> {
    // `home.newChief` is available to a person-authorized agent, but a Chief
    // turn must still go through its own `chiefs` tool and grant.
    if action.trim() == "home.newChief" || action.trim() == "home new-chief" {
        return super::super::caller_env::var(super::super::chief_target::OWNER_KEY)
            .filter(|value| !value.trim().is_empty())
            .and_then(|_| agent_control_refusal("cmux action run home.newChief", action.trim()));
    }
    if !APP_ACTIONS.contains(&action.trim()) {
        return None;
    }
    agent_control_refusal(&format!("cmux action run {}", action.trim()), action.trim())
}

/// The env key of a Chief host's turn key: its own turn sessions have it,
/// subagents never (optchat-chief chief_profile.rs `TURN_KEY_ENV`).
#[cfg(unix)]
const TURN_KEY_ENV: &str = "OPTCHAT_TURN_SEAL";

/// `cmux chief new|edit` inside a Chief's own turn: the request goes to the
/// turn's Chief host (`$MUX_HOME/optchat/tools.sock`, tool `chiefs`) with
/// the turn key the host gave that turn; the host answers only with that key
/// and sends the write on its own bound connection, where the daemon decides
/// (the Chief's `chiefs` grant and ceiling). The env only finds the host and
/// carries the key: it grants nothing. `None` when this is no Chief turn
/// (no key or no home): the caller is refused as any agent caller.
#[cfg(unix)]
fn relay_to_turn_host(request: &Request, output: OutputMode) -> Option<i32> {
    use std::io::{BufRead, BufReader, Write};
    let key = std::env::var(TURN_KEY_ENV).ok().filter(|k| !k.is_empty())?;
    let home = std::env::var("MUX_HOME").ok().filter(|h| !h.is_empty())?;
    let socket = Path::new(&home).join("optchat").join("tools.sock");
    let mut call = request.fields.clone();
    call.insert("tool".into(), json!("chiefs"));
    call.insert("turn_key".into(), json!(key));
    let action = if request.word == "new" { "create" } else { "update" };
    call.insert("action".into(), json!(action));
    if let Some(chief) = &request.chief {
        call.insert("chief".into(), json!(chief));
    }
    if let Some(path) = &request.avatar {
        let absolute = cmux_blocking::fs::canonicalize(path).unwrap_or_else(|_| path.clone());
        call.insert("avatar_path".into(), json!(absolute.display().to_string()));
    }
    if request.clear_avatar {
        call.insert("clear_avatar".into(), json!(true));
    }
    let json_out = request.json || super::json_output(output);
    let fail = |message: String| -> i32 {
        if json_out {
            let error = json!({"code": "operation.failed", "message": message,
                               "details": {"reason": "chief_host"}, "retryable": false});
            super::super::wire::print_operation_error(&error, OutputMode::Json)
        } else {
            eprintln!("cmux: {message}");
            1
        }
    };
    let mut stream = match std::os::unix::net::UnixStream::connect(&socket) {
        Ok(stream) => stream,
        Err(error) => {
            return Some(fail(format!(
                "this Chief's host is not running ({}: {error})",
                socket.display()
            )));
        }
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(120)));
    if writeln!(stream, "{}", Value::Object(call)).is_err() {
        return Some(fail("this Chief's host closed the connection".into()));
    }
    let mut line = String::new();
    if BufReader::new(stream).read_line(&mut line).unwrap_or(0) == 0 {
        return Some(fail("this Chief's host gave no answer".into()));
    }
    let answer: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
    match (answer.get("text").and_then(Value::as_str), answer.get("error").and_then(Value::as_str))
    {
        (Some(answer_text), _) => {
            // The record (JSON) first, then a note line.
            let (record, note) = answer_text
                .split_once("\n}\n")
                .map_or((answer_text.to_owned(), ""), |(r, n)| (format!("{r}\n}}"), n));
            if json_out {
                let compact = serde_json::from_str::<Value>(&record)
                    .map_or(record.clone(), |v| v.to_string());
                println!("{compact}");
            } else {
                let value = serde_json::from_str::<Value>(&record).unwrap_or(Value::Null);
                let template = if request.word == "new" { text().created } else { text().updated };
                println!("{}", fill(&value, template));
                if !note.is_empty() {
                    println!("{note}");
                }
            }
            Some(0)
        }
        (None, Some(error)) => Some(fail(error.to_owned())),
        _ => Some(fail("this Chief's host gave an empty answer".into())),
    }
}

/// No Chief host off Unix (its tools socket is a Unix socket).
#[cfg(not(unix))]
fn relay_to_turn_host(_request: &Request, _output: OutputMode) -> Option<i32> {
    None
}

/// `cmux chief list|get|new|edit|delete …`.
pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let t = text();
    let request = match parse(args) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", t.usage);
            return 2;
        }
    };
    if request.help {
        println!("{}", t.usage);
        return 0;
    }
    if let Some(what) = request.write()
        && let Some(marker) = std::env::var(super::super::chief_target::OWNER_KEY)
            .ok()
            .filter(|value| !value.trim().is_empty())
    {
        let output = if request.json { OutputMode::Json } else { global.output };
        // A Chief's own turn: its host decides, on its bound connection. A
        // person-authorized agent without the Chief owner marker proceeds to
        // the normal owner socket below.
        if matches!(what, "new" | "edit")
            && request.chief_home.is_none()
            && let Some(code) = relay_to_turn_host(&request, output)
        {
            return code;
        }
        return super::super::wire::print_operation_error(&agent_refused(what, &marker), output);
    }
    let socket = match super::target(global, request.chief_home.as_deref()) {
        Ok(Target::Explicit(socket, derived)) => (socket, derived),
        Ok(Target::Home(home)) => match home.socket() {
            Ok(socket) => (socket, true),
            Err(error) => {
                eprintln!("cmux: {error}");
                return 2;
            }
        },
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            return code;
        }
    };
    let mut link = match Link::connect(&socket.0, socket.1) {
        Ok(link) => link,
        Err(error) => {
            eprintln!("{}", super::super::wire::connect_failure(&socket.0, &error));
            return 3;
        }
    };
    match execute(&mut link, &request, global.output) {
        Ok(()) => 0,
        Err(Failure::Usage(message)) => {
            eprintln!("cmux: {message}");
            2
        }
        Err(Failure::Link(LinkError::Transport(message))) => {
            eprintln!("cmux: {message}");
            3
        }
        Err(Failure::Unsupported) => {
            eprintln!("cmux: {}", t.unsupported);
            1
        }
        Err(Failure::Link(LinkError::Rejected { code, message })) => {
            eprintln!("cmux: {code}: {message}");
            1
        }
        Err(Failure::Partial { done, error }) => {
            eprintln!("cmux: {done}");
            eprintln!("cmux: {error}");
            1
        }
    }
}

enum Failure {
    Usage(String),
    Link(LinkError),
    /// The daemon has no Chief registry (an older build).
    Unsupported,
    /// An earlier write of the command committed, a later one failed.
    Partial {
        done: String,
        error: LinkError,
    },
}

impl From<LinkError> for Failure {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

fn execute(link: &mut Link, request: &Request, output: OutputMode) -> Result<(), Failure> {
    let t = text();
    let json_out = request.json || super::json_output(output);
    // The first call: an older daemon refuses the unknown operation.
    let chiefs = match link.call("chief.profile.list", json!({}), None) {
        Ok(chiefs) => chiefs,
        Err(LinkError::Rejected { code, .. }) if code.starts_with("validation.invalid") => {
            return Err(Failure::Unsupported);
        }
        Err(error) => return Err(error.into()),
    };
    let records = chiefs.get("chiefs").and_then(Value::as_array).cloned().unwrap_or_default();
    if request.word == "get" {
        let wanted = request.chief.as_deref().unwrap_or_default();
        let found = resolve(&records, wanted).map_err(Failure::Usage)?;
        if json_out {
            println!("{found}");
        } else {
            println!("{}", serde_json::to_string_pretty(&found).unwrap_or_default());
        }
        return Ok(());
    }
    if request.word == "list" {
        if json_out {
            println!("{chiefs}");
        } else {
            for record in &records {
                println!("{}", line(record, t));
            }
        }
        return Ok(());
    }
    let avatar = request.avatar.as_deref().map(read_avatar).transpose().map_err(Failure::Usage)?;
    let mut record = if request.word == "adopt" {
        let agent = request.chief.as_deref().ok_or_else(|| Failure::Usage(t.needs_agent.into()))?;
        let mut params = request.fields.clone();
        params.insert("participant_id".into(), json!(agent));
        let key = super::link::new_message_id();
        let adopted = link.call("chief.profile.adopt", Value::Object(params), Some(&key))?;
        adopted.get("value").cloned().unwrap_or(Value::Null)
    } else if request.word == "new" {
        if !request.fields.contains_key("display_name") {
            return Err(Failure::Usage(t.needs_name.into()));
        }
        let key = super::link::new_message_id();
        let created =
            link.call("chief.profile.create", Value::Object(request.fields.clone()), Some(&key))?;
        created.get("value").cloned().unwrap_or(Value::Null)
    } else {
        let wanted =
            request.chief.as_deref().ok_or_else(|| Failure::Usage(t.needs_chief.into()))?;
        let found = resolve(&records, wanted).map_err(Failure::Usage)?;
        let id = text_of(&found, "id").to_owned();
        if request.word == "history" {
            let mut params = json!({"chief": id});
            if let Some(limit) = request.limit {
                params["limit"] = json!(limit);
            }
            let history = link.call("chief.profile.history", params, None)?;
            let revisions =
                history.get("revisions").and_then(Value::as_array).cloned().unwrap_or_default();
            if json_out {
                println!("{history}");
            } else if revisions.is_empty() {
                println!("{}", t.no_history);
            } else {
                for revision in &revisions {
                    println!("{}", revision_line(revision));
                }
            }
            return Ok(());
        }
        if request.word == "undo" {
            let key = super::link::new_message_id();
            let mut params = json!({"chief": id, "expected_rev": found["rev"]});
            if let Some(rev) = request.to_rev {
                params["to_rev"] = json!(rev);
            }
            let undone = link.call("chief.profile.undo", params, Some(&key))?;
            let value = undone.get("value").cloned().unwrap_or(Value::Null);
            print_result(&value, t.restored, json_out);
            return Ok(());
        }
        if request.word == "delete" {
            let key = super::link::new_message_id();
            let params = json!({"chief": id, "expected_rev": found["rev"]});
            let deleted = link.call("chief.profile.delete", params, Some(&key))?;
            let value = deleted.get("value").cloned().unwrap_or(Value::Null);
            print_result(&value, t.deleted, json_out);
            return Ok(());
        }
        let mut current = found;
        if !request.fields.is_empty() {
            let mut params = request.fields.clone();
            params.insert("chief".into(), json!(id));
            params.insert("expected_rev".into(), current["rev"].clone());
            let key = super::link::new_message_id();
            let updated = link.call("chief.profile.update", Value::Object(params), Some(&key))?;
            current = updated.get("value").cloned().unwrap_or(Value::Null);
        }
        if request.clear_avatar {
            let key = super::link::new_message_id();
            let params = json!({"chief": id, "clear": true});
            match link.call("chief.profile.avatar.set", params, Some(&key)) {
                Ok(cleared) => current = cleared.get("value").cloned().unwrap_or(Value::Null),
                Err(error) if !request.fields.is_empty() => {
                    let done = format!("{}; {}", fill(&current, t.updated), t.picture_not_set);
                    return Err(Failure::Partial { done, error });
                }
                Err(error) => return Err(error.into()),
            }
        }
        current
    };
    if let Some((media_type, bytes)) = avatar {
        let key = super::link::new_message_id();
        let params = json!({"chief": record["id"], "media_type": media_type, "data": STANDARD.encode(bytes)});
        match link.call("chief.profile.avatar.set", params, Some(&key)) {
            Ok(set) => record = set.get("value").cloned().unwrap_or(Value::Null),
            Err(error) => {
                let template = match request.word.as_str() {
                    "new" => t.created,
                    "adopt" => t.adopted,
                    _ => t.updated,
                };
                let done = format!("{}; {}", fill(&record, template), t.picture_not_set);
                return Err(Failure::Partial { done, error });
            }
        }
    }
    let template = match request.word.as_str() {
        "new" => t.created,
        "adopt" => t.adopted,
        _ => t.updated,
    };
    print_result(&record, template, json_out);
    Ok(())
}

fn print_result(record: &Value, template: &str, json_out: bool) {
    if json_out {
        println!("{record}");
        return;
    }
    println!("{}", fill(record, template));
}

fn fill(record: &Value, template: &str) -> String {
    let rev = record.get("rev").map(Value::to_string).unwrap_or_default();
    template
        .replace("{name}", text_of(record, "display_name"))
        .replace("{id}", text_of(record, "id"))
        .replace("{rev}", &rev)
}

/// `rev  at  actor  operation`, tab-separated (`cmux chief history`).
fn revision_line(revision: &Value) -> String {
    let rev = revision.get("rev").map(Value::to_string).unwrap_or_default();
    [
        rev.as_str(),
        text_of(revision, "at"),
        text_of(revision, "actor"),
        text_of(revision, "operation"),
    ]
    .join("\t")
}

/// `id  name  role  [default]`, tab-separated.
fn line(record: &Value, t: &Text) -> String {
    let mut parts =
        vec![text_of(record, "id"), text_of(record, "display_name"), text_of(record, "role")];
    if record.get("is_default").and_then(Value::as_bool) == Some(true) {
        parts.push(t.default_mark);
    }
    parts.join("\t").trim_end().to_owned()
}

fn text_of<'a>(record: &'a Value, key: &str) -> &'a str {
    record.get(key).and_then(Value::as_str).unwrap_or("")
}

/// The one record `wanted` names: its id, else its display name.
fn resolve(records: &[Value], wanted: &str) -> Result<Value, String> {
    let t = text();
    if let Some(record) = records.iter().find(|r| text_of(r, "id") == wanted) {
        return Ok(record.clone());
    }
    let named: Vec<&Value> =
        records.iter().filter(|r| text_of(r, "display_name") == wanted).collect();
    match named.as_slice() {
        [one] => Ok((*one).clone()),
        [] => Err(t.no_such.replace("{chief}", wanted)),
        _ => Err(t.ambiguous.replace("{chief}", wanted)),
    }
}

/// The picture at `path` and its media type, from its first bytes.
fn read_avatar(path: &Path) -> Result<(&'static str, Vec<u8>), String> {
    let size =
        cmux_blocking::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?.len();
    if size > MAX_AVATAR_BYTES {
        return Err(format!("{}: the picture is larger than 1 MiB", path.display()));
    }
    let bytes = cmux_blocking::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let media_type = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else {
        return Err(format!("{}: not a PNG, JPEG, GIF or WebP picture", path.display()));
    };
    Ok((media_type, bytes))
}
