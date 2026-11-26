//! The runner for a sub-agent on a fork (RFD 0144 piece 7, the slice after cmux#53702): it wakes
//! the fork, opens one stream to it, runs the sub-agent's work there, reads its output as it comes,
//! and brings its files back as [`super::sub_fork::capture`]'s byte-exact patch.
//!
//! Two ends, one wire:
//! - this daemon ([`ForkRunner`], a [`SubRun`]): [`ForkLink::start`] first, always (a request
//!   alone does not reliably wake a paused fork: the split drill's run 45390380891 saw 8 of 20 first
//!   requests answered HTTP 502), then [`ForkLink::open`] once: one stream for the whole run, never a
//!   connect per call. It sends a [`Job`] and reads [`Frame`] lines back.
//! - the fork (`acpmux sub-fork-job`, [`run_job`]): applies the job's sync patch (a warm fork is
//!   brought up to the parent's files now), snapshots its checkout, runs the sub-agent's harness
//!   there (`acpmux new` then `acpmux send`, whose reply streams), and ends with the patch of what
//!   it changed.
//!
//! The real link ([`CloudLink`]) wakes the fork with cmux-cloud-api's `resume_machine`
//! (`POST /v1/machines/{id}/resume`), asks the platform for an ssh route to it with a key made
//! for this run alone (`vm.scp_endpoint`, `POST /v1/cloud/machines/{id}/ssh-endpoint`), pins the
//! host key the platform answered, and runs `acpmux sub-fork-job` over that one ssh connection.

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::time::Instant;
use tokio::io::{AsyncBufRead, AsyncBufReadExt as _, AsyncWriteExt as _};

use super::sub_fork::{Ran, SubRun, Task};

/// The most of the sub-agent's output a report keeps (its tail).
const REPORT_LIMIT: usize = 64 * 1024;

/// What the fork is asked to do, one JSON object on the stream's input.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    /// The checkout on the fork (the parent's path: the fork is a copy of its disk).
    pub checkout: PathBuf,
    /// A patch that brings the fork's files to the parent's now ([`super::sub_fork::capture`]
    /// against the tree the fork was taken at), base64; empty for a fork taken for this task.
    #[serde(default)]
    pub sync_patch: String,
    pub prompt: String,
    /// The sub-agent's session name on the fork.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// A shell command to run instead of a sub-agent (a run VM, RFD 0144 piece 3,
    /// [`super::run_vm`]): `sh -c` in `cwd`, its stdout and stderr streamed as [`Frame::Out`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Where the command runs (the agent's working directory, inside `checkout`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    /// The agent's `PATH`, so the command finds the same tools it would here (an ssh
    /// session's `PATH` is a login default).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// One line the fork writes back.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Frame {
    /// The fork's checkout is synced and snapshotted: the patch's base on the fork.
    Base(String),
    /// A line of the sub-agent's output, as it came.
    Out(String),
    /// The end: the harness's exit code and the fork's changes (base64 `capture` patch).
    Done { exit: i32, patch: String },
    /// The job could not run (a sync patch that did not apply, no git, no harness).
    Error(String),
}

impl Frame {
    pub fn line(&self) -> String {
        let mut line = serde_json::to_string(self).unwrap_or_default();
        line.push('\n');
        line
    }
}

/// The stream a fork's job answers on: its lines, until the job ends.
pub type Lines = Pin<Box<dyn AsyncBufRead + Send>>;

/// How this daemon reaches a fork.
pub trait ForkLink: Send + Sync {
    /// Wake the fork and wait until it runs. Called before anything else reaches it.
    fn start(&self, fork: &str) -> impl Future<Output = Result<(), String>> + Send;
    /// Open the one stream to the fork's job: `job` goes in, its [`Frame`] lines come out.
    fn open(&self, fork: &str, job: &Job) -> impl Future<Output = Result<Lines, String>> + Send;
}

/// What a run on a fork measured, beside [`Ran`].
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunTimes {
    /// The wake call (`start`).
    pub start_ms: u64,
    /// The run's start (wake included) to its first output line.
    pub first_output_ms: Option<u64>,
    /// The `Done` frame to the patch decoded (the files' way back, before the apply).
    pub files_back_ms: u64,
}

/// The [`SubRun`] that runs a sub-agent on a fork through `L`.
pub struct ForkRunner<L: ForkLink> {
    pub link: L,
    /// What each line of output is shown as while it runs (the placement's progress).
    pub on_output: Option<Box<dyn Fn(&str) + Send + Sync>>,
    pub times: std::sync::Mutex<RunTimes>,
}

impl<L: ForkLink> ForkRunner<L> {
    pub fn new(link: L) -> Self {
        Self { link, on_output: None, times: Default::default() }
    }

    pub fn times(&self) -> RunTimes {
        self.times.lock().map(|t| t.clone()).unwrap_or_default()
    }
}

/// A session name for the sub-agent on its fork.
fn job_name(task: &Task) -> String {
    let tree: String = task.base_tree.chars().take(12).collect();
    format!("sub-fork-{tree}")
}

impl<L: ForkLink> SubRun for ForkRunner<L> {
    async fn run(&self, fork: &str, task: &Task) -> Result<Ran, String> {
        let began = Instant::now();
        self.link.start(fork).await.map_err(|e| format!("waking the fork: {e}"))?;
        let start_ms = began.elapsed().as_millis() as u64;
        let job = Job {
            checkout: task.checkout.clone(),
            sync_patch: base64::engine::general_purpose::STANDARD.encode(&task.sync_patch),
            prompt: task.prompt.clone(),
            name: job_name(task),
            model: task.model.clone(),
            command: None,
            cwd: None,
            path: None,
        };
        let mut lines =
            self.link.open(fork, &job).await.map_err(|e| format!("reaching the fork: {e}"))?;
        let mut report = String::new();
        let mut first_output_ms = None;
        let mut line = String::new();
        loop {
            line.clear();
            let n =
                lines.read_line(&mut line).await.map_err(|e| format!("the fork's stream: {e}"))?;
            if n == 0 {
                return Err("the fork's stream ended before the job did".into());
            }
            // A line that is not a frame (a login banner) is not the job's.
            let Ok(frame) = serde_json::from_str::<Frame>(line.trim_end()) else { continue };
            match frame {
                Frame::Base(_) => {}
                Frame::Out(text) => {
                    first_output_ms.get_or_insert(began.elapsed().as_millis() as u64);
                    if let Some(show) = &self.on_output {
                        show(&text);
                    }
                    report.push_str(&text);
                    report.push('\n');
                    if report.len() > REPORT_LIMIT * 2 {
                        let cut = report.len() - REPORT_LIMIT;
                        let cut =
                            (cut..report.len()).find(|i| report.is_char_boundary(*i)).unwrap_or(0);
                        report.drain(..cut);
                    }
                }
                Frame::Error(e) => return Err(format!("on the fork: {e}")),
                Frame::Done { exit, patch } => {
                    let back = Instant::now();
                    let patch = base64::engine::general_purpose::STANDARD
                        .decode(patch.as_bytes())
                        .map_err(|e| format!("the fork's patch: {e}"))?;
                    if exit != 0 {
                        return Err(format!("the sub-agent on the fork exited {exit}"));
                    }
                    let files_back_ms = back.elapsed().as_millis() as u64;
                    if let Ok(mut t) = self.times.lock() {
                        *t = RunTimes { start_ms, first_output_ms, files_back_ms };
                    }
                    if report.len() > REPORT_LIMIT {
                        let cut = report.len() - REPORT_LIMIT;
                        let cut =
                            (cut..report.len()).find(|i| report.is_char_boundary(*i)).unwrap_or(0);
                        report.drain(..cut);
                    }
                    return Ok(Ran {
                        report: report.trim_end().to_owned(),
                        patch,
                        first_output_ms,
                        files_back_ms: Some(files_back_ms),
                    });
                }
            }
        }
    }
}

/// How the fork's job runs the sub-agent: `out` gets each output line as it comes; answers the
/// harness's exit code. The real one is [`acpmux_harness`]; tests pass their own.
pub trait Harness {
    fn run(
        &self,
        job: &Job,
        out: &mut (dyn FnMut(&str) + Send),
    ) -> impl Future<Output = Result<i32, String>> + Send;
}

/// The fork's end of the wire: sync, snapshot, run, capture, each step a [`Frame`] on `w`.
pub async fn run_job<H: Harness, W: tokio::io::AsyncWrite + Unpin + Send>(
    job: &Job,
    harness: &H,
    w: &mut W,
) -> std::io::Result<()> {
    let frame = Frame::Error;
    let sync = match base64::engine::general_purpose::STANDARD.decode(job.sync_patch.as_bytes()) {
        Ok(sync) => sync,
        Err(e) => return w.write_all(frame(format!("sync patch: {e}")).line().as_bytes()).await,
    };
    if let Err(e) = super::sub_fork::apply(&job.checkout, &sync) {
        return w.write_all(frame(format!("sync: {e}")).line().as_bytes()).await;
    }
    let base = match super::sub_fork::snapshot(&job.checkout) {
        Ok(base) => base,
        Err(e) => return w.write_all(frame(format!("snapshot: {e}")).line().as_bytes()).await,
    };
    w.write_all(Frame::Base(base.clone()).line().as_bytes()).await?;
    w.flush().await?;
    // The harness's lines go out as they come, through a channel the writer drains.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let mut push = move |l: &str| {
        let _ = tx.send(l.to_owned());
    };
    let ran = harness.run(job, &mut push);
    tokio::pin!(ran);
    let exit = loop {
        tokio::select! {
            biased;
            Some(l) = rx.recv() => {
                w.write_all(Frame::Out(l).line().as_bytes()).await?;
                w.flush().await?;
            }
            exit = &mut ran => break exit,
        }
    };
    while let Ok(l) = rx.try_recv() {
        w.write_all(Frame::Out(l).line().as_bytes()).await?;
    }
    let exit = match exit {
        Ok(code) => code,
        Err(e) => return w.write_all(frame(format!("harness: {e}")).line().as_bytes()).await,
    };
    let out = match super::sub_fork::capture(&job.checkout, &base) {
        Ok(patch) => {
            Frame::Done { exit, patch: base64::engine::general_purpose::STANDARD.encode(patch) }
        }
        Err(e) => frame(format!("capture: {e}")),
    };
    w.write_all(out.line().as_bytes()).await?;
    w.flush().await
}

/// The fork's harness: its own acpmux, `new --detach` in the checkout, then `send`, whose reply
/// streams on stdout until the turn ends.
pub struct AcpmuxHarness {
    pub acpmux: PathBuf,
}

pub fn acpmux_harness() -> AcpmuxHarness {
    AcpmuxHarness { acpmux: std::env::current_exe().unwrap_or_else(|_| PathBuf::from("acpmux")) }
}

impl Harness for AcpmuxHarness {
    async fn run(&self, job: &Job, out: &mut (dyn FnMut(&str) + Send)) -> Result<i32, String> {
        let mut new = cmux_process::Command::new(&self.acpmux);
        new.arg("new").arg("--detach").arg("--quiet").arg("--name").arg(&job.name);
        new.arg("--cwd").arg(&job.checkout);
        if let Some(model) = &job.model {
            new.arg("--model").arg(model);
        }
        new.stdin(cmux_process::Stdio::null());
        let made = output(new).await.map_err(|e| format!("acpmux new: {e}"))?;
        if !made.status.success() {
            return Err(format!("acpmux new: {}", String::from_utf8_lossy(&made.stderr).trim()));
        }
        // Owned: dropped while it runs (the turn cancelled), it ends with its handle.
        let mut send = cmux_process::Command::new(&self.acpmux);
        send.arg("send").arg(&job.name).arg("-");
        send.stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::inherit());
        let mut child = send.spawn().map_err(|e| format!("acpmux send: {e}"))?;
        if let Some(stdin) = child.stdin.take() {
            let mut stdin = tokio::process::ChildStdin::from_std(stdin)
                .map_err(|e| format!("acpmux send: {e}"))?;
            stdin
                .write_all(job.prompt.as_bytes())
                .await
                .map_err(|e| format!("acpmux send: {e}"))?;
        }
        let stdout = child.stdout.take().ok_or("acpmux send: no stdout")?;
        let stdout = tokio::process::ChildStdout::from_std(stdout)
            .map_err(|e| format!("acpmux send: {e}"))?;
        let mut lines = tokio::io::BufReader::new(stdout).lines();
        while let Some(l) = lines.next_line().await.map_err(|e| format!("acpmux send: {e}"))? {
            out(&l);
        }
        // Its stdout ended, so it is exiting: the wait is short, off the runtime's workers.
        let status = tokio::task::spawn_blocking(move || child.wait())
            .await
            .map_err(|e| format!("acpmux send: {e}"))?
            .map_err(|e| format!("acpmux send: {e}"))?;
        Ok(status.code().unwrap_or(-1))
    }
}

/// `acpmux sub-fork-job`: the job on stdin, its frames on stdout.
pub async fn job_main() -> anyhow::Result<()> {
    let mut input = Vec::new();
    tokio::io::AsyncReadExt::read_to_end(&mut tokio::io::stdin(), &mut input).await?;
    let mut stdout = tokio::io::stdout();
    match serde_json::from_slice::<Job>(&input) {
        Ok(job) if job.command.is_some() => {
            run_job(&job, &super::run_vm::ShellHarness, &mut stdout).await?
        }
        Ok(job) => run_job(&job, &acpmux_harness(), &mut stdout).await?,
        Err(e) => {
            stdout.write_all(Frame::Error(format!("not a job: {e}")).line().as_bytes()).await?
        }
    }
    stdout.flush().await?;
    Ok(())
}

/// The Cloud link: `resume_machine`, then one ssh connection on the route the platform answers
/// for a key made for this run.
pub struct CloudLink {
    pub request: super::sub_fork::CloudRequest,
    /// The key, known-hosts file and the ssh process live here for the run.
    dir: std::sync::Mutex<Option<tempfile::TempDir>>,
}

impl CloudLink {
    pub fn new(request: super::sub_fork::CloudRequest) -> Self {
        Self { request, dir: std::sync::Mutex::new(None) }
    }

    #[cfg(unix)]
    fn failure(&self, f: cmux_cloud_api::Failure) -> String {
        cmux_cloud_api::scrub(cmux_cloud_api::answer_line(&Err(f)), &self.request)
    }
}

/// The ssh route an `ssh-endpoint` answer gives: `(host, port, user, host key)`.
pub fn ssh_route(endpoint: &Value) -> Result<(String, u16, String, String), String> {
    let text = |a: &str, b: &str| {
        endpoint.get(a).or_else(|| endpoint.get(b)).and_then(Value::as_str).map(str::to_owned)
    };
    let host = text("host", "host").filter(|h| {
        !h.is_empty()
            && !h.starts_with('-')
            && h.bytes().all(|b| b.is_ascii_alphanumeric() || b".-:[]".contains(&b))
    });
    let host = host.ok_or("the ssh route has no usable host")?;
    let port = endpoint.get("port").and_then(Value::as_u64).and_then(|p| u16::try_from(p).ok());
    let user = text("username", "username").filter(|u| {
        !u.is_empty()
            && !u.starts_with('-')
            && u.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-+.".contains(&b))
    });
    let key = text("hostPublicKey", "host_public_key")
        .filter(|k| k.starts_with("ssh-ed25519 ") && !k.contains('\n'));
    Ok((
        host,
        port.ok_or("the ssh route has no port")?,
        user.ok_or("the ssh route has no usable user")?,
        key.ok_or("the ssh route has no ed25519 host key")?,
    ))
}

/// Windows: no Cloud request exists there ([`super::sub_fork::CloudRequest`]).
#[cfg(not(unix))]
impl ForkLink for CloudLink {
    async fn start(&self, _fork: &str) -> Result<(), String> {
        match self.request {}
    }

    async fn open(&self, _fork: &str, _job: &Job) -> Result<Lines, String> {
        match self.request {}
    }
}

#[cfg(unix)]
impl ForkLink for CloudLink {
    async fn start(&self, fork: &str) -> Result<(), String> {
        cmux_cloud_api::machine_resume::resume_machine(&self.request, fork)
            .await
            .map(|_| ())
            .map_err(|f| self.failure(f))
    }

    async fn open(&self, fork: &str, job: &Job) -> Result<Lines, String> {
        let dir = tempfile::tempdir().map_err(|e| format!("key folder: {e}"))?;
        let key = dir.path().join("id");
        let mut keygen = cmux_process::Command::new("ssh-keygen");
        keygen
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "cmux-sub-fork", "-f"])
            .arg(&key)
            .stdin(cmux_process::Stdio::null());
        let made = output(keygen).await.map_err(|e| format!("ssh-keygen: {e}"))?;
        if !made.status.success() {
            return Err(format!("ssh-keygen: {}", String::from_utf8_lossy(&made.stderr).trim()));
        }
        let public = std::fs::read_to_string(key.with_extension("pub"))
            .map_err(|e| format!("ssh key: {e}"))?;
        let mut request = self.request.clone();
        request.call = "vm.scp_endpoint".into();
        request.auth = cmux_cloud_api::Auth::Worker;
        request.args = json!({"id": fork, "publicKey": public.trim()})
            .as_object()
            .cloned()
            .unwrap_or_default();
        let endpoint = cmux_cloud_api::perform(&request, zeroize::Zeroizing::new(Vec::new()))
            .await
            .map_err(|f| self.failure(f))?;
        let (host, port, user, host_key) = ssh_route(&endpoint)?;
        let known = dir.path().join("known_hosts");
        let name = if port == 22 { host.clone() } else { format!("[{host}]:{port}") };
        std::fs::write(&known, format!("{name} {host_key}\n"))
            .map_err(|e| format!("known hosts: {e}"))?;
        let mut ssh = cmux_process::Command::new("ssh");
        ssh.arg("-i").arg(&key);
        ssh.arg("-o").arg(format!("UserKnownHostsFile={}", known.display()));
        for opt in [
            "IdentitiesOnly=yes",
            "StrictHostKeyChecking=yes",
            "BatchMode=yes",
            "ConnectTimeout=30",
            "ServerAliveInterval=15",
            "ServerAliveCountMax=4",
        ] {
            ssh.arg("-o").arg(opt);
        }
        ssh.arg("-p").arg(port.to_string()).arg(format!("{user}@{host}"));
        ssh.arg("acpmux sub-fork-job");
        ssh.stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null());
        let mut child = ssh.spawn().map_err(|e| format!("ssh: {e}"))?;
        let stdin = child.stdin.take().ok_or("ssh: no stdin")?;
        let mut stdin =
            tokio::process::ChildStdin::from_std(stdin).map_err(|e| format!("ssh: {e}"))?;
        let body = serde_json::to_vec(job).map_err(|e| format!("job: {e}"))?;
        stdin.write_all(&body).await.map_err(|e| format!("ssh: {e}"))?;
        drop(stdin);
        let stdout = child.stdout.take().ok_or("ssh: no stdout")?;
        let stdout =
            tokio::process::ChildStdout::from_std(stdout).map_err(|e| format!("ssh: {e}"))?;
        if let Ok(mut held) = self.dir.lock() {
            *held = Some(dir);
        }
        // The child lives as long as its stream: dropping the stream kills ssh.
        Ok(Box::pin(Owned { reader: tokio::io::BufReader::new(stdout), _child: child }))
    }
}

/// `cmd`'s output, waited for off the runtime's workers.
async fn output(mut cmd: cmux_process::Command) -> std::io::Result<cmux_process::Output> {
    tokio::task::spawn_blocking(move || cmd.output()).await.map_err(std::io::Error::other)?
}

/// A reader that keeps its process alive (and kills it when dropped).
struct Owned<R> {
    reader: R,
    _child: cmux_process::Child,
}

impl<R: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for Owned<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        Pin::new(&mut self.reader).poll_read(cx, buf)
    }
}

impl<R: AsyncBufRead + Unpin> AsyncBufRead for Owned<R> {
    fn poll_fill_buf(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<&[u8]>> {
        Pin::new(&mut self.get_mut().reader).poll_fill_buf(cx)
    }
    fn consume(mut self: Pin<&mut Self>, amt: usize) {
        Pin::new(&mut self.reader).consume(amt)
    }
}

#[cfg(test)]
#[path = "sub_fork_run_tests.rs"]
mod tests;
