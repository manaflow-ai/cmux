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

use serde_json::{Value, json};

use super::machine_link::{Conversation, link_socket, pick, refused};
use super::{GlobalArgs, OutputMode};

const USAGE: &str = "usage: cmux mobile pair-requests list --mac MAC
       cmux mobile pair-requests allow DEVICE_ID --fingerprint HEX --mac MAC
       cmux mobile pair-requests deny DEVICE_ID --fingerprint HEX --mac MAC
  list or answer the pairing requests waiting on another of your Macs, from this machine
  MAC is the Mac's name, device id or machine id; this machine must be paired with it and hold Control there
  HEX is the fingerprint `list` prints (at least its first 8 characters, as that Mac's prompt shows)";

/// What the command asks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Request {
    List { mac: String },
    Answer { mac: String, device_id: String, fingerprint: String, allow: bool },
}

impl Request {
    fn mac(&self) -> &str {
        match self {
            Self::List { mac } | Self::Answer { mac, .. } => mac,
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
    let mac =
        mac.filter(|m| !m.trim().is_empty()).ok_or("--mac names the Mac the request waits on")?;
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

/// The target's refusal, as `(code, message with a next step)`.
pub(super) fn explain(code: &str, reason: &str, mac: &str) -> (String, String) {
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
            "the request on {mac} is for another key ({reason}). Run `cmux mobile pair-requests list --mac {mac}` \
             again and check the fingerprint against the one the asking device shows before you answer"
        ),
        "no_waiting_request" => format!(
            "{reason}: the asking device stopped waiting (it gave up, closed, or was already answered). Start \
             pairing on that device again, then run `cmux mobile pair-requests list --mac {mac}`"
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

/// The device id `mac` names: a device id as given, else the one Mac the hub lists under it.
fn resolve(socket: &std::path::Path, mac: &str) -> Result<(String, String), (String, String)> {
    if uuid::Uuid::parse_str(mac).is_ok() {
        return Ok((mac.to_owned(), mac.to_owned()));
    }
    let listed =
        Conversation::start(socket, &json!({"op": "machines"})).and_then(|mut c| c.next())?;
    if let Some(error) = refused(&listed) {
        return Err(error);
    }
    let machines = listed.get("machines").and_then(Value::as_array).cloned().unwrap_or_default();
    let machine = pick(&machines, mac).map_err(|m| ("machine.not_found".to_owned(), m))?;
    let text = |key: &str| machine.get(key).and_then(Value::as_str).unwrap_or(mac).to_owned();
    Ok((text("device_id"), text("name")))
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
    let (device_id, label) = match resolve(&socket, request.mac()) {
        Ok(found) => found,
        Err(error) => return fail(error),
    };
    let open = json!({
        "op": "open", "peer": device_id, "service": "pair-requests",
        "args": request.args(), "closeLine": true,
    });
    let mut conversation = match Conversation::start(&socket, &open) {
        Ok(conversation) => conversation,
        Err(error) => return fail(error),
    };
    let mut asked = false;
    let opened = loop {
        match conversation.next() {
            Ok(answer) if answer.get("pending").and_then(Value::as_bool) == Some(true) => {
                if !asked && output == OutputMode::Human {
                    eprintln!(
                        "{label} has not paired this machine yet and is asking its person to allow it (on that Mac, \
                         or on your phone)…"
                    );
                }
                asked = true;
            }
            Ok(answer) => break answer,
            Err(error) => return fail(error),
        }
    };
    if let Some(error) = refused(&opened) {
        return fail(error);
    }
    let answer = match conversation.next() {
        Ok(answer) => answer,
        Err((code, _)) if code == "machine.closed" => {
            return fail(explain("closed", "the link closed before it answered", &label));
        }
        Err(error) => return fail(error),
    };
    if let Some(code) = answer.get("error").and_then(Value::as_str) {
        let reason = answer.get("message").and_then(Value::as_str).unwrap_or_default();
        return fail(explain(code, reason, &label));
    }
    match output {
        OutputMode::Human => print!("{}", human(request, &answer, &label)),
        OutputMode::Json | OutputMode::JsonLines => println!("{answer}"),
        OutputMode::Quiet => {}
    }
    0
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
                    "check the fingerprint against the asking device, then: cmux mobile pair-requests allow {} --fingerprint {} --mac {mac}\n",
                    text(first, "deviceId"),
                    text(first, "fingerprint"),
                ));
            }
            out
        }
    }
}

#[cfg(test)]
#[path = "mobile_pair_requests_tests.rs"]
mod tests;
