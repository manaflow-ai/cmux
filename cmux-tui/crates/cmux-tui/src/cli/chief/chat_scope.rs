//! `cmux chat send|read|wait|list` for coding agents (u19922, Nov 3: "ensure
//! that one can communicate with the chief/any chief/other humans in cmux
//! chat, via the CLI/mcp, so that other coding agents can message you or
//! other chiefs directly").
//!
//! `cmux chat send --to X --text T` is the app's Send Message To… action
//! (`home.messageTo`), which sends as the owner. From a coding agent
//! (`caller.rs`) that would put the agent's words in the owner's mouth, and a
//! Chief would obey them with the owner's trust. So here, before the app
//! action runs:
//!
//! - a Chief's chat (`chief`, a Chief's name or id, a chat id or title the
//!   Chief home lists) is sent as the agent through `cmux chief send`
//!   (`agent_sender`: the Chief reads it as that agent's words under the ask
//!   floor), and `--wait` prints the Chief's reply;
//! - any other chat (a person, a group) still goes through the app action,
//!   with the text labelled `[from NAME]` so every reader sees who wrote it.
//!
//! The person at a terminal (no agent detected) keeps the app action as it
//! was. `read`, `wait` and `list` read Chief chats (`cmux chief read|wait|
//! chats`); people's and group chats live with the app's cloud lease, which
//! only the app may use.

use super::script::{self, Request};
use super::{ChatTarget, Session, caller, pick_chat};
use crate::cli::GlobalArgs;

/// What `cmux chat …` becomes.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Chat {
    /// Done here, with this exit code.
    Exit(i32),
    /// The app action with these words instead (the text labelled).
    Rewritten(Vec<String>),
}

/// A parsed `cmux chat send`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Send {
    to: Option<String>,
    text: Option<String>,
    wait: bool,
    no_wait_agents: bool,
    timeout_secs: Option<u64>,
    sender_name: Option<String>,
    class: Option<String>,
    json: bool,
    /// Flags the app action takes that this file does not read, kept as is.
    other: Vec<String>,
}

const USAGE: &str = "usage: cmux chat send --to chief|CHIEF|PERSON|GROUP --text TEXT [--from \"APP › PERSONA\"] [--wait] [--timeout S] [--class C] [--json]\n       cmux chat read [--to CHIEF] [--last N] [--json]\n       cmux chat wait [--to CHIEF] [--after SEQ] [--from chief|me|ID] [--timeout S] [--json]\n       cmux chat list [--json]\n\n  Message your Chief, another Chief, a person or a group chat from any terminal or coding agent.\n  --to chief is your Chief; a Chief's name (`codex` is \"Codex Chief\") or id is that Chief;\n  any other name is a person or a group chat in Home. From a coding agent (acpmux, Claude Code,\n  Codex, OpenCode, pi) the message is that agent's, and a Chief reads it as the agent's words.\n  Say who you are with --from: the app, and the persona inside it (--from \"Grok bot › Ada\",\n  --from Muse). The chat shows it with the app's icon (a monogram for an app it does not know).\n  Without --from it is your harness and session (\"Claude Code › 3fa9c1d2@mini-7\").\n  --wait prints a Chief's reply and exits when its turn ends. read and wait read Chief chats.\n  Exit codes: 0 ok, 1 refused, 2 bad arguments, 3 connection lost, 124 timeout.";

const USAGE_JA: &str = "使い方: cmux chat send --to chief|CHIEF|PERSON|GROUP --text TEXT [--from \"APP › PERSONA\"] [--wait] [--timeout S] [--class C] [--json]\n       cmux chat read [--to CHIEF] [--last N] [--json]\n       cmux chat wait [--to CHIEF] [--after SEQ] [--from chief|me|ID] [--timeout S] [--json]\n       cmux chat list [--json]\n\n  どの端末やコーディングエージェントからでも、あなたの Chief、別の Chief、人、グループチャットにメッセージを送ります。\n  --to chief はあなたの Chief、Chief の名前 (`codex` は \"Codex Chief\") または ID はその Chief、\n  それ以外の名前は Home の人またはグループチャットです。コーディングエージェント (acpmux、Claude Code、\n  Codex、OpenCode、pi) からのメッセージはそのエージェントのもので、Chief はエージェントの言葉として読みます。\n  --from で名乗ってください: アプリとその中のペルソナ (--from \"Grok bot › Ada\"、--from Muse)。\n  チャットにはアプリのアイコン (知らないアプリはモノグラム) と一緒に表示されます。\n  --from がなければハーネスとセッションです (\"Claude Code › 3fa9c1d2@mini-7\")。\n  --wait は Chief の返信を表示し、そのターンの終わりに終了します。read と wait は Chief のチャットを読みます。\n  終了コード: 0 成功、1 拒否、2 引数の誤り、3 接続切れ、124 タイムアウト。";

const WAIT_PEOPLE: &str =
    "--wait reads a Chief's reply; a person's or a group's reply comes in Home";
const WAIT_PEOPLE_JA: &str =
    "--wait は Chief の返信を読みます。人やグループの返信は Home に届きます";

fn usage() -> &'static str {
    if crate::localization::catalog().is_japanese() { USAGE_JA } else { USAGE }
}

/// `cmux [globals] chat send|read|wait|list …` as this file runs it; None for
/// anything else (the app's `chat create|replies|colors`, and a person's
/// `chat send`, which run the app action unchanged).
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<Chat> {
    let (global, command) = crate::cli::parse_globals(args).ok()?;
    let (scope, rest) = command.split_first()?;
    if scope != "chat" {
        return None;
    }
    let (verb, rest) = rest.split_first()?;
    let prefix = args.get(..args.len().saturating_sub(command.len())).unwrap_or_default();
    match verb.as_str() {
        "send" => send(&global, prefix, rest),
        "read" | "wait" | "list" => Some(Chat::Exit(read(&global, verb, rest))),
        _ => None,
    }
}

fn parse_send(args: &[String]) -> Result<Send, String> {
    let mut send = Send::default();
    let mut words = Vec::new();
    let mut index = 0;
    while let Some(arg) = args.get(index).map(String::as_str) {
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
            "--to" => send.to = Some(value()?),
            "--text" => send.text = Some(value()?),
            "--wait" => send.wait = true,
            "--no-wait-agents" => send.no_wait_agents = true,
            "--timeout" => {
                let text = value()?;
                let secs: u64 =
                    text.parse().map_err(|_| format!("--timeout takes seconds, not {text}"))?;
                send.timeout_secs = (secs > 0).then_some(secs);
            }
            "--as" | "--from" => send.sender_name = Some(value()?),
            "--class" => send.class = Some(value()?),
            "--json" => send.json = true,
            "--" => {
                words.extend(args.iter().skip(index + 1).cloned());
                break;
            }
            other if other.starts_with("--") => {
                send.other.push(arg.to_owned());
                if inline.is_none()
                    && let Some(next) = args.get(index + 1)
                    && !next.starts_with("--")
                {
                    send.other.push(next.clone());
                    index += 1;
                }
            }
            word => words.push(word.to_owned()),
        }
        index += 1;
    }
    if send.text.is_none() && !words.is_empty() {
        send.text = Some(words.join(" "));
    }
    Ok(send)
}

fn send(global: &GlobalArgs, prefix: &[String], rest: &[String]) -> Option<Chat> {
    if rest.iter().any(|a| a == "-h" || a == "--help") {
        println!("{}", usage());
        return Some(Chat::Exit(0));
    }
    let send = match parse_send(rest) {
        Ok(send) => send,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", usage());
            return Some(Chat::Exit(2));
        }
    };
    let sender = caller::current(send.sender_name.as_deref(), send.class.as_deref(), None);
    // The person without --wait: the app action, unchanged.
    if sender.is_none() && !send.wait {
        return None;
    }
    let (Some(to), Some(text)) = (send.to.clone(), send.text.clone()) else {
        eprintln!("cmux: chat send needs --to and --text\n\n{}", usage());
        return Some(Chat::Exit(2));
    };
    if text.trim().is_empty() {
        eprintln!("cmux: chat send needs --to and --text\n\n{}", usage());
        return Some(Chat::Exit(2));
    }
    match chief_chat(global, &to) {
        Ok(Some(chat)) => {
            let request = Request {
                word: "send".into(),
                target: script::TargetArgs { chat: Some(chat), ..Default::default() },
                json: send.json,
                words: vec![text],
                wait: send.wait,
                no_wait_agents: send.no_wait_agents,
                timeout_secs: send.timeout_secs.or(Some(super::DEFAULT_TIMEOUT_SECS)),
                sender_name: send.sender_name.clone(),
                class: send.class,
                ..Request::default()
            };
            Some(Chat::Exit(script::execute(global, &request)))
        }
        Ok(None) if send.wait => {
            let why = if crate::localization::catalog().is_japanese() {
                WAIT_PEOPLE_JA
            } else {
                WAIT_PEOPLE
            };
            eprintln!("cmux: {why}");
            Some(Chat::Exit(2))
        }
        Ok(None) => {
            let sender = sender?;
            let mut words = prefix.to_vec();
            if send.json && !words.iter().any(|w| w == "--json") {
                words.push("--json".into());
            }
            words.extend(["chat", "send", "--to"].map(str::to_owned));
            words.push(to);
            words.push("--text".into());
            words.push(sender.labelled(&text));
            words.extend(send.other);
            Some(Chat::Rewritten(words))
        }
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            Some(Chat::Exit(code))
        }
    }
}

/// The id of the Chief chat `to` names on the Chief home (`pick_chat`), None
/// when it names none (a person or a group: the app's). `chief` must find one.
fn chief_chat(global: &GlobalArgs, to: &str) -> Result<Option<String>, (i32, String)> {
    let mine = to.trim().eq_ignore_ascii_case("chief");
    let mut session = match Session::connect(global, None, &ChatTarget::default()) {
        Ok(session) => session,
        Err(error) if mine => return Err(error),
        Err(_) => return Ok(None),
    };
    let chats = match session.client.chats() {
        Ok(chats) => chats,
        Err(error) if mine => return Err(session.failed(error)),
        Err(_) => return Ok(None),
    };
    match pick_chat(&chats, Some(to), session.client.owner) {
        Ok(chat) => Ok(chat.get("id").and_then(serde_json::Value::as_str).map(str::to_owned)),
        Err(why) if mine => Err((1, why)),
        Err(_) => Ok(None),
    }
}

/// `cmux chat read|wait|list` as `cmux chief read|wait|chats`, `--to` naming the chat.
fn read(global: &GlobalArgs, verb: &str, rest: &[String]) -> i32 {
    if rest.iter().any(|a| a == "-h" || a == "--help") {
        println!("{}", usage());
        return 0;
    }
    let word = if verb == "list" { "chats" } else { verb };
    let mut args = vec![word.to_owned()];
    args.extend(rest.iter().cloned());
    match script::parse(&args) {
        Ok(request) => script::execute(global, &request),
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", usage());
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| (*w).to_owned()).collect()
    }

    #[test]
    fn send_takes_its_text_as_a_flag_or_words_and_keeps_the_apps_flags() {
        let send = parse_send(&strings(&["--to", "Codex Chief", "--text=hi there", "--wait"]))
            .expect("parsed");
        assert_eq!(send.to.as_deref(), Some("Codex Chief"));
        assert_eq!(send.text.as_deref(), Some("hi there"));
        assert!(send.wait);
        let words =
            parse_send(&strings(&["--to", "Austin", "ship", "it", "--focus"])).expect("parsed");
        assert_eq!(words.text.as_deref(), Some("ship it"));
        assert_eq!(words.other, strings(&["--focus"]));
        let dashed =
            parse_send(&strings(&["--to", "chief", "--", "--wait", "is", "text"])).expect("parsed");
        assert_eq!((dashed.text.as_deref(), dashed.wait), (Some("--wait is text"), false));
        assert!(parse_send(&strings(&["--timeout", "soon"])).is_err());
    }

    #[test]
    fn a_persons_send_without_wait_is_the_app_action_unchanged() {
        // No agent in this test's own environment is assumed: --as names one only when given.
        let words = strings(&["chat", "send", "--to", "Austin", "--text", "hi"]);
        if caller::current(None, None, None).is_none() {
            assert_eq!(run_if_requested(&words), None);
        }
        assert_eq!(run_if_requested(&strings(&["chat", "create", "--members", "a"])), None);
    }
}
