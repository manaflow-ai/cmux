//! Checkpoint requests that once trapped the daemon: a list with `limit` 0,
//! a mutation that reaches its handler without a key, and an operation the
//! router sends here by mistake.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_process::Command;
use serde_json::{Value, json};

use crate::resource_router::{ParsedResourceRequest, parse_resource_request};
use crate::{Mux, SurfaceOptions};

/// A durable session (checkpoints need a state directory) and a repository
/// with one commit, both under one temporary directory.
struct Fixture {
    root: PathBuf,
    repo: PathBuf,
    mux: Arc<Mux>,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-checkpoint-{name}-{}", crate::workspace_registry::new_uuid_v4()));
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "--quiet"]);
        std::fs::write(repo.join("README.md"), "readme\n").unwrap();
        git(&repo, &["add", "README.md"]);
        git(&repo, &["commit", "--quiet", "-m", "initial"]);
        let state = root.join("state");
        let mux = Mux::open_persistent(name, SurfaceOptions::default(), &state).unwrap();
        Self { root, repo, mux }
    }

    /// `operation` on this repository, as the catalog parses it.
    fn request(
        &self,
        operation: &str,
        mut params: Value,
        key: Option<&str>,
    ) -> ParsedResourceRequest {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        params["path"] = json!(self.repo.to_string_lossy());
        let mut envelope = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": format!("{operation}-test"),
            "operation": operation,
            "params": params,
        });
        if let Some(key) = key {
            envelope["idempotency_key"] = json!(key);
        }
        parse_resource_request(&envelope.to_string()).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.mux.shutdown();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn git(repo: &Path, arguments: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "user.name=cmux", "-c", "user.email=cmux@example.invalid"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?} failed");
}

#[test]
fn list_with_limit_zero_returns_an_empty_page_without_a_cursor() {
    let fixture = Fixture::new("list-limit-zero");
    let create = fixture.request("git.checkpoint.create", json!({}), Some("create-1"));
    super::dispatch(&fixture.mux, create).unwrap();

    let one = fixture.request("git.checkpoint.list", json!({"limit": 1}), None);
    let one = super::dispatch(&fixture.mux, one).unwrap();
    assert_eq!(one["checkpoints"].as_array().map(Vec::len), Some(1), "{one}");

    // The catalog refuses `limit` 0 from a client; the handler must not trap
    // on it either when a caller skips that check.
    let mut envelope = fixture.request("git.checkpoint.list", json!({}), None).envelope;
    envelope.params["limit"] = json!(0);
    let refused = crate::resource_router::validate_resource_envelope(
        envelope,
        crate::workspace_registry::Actor::local_user(),
    )
    .err()
    .unwrap();
    assert_eq!(refused.code, "validation.invalid", "{refused:?}");
    let mut empty = fixture.request("git.checkpoint.list", json!({}), None);
    empty.fields.insert("limit".into(), json!(0));
    let empty = super::dispatch(&fixture.mux, empty).unwrap();
    assert_eq!(empty["checkpoints"], json!([]), "{empty}");
    assert_eq!(empty["next_cursor"], Value::Null, "{empty}");
}

#[test]
fn mutation_without_an_idempotency_key_is_a_validation_error() {
    let fixture = Fixture::new("mutation-no-key");
    let checkpoint_id = format!("ckpt_{}", "0".repeat(32));
    for (operation, params) in [
        ("git.checkpoint.create", json!({})),
        (
            "git.checkpoint.pin",
            json!({"checkpoint_id": checkpoint_id, "pin_id": "p", "reason": "r"}),
        ),
    ] {
        let mut request = fixture.request(operation, params, Some("no-key"));
        request.envelope.idempotency_key = None;
        let error = super::dispatch(&fixture.mux, request).unwrap_err();
        assert_eq!(error.code, "validation.invalid", "{operation}: {error:?}");
        assert_eq!(error.details["field"], "idempotency_key", "{operation}: {error:?}");
    }
}

#[test]
fn an_operation_checkpoint_does_not_serve_is_an_internal_operation_failure() {
    let fixture = Fixture::new("checkpoint-unrouted");
    let status = fixture.request("git.status", json!({}), None);
    let error = super::dispatch(&fixture.mux, status).unwrap_err();
    assert_eq!(error.code, "operation.failed", "{error:?}");
    assert_eq!(error.details["operation"], "git.status", "{error:?}");
    assert_eq!(error.details["reason"], "internal", "{error:?}");
}
