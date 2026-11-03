//! CI activities use the installed authenticated controller client. The activity journal
//! owns the immutable request before submission; a retry never creates another request key.
use super::*;
use crate::workflow_runs::{ActivityRecord, CiIntent, RunRecord};
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

fn error(message: impl std::fmt::Display) -> RpcError {
    RpcError::internal(message.to_string())
}

async fn git(cwd: &Path, args: &[&str]) -> Result<String, RpcError> {
    let result = tokio::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
        .map_err(|_| error("cannot resolve workflow CI source"))?;
    if !result.status.success() {
        // Git diagnostics can include a credentialed remote URL.
        return Err(error("cannot resolve workflow CI source"));
    }
    String::from_utf8(result.stdout)
        .map(|s| s.trim_end().to_owned())
        .map_err(|_| error("workflow CI source is not UTF-8"))
}

fn github_repo(raw: &str) -> Result<String, RpcError> {
    let path = if let Some(path) = raw.strip_prefix("git@github.com:") {
        path.to_owned()
    } else {
        let url =
            reqwest::Url::parse(raw).map_err(|_| error("CI source must be a GitHub repository"))?;
        if url.host_str() != Some("github.com")
            || !matches!(url.scheme(), "https" | "ssh")
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(error("CI source must be a GitHub repository"));
        }
        url.path().trim_start_matches('/').to_owned()
    };
    let path = path.strip_suffix(".git").unwrap_or(&path);
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() != 2
        || parts.iter().any(|part| {
            part.is_empty()
                || *part == "."
                || *part == ".."
                || !part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
    {
        return Err(error("CI source must name a GitHub owner and repository"));
    }
    Ok(format!("https://github.com/{path}.git"))
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub(crate) async fn prepare(
    run: &RunRecord,
    activity: &str,
    command: &str,
    options: &Value,
) -> Result<CiIntent, RpcError> {
    let repo = github_repo(&git(&run.cwd, &["remote", "get-url", "origin"]).await?)?;
    let source_ref = git(&run.cwd, &["rev-parse", "--verify", "HEAD^{commit}"]).await?;
    if source_ref.len() != 40 || !source_ref.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(error("CI source must resolve to a full commit SHA"));
    }
    let relative = git(&run.cwd, &["rev-parse", "--show-prefix"]).await?;
    let target_worker = match options.get("targetWorker") {
        None => String::new(),
        Some(Value::String(target)) => target.clone(),
        Some(_) => return Err(RpcError::invalid_params("targetWorker must be a string")),
    };
    Ok(CiIntent {
        request_key: format!(
            "wf-{}",
            crate::workflow_runs::digest(&format!("{}:{activity}", run.id))
        ),
        repo,
        source_ref,
        command: format!(
            "cd -- {} && /bin/sh -c {}",
            quote(if relative.is_empty() { "." } else { &relative }),
            quote(command)
        ),
        target_worker,
    })
}

struct Client {
    program: PathBuf,
}
impl Client {
    fn installed() -> Self {
        Self { program: PathBuf::from("cmux-ci") }
    }

    async fn call(&self, args: &[String]) -> Result<Output, RpcError> {
        tokio::time::timeout(
            std::time::Duration::from_secs(300),
            tokio::process::Command::new(&self.program)
                .args(args)
                .stdin(Stdio::null())
                .kill_on_drop(true)
                .output(),
        )
        .await
        .map_err(|_| error("CI client timed out; request key is retained for reconciliation"))?
        .map_err(|_| error("authenticated cmux-ci client unavailable; no local fallback"))
    }

    async fn submit(&self, intent: &CiIntent, receipt: &Path) -> Result<Value, RpcError> {
        let mut args = vec![
            "submit".into(),
            "--command".into(),
            intent.command.clone(),
            "--request-key".into(),
            intent.request_key.clone(),
            "--kind".into(),
            "cmux".into(),
            "--repo".into(),
            intent.repo.clone(),
            "--ref".into(),
            intent.source_ref.clone(),
            "--receipt".into(),
            receipt.to_string_lossy().into_owned(),
        ];
        if !intent.target_worker.is_empty() {
            args.extend(["--target-worker".into(), intent.target_worker.clone()]);
        }
        let output = self.call(&args).await?;
        if !output.status.success() {
            // A lost acknowledgement may already have queued the job. Lookup is read-only;
            // the identical POST then proves that this intent is the key's binding (or 409).
            let status = self
                .call(&["status".into(), "--request-key".into(), intent.request_key.clone()])
                .await?;
            if !status.status.success() {
                return Err(error(
                    "CI submission unacknowledged; resume with the saved request key",
                ));
            }
            binding(
                &serde_json::from_slice::<Value>(&status.stdout).map_err(error)?,
                intent,
                None,
            )?;
            let output = self.call(&args).await?;
            if !output.status.success() {
                return Err(error("CI request binding refused; no replacement job was submitted"));
            }
            return serde_json::from_slice(&output.stdout).map_err(error);
        }
        serde_json::from_slice(&output.stdout).map_err(error)
    }

    async fn cancel(&self, intent: &CiIntent, receipt: Option<&Value>) -> Result<(), RpcError> {
        let job = match receipt {
            Some(receipt) => receipt.clone(),
            None => {
                let output = self
                    .call(&["status".into(), "--request-key".into(), intent.request_key.clone()])
                    .await?;
                if !output.status.success() {
                    return Err(error("CI cancellation cannot establish request binding"));
                }
                serde_json::from_slice(&output.stdout).map_err(error)?
            }
        };
        let (id, digest) = binding(&job, intent, None)?;
        let result = self
            .call(&[
                "cancel".into(),
                id,
                "--request-key".into(),
                intent.request_key.clone(),
                "--command-digest".into(),
                digest,
            ])
            .await?;
        if !result.status.success() {
            return Err(error("conditional CI cancellation refused"));
        }
        Ok(())
    }
}

/// A successful keyed POST enforces the controller's complete immutable digest. Older
/// controllers without either echoed binding are refused. Never guess a command-only digest.
fn binding(
    job: &Value,
    intent: &CiIntent,
    previous: Option<&Value>,
) -> Result<(String, String), RpcError> {
    let field = |key| job.get(key).and_then(Value::as_str).unwrap_or("");
    let id = field("id");
    let digest = field("command_digest");
    if id.len() != 24
        || !id.bytes().all(|b| b.is_ascii_hexdigit())
        || field("request_key") != intent.request_key
        || !digest
            .strip_prefix("sha256:")
            .is_some_and(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
        || field("command") != intent.command
        || field("repo") != intent.repo
        || field("ref") != intent.source_ref
        || field("kind") != "cmux"
        || (previous.is_some_and(|p| {
            p.get("id") != job.get("id") || p.get("command_digest") != job.get("command_digest")
        }))
    {
        return Err(error("CI receipt does not match the saved request binding"));
    }
    Ok((id.to_owned(), digest.to_owned()))
}

impl Hub {
    pub(crate) async fn workflow_ci_execute(
        self: &Arc<Self>,
        run: &RunRecord,
        generation: u64,
        activity: &ActivityRecord,
        intent: &CiIntent,
    ) -> Result<Value, RpcError> {
        let client = Client::installed();
        let files = tempfile::tempdir().map_err(error)?;
        let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
        self.workflow_runs
            .store()
            .authorize(&run.id, generation, &run.owner_session_id)
            .map_err(error)?;
        self.workflow_activity_scope(run, "machine").await?;
        let job = client.submit(intent, &files.path().join("submit.json")).await?;
        let (id, _) = binding(&job, intent, activity.policy.get("ciReceipt"))?;
        self.workflow_runs
            .store()
            .update_activity_policy(
                &run.id,
                generation,
                &run.owner_session_id,
                &activity.id,
                json!({"ciReceipt":job}),
            )
            .map_err(error)?;
        drop(gate);
        let log = files.path().join("output.log");
        let receipt = files.path().join("terminal.json");
        loop {
            self.workflow_runs
                .store()
                .authorize(&run.id, generation, &run.owner_session_id)
                .map_err(error)?;
            let result = client
                .call(&[
                    "wait".into(),
                    id.clone(),
                    "--timeout".into(),
                    "60".into(),
                    "--full-log".into(),
                    log.to_string_lossy().into_owned(),
                    "--receipt".into(),
                    receipt.to_string_lossy().into_owned(),
                ])
                .await?;
            if result.status.code() == Some(2) {
                continue;
            }
            let terminal: Value = serde_json::from_slice(
                &tokio::fs::read(&receipt)
                    .await
                    .map_err(|_| error("CI wait returned no terminal receipt"))?,
            )
            .map_err(error)?;
            binding(&terminal, intent, Some(&job))?;
            if result.status.code() == Some(74) {
                return Err(error("CI complete output unavailable"));
            }
            let output =
                tokio::fs::read(&log).await.map_err(|_| error("CI complete output unavailable"))?;
            use base64::Engine;
            let view = json!({"jobId":id,"state":"exited","exitCode":if result.status.success() {0} else {1},
                "text":String::from_utf8_lossy(&output),"data":base64::engine::general_purpose::STANDARD.encode(&output),
                "fromByte":0,"nextByte":output.len(),"skippedBytes":0,"ciReceipt":terminal});
            if !matches!(
                terminal.get("state").and_then(Value::as_str),
                Some("done" | "failed" | "cancelled")
            ) {
                return Err(error("CI wait returned a nonterminal job"));
            }
            if !result.status.success()
                || terminal.get("state").and_then(Value::as_str) != Some("done")
            {
                return Err(error("workflow CI command did not succeed").with_data(view));
            }
            return Ok(view);
        }
    }

    pub(crate) async fn workflow_ci_cancel(
        &self,
        activity: &ActivityRecord,
        intent: &CiIntent,
    ) -> Result<(), RpcError> {
        Client::installed().cancel(intent, activity.policy.get("ciReceipt")).await
    }
}
