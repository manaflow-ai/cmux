//! CI activities use the installed authenticated controller client. The activity journal
//! owns the immutable request before submission; a retry never creates another request key.
use super::*;
use crate::workflow_runs::{ActivityRecord, CiIntent, RunRecord};
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;
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
        .map(|s| s.strip_suffix('\n').unwrap_or(&s).to_owned())
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
    let request_key =
        format!("wf-{}", crate::workflow_runs::digest(&format!("{}:{activity}", run.id)));
    // Generic controller jobs do not promise exit_code. A final wrapper-owned marker
    // in the verified complete log preserves the actual shell status and exact output.
    let body = format!(
        "printf '\\ncmux-workflow-start-{}\\n'; cd -- {} && /bin/sh -c {}; _cmux_workflow_status=$?; printf '\\ncmux-workflow-exit-{}:%s\\n' \"$_cmux_workflow_status\"; exit \"$_cmux_workflow_status\"",
        request_key,
        quote(if relative.is_empty() { "." } else { &relative }),
        quote(command),
        request_key
    );
    Ok(CiIntent {
        request_key,
        repo,
        source_ref,
        command: format!("/bin/sh -c {}", quote(&body)),
        target_worker,
    })
}

struct Client {
    #[cfg(test)]
    program: Option<PathBuf>,
}
impl Client {
    fn installed() -> Self {
        Self {
            #[cfg(test)]
            program: None,
        }
    }

    async fn call(&self, args: &[String]) -> Result<Output, RpcError> {
        let program = Path::new("cmux-ci");
        #[cfg(test)]
        let program = self.program.as_deref().unwrap_or(program);
        tokio::time::timeout(
            std::time::Duration::from_secs(300),
            tokio::process::Command::new(program)
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
        let output = self.call(&args).await;
        if !output.as_ref().is_ok_and(|output| output.status.success()) {
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
        serde_json::from_slice(&output?.stdout).map_err(error)
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
        let state = job.get("state").and_then(Value::as_str);
        // The controller can temporarily call a stalled pool job cancelled while
        // stopping it for retry. Its original request still needs cancellation.
        let stopping_for_retry =
            job.pointer("/linux_pool/stall_stopping").and_then(Value::as_bool) == Some(true);
        if matches!(state, Some("done" | "failed"))
            || (state == Some("cancelled") && !stopping_for_retry)
        {
            return Ok(());
        }
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
    if job.get("pin_requested").and_then(Value::as_str).unwrap_or_else(|| field("target_worker"))
        != intent.target_worker
    {
        return Err(error("CI requested target differs from saved intent"));
    }
    Ok((id.to_owned(), digest.to_owned()))
}

async fn finish_wait(
    code: Option<i32>,
    receipt: &Path,
    log: &Path,
    intent: &CiIntent,
    job: &Value,
) -> Result<Value, RpcError> {
    let terminal: Value = serde_json::from_slice(
        &tokio::fs::read(receipt)
            .await
            .map_err(|_| error("CI wait returned no terminal receipt"))?,
    )
    .map_err(error)?;
    binding(&terminal, intent, Some(job))?;
    if code == Some(74) {
        return Err(error("CI complete output unavailable"));
    }
    let state = terminal.get("state").and_then(Value::as_str);
    if !matches!(state, Some("done" | "failed" | "cancelled")) {
        return Err(error("CI wait returned a nonterminal job"));
    }
    let mut output =
        tokio::fs::read(log).await.map_err(|_| error("CI complete output unavailable"))?;
    // Source/setup failures and cancellation may end before the wrapper can report.
    // Keep their verified complete diagnostic output without inventing an exit status.
    let incomplete = |message| {
        error(message).with_data(json!({"jobId":job.get("id"),
        "state":state,"exitCode":Value::Null,"text":String::from_utf8_lossy(&output),"ciReceipt":terminal}))
    };
    let marker = format!("\ncmux-workflow-exit-{}:", intent.request_key);
    let end = output
        .windows(marker.len())
        .rposition(|v| v == marker.as_bytes())
        .ok_or_else(|| incomplete("CI output has no final command status"))?;
    let status = output
        .get(end + marker.len()..)
        .and_then(|v| v.iter().position(|b| *b == b'\n').and_then(|i| v.get(..i)))
        .and_then(|v| std::str::from_utf8(v).ok())
        .and_then(|v| v.parse::<u8>().ok())
        .ok_or_else(|| incomplete("CI output has an invalid final command status"))?;
    let beginning = format!("\ncmux-workflow-start-{}\n", intent.request_key);
    let start = output
        .windows(beginning.len())
        .position(|v| v == beginning.as_bytes())
        .map(|start| start + beginning.len())
        .filter(|start| *start <= end)
        .ok_or_else(|| incomplete("CI output has no command start"))?;
    output = output
        .get(start..end)
        .ok_or_else(|| incomplete("CI output has an invalid command range"))?
        .to_vec();
    use base64::Engine;
    let view = json!({"jobId":job.get("id"),"state":"exited","exitCode":status,
        "text":String::from_utf8_lossy(&output),"data":base64::engine::general_purpose::STANDARD.encode(&output),
        "fromByte":0,"nextByte":output.len(),"skippedBytes":0,"ciReceipt":terminal});
    if code != Some(0) || state != Some("done") || status != 0 {
        return Err(error("workflow CI command did not succeed").with_data(view));
    }
    Ok(view)
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
            let outcome = finish_wait(result.status.code(), &receipt, &log, intent, &job).await;
            // Parent cleanup reads the current activity. Persist a verified terminal receipt
            // so it does not issue a redundant cancellation after a finished command.
            let view = match &outcome {
                Ok(view) => Some(view),
                Err(error) => error.data.as_ref(),
            };
            if let Some(terminal) = view.and_then(|view| view.get("ciReceipt")) {
                let _gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                self.workflow_runs
                    .store()
                    .update_activity_policy(
                        &run.id,
                        generation,
                        &run.owner_session_id,
                        &activity.id,
                        json!({"ciReceipt":terminal}),
                    )
                    .map_err(error)?;
            }
            return outcome;
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

#[cfg(all(test, unix))]
mod tests;
