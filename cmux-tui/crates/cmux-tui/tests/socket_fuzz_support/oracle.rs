//! The oracle: what each reply must be, the topology a refused request must
//! leave unchanged, and the findings report.

use std::collections::BTreeSet;
use std::time::Duration;

use serde_json::{Value, json};

use super::catalog::Catalog;
use super::daemon::{Conn, Daemon, Outcome};

pub const DEADLINE: Duration = Duration::from_secs(5);

/// A comparable projection of the session: every resource id with the names
/// and parents a person sees. Revisions, clients and timestamps are left out
/// (they move on their own).
pub fn topology(snapshot: &Value) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for array in
        ["workspaces", "screens", "panes", "tabs", "terminals", "browsers", "notifications"]
    {
        for item in snapshot[array].as_array().into_iter().flatten() {
            let id = item["id"].as_str().unwrap_or("?");
            let mut row = format!("{array}:{id}");
            // No title: a program changes it on its own.
            for key in ["name", "workspace_id", "screen_id", "pane_id", "tab_id", "pinned", "kind"]
            {
                if let Some(value) = item.get(key) {
                    if !value.is_null() {
                        row.push_str(&format!(" {key}={value}"));
                    }
                }
            }
            out.insert(row);
        }
    }
    out
}

pub fn v2_request(
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<String>,
) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": id,
        "operation": operation, "params": params,
    });
    if let Some(key) = idempotency_key {
        request["idempotency_key"] = json!(key);
    }
    request
}

/// `session.snapshot` on a fresh connection; `None` when the daemon gives
/// none before the deadline.
pub fn snapshot(daemon: &Daemon) -> Option<Value> {
    let mut conn = Conn::open(&daemon.socket).ok()?;
    let id = json!("snap");
    let request = v2_request(
        "snap",
        "session.snapshot",
        json!({"machine": "current", "session": "current"}),
        None,
    );
    match conn.call(&request, &id, DEADLINE) {
        Outcome::Reply(reply) if reply["ok"] == true => Some(reply["result"].clone()),
        _ => None,
    }
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub class: &'static str,
    pub target: String,
    pub case: String,
    pub request: String,
    pub detail: String,
}

impl Finding {
    pub fn json(&self, seed: u64) -> Value {
        json!({"class": self.class, "target": self.target, "case": self.case,
               "request": self.request, "detail": self.detail, "seed": seed.to_string()})
    }
}

/// The run's report: counts per target and the findings, printed as lines
/// the verdict script reads (`FUZZ-SUMMARY`, `FUZZ-FINDING`, `FUZZ-VERDICT`).
pub struct Report {
    pub row: &'static str,
    pub seed: u64,
    pub targets: BTreeSet<String>,
    pub cases: usize,
    pub replies_ok: usize,
    pub replies_error: usize,
    pub findings: Vec<Finding>,
    pub budget_stop: bool,
}

impl Report {
    pub fn new(row: &'static str, seed: u64) -> Self {
        Self {
            row,
            seed,
            targets: BTreeSet::new(),
            cases: 0,
            replies_ok: 0,
            replies_error: 0,
            findings: Vec::new(),
            budget_stop: false,
        }
    }

    pub fn add(&mut self, finding: Finding) {
        eprintln!("FUZZ-FINDING {}", finding.json(self.seed));
        self.findings.push(finding);
    }

    /// Prints the summary and fails the test when there is a finding.
    pub fn finish(self) {
        let mut classes = std::collections::BTreeMap::<&str, usize>::new();
        for finding in &self.findings {
            *classes.entry(finding.class).or_default() += 1;
        }
        let summary = json!({
            "row": self.row, "seed": self.seed.to_string(), "targets": self.targets.len(),
            "cases": self.cases, "replies_ok": self.replies_ok, "replies_error": self.replies_error,
            "findings": self.findings.len(), "classes": classes, "budget_stop": self.budget_stop,
        });
        eprintln!("FUZZ-SUMMARY {summary}");
        if let Ok(path) = std::env::var("CMUX_FUZZ_REPORT_DIR") {
            let _ = std::fs::create_dir_all(&path);
            let lines: String =
                self.findings.iter().map(|f| format!("{}\n", f.json(self.seed))).collect();
            let _ = std::fs::write(format!("{path}/{}-findings.jsonl", self.row), lines);
            let _ =
                std::fs::write(format!("{path}/{}-summary.json", self.row), summary.to_string());
        }
        let verdict = if self.findings.is_empty() {
            "PASS".to_string()
        } else {
            format!("FAIL {} findings", self.findings.len())
        };
        eprintln!("FUZZ-VERDICT {} {verdict}", self.row);
        assert!(
            self.findings.is_empty(),
            "{} fuzz findings (see FUZZ-FINDING lines; seed {})",
            self.findings.len(),
            self.seed
        );
    }
}

/// Checks one v2 reply: a JSON object with `ok`, and on `ok: false` an error
/// with a catalog code. Returns `Some(true)` for a success, `Some(false)` for
/// a typed refusal, `None` when the reply broke the contract (reported).
pub fn check_v2_reply(
    catalog: &Catalog,
    report: &mut Report,
    target: &str,
    case: &str,
    request: &Value,
    outcome: &Outcome,
) -> Option<bool> {
    let short = |value: &Value| {
        let text = value.to_string();
        if text.len() > 600 {
            format!("{}...({} bytes)", text.chars().take(600).collect::<String>(), text.len())
        } else {
            text
        }
    };
    let finding = |class, detail: String| Finding {
        class,
        target: target.to_string(),
        case: case.to_string(),
        request: short(request),
        detail,
    };
    match outcome {
        Outcome::Timeout => {
            report.add(finding("hang", format!("no reply in {DEADLINE:?}")));
            None
        }
        Outcome::Closed => {
            report.add(finding("closed", "the daemon closed the connection with no reply".into()));
            None
        }
        Outcome::NotJson(line) => {
            report.add(finding(
                "untyped",
                format!("reply is not JSON: {}", line.chars().take(300).collect::<String>()),
            ));
            None
        }
        Outcome::Reply(reply) => match reply["ok"].as_bool() {
            Some(true) => {
                report.replies_ok += 1;
                Some(true)
            }
            Some(false) => {
                report.replies_error += 1;
                let code = reply["error"]["code"].as_str().unwrap_or_default();
                if !catalog.is_error_code(code) {
                    report.add(finding(
                        "untyped",
                        format!("error without a catalog code: {}", short(reply)),
                    ));
                }
                Some(false)
            }
            None => {
                report.add(finding("untyped", format!("reply has no ok: {}", short(reply))));
                None
            }
        },
    }
}
