//! CI activities use the installed authenticated controller client. The activity journal
//! owns the immutable request before submission; a retry never creates another request key.
use super::*;
use crate::workflow_runs::{ActivityRecord, CiIntent, RunRecord};
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;
use std::process::{Output, Stdio};
use std::time::Duration;

/// The route `cmux-ci test` takes to the fleet's Linux pool: a plain command, not a dev build.
const POOL_KIND: &str = "fast-checks";
const POOL_LABEL: &str = "cmux-next-linux";
/// One wait's bound from job creation, unless `timeoutMs` names another (within the cap).
const DEFAULT_TIMEOUT_SECS: u64 = 3600;
const MAX_TIMEOUT_SECS: u64 = 10800;
/// The client's own time to answer past its `--timeout`: the terminal read plus the complete
/// log, which `cmux-ci wait --full-log` may take up to 600 s to receive.
const WAIT_GRACE_SECS: u64 = 660;
/// Submit, status and cancel are single controller round trips.
const CALL_SECS: u64 = 300;

/// Why a CI placement did not produce a command result. Every failure carries one in
/// `data.reason`, so a workflow can branch on it instead of matching message text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    /// No installed authenticated `cmux-ci` client. Nothing ran, locally or remotely.
    Unavailable,
    /// The controller refused the submission or its binding; no replacement job exists.
    Refused,
    /// A submission may have queued but was never acknowledged; resume reattaches by key.
    Unacknowledged,
    /// The controller stopped answering during the wait; the job keeps its place.
    Unreachable,
    /// The job did not end within its deadline and was cancelled.
    Deadline,
    /// A receipt or output does not match the saved intent.
    Binding,
    /// The job ended without a verifiable command status or complete output.
    Incomplete,
    /// The command ran and exited nonzero (or the job failed or was cancelled).
    Failed,
}

impl Reason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => "ci.unavailable",
            Self::Refused => "ci.refused",
            Self::Unacknowledged => "ci.unacknowledged",
            Self::Unreachable => "ci.unreachable",
            Self::Deadline => "ci.deadline",
            Self::Binding => "ci.binding",
            Self::Incomplete => "ci.incomplete",
            Self::Failed => "ci.failed",
        }
    }
}

fn fail(reason: Reason, message: impl std::fmt::Display) -> RpcError {
    RpcError::internal(message.to_string()).with_data(json!({"reason": reason.as_str()}))
}

fn fail_with(reason: Reason, message: impl std::fmt::Display, mut data: Value) -> RpcError {
    if let Some(map) = data.as_object_mut() {
        map.insert("reason".into(), json!(reason.as_str()));
    }
    RpcError::internal(message.to_string()).with_data(data)
}

fn error(message: impl std::fmt::Display) -> RpcError {
    RpcError::internal(message.to_string())
}

/// The controller answers with JSON on success; anything else is a binding failure.
fn parse(bytes: &[u8]) -> Result<Value, RpcError> {
    serde_json::from_slice(bytes).map_err(|_| fail(Reason::Binding, "CI client answered no JSON"))
}

fn timeout_secs(options: &Value) -> Result<u64, RpcError> {
    match options.get("timeoutMs") {
        None => Ok(DEFAULT_TIMEOUT_SECS),
        Some(value) => value
            .as_u64()
            .filter(|ms| (1000..=MAX_TIMEOUT_SECS * 1000).contains(ms))
            .map(|ms| ms.div_ceil(1000))
            .ok_or_else(|| {
                RpcError::invalid_params(format!(
                    "timeoutMs must be a whole number from 1000 to {}",
                    MAX_TIMEOUT_SECS * 1000
                ))
            }),
    }
}

fn bound(intent: &CiIntent) -> u64 {
    if intent.timeout_secs == 0 { DEFAULT_TIMEOUT_SECS } else { intent.timeout_secs }
}

/// Seconds left of the intent's bound, counted from the job's creation, so a resumed wait
/// never extends the deadline it started with.
fn remaining(intent: &CiIntent, job: &Value, now: chrono::DateTime<chrono::Utc>) -> u64 {
    let bound = bound(intent);
    let created = job
        .get("created_at")
        .and_then(Value::as_str)
        .and_then(|at| chrono::DateTime::parse_from_rfc3339(at).ok())
        .map(|at| at.with_timezone(&chrono::Utc));
    let Some(created) = created else { return bound };
    let elapsed = u64::try_from((now - created).num_seconds()).unwrap_or(0);
    // At least one second: a resumed run past its deadline still reads the terminal state once.
    bound.saturating_sub(elapsed).max(1)
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
    let timeout_secs = timeout_secs(options)?;
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
        kind: POOL_KIND.into(),
        label: POOL_LABEL.into(),
        timeout_secs,
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

    /// One client process, bounded. A missing client is `ci.unavailable`: nothing ran.
    async fn call_within(&self, args: &[String], bound: Duration) -> Result<Output, RpcError> {
        let resolved = crate::config::user_program("cmux-ci");
        let program = resolved.as_path();
        #[cfg(test)]
        let program = self.program.as_deref().unwrap_or(program);
        tokio::time::timeout(
            bound,
            tokio::process::Command::new(program)
                .args(args)
                .stdin(Stdio::null())
                .kill_on_drop(true)
                .output(),
        )
        .await
        .map_err(|_| {
            fail(
                Reason::Unacknowledged,
                "CI client gave no answer in its bound; request key is retained for reconciliation",
            )
        })?
        .map_err(|_| {
            fail(Reason::Unavailable, "authenticated cmux-ci client unavailable; no local fallback")
        })
    }

    async fn call(&self, args: &[String]) -> Result<Output, RpcError> {
        self.call_within(args, Duration::from_secs(CALL_SECS)).await
    }

    async fn submit(&self, intent: &CiIntent, receipt: &Path) -> Result<Value, RpcError> {
        let mut args = vec![
            "submit".into(),
            "--command".into(),
            intent.command.clone(),
            "--request-key".into(),
            intent.request_key.clone(),
            "--kind".into(),
            intent.kind.clone(),
            "--repo".into(),
            intent.repo.clone(),
            "--ref".into(),
            intent.source_ref.clone(),
            "--receipt".into(),
            receipt.to_string_lossy().into_owned(),
        ];
        if !intent.label.is_empty() {
            args.extend(["--label".into(), intent.label.clone()]);
        }
        if !intent.target_worker.is_empty() {
            args.extend(["--target-worker".into(), intent.target_worker.clone()]);
        }
        let output = match self.call(&args).await {
            Err(error) if reason_of(&error) == Some(Reason::Unavailable) => return Err(error),
            output => output,
        };
        if let Ok(output) = &output
            && output.status.success()
        {
            return parse(&output.stdout);
        }
        // A lost acknowledgement may already have queued the job. Lookup is read-only;
        // the identical POST then proves that this intent is the key's binding (or 409).
        let status = self
            .call(&["status".into(), "--request-key".into(), intent.request_key.clone()])
            .await?;
        match status.status.code() {
            Some(0) => {}
            // No job holds the key and the controller answered the submit: it took nothing.
            Some(1) if output.as_ref().is_ok_and(|o| o.status.code() != Some(3)) => {
                let why = output.as_ref().map(|o| last_line(&o.stderr)).unwrap_or_default();
                return Err(fail(Reason::Refused, format!("CI submission refused: {why}")));
            }
            _ => {
                return Err(fail(
                    Reason::Unacknowledged,
                    "CI submission unacknowledged; resume reattaches by the saved request key",
                ));
            }
        }
        binding(&parse(&status.stdout)?, intent, None)?;
        let output = self.call(&args).await?;
        if !output.status.success() {
            return Err(fail(
                Reason::Refused,
                "CI request binding refused; no replacement job was submitted",
            ));
        }
        parse(&output.stdout)
    }

    /// One wait for the job's end, bounded by the intent's deadline. The client follows the
    /// job on the controller and rides out short outages; this process never re-polls.
    async fn wait(
        &self,
        id: &str,
        seconds: u64,
        log: &Path,
        receipt: &Path,
    ) -> Result<Option<i32>, RpcError> {
        let args: [String; 8] = [
            "wait".into(),
            id.to_owned(),
            "--timeout".into(),
            seconds.to_string(),
            "--full-log".into(),
            log.to_string_lossy().into_owned(),
            "--receipt".into(),
            receipt.to_string_lossy().into_owned(),
        ];
        let bound = Duration::from_secs(seconds + WAIT_GRACE_SECS);
        match self.call_within(&args, bound).await {
            Ok(output) => Ok(output.status.code()),
            Err(error) if reason_of(&error) == Some(Reason::Unacknowledged) => Err(fail_with(
                Reason::Unreachable,
                "CI wait gave no answer past its deadline; the job keeps its place",
                json!({"jobId": id}),
            )),
            Err(error) => Err(error),
        }
    }

    async fn cancel(&self, intent: &CiIntent, receipt: Option<&Value>) -> Result<(), RpcError> {
        let job = match receipt {
            Some(receipt) => receipt.clone(),
            None => {
                let output = self
                    .call(&["status".into(), "--request-key".into(), intent.request_key.clone()])
                    .await?;
                match output.status.code() {
                    Some(0) => parse(&output.stdout)?,
                    // No job holds the key: nothing was queued, so nothing runs.
                    Some(1) => return Ok(()),
                    _ => {
                        return Err(fail(
                            Reason::Unreachable,
                            "CI cancellation cannot establish request binding",
                        ));
                    }
                }
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
            return Err(fail(Reason::Refused, "conditional CI cancellation refused"));
        }
        Ok(())
    }
}

fn reason_of(error: &RpcError) -> Option<Reason> {
    let reason = error.data.as_ref()?.get("reason")?.as_str()?;
    [
        Reason::Unavailable,
        Reason::Refused,
        Reason::Unacknowledged,
        Reason::Unreachable,
        Reason::Deadline,
        Reason::Binding,
        Reason::Incomplete,
        Reason::Failed,
    ]
    .into_iter()
    .find(|candidate| candidate.as_str() == reason)
}

fn last_line(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    text.lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("")
        .chars()
        .take(300)
        .collect()
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
        || field("kind") != intent.kind
        || (!intent.label.is_empty()
            && !job.get("labels").and_then(Value::as_array).is_some_and(|labels| {
                labels.iter().any(|l| l.as_str() == Some(intent.label.as_str()))
            }))
        || (previous.is_some_and(|p| {
            p.get("id") != job.get("id") || p.get("command_digest") != job.get("command_digest")
        }))
    {
        return Err(fail(Reason::Binding, "CI receipt does not match the saved request binding"));
    }
    if job.get("pin_requested").and_then(Value::as_str).unwrap_or_else(|| field("target_worker"))
        != intent.target_worker
    {
        return Err(fail(Reason::Binding, "CI requested target differs from saved intent"));
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
    let id = job.get("id").cloned().unwrap_or(Value::Null);
    match code {
        // The deadline passed with the job unfinished. The caller's cleanup cancels it.
        Some(2) => {
            return Err(fail_with(
                Reason::Deadline,
                format!("CI job did not end within {} s", bound(intent)),
                json!({"jobId": id}),
            ));
        }
        Some(3) => {
            return Err(fail_with(
                Reason::Unreachable,
                "CI controller stopped answering during the wait; the job keeps its place",
                json!({"jobId": id}),
            ));
        }
        _ => {}
    }
    let terminal: Value = serde_json::from_slice(
        &tokio::fs::read(receipt)
            .await
            .map_err(|_| fail(Reason::Incomplete, "CI wait returned no terminal receipt"))?,
    )
    .map_err(|_| fail(Reason::Incomplete, "CI terminal receipt is not JSON"))?;
    binding(&terminal, intent, Some(job))?;
    let state = terminal.get("state").and_then(Value::as_str);
    if !matches!(state, Some("done" | "failed" | "cancelled")) {
        return Err(fail(Reason::Incomplete, "CI wait returned a nonterminal job"));
    }
    // Keep the verified terminal receipt in every later failure, so cleanup does not cancel
    // a job that already ended.
    let ended = |reason, message: &str, text: &[u8]| {
        fail_with(
            reason,
            message,
            json!({"jobId":id,"state":state,"exitCode":Value::Null,
                "text":String::from_utf8_lossy(text),"ciReceipt":terminal}),
        )
    };
    if code == Some(74) {
        return Err(ended(Reason::Incomplete, "CI complete output unavailable", &[]));
    }
    let mut output = tokio::fs::read(log)
        .await
        .map_err(|_| ended(Reason::Incomplete, "CI complete output unavailable", &[]))?;
    // Source/setup failures and cancellation may end before the wrapper can report.
    // Keep their verified complete diagnostic output without inventing an exit status.
    let incomplete = |message| {
        let reason = if matches!(state, Some("failed" | "cancelled")) {
            Reason::Failed
        } else {
            Reason::Incomplete
        };
        ended(reason, message, &output)
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
        return Err(fail_with(Reason::Failed, "workflow CI command did not succeed", view));
    }
    Ok(view)
}

/// One wait, bounded by the deadline counted from the job's creation: a resume after a
/// restart reattaches to the same job and keeps the deadline it started with. Pause cancels
/// the job, which ends this wait; its outcome is then fenced by generation.
async fn settle(
    client: &Client,
    intent: &CiIntent,
    id: &str,
    job: &Value,
    dir: &Path,
) -> Result<Value, RpcError> {
    let log = dir.join("output.log");
    let receipt = dir.join("terminal.json");
    let seconds = remaining(intent, job, chrono::Utc::now());
    let code = client.wait(id, seconds, &log, &receipt).await?;
    finish_wait(code, &receipt, &log, intent, job).await
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
        let outcome = settle(&client, intent, &id, &job, files.path()).await;
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
        outcome
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
mod tests {
    use super::*;
    use crate::workflow_runs::{Child, State, Store};
    use std::os::unix::fs::PermissionsExt;

    fn run(cwd: &Path) -> RunRecord {
        RunRecord {
            version: 1,
            id: "wf-ci-test".into(),
            name: "CI machine".into(),
            owner_session_id: "owner".into(),
            local_principal: true,
            source: "machine('test')".into(),
            source_hash: String::new(),
            args: json!([]),
            allowed_tools: None,
            cwd: cwd.into(),
            generation: 1,
            state: State::Running,
            activities: Default::default(),
            outcome: None,
            caller_subagent: None,
        }
    }

    async fn repository(dir: &Path) {
        git(dir, &["init", "--quiet"]).await.unwrap();
        git(
            dir,
            &[
                "remote",
                "add",
                "origin",
                "https://secret:credential@github.com/example/project.git",
            ],
        )
        .await
        .unwrap();
        commit(dir).await;
    }

    async fn commit(dir: &Path) {
        git(
            dir,
            &[
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "--quiet",
                "--allow-empty",
                "-m",
                "fixture",
            ],
        )
        .await
        .unwrap();
    }

    fn fake(dir: &Path, intent: &CiIntent, lost_ack: bool) -> Client {
        std::fs::write(dir.join("intent.json"), serde_json::to_vec(intent).unwrap()).unwrap();
        if lost_ack {
            std::fs::write(dir.join("lose-ack"), "").unwrap();
        }
        let program = dir.join("client.py");
        std::fs::write(&program, r#"#!/usr/bin/env python3
import json, pathlib, subprocess, sys
root = pathlib.Path(__file__).parent
args = sys.argv[1:]
op = args[0]
def flag(name, default=''):
    return args[args.index(name)+1] if name in args else default
intent = json.loads((root/'intent.json').read_text())
state = root/'job.json'
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\n')
if op == 'submit':
    if (root/'refuse').exists():
        sys.stderr.write('controller: 422 label is not served by any pool\n')
        sys.exit(9)
    wanted = {'command':flag('--command'),'repo':flag('--repo'),'ref':flag('--ref'),'kind':flag('--kind'),'target_worker':flag('--target-worker'),'request_key':flag('--request-key')}
    if state.exists():
        job=json.loads(state.read_text())
        if any(job[k] != v for k,v in wanted.items()): sys.exit(9)
    else:
        labels=[flag('--label')] if '--label' in args else []
        job=dict(wanted,id='a'*24,command_digest='sha256:'+'b'*64,state='queued',labels=labels,created_at='2026-11-20T21:10:39.886522Z')
        state.write_text(json.dumps(job))
        (root/'created').write_text('one job')
    if (root/'lose-ack').exists():
        (root/'lose-ack').unlink()
        sys.exit(1)
    pathlib.Path(flag('--receipt')).write_text(json.dumps(job))
    print(json.dumps(job))
elif op == 'status':
    if not state.exists(): sys.exit(1)
    print(state.read_text())
elif op == 'cancel':
    job=json.loads(state.read_text())
    if args[1] != job['id'] or flag('--request-key') != job['request_key'] or flag('--command-digest') != job['command_digest']: sys.exit(9)
    job['state']='cancelled'
    state.write_text(json.dumps(job))
    print(json.dumps(job))
elif op == 'wait':
    if (root/'down').exists(): sys.exit(3)
    if (root/'stall').exists(): sys.exit(2)
    job=json.loads(state.read_text())
    (root/'ran').open('a').write('run\n')
    result=subprocess.run(job['command'],shell=True,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    job['state']='done' if result.returncode == 0 else 'failed'
    pathlib.Path(flag('--receipt')).write_text(json.dumps(job))
    pathlib.Path(flag('--full-log')).write_bytes(b'worker checkout logs\njob: nofile report\n'+result.stdout+(b'command failed: exit status 23\n' if result.returncode else b''))
    print('human wait progress, deliberately not JSON')
    sys.exit(0 if result.returncode == 0 else 1)
else: sys.exit(9)
"#).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        Client { program: Some(program) }
    }

    #[tokio::test]
    async fn workflow_ci_lost_ack_attaches_once_and_cancel_is_exact() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let intent = prepare(
            &run(dir.path()),
            "activity",
            "printf hello",
            &json!({"targetWorker":"requested-worker"}),
        )
        .await
        .unwrap();
        let client = fake(dir.path(), &intent, true);
        let job = client.submit(&intent, &dir.path().join("submit.json")).await.unwrap();
        binding(&job, &intent, None).unwrap();
        let attached = client.submit(&intent, &dir.path().join("again.json")).await.unwrap();
        assert_eq!(job["id"], attached["id"]);
        client.cancel(&intent, Some(&attached)).await.unwrap();
        let terminal: Value =
            serde_json::from_slice(&std::fs::read(dir.path().join("job.json")).unwrap()).unwrap();
        let before = std::fs::read(dir.path().join("calls.jsonl")).unwrap();
        client.cancel(&intent, Some(&terminal)).await.unwrap();
        assert_eq!(std::fs::read(dir.path().join("calls.jsonl")).unwrap(), before);
        let mut stopping = terminal;
        stopping["linux_pool"] = json!({"stall_stopping":true});
        client.cancel(&intent, Some(&stopping)).await.unwrap();
        let calls: Vec<Value> = std::fs::read_to_string(dir.path().join("calls.jsonl"))
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(calls.iter().filter(|call| call[0] == "submit").count(), 3);
        assert_eq!(calls.iter().filter(|call| call[0] == "status").count(), 1);
        assert_eq!(calls.iter().filter(|call| call[0] == "cancel").count(), 2);
        assert_eq!(
            calls.last().unwrap(),
            &json!([
                "cancel",
                "a".repeat(24),
                "--request-key",
                intent.request_key,
                "--command-digest",
                format!("sha256:{}", "b".repeat(64))
            ])
        );
        assert_eq!(std::fs::read_to_string(dir.path().join("created")).unwrap(), "one job");
    }

    #[tokio::test]
    async fn workflow_ci_replay_preserves_source_target_and_refuses_conflicting_binding() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        std::fs::create_dir(dir.path().join("subdir")).unwrap();
        let mut spec = run(&dir.path().join("subdir"));
        let intent = prepare(&spec, "activity", "pwd", &json!({"targetWorker":"first-worker"}))
            .await
            .unwrap();
        assert_eq!(intent.repo, "https://github.com/example/project.git");
        assert!(!serde_json::to_string(&intent).unwrap().contains("credential"));
        let store = Store::new(dir.path().join("runs"));
        spec = store.start(spec).unwrap();
        let activity = ActivityRecord {
            id: "activity".into(),
            kind: "machine".into(),
            fingerprint: "immutable".into(),
            child: Child::CiMachine { intent: intent.clone() },
            policy: Value::Null,
            outcome: None,
        };
        store.register_activity(&spec.id, spec.generation, "owner", activity.clone()).unwrap();
        commit(dir.path()).await;
        git(dir.path(), &["remote", "set-url", "origin", "https://github.com/changed/source.git"])
            .await
            .unwrap();
        let paused = store.pause(&spec.id, "owner").unwrap();
        store.paused(&spec.id, paused.generation).unwrap();
        let resumed = store.resume(&spec.id, "owner", false).unwrap();
        let saved =
            store.activity(&spec.id, resumed.generation, "owner", "activity").unwrap().unwrap();
        assert_eq!(saved.child, activity.child);
        assert_ne!(git(dir.path(), &["rev-parse", "HEAD"]).await.unwrap(), intent.source_ref);
        let Child::CiMachine { intent: pinned } = saved.child else { unreachable!() };
        let client = fake(dir.path(), &pinned, false);
        let first = client.submit(&pinned, &dir.path().join("receipt.json")).await.unwrap();
        binding(&first, &pinned, None).unwrap();
        let mut changed = pinned.clone();
        changed.target_worker = "other-worker".into();
        assert!(client.submit(&changed, &dir.path().join("conflict.json")).await.is_err());
        let mut missing = first.clone();
        missing.as_object_mut().unwrap().remove("command_digest");
        assert!(binding(&missing, &pinned, None).is_err());
        let mut conflict = first.clone();
        conflict["command_digest"] = json!(format!("sha256:{}", "c".repeat(64)));
        assert!(binding(&conflict, &pinned, Some(&first)).is_err());
        let mut moved = first.clone();
        moved["target_worker"] = json!("fallback-worker");
        moved["pin_requested"] = json!("first-worker");
        binding(&moved, &pinned, Some(&first)).unwrap();
    }

    #[tokio::test]
    async fn workflow_ci_full_log_preserves_output_and_exact_nonzero_status() {
        for status in [0, 23] {
            let dir = tempfile::tempdir().unwrap();
            repository(dir.path()).await;
            let nested = dir.path().join("sub dir ' ");
            std::fs::create_dir(&nested).unwrap();
            let command = format!("printf 'complete output'; printf ' stderr' >&2; exit {status}");
            let intent = prepare(&run(&nested), "activity", &command, &json!({})).await.unwrap();
            let client = fake(dir.path(), &intent, false);
            let job = client.submit(&intent, &dir.path().join("submit.json")).await.unwrap();
            let receipt = dir.path().join("terminal.json");
            let log = dir.path().join("full.log");
            let waited = client
                .call(&[
                    "wait".into(),
                    job["id"].as_str().unwrap().into(),
                    "--receipt".into(),
                    receipt.to_str().unwrap().into(),
                    "--full-log".into(),
                    log.to_str().unwrap().into(),
                ])
                .await
                .unwrap();
            let result = finish_wait(waited.status.code(), &receipt, &log, &intent, &job).await;
            let view =
                if status == 0 { result.unwrap() } else { result.unwrap_err().data.unwrap() };
            assert_eq!(view["text"], "complete output stderr");
            assert_eq!(view["exitCode"], status);
            std::fs::write(&log, "truncated output").unwrap();
            let incomplete = finish_wait(waited.status.code(), &receipt, &log, &intent, &job)
                .await
                .unwrap_err()
                .data
                .unwrap();
            assert_eq!(incomplete["text"], "truncated output");
            assert!(incomplete["exitCode"].is_null());
        }
    }

    #[tokio::test]
    async fn workflow_ci_unavailable_client_never_executes_command_locally() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let marker = dir.path().join("must-not-exist");
        let intent = prepare(
            &run(dir.path()),
            "activity",
            &format!("touch {}", quote(marker.to_str().unwrap())),
            &json!({}),
        )
        .await
        .unwrap();
        let client = Client { program: Some(dir.path().join("missing-client")) };
        assert!(client.submit(&intent, &dir.path().join("receipt.json")).await.is_err());
        assert!(!marker.exists());
        for url in [
            "https://github.com.evil/example/project",
            "file:///tmp/repo",
            "https://github.com/example/project?token=secret",
        ] {
            assert!(github_repo(url).is_err());
        }
    }

    fn calls(dir: &Path) -> Vec<Value> {
        std::fs::read_to_string(dir.join("calls.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect()
    }

    fn reason(error: &RpcError) -> &str {
        error.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or("")
    }

    #[tokio::test]
    async fn workflow_ci_step_runs_on_the_linux_pool_and_reports_back_with_one_wait() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let intent =
            prepare(&run(dir.path()), "activity", "printf placed", &json!({"timeoutMs":90000}))
                .await
                .unwrap();
        assert_eq!((intent.kind.as_str(), intent.label.as_str()), (POOL_KIND, POOL_LABEL));
        assert_eq!(intent.timeout_secs, 90);
        let client = fake(dir.path(), &intent, false);
        let job = client.submit(&intent, &dir.path().join("submit.json")).await.unwrap();
        let (id, _) = binding(&job, &intent, None).unwrap();
        let view = settle(&client, &intent, &id, &job, dir.path()).await.unwrap();
        assert_eq!(view["text"], "placed");
        assert_eq!(view["exitCode"], 0);
        assert_eq!(view["ciReceipt"]["state"], "done");
        let calls = calls(dir.path());
        let submit = calls.iter().find(|call| call[0] == "submit").unwrap();
        let args: Vec<&str> = submit.as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert!(args.windows(2).any(|w| w == ["--kind", POOL_KIND]));
        assert!(args.windows(2).any(|w| w == ["--label", POOL_LABEL]));
        // One wait for the whole job, bounded by what is left of its deadline: no re-polls.
        let waits: Vec<_> = calls.iter().filter(|call| call[0] == "wait").collect();
        assert_eq!(waits.len(), 1);
        let seconds: u64 = waits[0][3].as_str().unwrap().parse().unwrap();
        assert!((1..=90).contains(&seconds));
    }

    #[tokio::test]
    async fn workflow_ci_refused_unavailable_unreachable_and_late_fail_with_typed_reasons() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let marker = dir.path().join("must-not-exist");
        let command = format!("touch {}", quote(marker.to_str().unwrap()));
        let intent = prepare(&run(dir.path()), "activity", &command, &json!({})).await.unwrap();

        let missing = Client { program: Some(dir.path().join("missing-client")) };
        let error = missing.submit(&intent, &dir.path().join("r.json")).await.unwrap_err();
        assert_eq!(reason(&error), "ci.unavailable");

        let client = fake(dir.path(), &intent, false);
        std::fs::write(dir.path().join("refuse"), "").unwrap();
        let error = client.submit(&intent, &dir.path().join("r.json")).await.unwrap_err();
        assert_eq!(reason(&error), "ci.refused");
        assert!(error.message.contains("label is not served"), "{}", error.message);
        assert!(!dir.path().join("created").exists());
        std::fs::remove_file(dir.path().join("refuse")).unwrap();

        let job = client.submit(&intent, &dir.path().join("r.json")).await.unwrap();
        let (id, _) = binding(&job, &intent, None).unwrap();
        std::fs::write(dir.path().join("down"), "").unwrap();
        let error = settle(&client, &intent, &id, &job, dir.path()).await.unwrap_err();
        assert_eq!(reason(&error), "ci.unreachable");
        assert_eq!(error.data.as_ref().unwrap()["jobId"], id);
        std::fs::remove_file(dir.path().join("down")).unwrap();

        std::fs::write(dir.path().join("stall"), "").unwrap();
        let error = settle(&client, &intent, &id, &job, dir.path()).await.unwrap_err();
        assert_eq!(reason(&error), "ci.deadline");
        // Cleanup cancels the unfinished job by its exact binding.
        client.cancel(&intent, Some(&job)).await.unwrap();
        assert_eq!(calls(dir.path()).last().unwrap()[0], "cancel");
        assert!(!marker.exists());
        assert!(!dir.path().join("ran").exists());
    }

    #[tokio::test]
    async fn workflow_ci_resume_reattaches_the_same_job_and_never_runs_it_twice() {
        let dir = tempfile::tempdir().unwrap();
        repository(dir.path()).await;
        let intent =
            prepare(&run(dir.path()), "activity", "printf once", &json!({})).await.unwrap();
        let client = fake(dir.path(), &intent, false);
        // First runner: submits, then the daemon dies before the wait.
        let first = client.submit(&intent, &dir.path().join("a.json")).await.unwrap();
        // Resumed runner: the saved intent submits again under the same key and attaches.
        let saved: CiIntent =
            serde_json::from_str(&serde_json::to_string(&intent).unwrap()).unwrap();
        let again = client.submit(&saved, &dir.path().join("b.json")).await.unwrap();
        let (id, _) = binding(&again, &saved, Some(&first)).unwrap();
        let view = settle(&client, &saved, &id, &again, dir.path()).await.unwrap();
        assert_eq!(view["text"], "once");
        assert_eq!(std::fs::read_to_string(dir.path().join("created")).unwrap(), "one job");
        assert_eq!(std::fs::read_to_string(dir.path().join("ran")).unwrap(), "run\n");
        // An intent saved before the pool route resumes on its original binding.
        let legacy: CiIntent = serde_json::from_value(json!({
            "requestKey": intent.request_key, "repo": intent.repo, "sourceRef": intent.source_ref,
            "command": intent.command, "targetWorker": ""
        }))
        .unwrap();
        assert_eq!(
            (legacy.kind.as_str(), legacy.label.as_str(), legacy.timeout_secs),
            ("cmux", "", 0)
        );
        let mut old = first.clone();
        old["kind"] = json!("cmux");
        old["labels"] = json!([]);
        binding(&old, &legacy, None).unwrap();
        assert!(binding(&first, &legacy, None).is_err());
    }

    #[test]
    fn workflow_ci_deadline_counts_from_job_creation_and_bounds_options() {
        let mut intent = CiIntent {
            request_key: "wf-x".into(),
            repo: String::new(),
            source_ref: String::new(),
            command: String::new(),
            target_worker: String::new(),
            kind: POOL_KIND.into(),
            label: POOL_LABEL.into(),
            timeout_secs: 600,
        };
        let job = json!({"created_at":"2026-11-20T21:00:00Z"});
        let at = |s| chrono::DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&chrono::Utc);
        assert_eq!(remaining(&intent, &job, at("2026-11-20T21:01:40Z")), 500);
        assert_eq!(remaining(&intent, &job, at("2026-11-20T22:00:00Z")), 1);
        assert_eq!(remaining(&intent, &json!({}), at("2026-11-20T22:00:00Z")), 600);
        intent.timeout_secs = 0;
        assert_eq!(remaining(&intent, &job, at("2026-11-20T21:00:00Z")), DEFAULT_TIMEOUT_SECS);
        assert_eq!(timeout_secs(&json!({})).unwrap(), DEFAULT_TIMEOUT_SECS);
        assert_eq!(timeout_secs(&json!({"timeoutMs":1500})).unwrap(), 2);
        for bad in [json!(10), json!(MAX_TIMEOUT_SECS * 1000 + 1), json!("60000"), json!(-1)] {
            assert!(timeout_secs(&json!({"timeoutMs":bad})).is_err());
        }
    }
}
