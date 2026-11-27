//! `cmux mobile pair-requests`: list and answer the pairing requests waiting on
//! another of your Macs, from this machine (Leo, 2026-11-22: "ok surely we dont
//! need to be bottled this hard by a click").
//!
//! It goes the way `cmux machine NAME doctor` goes (machine_link.rs): this
//! Mac's hostd link socket opens the target Mac's `pair-requests` service
//! (cmux-mobile-host `pair_requests.rs`) on a link where this Mac passed `auth`
//! as a machine. So only a machine that Mac already paired, and gave Control,
//! may answer; account credentials alone open nothing there (audit B2). The
//! open asks for `closeLine`, so the target's refusal code comes back as the
//! last line and is printed with what to do next.
//!
//! On the Mac the request waits on (no `--mac`, or `--mac` naming this Mac) it
//! takes no link: the same link socket's `{"op":"pair-requests"}` asks this
//! Mac's own hostd, the process holding the request and telling the app's
//! Allow prompt. That socket is owner-only (`0600`, peer uid checked), so its
//! trust is the app's Allow button's: the same OS user on the same Mac. The
//! fingerprint check and every refusal of the service stay as they are.

use serde_json::{Value, json};

use super::machine_link::{Conversation, link_socket, pick, refused};
use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux mobile pair-requests list [--mac MAC]
       cmux mobile pair-requests allow DEVICE_ID --fingerprint HEX [--mac MAC]
       cmux mobile pair-requests deny DEVICE_ID --fingerprint HEX [--mac MAC]
  list or answer the pairing requests waiting on this Mac, or on another of your Macs
  without --mac (or with --mac naming this Mac) it answers this Mac's own requests, as its Allow button would
  MAC is another Mac's name, device id or machine id; this machine must be paired with it and hold Control there
  HEX is the fingerprint `list` prints (at least its first 8 characters, as that Mac's prompt shows)";

/// What the command asks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    /// `mac`: `None` is this Mac.
    List {
        mac: Option<String>,
    },
    Answer {
        mac: Option<String>,
        device_id: String,
        fingerprint: String,
        allow: bool,
    },
}

impl Request {
    fn mac(&self) -> Option<&str> {
        match self {
            Self::List { mac } | Self::Answer { mac, .. } => mac.as_deref(),
        }
    }

    /// The `pair-requests` service's open args.
    pub(super) fn args(&self) -> Value {
        match self {
            Self::List { .. } => json!({"action": "list"}),
            Self::Answer { device_id, fingerprint, allow, .. } => json!({
                "action": "answer",
                "deviceId": device_id,
                "fingerprint": fingerprint.to_ascii_lowercase(),
                "allow": allow,
            }),
        }
    }
}

/// `words` after the globals, from `pair-requests` on.
pub(super) fn parse(words: &[String]) -> Result<Request, String> {
    let [verb, rest @ ..] = words else { return Err("say list, allow or deny".into()) };
    let (mut mac, mut fingerprint, mut positional) = (None, None, Vec::new());
    let mut iter = rest.iter();
    while let Some(word) = iter.next() {
        let mut value_of = |flag: &str| -> Result<Option<String>, String> {
            if word == flag {
                return iter.next().cloned().map(Some).ok_or(format!("{flag} needs a value"));
            }
            Ok(word.strip_prefix(&format!("{flag}=")).map(str::to_owned))
        };
        if let Some(value) = value_of("--mac")? {
            mac = Some(value);
        } else if let Some(value) = value_of("--fingerprint")? {
            fingerprint = Some(value);
        } else if word.starts_with('-') {
            return Err(format!("unknown option {word}"));
        } else {
            positional.push(word.clone());
        }
    }
    if mac.as_ref().is_some_and(|m| m.trim().is_empty()) {
        return Err("--mac names the Mac the request waits on; leave it out for this Mac".into());
    }
    match verb.as_str() {
        "list" | "ls" if positional.is_empty() => Ok(Request::List { mac }),
        "list" | "ls" => Err(format!("list takes no device id (got {})", positional.join(" "))),
        "allow" | "deny" => {
            let [device_id] = positional.as_slice() else {
                return Err(format!("{verb} takes one device id (from `list`)"));
            };
            let fingerprint = fingerprint
                .ok_or("--fingerprint is required: the key's fingerprint `list` prints, so the answer cannot land on other keys")?;
            if fingerprint.len() < 8 || !fingerprint.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(
                    "--fingerprint is hex, at least the 8 characters that Mac's prompt shows"
                        .into(),
                );
            }
            Ok(Request::Answer {
                mac,
                device_id: device_id.clone(),
                fingerprint,
                allow: verb == "allow",
            })
        }
        other => Err(format!("unknown verb {other}; say list, allow or deny")),
    }
}

/// ` --mac MAC` as typed, or nothing for this Mac, for the commands a message names.
pub(super) fn mac_flag(mac: Option<&str>) -> String {
    mac.map(|mac| format!(" --mac {mac}")).unwrap_or_default()
}

/// The target's refusal, as `(code, message with a next step)`. `mac` labels the Mac;
/// `flag` is [`mac_flag`] for the commands it names.
pub(super) fn explain(code: &str, reason: &str, mac: &str, flag: &str) -> (String, String) {
    let text = match code {
        "unpaired" => format!(
            "{mac} has not paired this machine ({reason}). Pair it once: run `cmux machine {mac} doctor` and allow \
             this machine on {mac} or on your phone, then try again"
        ),
        "not_granted" => format!(
            "{mac} has paired this machine but not given it Control, which answering pairing requests needs. \
             Give this machine Control in cmux on {mac} (Settings, Devices), then try again"
        ),
        "revoked" => format!(
            "{mac} no longer allows this machine. Pair it again with `cmux machine {mac} doctor`, then give it Control"
        ),
        "forbidden" => format!(
            "{mac} refused: {reason}. Answer it from another of your paired devices (your phone, or another Mac)"
        ),
        "fingerprint_mismatch" => format!(
            "the request on {mac} is for another key ({reason}). Run `cmux mobile pair-requests list{flag}` \
             again and check the fingerprint against the one the asking device shows before you answer"
        ),
        "no_waiting_request" => format!(
            "{reason}: the asking device stopped waiting (it gave up, closed, or was already answered). Start \
             pairing on that device again, then run `cmux mobile pair-requests list{flag}`"
        ),
        "unavailable" => format!(
            "{mac} cannot answer pairing requests now ({reason}). Open the cmux app on {mac} and sign in, then try again"
        ),
        "unknown_service" | "not_offered" => format!(
            "{mac} does not offer pair-requests-v1, so it cannot be answered from here; run `cmux machine {mac} doctor` \
             to see the cmux link version it runs"
        ),
        "busy" => {
            format!("{mac} is busy with other pairing checks ({reason}); try again in a moment")
        }
        "local_unsupported" => format!(
            "the cmux link on {mac} has no local pair-requests answer ({reason}). Click Allow in its prompt, \
             or from another of your paired Macs run `cmux mobile pair-requests list --mac <this Mac's name>`"
        ),
        "bad_request" => format!("{mac} refused the request: {reason}"),
        _ => format!("{mac} refused ({code}): {reason}"),
    };
    (format!("pair_requests.{code}"), text)
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [noun, service, rest @ ..] = words.as_slice() else { return None };
    if noun != "mobile" || service != "pair-requests" {
        return None;
    }
    if rest.iter().any(|w| w == "--help" || w == "-h") || rest.is_empty() {
        println!("{USAGE}");
        return Some(if rest.is_empty() { 2 } else { 0 });
    }
    Some(match parse(rest) {
        Ok(request) => run(&global, &request),
        Err(message) => super::app::failure(
            "usage.invalid",
            &format!("cmux: {message}\n{USAGE}"),
            global.output,
            2,
        ),
    })
}

/// Where the request waits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Target {
    /// This Mac: its own hostd over the owner-only link socket, no link.
    Local,
    /// Another Mac, by device id, and its label.
    Remote { device_id: String, label: String },
}

/// Whether `mac` names this Mac's own row of the hostd list (its name, device id or machine id).
pub(super) fn names_this_mac(machines: &[Value], mac: &str) -> bool {
    let wanted = mac.to_lowercase();
    machines.iter().filter(|m| m.get("this").and_then(Value::as_bool) == Some(true)).any(|m| {
        let text =
            |key: &str| m.get(key).and_then(Value::as_str).unwrap_or_default().to_lowercase();
        text("name") == wanted
            || text("device_id") == wanted
            || (!wanted.is_empty() && text("machine_id").starts_with(&wanted))
    })
}

/// The Mac `mac` names: this one when omitted or naming this Mac, else a device id as given,
/// else the one Mac the hub lists under it.
fn resolve(socket: &std::path::Path, mac: Option<&str>) -> Result<Target, (String, String)> {
    let Some(mac) = mac else { return Ok(Target::Local) };
    let listed = Conversation::start(socket, &json!({"op": "machines"})).and_then(|mut c| c.next());
    let machines = match &listed {
        Ok(listed) => listed.get("machines").and_then(Value::as_array).cloned().unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    if names_this_mac(&machines, mac) {
        return Ok(Target::Local);
    }
    if uuid::Uuid::parse_str(mac).is_ok() {
        return Ok(Target::Remote { device_id: mac.to_owned(), label: mac.to_owned() });
    }
    let listed = listed?;
    if let Some(error) = refused(&listed) {
        return Err(error);
    }
    let machine = pick(&machines, mac).map_err(|m| ("machine.not_found".to_owned(), m))?;
    let text = |key: &str| machine.get(key).and_then(Value::as_str).unwrap_or(mac).to_owned();
    Ok(Target::Remote { device_id: text("device_id"), label: text("name") })
}

/// This Mac's own hostd answers: one line, the service's answer or `{"error","message"}`.
/// A hostd from before `{"op":"pair-requests"}` answers `bad_request` naming its ops.
pub(super) fn local_answer(answer: Value) -> Value {
    let message = answer.get("message").and_then(Value::as_str).unwrap_or_default();
    if answer.get("error").and_then(Value::as_str) == Some("bad_request")
        && message.starts_with("op is ")
        && !message.contains("pair-requests")
    {
        return json!({"error": "local_unsupported", "message": message});
    }
    answer
}

fn run(global: &GlobalArgs, request: &Request) -> i32 {
    let output = global.output;
    let fail = |(code, message): (String, String)| {
        super::app::failure(&code, &format!("cmux: {message}"), output, 1)
    };
    let daemon = match super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let socket = link_socket(&daemon);
    let flag = mac_flag(request.mac());
    let answer = match resolve(&socket, request.mac()) {
        Ok(Target::Local) => {
            let local = json!({"op": "pair-requests", "args": request.args()});
            match Conversation::start(&socket, &local).and_then(|mut c| c.next()) {
                Ok(answer) => Ok((local_answer(answer), "this Mac".to_owned())),
                Err(error) => Err(error),
            }
        }
        Ok(Target::Remote { device_id, label }) => {
            remote(&socket, request, &device_id, label, output)
        }
        Err(error) => Err(error),
    };
    let (answer, label) = match answer {
        Ok(found) => found,
        Err(error) => return fail(error),
    };
    if let Some(code) = answer.get("error").and_then(Value::as_str) {
        let reason = answer.get("message").and_then(Value::as_str).unwrap_or_default();
        return fail(explain(code, reason, &label, &flag));
    }
    match output {
        OutputMode::Human => print!("{}", human(request, &answer, &label)),
        OutputMode::Json | OutputMode::JsonLines => println!("{answer}"),
        OutputMode::Quiet => {}
    }
    0
}

/// Another Mac's `pair-requests` over a link: its answer line (or its refusal line), and its label.
fn remote(
    socket: &std::path::Path,
    request: &Request,
    device_id: &str,
    label: String,
    output: OutputMode,
) -> Result<(Value, String), (String, String)> {
    let open = json!({
        "op": "open", "peer": device_id, "service": "pair-requests",
        "args": request.args(), "closeLine": true,
    });
    let mut conversation = Conversation::start(socket, &open)?;
    let mut asked = false;
    let opened = loop {
        let answer = conversation.next()?;
        if answer.get("pending").and_then(Value::as_bool) != Some(true) {
            break answer;
        }
        if !asked && output == OutputMode::Human {
            eprintln!(
                "{label} has not paired this machine yet and is asking its person to allow it (on that Mac, \
                 or on your phone)…"
            );
        }
        asked = true;
    };
    if let Some(error) = refused(&opened) {
        return Err(error);
    }
    match conversation.next() {
        Ok(answer) => Ok((answer, label)),
        Err((code, _)) if code == "machine.closed" => {
            Ok((json!({"error": "closed", "message": "the link closed before it answered"}), label))
        }
        Err(error) => Err(error),
    }
}

/// What a person reads: the waiting requests and how to answer one, or the answer sent.
pub(super) fn human(request: &Request, answer: &Value, label: &str) -> String {
    match request {
        Request::Answer { device_id, allow, .. } => format!(
            "{} {device_id} on {label}; that device's pairing goes on as if you clicked {} on {label}\n",
            if *allow { "allowed" } else { "denied" },
            if *allow { "Allow" } else { "Don't Allow" },
        ),
        Request::List { mac } => {
            let rows =
                answer.get("requests").and_then(Value::as_array).cloned().unwrap_or_default();
            if rows.is_empty() {
                return format!("no pairing request is waiting on {label}\n");
            }
            let text = |row: &Value, key: &str| {
                row.get(key).and_then(Value::as_str).unwrap_or("?").to_owned()
            };
            let mut out = format!(
                "{:<38} {:<6} {:<17} {:>7}  name\n",
                "device id", "kind", "fingerprint", "waited"
            );
            for row in &rows {
                let waited = row.get("waitingMs").and_then(Value::as_u64).unwrap_or(0) / 1000;
                out.push_str(&format!(
                    "{:<38} {:<6} {:<17} {:>6}s  {}\n",
                    text(row, "deviceId"),
                    text(row, "kind"),
                    text(row, "fingerprint"),
                    waited,
                    text(row, "name"),
                ));
            }
            if let Some(first) = rows.first() {
                out.push_str(&format!(
                    "check the fingerprint against the asking device, then: cmux mobile pair-requests allow {} --fingerprint {}{}\n",
                    text(first, "deviceId"),
                    text(first, "fingerprint"),
                    mac_flag(mac.as_deref()),
                ));
            }
            out
        }
    }
}

#[cfg(test)]
#[path = "mobile_pair_requests_tests.rs"]
mod tests;
