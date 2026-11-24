//! `cmux computer-use setup [--dry-run] [--no-window] [--json]`: the person's
//! command for Computer Use's setup, the same steps as Set Up Computer Use in
//! the app.
//!
//! It runs `cmux setup computer-use` (which turns Computer Use on after the
//! person allows it in cmux, and names the macOS grant still missing). While a
//! grant is missing it opens Set Up Computer Use in the app
//! (`palette.computerUse.setup`), which walks through each grant in order, and
//! says which app to turn on in which System Settings list: the grants belong
//! to the helper app ("cmux NIGHTLY Helper"), not to cmux. Once both are in, it
//! runs a quick test: the doctor's live checks (the worker answers, capture,
//! accessibility and input are granted, the displays are found). Exit 0 only
//! when Computer Use is ready and the test passed.

use serde_json::{Value, json};

use super::GlobalArgs;
use super::doctor;
use crate::cli::OutputMode;
use cmux_json::JsonSet as _;

/// The app action behind Set Up Computer Use.
const SETUP_ACTION: &str = "palette.computerUse.setup";

pub(super) fn run(global: &GlobalArgs, dry_run: bool, window: bool, json_flag: bool) -> i32 {
    let mut report = match super::super::setup::computer_use_report(global, dry_run) {
        Ok(report) => report,
        Err((code, message)) => {
            eprintln!("cmux computer-use setup: {message}");
            return code;
        }
    };
    let applies = report.get("state").and_then(Value::as_str) != Some("not_applicable");
    if !dry_run && window && opens_window(&report) {
        report.set("window", open_window(global));
    }
    let ready = is_ready(&report);
    let mut test_ok = true;
    if ready && !dry_run {
        let (live, checks, ok) = doctor::read(global, None);
        test_ok = ok;
        report.set(
            "test",
            json!({
                "ok": ok,
                "checks": checks.iter().map(|c| json!({
                    "name": c.name, "ok": c.ok, "detail": c.detail, "fix": c.fix,
                })).collect::<Vec<_>>(),
                "displays": live.get("displays").cloned().unwrap_or(Value::Null),
            }),
        );
    }
    match (json_flag, global.output) {
        (true, _) | (_, OutputMode::Json | OutputMode::JsonLines) => println!("{report}"),
        (_, OutputMode::Quiet) => {}
        (_, OutputMode::Human) => print!("{}", human(&report)),
    }
    // Off macOS there is nothing to set up, as `cmux setup computer-use` says.
    i32::from(applies && !(ready && test_ok))
}

/// Whether the person still has a macOS grant to give: the window walks them through it.
pub(super) fn opens_window(report: &Value) -> bool {
    report["state"] == "needs_user" && report.pointer("/user_action/kind") == Some(&json!("grant"))
}

/// Computer Use is on and both grants are in.
pub(super) fn is_ready(report: &Value) -> bool {
    matches!(report["state"].as_str(), Some("ok" | "changed"))
        && report.pointer("/after/phase").and_then(Value::as_str) == Some("ready")
}

/// Shows Set Up Computer Use in the app: "opened", or the app's refusal.
fn open_window(global: &GlobalArgs) -> Value {
    let params = json!({
        "action": SETUP_ACTION,
        "wait": true,
        "origin": super::super::app::action_origin(),
    });
    match super::super::mcp::agent_app(
        global,
        "action.run",
        params,
        super::super::app::waiting_run_timeout(SETUP_ACTION),
        None,
    ) {
        Ok(_) => json!("opened"),
        Err(error) => json!({"error": error}),
    }
}

/// What the person reads: where things stand and the one thing to do next.
pub(super) fn human(report: &Value) -> String {
    let mut out = String::new();
    if report["state"] == "not_applicable" {
        out.push_str(
            "Computer Use setup is for the cmux app on macOS; there is nothing to set up here.\n",
        );
        return out;
    }
    let status = if report["after"].is_null() { &report["before"] } else { &report["after"] };
    let helper = status["helper"].as_str().filter(|name| !name.trim().is_empty());
    if let Some(test) = report.get("test") {
        if test["ok"] == true {
            out.push_str("Computer Use is ready.\n");
            if let Some(helper) = helper {
                out.push_str(&format!(
                    "{helper} has Accessibility and Screen Recording: agents can see and use your apps when you ask them to.\n"
                ));
            }
            out.push_str("Quick test passed:\n");
        } else {
            out.push_str("Computer Use is on, but the quick test failed:\n");
        }
        for check in test["checks"].as_array().into_iter().flatten() {
            let mark = if check["ok"] == true { "ok  " } else { "FAIL" };
            out.push_str(&format!("  {mark} {}\n", check["detail"].as_str().unwrap_or_default()));
            if let Some(fix) = check["fix"].as_str() {
                out.push_str(&format!("       fix: {fix}\n"));
            }
        }
        return out;
    }
    if report["state"] == "planned" {
        out.push_str("Computer Use is off. Without --dry-run, this turns it on after you allow it in cmux.\n");
        return out;
    }
    if report["window"] == "opened" {
        out.push_str("Set Up Computer Use is open in cmux.\n");
    } else if let Some(error) = report["window"].get("error") {
        let why = error["message"].as_str().or(error["code"].as_str()).unwrap_or("no answer");
        out.push_str(&format!(
            "cmux did not open Set Up Computer Use ({why}); open it from the command palette.\n"
        ));
    }
    if let Some(action) = report.get("user_action").filter(|action| !action.is_null()) {
        if let Some(text) = action["text"].as_str() {
            out.push_str(text);
            out.push('\n');
        }
        if action["kind"] == "grant" {
            out.push_str(
                "macOS asks for your password or Touch ID. If it offers Quit & Reopen, choose Later: \
                 cmux restarts the helper for you.\n",
            );
        }
    } else if report["state"] == "ok" || report["state"] == "changed" {
        out.push_str("Computer Use is ready.\n");
    }
    out
}

#[cfg(test)]
#[path = "computer_use_setup_tests.rs"]
mod tests;
