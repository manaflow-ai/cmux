//! `cmux avatar set|get`: one picture per conversation participant, a person
//! or a Chief (`participant.avatar.set`, `participant.avatar.get`,
//! capability participant-avatars-v1), on the session's daemon. PARTICIPANT
//! is `me` (the person, `user_local`), a person id (`user_...`) or a Chief id
//! (`agent_...`). The daemon decides who may set what; an agent caller is
//! refused here, before any request, as `cmux chief` refuses it.

use std::path::PathBuf;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use super::GlobalArgs;
use super::link::{Link, LinkError};
use crate::cli::OutputMode;

/// The largest picture the daemon takes.
const MAX_AVATAR_BYTES: u64 = 1024 * 1024;

struct Text {
    usage: &'static str,
    agent_refused: &'static str,
    unsupported: &'static str,
    no_picture: &'static str,
    set: &'static str,
    cleared: &'static str,
}

static ENGLISH: Text = Text {
    usage: "usage: cmux avatar set PARTICIPANT FILE\n       cmux avatar set PARTICIPANT --clear\n       cmux avatar get PARTICIPANT [--out FILE]\n\n  PARTICIPANT is me (the person who runs this cmux, user_local), a person (user_...)\n  or a Chief (agent_...). A person bound with a person credential names its own id.\n  FILE is a PNG, JPEG, GIF or WebP picture, at most 1 MiB.\n  A person sets only their own picture; the person sets their Chiefs' pictures.",
    agent_refused: "an agent cannot {what} a picture ({marker} is set); ask the person",
    unsupported: "this needs a newer cmux daemon (the participant.avatar operations); stop it and run the command again",
    no_picture: "{participant} has no picture",
    set: "set the picture of {participant} ({media_type}, {bytes} bytes)",
    cleared: "cleared the picture of {participant}",
};

static JAPANESE: Text = Text {
    usage: "使い方: cmux avatar set PARTICIPANT FILE\n        cmux avatar set PARTICIPANT --clear\n        cmux avatar get PARTICIPANT [--out FILE]\n\n  PARTICIPANT は me (この cmux を使う本人、user_local)、人 (user_...)、または Chief (agent_...) です。\n  人の資格情報で接続した人は自分の ID を指定します。\n  FILE は 1 MiB 以下の PNG、JPEG、GIF、WebP の画像です。\n  人は自分の画像だけを設定でき、Chief の画像はその人が設定します。",
    agent_refused: "エージェントは画像を {what} できません ({marker} が設定されています)。本人に依頼してください",
    unsupported: "これには新しい cmux デーモン (participant.avatar 操作) が必要です。デーモンを停止してから、もう一度実行してください",
    no_picture: "{participant} には画像がありません",
    set: "{participant} の画像を設定しました ({media_type}, {bytes} バイト)",
    cleared: "{participant} の画像を消しました",
};

fn text() -> &'static Text {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Request {
    word: String,
    participant: String,
    file: Option<PathBuf>,
    clear: bool,
    out: Option<PathBuf>,
    json: bool,
}

fn parse(args: &[String]) -> Result<Request, String> {
    let mut request = Request::default();
    let mut positional = Vec::new();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--clear" => request.clear = true,
            "--json" => request.json = true,
            "--out" => {
                index += 1;
                request.out = Some(args.get(index).ok_or("--out needs a file")?.into());
            }
            flag if flag.starts_with("--") => return Err(format!("unknown argument {flag}")),
            word => positional.push(word.to_owned()),
        }
        index += 1;
    }
    let mut words = positional.into_iter();
    request.word = words.next().ok_or("give set or get")?;
    let participant = words.next().ok_or("give the participant: me, user_... or agent_...")?;
    request.participant = if participant == "me" { "user_local".into() } else { participant };
    request.file = words.next().map(PathBuf::from);
    if let Some(extra) = words.next() {
        return Err(format!("unknown argument {extra}"));
    }
    match request.word.as_str() {
        "set" if request.clear == request.file.is_some() => {
            Err("cmux avatar set needs a FILE or --clear".into())
        }
        "set" => Ok(request),
        "get" if request.file.is_none() && !request.clear => Ok(request),
        "get" => Err("cmux avatar get takes no FILE (use --out FILE)".into()),
        other => Err(format!("unknown word {other}")),
    }
}

fn agent_refused(what: &str, marker: &str) -> Value {
    json!({
        "code": "origin.forbidden",
        "message": text().agent_refused.replace("{what}", what).replace("{marker}", marker),
        "details": {"reason": "agent_caller", "marker": marker, "refused": what},
        "retryable": false,
    })
}

/// `cmux avatar …`.
pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let t = text();
    if args.first().is_some_and(|a| a == "--help" || a == "-h" || a == "help") {
        println!("{}", t.usage);
        return 0;
    }
    let request = match parse(args) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", t.usage);
            return 2;
        }
    };
    let output = if request.json { OutputMode::Json } else { global.output };
    if request.word == "set"
        && let Some(marker) = super::super::federation::agent_marker(|key| std::env::var(key).ok())
    {
        return super::super::wire::print_operation_error(&agent_refused("set", marker), output);
    }
    let (socket, derived) = match super::super::wire::resolve_socket_with_origin(global) {
        Ok(found) => found,
        Err(error) => {
            eprintln!("{}", super::super::wire::resolve_failure_message(&error));
            return super::super::wire::RESOLVE_FAILURE_EXIT;
        }
    };
    let mut link = match Link::connect(&socket, derived) {
        Ok(link) => link,
        Err(error) => {
            eprintln!("{}", super::super::wire::connect_failure(&socket, &error));
            return 3;
        }
    };
    let json_out = request.json || super::json_output(global.output);
    match execute(&mut link, &request, json_out) {
        Ok(()) => 0,
        Err(Failure::Usage(message)) => {
            eprintln!("cmux: {message}");
            2
        }
        Err(Failure::Link(LinkError::Transport(message))) => {
            eprintln!("cmux: {message}");
            3
        }
        Err(Failure::Link(LinkError::Rejected { code, .. }))
            if code.starts_with("validation.invalid: unknown operation") =>
        {
            eprintln!("cmux: {}", t.unsupported);
            1
        }
        Err(Failure::Link(LinkError::Rejected { code, message })) => {
            eprintln!("cmux: {code}: {message}");
            1
        }
    }
}

enum Failure {
    Usage(String),
    Link(LinkError),
}

impl From<LinkError> for Failure {
    fn from(error: LinkError) -> Self {
        Self::Link(error)
    }
}

fn execute(link: &mut Link, request: &Request, json_out: bool) -> Result<(), Failure> {
    let t = text();
    let participant = request.participant.as_str();
    if request.word == "get" {
        let got =
            link.call("participant.avatar.get", json!({"participant_id": participant}), None)?;
        let avatar = got.get("avatar").cloned().unwrap_or(Value::Null);
        if let Some(out) = &request.out {
            let data = avatar.get("data").and_then(Value::as_str).ok_or_else(|| {
                Failure::Usage(t.no_picture.replace("{participant}", participant))
            })?;
            let bytes = STANDARD.decode(data).map_err(|e| Failure::Usage(e.to_string()))?;
            cmux_blocking::fs::write(out, bytes)
                .map_err(|e| Failure::Usage(format!("{}: {e}", out.display())))?;
        }
        if json_out {
            let mut shown = got;
            if let Some(avatar) = shown.get_mut("avatar").and_then(Value::as_object_mut) {
                avatar.remove("data");
            }
            println!("{shown}");
        } else if avatar.is_null() {
            println!("{}", t.no_picture.replace("{participant}", participant));
        } else {
            println!(
                "{}\t{}\t{}",
                avatar["sha256"].as_str().unwrap_or(""),
                avatar["media_type"].as_str().unwrap_or(""),
                avatar["bytes"]
            );
        }
        return Ok(());
    }
    let mut params = json!({"participant_id": participant});
    if request.clear {
        params["clear"] = json!(true);
    } else if let Some(file) = &request.file {
        let size = cmux_blocking::fs::metadata(file)
            .map_err(|e| Failure::Usage(format!("{}: {e}", file.display())))?
            .len();
        if size > MAX_AVATAR_BYTES {
            return Err(Failure::Usage(format!(
                "{}: the picture is larger than 1 MiB",
                file.display()
            )));
        }
        let bytes = cmux_blocking::fs::read(file)
            .map_err(|e| Failure::Usage(format!("{}: {e}", file.display())))?;
        params["bytes"] = json!(STANDARD.encode(bytes));
    }
    let key = super::link::new_message_id();
    let written = link.call("participant.avatar.set", params, Some(&key))?;
    let value = written.get("value").cloned().unwrap_or(Value::Null);
    if json_out {
        println!("{value}");
    } else if value["avatar"].is_null() {
        println!("{}", t.cleared.replace("{participant}", participant));
    } else {
        println!(
            "{}",
            t.set
                .replace("{participant}", participant)
                .replace("{media_type}", value["avatar"]["media_type"].as_str().unwrap_or(""))
                .replace("{bytes}", &value["avatar"]["bytes"].to_string())
        );
    }
    Ok(())
}
