//! One fuzz run: a daemon, the catalog, the report, and the per-case oracle
//! (typed reply, live daemon, unchanged topology after a refusal).

use std::collections::BTreeSet;
use std::sync::Arc;

use serde_json::{Value, json};

use super::catalog::Catalog;
use super::daemon::{Conn, Daemon, Outcome};
use super::generate::Context;
use super::oracle::{self, DEADLINE, Finding, Report, check_v2_reply, topology, v2_request};

/// Makes sure the session has two workspaces, each with a sink terminal.
pub fn seed_topology(daemon: &Daemon) {
    let mut conn = daemon.connect();
    for name in ["fuzz-a", "fuzz-b"] {
        let params = json!({
            "machine": "current", "session": "current", "name": name, "initial_content": "terminal",
            "argv": ["/bin/sh", "-c", "exec cat > /dev/null"], "cwd": daemon.dir.to_str().unwrap(),
        });
        let request = v2_request(name, "workspace.create", params, Some(format!("seed-{name}")));
        let _ = conn.call(&request, &json!(name), DEADLINE);
    }
}

pub struct Run {
    pub daemon: Daemon,
    pub report: Report,
    pub catalog: Arc<Catalog>,
    label: &'static str,
}

/// What one case asks of the oracle.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Expect {
    /// Any typed answer.
    Typed,
    /// A typed refusal: the request breaks the catalog's own descriptor.
    Refusal,
}

impl Run {
    pub fn new(label: &'static str, row: &'static str, seed: u64) -> Self {
        let daemon = Daemon::start(label);
        seed_topology(&daemon);
        Self { daemon, report: Report::new(row, seed), catalog: Arc::new(Catalog::load()), label }
    }

    /// The session's ids now; a session that lost every workspace to an
    /// earlier case (a close) gets the two seed workspaces again.
    pub fn context(&self) -> Context {
        let snapshot = oracle::snapshot(&self.daemon).unwrap_or(Value::Null);
        if snapshot["workspaces"].as_array().is_some_and(Vec::is_empty) {
            seed_topology(&self.daemon);
            let snapshot = oracle::snapshot(&self.daemon).unwrap_or(Value::Null);
            return Context::from_snapshot(&snapshot, self.daemon.dir.to_str().unwrap());
        }
        Context::from_snapshot(&snapshot, self.daemon.dir.to_str().unwrap())
    }

    pub fn topology(&self) -> Option<BTreeSet<String>> {
        oracle::snapshot(&self.daemon).map(|snapshot| topology(&snapshot))
    }

    pub fn finding(
        &mut self,
        class: &'static str,
        target: &str,
        case: &str,
        request: &str,
        detail: String,
    ) {
        self.report.add(Finding {
            class,
            target: target.to_string(),
            case: case.to_string(),
            request: request.chars().take(600).collect(),
            detail,
        });
    }

    /// A dead daemon is a crash finding; it is restarted so the run goes on.
    pub fn check_alive(&mut self, target: &str, case: &str, request: &str) {
        if let Some(exit) = self.daemon.exit() {
            let detail =
                format!("daemon exited ({exit}); stderr tail:\n{}", self.daemon.stderr_tail());
            self.finding("crash", target, case, request, detail);
            self.daemon = Daemon::start(self.label);
            seed_topology(&self.daemon);
        }
    }

    /// The topology diff from `before` to now, if any.
    pub fn diff_since(&self, before: Option<&BTreeSet<String>>) -> Option<String> {
        let (Some(before), Some(after)) = (before, self.topology()) else { return None };
        if *before == after {
            return None;
        }
        let added: Vec<_> = after.difference(before).take(4).cloned().collect();
        let removed: Vec<_> = before.difference(&after).take(4).cloned().collect();
        Some(format!("+{added:?} -{removed:?}"))
    }

    /// A refusal (or no answer) must leave what a person sees unchanged. A
    /// change is reported only when it happens again: after the session
    /// settles, `resend` sends the same request once more (true when it is
    /// refused again), so a late effect of an earlier accepted request is not
    /// taken for this one's.
    pub fn check_unchanged(
        &mut self,
        before: Option<BTreeSet<String>>,
        target: &str,
        case: &str,
        request: &str,
        why: &str,
        resend: &mut dyn FnMut(&mut Run) -> bool,
    ) {
        let Some(first) = self.diff_since(before.as_ref()) else { return };
        std::thread::sleep(std::time::Duration::from_millis(400));
        let settled = self.topology();
        if !resend(self) {
            return;
        }
        if let Some(second) = self.diff_since(settled.as_ref()) {
            let detail = format!("{why} but the topology changed, twice: {first}; again {second}");
            self.finding("silent-change", target, case, request, detail);
        }
    }

    /// `check_unchanged` for a request sent as one JSON line on a new
    /// connection: refused again means a reply with `ok: false`.
    pub fn check_unchanged_line(
        &mut self,
        before: Option<BTreeSet<String>>,
        target: &str,
        case: &str,
        request: &Value,
        why: &str,
    ) {
        let mut again = request.clone();
        if let Some(key) = again.get("idempotency_key").and_then(Value::as_str) {
            again["idempotency_key"] = json!(format!("{key}-again"));
        }
        let mut resend = |run: &mut Run| match Conn::open(&run.daemon.socket) {
            Ok(mut conn) => !matches!(
                conn.call(&again, &again["id"], DEADLINE),
                Outcome::Reply(ref reply) if reply["ok"] == true
            ),
            Err(_) => false,
        };
        let shown = request.to_string();
        self.check_unchanged(before, target, case, &shown, why, &mut resend);
    }

    /// One v2 request on a fresh connection, with the whole oracle.
    pub fn v2_case(&mut self, target: &str, case: &str, request: Value, expect: Expect) -> Outcome {
        self.report.cases += 1;
        let before = self.topology();
        let outcome = match Conn::open(&self.daemon.socket) {
            Ok(mut conn) => conn.call(&request, &request["id"], DEADLINE),
            Err(_) => Outcome::Closed,
        };
        let verdict =
            check_v2_reply(&self.catalog, &mut self.report, target, case, &request, &outcome);
        let shown = request.to_string();
        self.check_alive(target, case, &shown);
        if verdict == Some(true) && expect == Expect::Refusal {
            let detail =
                "a request that breaks the catalog's own descriptor was accepted".to_string();
            self.finding("accepts-invalid", target, case, &shown, detail);
        }
        let code = match &outcome {
            Outcome::Reply(reply) => {
                reply["error"]["code"].as_str().unwrap_or_default().to_string()
            }
            _ => String::new(),
        };
        // An indeterminate mutation may have applied: no claim either way.
        if verdict != Some(true) && code != "mutation.indeterminate" {
            self.check_unchanged_line(
                before,
                target,
                case,
                &request,
                &format!("refused (code {code:?})"),
            );
        }
        outcome
    }
}
