//! One request: parse its params, name the paths it touches, ask the local
//! policy, then run it. The approval round trip (mac profile) is the
//! `approve` callback: it sends the question to the Cloud and waits.

use super::agent::{Agents, EventSink};
use super::config::HandConfig;
use super::policy::{Decision, decide, resolve};
use super::{HandError, exec, fsops, patch};
use serde_json::{Value, json};
use std::future::Future;
use std::path::{Path, PathBuf};

fn s<'a>(p: &'a Value, k: &str) -> Result<&'a str, HandError> {
    p.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| HandError::new("request.invalid", format!("{k} (string) is required")))
}
fn opt_s<'a>(p: &'a Value, k: &str) -> Option<&'a str> {
    p.get(k).and_then(Value::as_str)
}
fn opt_u(p: &Value, k: &str) -> Option<u64> {
    p.get(k).and_then(Value::as_u64)
}

pub struct Ctx<'a> {
    pub cfg: &'a HandConfig,
    pub agents: &'a Agents,
    pub sink: EventSink,
}

fn cwd_of(p: &Value) -> Result<Option<PathBuf>, HandError> {
    opt_s(p, "cwd")
        .map(|c| resolve(c, None).map_err(|m| HandError::new("request.invalid", m)))
        .transpose()
}

fn path_of(p: &Value, key: &str, cwd: Option<&Path>) -> Result<PathBuf, HandError> {
    resolve(s(p, key)?, cwd).map_err(|m| HandError::new("request.invalid", m))
}

/// Runs `action` after the policy allows it. `approve(summary)` asks the
/// owner and resolves to their answer.
pub async fn handle<F, Fut>(
    ctx: &Ctx<'_>,
    action: &str,
    p: &Value,
    approve: F,
) -> Result<Value, HandError>
where
    F: FnOnce(Value) -> Fut,
    Fut: Future<Output = Result<bool, HandError>>,
{
    handle_with_consent(ctx, action, p, approve, || {
        crate::cli::cloud_join::require_joined_consent("control")
            .map_err(|_| HandError::new("consent_required", "local control consent is required"))
    })
    .await
}

async fn handle_with_consent<F, Fut, C>(
    ctx: &Ctx<'_>,
    action: &str,
    p: &Value,
    approve: F,
    consent: C,
) -> Result<Value, HandError>
where
    F: FnOnce(Value) -> Fut,
    Fut: Future<Output = Result<bool, HandError>>,
    C: Fn() -> Result<(), HandError>,
{
    consent()?;
    let cwd = cwd_of(p)?;
    let cwd_ref = cwd.as_deref();
    // The paths each action touches; the policy sees all of them.
    let (paths, patch_files): (Vec<PathBuf>, Option<Vec<Planned>>) = match action {
        "fs.read" | "fs.write" | "fs.edit" | "fs.list" => {
            (vec![path_of(p, "path", cwd_ref)?], None)
        }
        "fs.glob" | "fs.grep" => (vec![path_of(p, "root", cwd_ref)?], None),
        "fs.patch" => {
            let base = cwd
                .clone()
                .ok_or_else(|| HandError::new("request.invalid", "fs.patch needs cwd"))?;
            let files = patch::parse(s(p, "patch")?)?;
            let res = |t: Option<PathBuf>| {
                t.map(|t| {
                    resolve(&t.to_string_lossy(), None)
                        .map_err(|m| HandError::new("request.invalid", m))
                })
                .transpose()
            };
            let mut planned = Vec::new();
            for f in files {
                let (old, new) = patch::file_paths(&f, &base);
                planned.push((res(old)?, res(new)?, f));
            }
            let targets =
                planned.iter().flat_map(|(o, n, _)| [o.clone(), n.clone()]).flatten().collect();
            (targets, Some(planned))
        }
        // No cwd: the hand's default work folder (config.rs).
        "exec" | "agent.start" => {
            (vec![cwd.clone().unwrap_or_else(super::config::default_workdir)], None)
        }
        "agent.send" | "agent.cancel" | "agent.events" | "agent.deny" | "agent.stop" => {
            (vec![ctx.agents.cwd_of(s(p, "session")?)?], None)
        }
        other => {
            return Err(HandError::new(
                "request.unknown_action",
                format!("unknown action {other}"),
            ));
        }
    };
    let argv: Option<Vec<String>> = (action == "exec")
        .then(|| {
            p.get("argv")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect())
        })
        .flatten();
    match decide(ctx.cfg, action, &paths, opt_s(p, "_level"), opt_s(p, "_verdict"), argv.as_deref())
    {
        Decision::Allow => {}
        Decision::Deny(why) => return Err(HandError::new("policy.denied", why)),
        Decision::Ask => {
            let summary = json!({ "action": action, "paths": paths, "argv": p.get("argv"), "harness": p.get("harness"), "prompt": p.get("prompt") });
            if !approve(summary).await? {
                return Err(HandError::new(
                    "policy.owner_denied",
                    "the owner did not approve this request",
                ));
            }
        }
    }
    // Approval may have suspended this request for minutes. A later answer
    // authorizes this action, never a grant revoked while the owner was away.
    consent()?;
    let path = paths.first().cloned().unwrap_or_default();
    match action {
        "fs.read" => fsops::read(&path, opt_u(p, "start_line"), opt_u(p, "end_line")),
        "fs.write" => fsops::write(&path, s(p, "text")?, opt_s(p, "expect_sha256")),
        "fs.edit" => {
            let edits = p
                .get("edits")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    HandError::new("request.invalid", "edits (array of {old, new}) is required")
                })?
                .iter()
                .map(|e| Ok((s(e, "old")?.to_owned(), s(e, "new")?.to_owned())))
                .collect::<Result<Vec<_>, HandError>>()?;
            fsops::edit(&path, &edits, s(p, "expect_sha256")?)
        }
        "fs.list" => fsops::list(&path),
        // A search walks folders: off the async workers.
        "fs.glob" | "fs.grep" => {
            let pattern = s(p, "pattern")?.to_owned();
            let only = opt_s(p, "glob").map(str::to_owned);
            let limit = opt_u(p, "limit").map(|n| n as usize);
            let grep = action == "fs.grep";
            tokio::task::spawn_blocking(move || {
                if grep {
                    fsops::grep(&path, &pattern, only.as_deref(), limit)
                } else {
                    fsops::glob(&path, &pattern, limit)
                }
            })
            .await
            .map_err(|e| HandError::new("fs.search_failed", e.to_string()))?
        }
        "fs.patch" => apply_patch(patch_files.unwrap_or_default()),
        "exec" => {
            let argv = p
                .get("argv")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    HandError::new("request.invalid", "argv (array of strings) is required")
                })?
                .iter()
                .map(|a| {
                    a.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| HandError::new("request.invalid", "argv holds only strings"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            exec::run(&argv, &path, opt_u(p, "timeout_ms")).await
        }
        "agent.start" => {
            // A missing work folder is made (its path passed the policy above, so it is inside the
            // hand's roots and not one of its own files).
            if !path.exists() {
                std::fs::create_dir_all(&path).map_err(|e| {
                    HandError::new("agent.bad_cwd", format!("cannot make {}: {e}", path.display()))
                })?;
            }
            let model_route = p
                .get("model_route")
                .filter(|v| !v.is_null())
                .map(super::gateway::parse)
                .transpose()?;
            ctx.agents
                .start(
                    &ctx.cfg.api,
                    model_route,
                    super::policy::Level::of(opt_s(p, "_level"), ctx.cfg.profile),
                    &ctx.cfg.agent_policy,
                    s(p, "harness")?,
                    path,
                    s(p, "prompt")?,
                    opt_s(p, "model"),
                    opt_s(p, "effort"),
                    ctx.sink.clone(),
                )
                .await
        }
        "agent.send" => {
            let session = s(p, "session")?;
            if let Some(r) = p.get("model_route").filter(|v| !v.is_null()) {
                ctx.agents.renew_route(session, &super::gateway::parse(r)?)?;
            }
            let id = ctx.agents.prompt(session, s(p, "prompt")?)?;
            Ok(json!({ "session": session, "prompt_id": id }))
        }
        "agent.cancel" => ctx.agents.cancel(s(p, "session")?).await,
        "agent.stop" => ctx.agents.stop(s(p, "session")?, &ctx.sink).await,
        "agent.deny" => ctx.agents.deny(s(p, "session")?, s(p, "permission_id")?).await,
        "agent.events" => {
            ctx.agents
                .events(
                    s(p, "session")?,
                    opt_u(p, "after_seq").unwrap_or(0),
                    opt_u(p, "limit").unwrap_or(200),
                )
                .await
        }
        other => Err(HandError::new("request.unknown_action", format!("unknown action {other}"))),
    }
}

/// One file of a patch: its resolved old and new path (the paths the policy
/// checked; nothing else is opened).
type Planned = (Option<PathBuf>, Option<PathBuf>, patch::FilePatch);

/// All files apply in memory first (a file named twice sees the first
/// change); then each is written (or removed).
fn apply_patch(files: Vec<Planned>) -> Result<Value, HandError> {
    let mut current: std::collections::BTreeMap<PathBuf, Option<String>> = Default::default();
    let read = |path: &Path| -> Result<Option<String>, HandError> {
        match std::fs::read_to_string(path) {
            Ok(t) => Ok(Some(t)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(HandError::io(path, e)),
        }
    };
    let mut order: Vec<PathBuf> = Vec::new();
    for (old, new, f) in &files {
        let source = old.clone().or_else(|| new.clone()).unwrap_or_default();
        if !current.contains_key(&source) {
            current.insert(source.clone(), read(&source)?);
        }
        let text = current[&source].clone();
        let name = source.display().to_string();
        if old.is_some() && text.is_none() {
            return Err(HandError::new("fs.not_found", format!("{name} does not exist")));
        }
        let out = patch::apply_one(text.as_deref(), f, &name)?;
        let target = new.clone().unwrap_or_else(|| source.clone());
        if target != source {
            if !current.contains_key(&target) && read(&target)?.is_some() {
                return Err(HandError::new(
                    "fs.patch.exists",
                    format!("{} already exists", target.display()),
                ));
            }
            current.insert(source.clone(), None);
            order.push(source.clone());
        }
        current.insert(target.clone(), out);
        order.push(target);
    }
    order.dedup();
    let mut result = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for path in order {
        if !seen.insert(path.clone()) {
            continue;
        }
        match &current[&path] {
            Some(text) => {
                fsops::atomic_write(&path, text)?;
                result.push(json!({ "path": path, "sha256": fsops::sha256_hex(text.as_bytes()) }));
            }
            None => {
                if path.exists() {
                    std::fs::remove_file(&path).map_err(|e| HandError::io(&path, e))?;
                }
                result.push(json!({ "path": path, "deleted": true }));
            }
        }
    }
    Ok(json!({ "files": result }))
}

#[cfg(test)]
mod consent_tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[tokio::test]
    async fn revocation_during_owner_approval_prevents_execution() {
        let root = tempfile::tempdir().unwrap();
        let destination = root.path().join("must-not-exist");
        let cfg = HandConfig {
            api: "https://example.com".into(),
            hand: "test".into(),
            key: "test".into(),
            profile: super::super::config::Profile::Mac,
            roots: vec![root.path().to_owned()],
            allow: vec![],
            agent_policy: "ask".into(),
        };
        let agents = Agents::default();
        let ctx = Ctx { cfg: &cfg, agents: &agents, sink: tokio::sync::mpsc::channel(1).0 };
        let granted = AtomicBool::new(true);
        let result = handle_with_consent(
            &ctx,
            "fs.write",
            &json!({"path":destination,"text":"forbidden","_level":"ask"}),
            |_| async {
                tokio::task::yield_now().await;
                granted.store(false, Ordering::SeqCst);
                Ok(true)
            },
            || {
                if granted.load(Ordering::SeqCst) {
                    Ok(())
                } else {
                    Err(HandError::new("consent_required", "revoked"))
                }
            },
        )
        .await;
        assert_eq!(result.unwrap_err().code, "consent_required");
        assert!(!destination.exists());
    }
}
