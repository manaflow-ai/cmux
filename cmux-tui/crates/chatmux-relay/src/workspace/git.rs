//! Read-only git workspace ops (moved out of workspace.rs): `git_status` and
//! `git_diff`, with the bounded git child-process, stdout and stderr handling
//! they share.

use super::*;

// ---------------------------------------------------------------------------
// Git ops (shell git via tokio::process — git ships in every image and on
// every dev machine; kill_on_drop keeps an abandoned op from outliving its
// timeout)
// ---------------------------------------------------------------------------

/// Environment for the read-only git helpers.
///
/// Git can load configuration and invoke helper programs from its inherited
/// environment. A relay process also carries credentials for the control
/// plane, so passing that environment to git would expose those credentials to
/// a repository-controlled helper. Keep the same small baseline used by the
/// action and PTY runners, then disable system configuration and interactive
/// prompts explicitly.
fn git_environment_from(
    base: &std::collections::HashMap<String, String>,
) -> std::collections::HashMap<String, String> {
    let mut environment = scrubbed_env(base);
    environment.insert("GIT_CONFIG_NOSYSTEM".to_owned(), "1".to_owned());
    environment.insert("GIT_TERMINAL_PROMPT".to_owned(), "0".to_owned());
    environment.insert("GIT_PAGER".to_owned(), "cat".to_owned());
    environment
}

fn git_environment() -> std::collections::HashMap<String, String> {
    git_environment_from(&process_env_snapshot())
}

fn git_command(root: &Path, args: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(root)
        .args(args)
        .env_clear()
        .envs(git_environment())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", if cfg!(windows) { "NUL" } else { "/dev/null" })
        .env("LC_ALL", "C")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    {
        // Git may launch helpers which inherit its pipes. A private process
        // group lets cancellation terminate the whole tree without an unsafe
        // pre_exec hook.
        command.process_group(0);
    }
    command
}

fn git_refusal(context: &str, stderr: &[u8]) -> Refusal {
    let text = String::from_utf8_lossy(stderr);
    let text = text.trim();
    let capped: String = text.chars().take(500).collect();
    if text.contains("not a git repository") {
        Refusal::new(wire::WorkspaceErrorCode::NotARepository, format!("{context}: {capped}"))
    } else {
        Refusal::failed(format!("{context}: {capped}"))
    }
}

const GIT_DIFF_PREFIX_BYTES: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
enum BoundedGitDiffLine {
    Complete(String),
    TooLong { prefix: [u8; GIT_DIFF_PREFIX_BYTES], length: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GitDiffLineKind {
    File,
    Addition,
    Deletion,
    Other,
}

fn classify_git_diff_line(bytes: &[u8]) -> GitDiffLineKind {
    if bytes.starts_with(b"diff --git ") {
        GitDiffLineKind::File
    } else if bytes.first() == Some(&b'+') && !bytes.starts_with(b"+++") {
        GitDiffLineKind::Addition
    } else if bytes.first() == Some(&b'-') && !bytes.starts_with(b"---") {
        GitDiffLineKind::Deletion
    } else {
        GitDiffLineKind::Other
    }
}

fn retain_git_diff_prefix(
    prefix: &mut [u8; GIT_DIFF_PREFIX_BYTES],
    length: &mut usize,
    bytes: &[u8],
) {
    let available = GIT_DIFF_PREFIX_BYTES.saturating_sub(*length);
    let take = available.min(bytes.len());
    prefix[*length..*length + take].copy_from_slice(&bytes[..take]);
    *length += take;
}

/// Read one diff line without allowing a missing newline to grow the buffer
/// without bound. `fill_buf` is cancellation-safe; consume every byte of an
/// over-limit line without retaining it, so the caller can keep calculating
/// the full diff stat while dropping the patch safely.
async fn read_bounded_git_diff_line<R>(
    reader: &mut R,
    line: &mut Vec<u8>,
    maximum: usize,
) -> std::io::Result<Option<BoundedGitDiffLine>>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    use tokio::io::AsyncBufReadExt as _;

    line.clear();
    let mut too_long = false;
    let mut prefix = [0_u8; GIT_DIFF_PREFIX_BYTES];
    let mut prefix_length = 0_usize;
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            if too_long {
                return Ok(Some(BoundedGitDiffLine::TooLong {
                    prefix,
                    length: prefix_length as u8,
                }));
            }
            return if line.is_empty() {
                Ok(None)
            } else {
                decode_git_diff_line(line).map(|line| Some(BoundedGitDiffLine::Complete(line)))
            };
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let take = newline.map_or(buffer.len(), |index| index + 1);
        if too_long {
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            reader.consume(take);
        } else if line.len().saturating_add(take) > maximum {
            // Consume this chunk, including a possible newline, and then
            // report a marker instead of returning an error. This keeps the
            // stream aligned for later lines and bounds retained memory.
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            reader.consume(take);
            line.clear();
            too_long = true;
        } else {
            retain_git_diff_prefix(&mut prefix, &mut prefix_length, &buffer[..take]);
            line.extend_from_slice(&buffer[..take]);
            reader.consume(take);
        }
        if newline.is_some() {
            return if too_long {
                Ok(Some(BoundedGitDiffLine::TooLong { prefix, length: prefix_length as u8 }))
            } else {
                decode_git_diff_line(line).map(|line| Some(BoundedGitDiffLine::Complete(line)))
            };
        }
    }
}

fn decode_git_diff_line(line: &mut Vec<u8>) -> std::io::Result<String> {
    if line.last() == Some(&b'\n') {
        line.pop();
        if line.last() == Some(&b'\r') {
            line.pop();
        }
    }
    std::str::from_utf8(line)
        .map(str::to_owned)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

/// Own stderr draining for one Git process. Retain only a bounded prefix, but
/// continue reading after the cap so Git cannot block on a full stderr pipe.
pub(super) struct GitStderrDrain {
    task: tokio::task::JoinHandle<std::io::Result<()>>,
    retained: Arc<std::sync::Mutex<Vec<u8>>>,
}

struct GitStderrResult {
    bytes: Vec<u8>,
    complete: bool,
}

impl Drop for GitStderrDrain {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl GitStderrDrain {
    pub(super) fn start<R>(mut stderr: R) -> GitStderrDrain
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
    {
        let retained = Arc::new(std::sync::Mutex::new(Vec::new()));
        let task_retained = Arc::clone(&retained);
        let task = tokio::spawn(async move {
            let mut buffer = [0_u8; 8 * 1024];
            loop {
                let read = stderr.read(&mut buffer).await?;
                if read == 0 {
                    break;
                }
                if let Ok(mut retained) = task_retained.lock()
                    && retained.len() < GIT_STDERR_MAX_BYTES
                {
                    let keep = (GIT_STDERR_MAX_BYTES - retained.len()).min(read);
                    retained.extend_from_slice(&buffer[..keep]);
                }
            }
            Ok(())
        });
        GitStderrDrain { task, retained }
    }

    async fn finish(mut self) -> Result<GitStderrResult, Refusal> {
        match tokio::time::timeout(GIT_STDERR_DRAIN_TIMEOUT, &mut self.task).await {
            Ok(result) => result
                .map_err(|error| Refusal::failed(format!("git stderr drain failed: {error}")))?
                .map_err(|error| Refusal::failed(format!("git stderr read failed: {error}")))?,
            Err(_) => {
                self.task.abort();
                let _ = (&mut self.task).await;
                return Ok(GitStderrResult {
                    bytes: self
                        .retained
                        .lock()
                        .map(|retained| retained.clone())
                        .unwrap_or_default(),
                    complete: false,
                });
            }
        }
        Ok(GitStderrResult {
            bytes: self.retained.lock().map(|retained| retained.clone()).unwrap_or_default(),
            complete: true,
        })
    }
}

/// Keep the process-group identity armed until the direct child has been
/// awaited. Drop can signal the group, but it cannot await, so owned async
/// paths must call `stop_git`/`wait_git_until` before disarming this guard.
pub(super) struct GitProcessGuard(Option<u32>);

impl GitProcessGuard {
    pub(super) fn new(child: &tokio::process::Child) -> GitProcessGuard {
        GitProcessGuard(child.id())
    }

    fn kill_group(&self) {
        #[cfg(unix)]
        if let Some(pid) = self.0 {
            // SAFETY: `pid` is the process-group leader we just spawned.
            unsafe {
                let _ = libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
            }
        }
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for GitProcessGuard {
    fn drop(&mut self) {
        if self.0.is_some() {
            self.kill_group();
        }
        // Tokio's kill_on_drop handles the direct child. Async owners call
        // `wait_git_until` before this guard is disarmed to provide deterministic
        // reaping; Drop is only an emergency descendant-kill fallback.
    }
}

fn disarm_if_reaped(child: &tokio::process::Child, guard: &mut GitProcessGuard) {
    if child.id().is_none() {
        guard.disarm();
    }
}

/// Terminate the process group and await the direct child within a bound.
async fn stop_git(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // SAFETY: the child was spawned with `process_group(0)`.
        unsafe {
            let _ = libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
        }
    }
    let _ = child.start_kill();
    let _ = tokio::time::timeout(GIT_STOP_TIMEOUT, child.wait()).await;
}

fn remaining_git_time(deadline: std::time::Instant) -> Option<Duration> {
    // Normal stdout reads use the complete request budget. Keep short caps in
    // `bounded_git_time` for post-cancellation cleanup and child reaping only.
    deadline.checked_duration_since(std::time::Instant::now())
}

fn bounded_git_time(deadline: std::time::Instant, cap: Duration) -> Option<Duration> {
    Some(remaining_git_time(deadline)?.min(cap))
}

pub(super) async fn wait_git_until(
    child: &mut tokio::process::Child,
    deadline: std::time::Instant,
) -> Result<std::process::ExitStatus, Refusal> {
    let Some(timeout) = bounded_git_time(deadline, GIT_CHILD_WAIT_TIMEOUT) else {
        stop_git(child).await;
        return Err(Refusal::failed("git operation deadline exceeded"));
    };
    match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(status)) => Ok(status),
        Ok(Err(error)) => Err(Refusal::failed(format!("could not wait for git: {error}"))),
        Err(_) => {
            stop_git(child).await;
            Err(Refusal::failed("git operation deadline exceeded"))
        }
    }
}

async fn finish_git_stderr(
    stderr_task: Option<GitStderrDrain>,
    child: &mut tokio::process::Child,
    guard: &mut GitProcessGuard,
    deadline: std::time::Instant,
    operation: &str,
) -> Result<Vec<u8>, Refusal> {
    let Some(task) = stderr_task else { return Ok(Vec::new()) };
    let Some(timeout) = bounded_git_time(deadline, GIT_STDERR_DRAIN_TIMEOUT) else {
        guard.kill_group();
        stop_git(child).await;
        disarm_if_reaped(child, guard);
        return Err(Refusal::failed(format!("{operation} operation deadline exceeded")));
    };
    let result = match tokio::time::timeout(timeout, task.finish()).await {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            return Err(error);
        }
        Err(_) => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            return Err(Refusal::failed(format!("{operation} operation deadline exceeded")));
        }
    };
    match result {
        GitStderrResult { bytes, complete: true } => Ok(bytes),
        GitStderrResult { complete: false, .. } => {
            guard.kill_group();
            stop_git(child).await;
            disarm_if_reaped(child, guard);
            Err(Refusal::failed(format!("{operation} stderr drain timed out")))
        }
    }
}

/// Kill and reap after a read/stream error. The stderr task is finished while
/// the process-group identity is still owned by the live child handle.
pub(super) async fn abort_git_operation(
    stderr_task: Option<GitStderrDrain>,
    child: &mut tokio::process::Child,
    guard: &mut GitProcessGuard,
) {
    guard.kill_group();
    let _ = child.start_kill();
    if let Some(task) = stderr_task {
        let _ = task.finish().await;
    }
    stop_git(child).await;
    disarm_if_reaped(child, guard);
}

/// Two-column XY code in the porcelain v1 spelling ("M " not "M.") — the
/// wire schema pins v1's verbatim codes.
fn porcelain_v1_xy(xy: &str) -> String {
    xy.chars().map(|column| if column == '.' { ' ' } else { column }).collect()
}

pub(super) async fn run_git_status_with_cancel_until(
    scope: &Scope,
    cancellation: &CancellationToken,
    deadline: std::time::Instant,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = scope.existing_workdir()?;
    let mut child = git_command(
        &root,
        &["-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch", "-z"],
    )
    .spawn()
    .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    let mut process_guard = GitProcessGuard::new(&child);
    let Some(stdout) = child.stdout.take() else {
        stop_git(&mut child).await;
        disarm_if_reaped(&child, &mut process_guard);
        return Err(Refusal::failed("git status produced no stdout pipe"));
    };
    let mut stderr_task = child.stderr.take().map(GitStderrDrain::start);
    const STATUS_MAX_BYTES: usize = 16 * 1024 * 1024;
    let mut stdout_bytes = Vec::new();
    let read_limit = STATUS_MAX_BYTES.saturating_add(1);
    let read_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "git status cancelled",
        )),
        result = async {
            let Some(timeout) = remaining_git_time(deadline) else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "git status operation deadline exceeded",
                ));
            };
            tokio::time::timeout(
                timeout,
                stdout.take(read_limit as u64).read_to_end(&mut stdout_bytes),
            )
            .await
            .map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "git status stdout drain timed out",
                )
            })
            .and_then(|result| result)
        } => result,
    };
    if let Err(error) = read_result {
        abort_git_operation(stderr_task.take(), &mut child, &mut process_guard).await;
        return Err(Refusal::failed(format!("could not read git status: {error}")));
    }
    let stdout_capped = stdout_bytes.len() > STATUS_MAX_BYTES;
    if stdout_capped {
        stdout_bytes.truncate(STATUS_MAX_BYTES);
        process_guard.kill_group();
        let _ = child.start_kill();
    }
    let stderr_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = finish_git_stderr(
            stderr_task.take(),
            &mut child,
            &mut process_guard,
            deadline,
            "git status",
        ) => Some(result),
    };
    let stderr = match stderr_result {
        Some(result) => result?,
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git status cancelled"));
        }
    };
    let status_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = wait_git_until(&mut child, deadline) => Some(result),
    };
    let status = match status_result {
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git status cancelled"));
        }
        Some(Ok(status)) => status,
        Some(Err(error)) => {
            disarm_if_reaped(&child, &mut process_guard);
            return Err(error);
        }
    };
    process_guard.disarm();
    if !status.success() {
        return Err(git_refusal("git status failed", &stderr));
    }
    let mut branch: Option<String> = None;
    let mut upstream: Option<String> = None;
    let mut ahead: i64 = 0;
    let mut behind: i64 = 0;
    let mut entries: Vec<wire::GitStatusEntry> = Vec::new();
    let mut truncated = stdout_capped;
    let mut chunks = stdout_bytes
        .split(|byte| *byte == 0)
        .map(String::from_utf8_lossy)
        .collect::<Vec<_>>()
        .into_iter();
    while let Some(chunk) = chunks.next() {
        if chunk.is_empty() {
            continue;
        }
        if let Some(head) = chunk.strip_prefix("# branch.head ") {
            if head != "(detached)" {
                branch = Some(head.to_owned());
            }
            continue;
        }
        if let Some(name) = chunk.strip_prefix("# branch.upstream ") {
            upstream = Some(name.to_owned());
            continue;
        }
        if let Some(ab) = chunk.strip_prefix("# branch.ab ") {
            for part in ab.split(' ') {
                if let Some(count) = part.strip_prefix('+') {
                    ahead = count.parse().unwrap_or(0);
                } else if let Some(count) = part.strip_prefix('-') {
                    behind = count.parse().unwrap_or(0);
                }
            }
            continue;
        }
        if chunk.starts_with("# ") {
            continue;
        }
        let entry = if let Some(rest) = chunk.strip_prefix("1 ") {
            // 1 XY sub mH mI mW hH hI path
            let mut fields = rest.splitn(8, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(6).unwrap_or_default().to_owned();
            Some((path, porcelain_v1_xy(&xy), None))
        } else if let Some(rest) = chunk.strip_prefix("2 ") {
            // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
            let mut fields = rest.splitn(9, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(7).unwrap_or_default().to_owned();
            let orig = chunks.next().map(|orig| orig.into_owned()).unwrap_or_default();
            Some((path, porcelain_v1_xy(&xy), Some(orig)))
        } else if let Some(rest) = chunk.strip_prefix("u ") {
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            let mut fields = rest.splitn(10, ' ');
            let xy = fields.next().unwrap_or_default().to_owned();
            let path = fields.nth(8).unwrap_or_default().to_owned();
            Some((path, xy, None))
        } else {
            chunk.strip_prefix("? ").map(|path| (path.to_owned(), "??".to_owned(), None))
        };
        let Some((path, status, orig_path)) = entry else { continue };
        if path.is_empty() || status.is_empty() {
            continue;
        }
        if entries.len() >= STATUS_MAX_ENTRIES {
            truncated = true;
            break;
        }
        entries.push(wire::GitStatusEntry {
            path,
            status,
            orig_path: orig_path.filter(|orig| !orig.is_empty()),
        });
    }
    Ok(wire::WorkspaceResultBody::GitStatus(wire::GitStatusResult {
        op: wire::TagGitStatus::GitStatus,
        branch,
        upstream,
        ahead,
        behind,
        entries,
        truncated,
    }))
}

pub(super) async fn run_git_diff_with_cancel_until(
    scope: &Scope,
    op: &wire::GitDiffOp,
    cancellation: &CancellationToken,
    deadline: std::time::Instant,
) -> Result<wire::WorkspaceResultBody, Refusal> {
    let root = scope.existing_workdir()?;
    let base = op.base.as_deref().unwrap_or("HEAD");
    if base.is_empty() || base.starts_with('-') {
        return Err(Refusal::failed("invalid diff base"));
    }
    let context = op.context_lines.map(|lines| format!("-U{}", lines.clamp(0, 100)));
    let mut args: Vec<&str> =
        vec!["-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv", base];
    if let Some(context) = context.as_deref() {
        args.push(context);
    }
    let paths = op.paths.as_deref().unwrap_or_default();
    if !paths.is_empty() {
        args.push("--");
        for path in paths {
            scope.validate_git_pathspec(path)?;
            args.push(path);
        }
    }
    let mut child = git_command(&root, &args)
        .spawn()
        .map_err(|error| Refusal::failed(format!("could not run git: {error}")))?;
    let mut process_guard = GitProcessGuard::new(&child);
    // Stream stdout: the stat counts the FULL diff, but the patch buffer
    // drops whole files past DIFF_MAX_BYTES so memory and the wire stay
    // bounded even for a pathological working tree.
    let Some(stdout) = child.stdout.take() else {
        stop_git(&mut child).await;
        disarm_if_reaped(&child, &mut process_guard);
        return Err(Refusal::failed("git diff produced no stdout pipe"));
    };
    let mut stderr_task = child.stderr.take().map(GitStderrDrain::start);
    let mut reader = tokio::io::BufReader::new(stdout);
    let mut line_bytes = Vec::with_capacity(GIT_DIFF_LINE_MAX_BYTES.min(8 * 1024));
    let mut patch = String::new();
    let mut current_file_start = 0_usize;
    let mut capped = false;
    let mut truncated = false;
    let mut files: i64 = 0;
    let mut additions: i64 = 0;
    let mut deletions: i64 = 0;
    loop {
        let line = tokio::select! {
            biased;
            _ = cancellation.cancelled() => {
                abort_git_operation(
                    stderr_task.take(),
                    &mut child,
                    &mut process_guard,
                )
                .await;
                return Err(Refusal::failed("git diff cancelled"));
            }
            result = async {
                let Some(timeout) = remaining_git_time(deadline) else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "git diff operation deadline exceeded",
                    ));
                };
                tokio::time::timeout(
                    timeout,
                    read_bounded_git_diff_line(
                        &mut reader,
                        &mut line_bytes,
                        GIT_DIFF_LINE_MAX_BYTES,
                    ),
                )
                .await
                .map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "git diff stdout drain timed out",
                    )
                })
                .and_then(|result| result)
            } => match result {
                Ok(Some(line)) => line,
                Ok(None) => break,
                Err(error) => {
                    abort_git_operation(
                        stderr_task.take(),
                        &mut child,
                        &mut process_guard,
                    )
                    .await;
                    return Err(Refusal::failed(format!("could not read git diff: {error}")));
                }
            },
        };
        if let BoundedGitDiffLine::TooLong { prefix, length } = line {
            let prefix = &prefix[..usize::from(length)];
            match classify_git_diff_line(prefix) {
                GitDiffLineKind::File => files += 1,
                GitDiffLineKind::Addition => additions += 1,
                GitDiffLineKind::Deletion => deletions += 1,
                GitDiffLineKind::Other => {}
            }
            if !capped {
                // Drop the partial file: a caller must never see half a
                // file's hunks (parsePatchFiles input). Continue reading so
                // stats cover the complete Git output.
                patch.truncate(current_file_start);
                capped = true;
                truncated = true;
            }
            continue;
        }
        let BoundedGitDiffLine::Complete(line) = line else {
            unreachable!("handled all bounded diff line variants");
        };
        match classify_git_diff_line(line.as_bytes()) {
            GitDiffLineKind::File => {
                files += 1;
                if !capped {
                    current_file_start = patch.len();
                }
            }
            GitDiffLineKind::Addition => additions += 1,
            GitDiffLineKind::Deletion => deletions += 1,
            GitDiffLineKind::Other => {}
        }
        if !capped {
            if patch.len().saturating_add(line.len()).saturating_add(1) > DIFF_MAX_BYTES {
                // Drop the partial file: a caller must never see half a
                // file's hunks (parsePatchFiles input).
                patch.truncate(current_file_start);
                capped = true;
                truncated = true;
            } else {
                patch.push_str(&line);
                patch.push('\n');
            }
        }
    }
    let stderr_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = finish_git_stderr(
            stderr_task.take(),
            &mut child,
            &mut process_guard,
            deadline,
            "git diff",
        ) => Some(result),
    };
    let stderr = match stderr_result {
        Some(result) => result?,
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git diff cancelled"));
        }
    };
    let status_result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = wait_git_until(&mut child, deadline) => Some(result),
    };
    let status = match status_result {
        None => {
            abort_git_operation(None, &mut child, &mut process_guard).await;
            return Err(Refusal::failed("git diff cancelled"));
        }
        Some(Ok(status)) => status,
        Some(Err(error)) => {
            disarm_if_reaped(&child, &mut process_guard);
            return Err(error);
        }
    };
    process_guard.disarm();
    if !status.success() {
        return Err(git_refusal("git diff failed", &stderr));
    }
    Ok(wire::WorkspaceResultBody::GitDiff(wire::GitDiffResult {
        op: wire::TagGitDiff::GitDiff,
        patch,
        stat: wire::GitDiffStat { files, additions, deletions },
        truncated,
    }))
}
