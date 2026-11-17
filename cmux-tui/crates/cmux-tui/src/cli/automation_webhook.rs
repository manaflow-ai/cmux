//! `cmux automation create NAME --webhook --on cloud --from MACHINE --repo OWNER/REPO --prompt TEXT`
//! (cmuxterm-hq docs/rfd/0001-webhooks.md, section 5). Skeleton: the tests come first.

use std::time::Duration;

use serde_json::Value;

use super::{Failure, messages};
use crate::cli::{Platform, PlatformCallError as CallError};

pub(super) const TRIGGERS_PATH: &str = "/v1/triggers";

pub(super) fn wants(_args: &[String]) -> bool {
    false
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Plan {
    pub name: String,
    pub slug: String,
    pub from: String,
    pub repository: String,
    pub prompt: String,
    pub cwd: String,
    pub harness: String,
    pub events: Vec<&'static str>,
    pub cooldown_seconds: u64,
    pub max_runs: u64,
    pub platform: Option<String>,
}

impl Plan {
    fn workspace(&self) -> String {
        todo!()
    }
    fn session(&self) -> String {
        todo!()
    }
    fn client_key(&self) -> String {
        todo!()
    }
}

fn plan(_args: &[String]) -> Result<Plan, Failure> {
    todo!()
}

fn slug(_name: &str) -> String {
    todo!()
}

fn consent_line(_from: &str) -> String {
    let _ = messages();
    todo!()
}

fn fork_path(_plan: &Plan) -> String {
    todo!()
}
fn fork_body(_plan: &Plan) -> Value {
    todo!()
}
fn bind_path(_plan: &Plan) -> String {
    todo!()
}
fn bind_body(_plan: &Plan, _fork: &str) -> Value {
    todo!()
}
fn trigger_body(_plan: &Plan, _fork: &str) -> Value {
    todo!()
}

struct Registered {
    machine: String,
    trigger: String,
    secret: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Fork,
    Bind,
    Trigger,
}

enum Why {
    Call(CallError),
    Bound(String),
}

struct Stopped {
    step: Step,
    machine: Option<String>,
    why: Why,
}

fn register(_platform: &Platform, _plan: &Plan) -> Result<Registered, Stopped> {
    let _ = Duration::ZERO;
    todo!()
}

fn created(_plan: &Plan, _origin: &str, _done: &Registered) -> Value {
    todo!()
}

fn human_lines(_plan: &Plan, _created: &Value) -> Vec<String> {
    todo!()
}

fn quiet_lines(_created: &Value) -> Vec<String> {
    todo!()
}

fn stopped_error(_plan: &Plan, _stop: &Stopped) -> (Value, i32, bool) {
    todo!()
}

fn trigger_id(_word: &str) -> Result<&str, Failure> {
    todo!()
}

#[cfg(test)]
#[path = "automation_webhook_tests.rs"]
mod tests;
