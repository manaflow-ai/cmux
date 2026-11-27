//! `--webhook` on this machine: an automation that starts when a signed POST
//! reaches the runner's loopback listener ([`cmux_automations::webhook`]), and
//! `cmux automation webhook show|rotate|send`.
//!
//! The cloud's GitHub webhooks (`--webhook --on cloud`, `automation webhook rm`)
//! stay in `automation_webhook.rs`; these words are told apart by their verb.

use std::io::Read as _;
use std::time::Duration;

use cmux_automations::exec::pid_alive;
use cmux_automations::watch::EventSender;
use cmux_automations::webhook::{self, Server, WebhookFilter};
use cmux_automations::{Automation, Store, Trigger};
use serde_json::{Value, json};

use super::super::OutputMode;
use super::{Args, Failure, Out, Outcome, messages, now_ms, open_store, parse_duration, usage};

/// The flag that picks this trigger.
pub(super) const FLAG: &str = "webhook";
/// Its options: `--match PATH=VALUE` and `--header NAME=VALUE` (both repeatable), `--dedupe 1h`.
pub(super) const VALUED: &[&str] = &["match", "header", "dedupe"];
/// The verbs `automation webhook` takes here; any other goes to the cloud's.
pub(super) const VERBS: &[&str] = &["show", "rotate", "send"];

/// After a bind fails (the port is taken), the runner tries again this much later.
const RETRY_BIND: Duration = Duration::from_secs(30);

/// `create`'s and `edit`'s flags: the local ones plus `--webhook` and its options.
pub(super) fn spec_args(args: &[String], valued: &[&str], flags: &[&str]) -> Result<Args, Failure> {
    let mut valued = valued.to_vec();
    valued.extend(VALUED);
    let mut flags = flags.to_vec();
    flags.push(FLAG);
    Args::parse(args, &valued, &flags)
}

/// The first webhook option given, so one without `--webhook` (on a trigger that is not one)
/// is refused rather than dropped.
pub(super) fn option_given(a: &Args) -> Option<&'static str> {
    VALUED.iter().copied().find(|f| a.value(f).is_some())
}

pub(super) fn options_need_webhook(flag: &str) -> Failure {
    Failure::Usage(messages().local_hook_options_need_webhook.replace("{flag}", flag))
}

/// The trigger `--webhook` and its options name; `base`'s filters and window are kept when no
/// option replaces them (an `edit` that only moves the window keeps the filters).
pub(super) fn trigger(a: &Args, base: Option<&Trigger>) -> Result<Trigger, Failure> {
    let (mut filters, mut dedupe_seconds) = match base {
        Some(Trigger::Webhook { filters, dedupe_seconds }) => (filters.clone(), *dedupe_seconds),
        _ => (Vec::new(), webhook::DEFAULT_DEDUPE_SECONDS),
    };
    let (matches, headers) = (a.values_of("match"), a.values_of("header"));
    if !matches.is_empty() || !headers.is_empty() {
        filters = matches
            .iter()
            .map(|m| WebhookFilter::parse_json(m))
            .chain(headers.iter().map(|h| WebhookFilter::parse_header(h)))
            .collect::<Result<_, _>>()
            .map_err(Failure::Usage)?;
    }
    if let Some(d) = a.value("dedupe") {
        dedupe_seconds = parse_duration(d)?;
    }
    Ok(Trigger::Webhook { filters, dedupe_seconds })
}

/// Where the runner listens now, if one does.
fn listening(store: &Store) -> Option<String> {
    store.webhook_listener().filter(|l| pid_alive(l.pid)).map(|l| l.addr)
}

/// Where deliveries go: the live listener's address, else the one a runner would bind.
fn address(store: &Store) -> String {
    listening(store).unwrap_or_else(webhook::configured_addr)
}

/// `create --json`'s and `webhook show --json`'s object.
pub(super) fn json(store: &Store, x: &Automation, with_secret: bool) -> Result<Value, Failure> {
    let addr = address(store);
    let mut v = json!({
        "url": webhook::url(&addr, &x.id),
        "address": addr,
        "listening": listening(store).is_some(),
        "signature_header": "X-Cmux-Signature-256",
        "delivery_headers": webhook::DELIVERY_HEADERS,
    });
    if with_secret && let Some(o) = v.as_object_mut() {
        o.insert("secret".into(), json!(store.webhook_secret(&x.id)?));
    }
    Ok(v)
}

/// After `create` (and in `webhook show`): the URL, the secret, how to sign, whether anyone listens.
pub(super) fn print(store: &Store, x: &Automation, with_secret: bool) -> Result<(), Failure> {
    let m = messages();
    let addr = address(store);
    println!("{}", m.local_hook_url.replace("{url}", &webhook::url(&addr, &x.id)));
    if with_secret {
        println!("{}", m.local_hook_secret.replace("{secret}", &store.webhook_secret(&x.id)?));
        println!("{}", m.local_hook_sign);
    }
    match listening(store) {
        Some(addr) => println!("{}", m.local_hook_listening.replace("{addr}", &addr)),
        None => println!("{}", m.local_hook_not_listening.replace("{addr}", &addr)),
    }
    Ok(())
}

/// `create`'s extra lines or JSON field, for a webhook trigger.
pub(super) fn after_create(
    store: &Store,
    x: &Automation,
    out: &Out,
    v: &mut Value,
) -> Result<(), Failure> {
    if !matches!(x.trigger, Trigger::Webhook { .. }) {
        return Ok(());
    }
    match out.mode {
        OutputMode::Json => {
            if let Some(o) = v.as_object_mut() {
                o.insert("webhook".into(), json(store, x, true)?);
            }
        }
        OutputMode::Quiet => {}
        _ => print(store, x, true)?,
    }
    Ok(())
}

/// `show`'s line for a webhook trigger: its URL.
pub(super) fn show_line(store: &Store, x: &Automation) {
    if matches!(x.trigger, Trigger::Webhook { .. }) {
        println!(
            "{}",
            messages().local_hook_url.replace("{url}", &webhook::url(&address(store), &x.id))
        );
    }
}

fn find_webhook(store: &Store, word: &str) -> Result<Automation, Failure> {
    let x = store.find(word)?;
    if matches!(x.trigger, Trigger::Webhook { .. }) {
        Ok(x)
    } else {
        usage(messages().local_hook_not_webhook.replace("{name}", &x.name))
    }
}

/// `automation webhook show|rotate|send AUTOMATION …`.
pub(super) fn run(verb: &str, rest: &[String], out: &Out) -> Outcome {
    match verb {
        "show" => {
            let a = Args::parse(rest, &[], &["secret"])?;
            let store = open_store()?;
            let x = find_webhook(&store, a.one_word("AUTOMATION")?)?;
            match out.mode {
                OutputMode::Json | OutputMode::JsonLines => {
                    out.value(&json(&store, &x, a.flag("secret"))?);
                }
                OutputMode::Quiet => {}
                OutputMode::Human => print(&store, &x, a.flag("secret"))?,
            }
            Ok(0)
        }
        "rotate" => {
            let a = Args::parse(rest, &[], &[])?;
            let store = open_store()?;
            let x = find_webhook(&store, a.one_word("AUTOMATION")?)?;
            let secret = store.rotate_webhook_secret(&x.id)?;
            match out.mode {
                OutputMode::Json | OutputMode::JsonLines => {
                    out.value(&json!({"id": x.id, "secret": secret}));
                }
                OutputMode::Quiet => {}
                OutputMode::Human => println!(
                    "{}",
                    messages()
                        .local_hook_rotated
                        .replace("{name}", &x.name)
                        .replace("{secret}", &secret)
                ),
            }
            Ok(0)
        }
        "send" => send(rest, out),
        other => usage(messages().unknown_verb.replace("{verb}", other)),
    }
}

/// `automation webhook send AUTOMATION [--body JSON | --body-file FILE|-] [--delivery ID]
/// [--header NAME=VALUE]`: a signed delivery to this machine's runner, as a sender would post it.
fn send(rest: &[String], out: &Out) -> Outcome {
    let a = Args::parse(rest, &["body", "body-file", "delivery", "header"], &[])?;
    let store = open_store()?;
    let x = find_webhook(&store, a.one_word("AUTOMATION")?)?;
    let body = match (a.value("body"), a.value("body-file")) {
        (Some(_), Some(_)) => {
            return usage(messages().unexpected_argument.replace("{value}", "--body-file"));
        }
        (Some(b), None) => b.as_bytes().to_vec(),
        (None, Some("-")) => {
            let mut buf = Vec::new();
            std::io::stdin()
                .take(webhook::MAX_BODY_BYTES as u64 + 1)
                .read_to_end(&mut buf)
                .map_err(|e| Failure::Usage(e.to_string()))?;
            buf
        }
        (None, Some(path)) => {
            std::fs::read(path).map_err(|e| Failure::Usage(format!("{path}: {e}")))?
        }
        (None, None) => b"{}".to_vec(),
    };
    let mut headers = Vec::new();
    if let Some(id) = a.value("delivery") {
        headers.push(("X-Cmux-Delivery".to_string(), id.to_string()));
    }
    for h in a.values_of("header") {
        let Some((name, value)) = h.split_once('=') else {
            return usage(messages().unexpected_argument.replace("{value}", h));
        };
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }
    let addr = address(&store);
    let secret = store.webhook_secret(&x.id)?;
    match webhook::send(&addr, &x.id, &secret, &body, &headers) {
        Ok((status, answer)) => {
            let outcome = answer.get("status").and_then(Value::as_str).unwrap_or("").to_string();
            match out.mode {
                OutputMode::Json | OutputMode::JsonLines => {
                    out.value(&json!({"id": x.id, "http_status": status, "answer": answer}));
                }
                OutputMode::Quiet => {}
                OutputMode::Human => println!(
                    "{}",
                    messages()
                        .local_hook_sent
                        .replace("{status}", &status.to_string())
                        .replace("{outcome}", &outcome)
                ),
            }
            Ok(if (200..300).contains(&status) { 0 } else { 1 })
        }
        Err(e) => {
            let text = messages()
                .local_hook_unreachable
                .replace("{addr}", &addr)
                .replace("{error}", &e.to_string());
            Ok(out.error(
                &json!({"code": "automation.webhook_unreachable", "message": text}),
                1,
                false,
            ))
        }
    }
}

/// The runner's listener: bound while an enabled automation has `--webhook`, closed once none
/// does, so a machine with none opens no port.
#[derive(Default)]
pub(super) struct Listener {
    server: Option<Server>,
    retry_at_ms: i64,
}

impl Listener {
    pub(super) fn reconcile(
        &mut self,
        store: &Store,
        automations: &[Automation],
        sink: &EventSender,
    ) {
        if !webhook::wanted(automations) {
            self.server = None;
            return;
        }
        if self.server.is_some() || now_ms() < self.retry_at_ms {
            return;
        }
        let addr = webhook::configured_addr();
        match Server::start(store.clone(), &addr, sink.clone()) {
            Ok(server) => self.server = Some(server),
            Err(e) => {
                self.retry_at_ms = now_ms() + RETRY_BIND.as_millis() as i64;
                eprintln!(
                    "{}",
                    messages()
                        .local_hook_listen_failed
                        .replace("{addr}", &addr)
                        .replace("{error}", &e.to_string())
                );
            }
        }
    }
}

#[cfg(test)]
#[path = "local_webhook_tests.rs"]
mod tests;
