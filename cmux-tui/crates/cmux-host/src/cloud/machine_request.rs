//! `cmux machine request` on a Cloud machine (sans I/O): the agent socket line
//! `{"machine_request": {"vcpu", "mem_gib"?, "fanout"?, "kind"?, "for", "until"?}}`, the op it
//! becomes (`cloud.vm.machine.request` as this machine's `vm` install, the machine filled in
//! here, never by the caller) and the one reply line.
//!
//! Leo, 2026-11-25: "but what if we want even more than the 32vcpu machines? how can an agent
//! know/ask for more capacity?" and "when they're on the vm that is". cmuxterm-hq RFD draft
//! `docs/rfd/drafts/agent-work-placement.md`, sections 9 and 13. The platform answers at once
//! (cmux-platform `MachineRequest.ts`): fits, grow, over_plan, fanout, unavailable or refused,
//! with the words the agent reads back; no person's token is on the machine.

use serde_json::{Map, Value, json};

use super::github::refusal;
use super::sender::{Answer, OpRequest};

/// The socket line's key.
pub const REQUEST_KEY: &str = "machine_request";
/// The platform op.
pub const OP: &str = "cloud.vm.machine.request";

/// One checked ask: the op's params without `machine`.
#[derive(Clone, Debug, PartialEq)]
pub struct MachineAsk(pub Map<String, Value>);

fn int_in(value: &Value, name: &str, lo: u64, hi: u64) -> Result<Option<u64>, String> {
    match value.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_u64().filter(|n| (lo..=hi).contains(n)) {
            Some(n) => Ok(Some(n)),
            None => Err(format!("machine_request {name} must be a whole number from {lo} to {hi}")),
        },
    }
}

fn text(value: &Value, name: &str, max: usize) -> Result<Option<String>, String> {
    match value.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.trim().is_empty() && s.chars().count() <= max => {
            Ok(Some(s.trim().to_owned()))
        }
        Some(_) => Err(format!("machine_request {name} must be text of 1 to {max} characters")),
    }
}

/// The `machine_request` object of a socket line, checked as the op's schema does.
pub fn check_ask(value: &Value) -> Result<MachineAsk, String> {
    if !value.is_object() {
        return Err("machine_request must be a JSON object".to_owned());
    }
    let mut out = Map::new();
    let vcpu = int_in(value, "vcpu", 1, 4096)?.ok_or("machine_request needs vcpu")?;
    out.insert("vcpu".into(), json!(vcpu));
    if let Some(mem) = int_in(value, "mem_gib", 1, 16384)? {
        out.insert("mem_gib".into(), json!(mem));
    }
    if let Some(k) = int_in(value, "fanout", 1, 64)? {
        out.insert("fanout".into(), json!(k));
    }
    if let Some(kind) = text(value, "kind", 8)? {
        if !["linux", "mac", "gpu"].contains(&kind.as_str()) {
            return Err("machine_request kind must be linux, mac or gpu".to_owned());
        }
        out.insert("kind".into(), json!(kind));
    }
    let why =
        text(value, "for", 500)?.ok_or("machine_request needs for: what the capacity is for")?;
    out.insert("for".into(), json!(why));
    if let Some(until) = text(value, "until", 32)? {
        out.insert("until".into(), json!(until));
    }
    Ok(MachineAsk(out))
}

/// The op for `machine`, the machine this install speaks for.
pub fn request(ask: &MachineAsk, machine: &str) -> OpRequest {
    let mut params = ask.0.clone();
    params.insert("machine".into(), json!(machine));
    OpRequest { op: OP, params: Value::Object(params), reason: "machine.request".to_owned() }
}

/// The reply line for the platform's answer: `{ok: true, outcome, message, machine, ...}`, or a
/// refusal with the platform's code.
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } if body.get("ok") == Some(&json!(true)) => {
            match body.get("value") {
                Some(Value::Object(value))
                    if value.get("outcome").is_some_and(Value::is_string) =>
                {
                    let mut reply = value.clone();
                    reply.insert("ok".into(), json!(true));
                    Value::Object(reply)
                }
                _ => refusal("machine.bad_answer", "cmux did not answer the machine request."),
            }
        }
        Answer::Http { body, .. }
            if body.get("ok") == Some(&json!(false))
                && body.pointer("/error/code").is_some_and(Value::is_string) =>
        {
            let code = body.pointer("/error/code").and_then(Value::as_str).unwrap_or_default();
            let message = body
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("cmux refused the machine request.");
            if code == "cloud.op.unknown" || code == "op.unknown" {
                return refusal(
                    "machine.unavailable",
                    "cmux Cloud here does not take machine requests yet.",
                );
            }
            refusal(code, message)
        }
        Answer::Http { status: 401 | 403, .. } => {
            refusal("auth.refused", "cmux refused this machine's request.")
        }
        Answer::Http { status: 429, .. } => {
            refusal("rate_limited", "cmux is rate limited. Wait a moment, then retry.")
        }
        Answer::Http { .. } => {
            refusal("machine.unavailable", "cmux did not answer the machine request.")
        }
        Answer::Transport => refusal(
            "machine.unreachable",
            "Check this machine's connection and retry the machine request.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_and_fills_the_machine() {
        let ask = check_ask(&json!({"vcpu": 64, "for": "cargo build", "until": "2h"})).unwrap();
        let op = request(&ask, "vm_1");
        assert_eq!(op.op, OP);
        assert_eq!(
            op.params,
            json!({"vcpu": 64, "for": "cargo build", "until": "2h", "machine": "vm_1"})
        );
        // A caller naming a machine does not choose it.
        let ask = check_ask(&json!({"vcpu": 4, "for": "x", "machine": "vm_other"})).unwrap();
        assert_eq!(request(&ask, "vm_1").params["machine"], "vm_1");
    }

    #[test]
    fn refuses_bad_asks() {
        assert!(check_ask(&json!({"for": "x"})).is_err());
        assert!(check_ask(&json!({"vcpu": 0, "for": "x"})).is_err());
        assert!(check_ask(&json!({"vcpu": 4})).is_err());
        assert!(check_ask(&json!({"vcpu": 4, "for": "x", "kind": "tpu"})).is_err());
        assert!(check_ask(&json!({"vcpu": 4, "for": "x", "fanout": 65})).is_err());
    }

    #[test]
    fn replies() {
        let body = json!({"ok": true, "value": {"outcome": "grow", "message": "Growing", "machine": "vm_1"}});
        let reply = reply_for(&Answer::Http { status: 200, body });
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["outcome"], "grow");
        let body =
            json!({"ok": false, "error": {"code": "cloud.spend_cap.reached", "message": "cap"}});
        let reply = reply_for(&Answer::Http { status: 402, body });
        assert_eq!(reply["error"]["code"], "cloud.spend_cap.reached");
        assert_eq!(reply_for(&Answer::Transport)["error"]["code"], "machine.unreachable");
    }
}
