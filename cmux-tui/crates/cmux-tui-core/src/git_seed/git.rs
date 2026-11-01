//! How a seed runs git: the environment and credential order of
//! CloudMachineRepo's `repo` step (Packages/macOS/CmuxNext/Sources/
//! CmuxNextCloud/Bootstrap/CloudMachineRepo.swift), progress read from
//! `--progress`, and the failures a seed tells apart.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The Cloud agent's socket: `cmux github credential` mints a short
/// repo-scoped token through it.
const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// Lines of git's stderr kept for the error and its classification.
const KEPT_LINES: usize = 40;
/// Longest error text in a status answer.
const MAX_ERROR_CHARS: usize = 400;

/// One GitHub path of the machine, in the order the `repo` step tries them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Credential {
    /// The lane broker's helper (`!$HOME/.local/bin/lane-gh-credential`).
    Lane(String),
    /// `!'<cmux>' github credential`.
    CmuxGithub(String),
    Anonymous,
}

impl Credential {
    fn helper(&self) -> Option<&str> {
        match self {
            Self::Lane(helper) | Self::CmuxGithub(helper) => Some(helper),
            Self::Anonymous => None,
        }
    }
}

/// The machine's GitHub paths, in order: the lane helper when it is the
/// configured github.com helper, `cmux github credential` when the Cloud
/// agent's socket exists and `cmux` is on PATH, then none.
#[must_use]
pub fn machine_credentials() -> Vec<Credential> {
    let mut credentials = Vec::new();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let program = home.join(".local/bin/lane-gh-credential");
        let lane = format!("!{}", program.display());
        if executable(&program) && global_github_helpers().contains(&lane) {
            credentials.push(Credential::Lane(lane));
        }
    }
    let socket = std::fs::symlink_metadata(AGENT_SOCKET).is_ok_and(|meta| {
        use std::os::unix::fs::FileTypeExt as _;
        meta.file_type().is_socket()
    });
    if socket && let Some(cmux) = on_path("cmux") {
        let quoted = cmux.display().to_string().replace('\'', r"'\''");
        credentials.push(Credential::CmuxGithub(format!("!'{quoted}' github credential")));
    }
    credentials.push(Credential::Anonymous);
    credentials
}

/// `git config --global --includes --get-all credential.https://github.com.helper`.
fn global_github_helpers() -> Vec<String> {
    let output = Command::new("git")
        .args(["config", "--global", "--includes", "--get-all"])
        .arg("credential.https://github.com.helper")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).lines().map(str::to_owned).collect()
        }
        _ => Vec::new(),
    }
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

fn on_path(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| executable(candidate))
}

/// Best-effort transfer progress from `git --progress`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Progress {
    pub received_bytes: u64,
    pub objects: u64,
    pub total_objects: u64,
}

/// Reads one progress line (`Receiving objects:  45% (450/1000), 1.20 MiB |
/// 2.00 MiB/s`) into `progress`. Other lines leave it as it is.
pub fn read_progress(line: &str, progress: &mut Progress) {
    let line = line.trim_start_matches("remote: ").trim();
    if !line.starts_with("Receiving objects:") {
        return;
    }
    if let Some((open, close)) = line.find('(').zip(line.find(')'))
        && let Some((done, total)) =
            line.get(open + 1..close).and_then(|inner| inner.split_once('/'))
        && let (Ok(done), Ok(total)) = (done.trim().parse::<u64>(), total.trim().parse::<u64>())
    {
        progress.objects = done;
        progress.total_objects = total;
    }
    if let Some(after) = line.split_once("), ").map(|(_, after)| after) {
        let amount = after.split('|').next().unwrap_or("").trim();
        if let Some((number, unit)) = amount.split_once(' ')
            && let Ok(number) = number.parse::<f64>()
        {
            let scale: f64 = match unit {
                "bytes" => 1.0,
                "KiB" => 1024.0,
                "MiB" => 1024.0 * 1024.0,
                "GiB" => 1024.0 * 1024.0 * 1024.0,
                _ => return,
            };
            // Saturating float to int; the amount is a display estimate.
            let bytes = (number * scale) as u64;
            progress.received_bytes = bytes;
        }
    }
}

/// A git run that failed: its stderr's last lines (or why it did not run).
#[derive(Clone, Debug, Default)]
pub struct Failure {
    pub lines: Vec<String>,
}

impl Failure {
    fn text(&self) -> String {
        self.lines.join("\n").to_ascii_lowercase()
    }

    /// The disk filled up.
    #[must_use]
    pub fn disk_full(&self) -> bool {
        let text = self.text();
        ["no space left on device", "enospc", "disk quota exceeded"]
            .iter()
            .any(|needle| text.contains(needle))
    }

    /// GitHub refused this path (private, not found, or no token).
    #[must_use]
    pub fn auth(&self) -> bool {
        let text = self.text();
        [
            "authentication failed",
            "could not read username",
            "could not read password",
            "terminal prompts disabled",
            "repository not found",
            "invalid username or password",
            "returned error: 401",
            "returned error: 403",
            "returned error: 404",
            "cmux github credential:",
        ]
        .iter()
        .any(|needle| text.contains(needle))
    }

    /// The GitHub App install link `cmux github credential` named, if any.
    #[must_use]
    pub fn install_url(&self) -> Option<String> {
        self.lines.iter().filter(|line| line.contains("cmux github credential:")).find_map(|line| {
            line.split_whitespace()
                .map(|word| word.trim_end_matches(|c: char| ",.;)\"'".contains(c)))
                .find(|word| word.starts_with("https://github.com/"))
                .map(str::to_owned)
        })
    }

    /// The error's display text: the last line that is not progress.
    #[must_use]
    pub fn message(&self) -> String {
        let line = self
            .lines
            .iter()
            .rev()
            .find(|line| !line.contains('%') && !line.trim().is_empty())
            .map_or("git failed", String::as_str);
        line.chars().take(MAX_ERROR_CHARS).collect()
    }

    pub(super) fn of(message: impl Into<String>) -> Self {
        Self { lines: vec![message.into()] }
    }
}

/// Runs git in a seed: no user or system config, no prompt, no trace, no
/// hook, and (when given) one credential helper on the command line.
#[derive(Clone, Debug, Default)]
pub struct Git {
    /// Extra `-c` values (tests rewrite the GitHub URL to a local remote).
    pub extra_config: Vec<String>,
}

impl Git {
    fn command(&self, cwd: Option<&Path>, credential: &Credential) -> Command {
        let mut command = Command::new("git");
        command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        // Nothing inherited may ask another credential source, log a
        // request, or point git at another repository.
        for name in [
            "GIT_ASKPASS",
            "SSH_ASKPASS",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
            "GIT_CURL_VERBOSE",
            "GIT_TRACE_CURL_NO_DATA",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_NAMESPACE",
            "GIT_SSH",
            "GIT_SSH_COMMAND",
            "GIT_PROXY_COMMAND",
            "GIT_EXTERNAL_DIFF",
        ] {
            command.env_remove(name);
        }
        for (name, value) in [
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_TRACE_REDACT", "1"),
            ("GIT_TRACE", "0"),
            ("GIT_TRACE_CURL", "0"),
            ("GIT_TRACE_PACKET", "0"),
            ("GIT_TRACE_SETUP", "0"),
            ("GIT_TRACE_PERFORMANCE", "0"),
            ("GIT_TRACE2", "0"),
            ("GIT_TRACE2_EVENT", "0"),
            ("GIT_TRACE2_PERF", "0"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("LC_ALL", "C"),
            ("LANGUAGE", "C"),
        ] {
            command.env(name, value);
        }
        if let Some(cwd) = cwd {
            command.arg("-C").arg(cwd);
        }
        // An empty helper drops every helper read before it (a checkout's
        // own config may hold one); the chosen one comes after it.
        for value in [
            "credential.helper=",
            "core.askPass=",
            "credential.username=",
            "credential.https://github.com.username=",
            "core.hooksPath=/dev/null",
            "core.fsmonitor=false",
            // Only https: a submodule's URL may not reach ssh, ext or a
            // local path on this machine.
            "protocol.allow=never",
            "protocol.https.allow=always",
        ] {
            command.arg("-c").arg(value);
        }
        if let Some(helper) = credential.helper() {
            command.arg("-c").arg(format!("credential.https://github.com.helper={helper}"));
            command.arg("-c").arg("credential.https://github.com.useHttpPath=true");
        }
        for value in &self.extra_config {
            command.arg("-c").arg(value);
        }
        command
    }

    /// Runs `git ARGS` in `cwd`; its stdout on success. Each stderr line
    /// (split on `\r` too) goes to `on_line`.
    pub fn run(
        &self,
        cwd: Option<&Path>,
        credential: &Credential,
        args: &[&str],
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Vec<u8>, Failure> {
        self.run_in(cwd, credential, args, None, on_line)
    }

    /// [`Self::run`] with `index` as git's index file (`GIT_INDEX_FILE`).
    pub fn run_in(
        &self,
        cwd: Option<&Path>,
        credential: &Credential,
        args: &[&str],
        index: Option<&Path>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Vec<u8>, Failure> {
        let mut command = self.command(cwd, credential);
        command.args(args);
        if let Some(index) = index {
            command.env("GIT_INDEX_FILE", index);
        }
        let mut child =
            command.spawn().map_err(|error| Failure::of(format!("cannot run git: {error}")))?;
        let mut stdout = child.stdout.take();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(stdout) = stdout.as_mut() {
                let _ = stdout.read_to_end(&mut bytes);
            }
            bytes
        });
        let mut kept: std::collections::VecDeque<String> = std::collections::VecDeque::new();
        if let Some(mut stderr) = child.stderr.take() {
            let mut pending = Vec::new();
            let mut chunk = [0u8; 8192];
            loop {
                let read = match stderr.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(read) => read,
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                pending.extend_from_slice(chunk.get(..read).unwrap_or_default());
                while let Some(at) =
                    pending.iter().position(|byte| *byte == b'\n' || *byte == b'\r')
                {
                    let line: Vec<u8> = pending.drain(..=at).collect();
                    let line = String::from_utf8_lossy(&line).trim_end().to_owned();
                    keep(&mut kept, line, on_line);
                }
            }
            if !pending.is_empty() {
                keep(&mut kept, String::from_utf8_lossy(&pending).trim_end().to_owned(), on_line);
            }
        }
        let status = child.wait();
        let stdout = reader.join().unwrap_or_default();
        match status {
            Ok(status) if status.success() => Ok(stdout),
            Ok(_) => Err(Failure { lines: kept.into() }),
            Err(error) => Err(Failure::of(format!("git did not finish: {error}"))),
        }
    }

    /// [`Self::run`] with no line handler.
    pub fn quiet(
        &self,
        cwd: Option<&Path>,
        credential: &Credential,
        args: &[&str],
    ) -> Result<Vec<u8>, Failure> {
        self.run(cwd, credential, args, &mut |_| {})
    }
}

fn keep(
    kept: &mut std::collections::VecDeque<String>,
    line: String,
    on_line: &mut dyn FnMut(&str),
) {
    if line.is_empty() {
        return;
    }
    on_line(&line);
    // Progress lines repeat; keep only the last of a run of them.
    if line.contains('%') && kept.back().is_some_and(|last| last.contains('%')) {
        kept.pop_back();
    }
    kept.push_back(line);
    if kept.len() > KEPT_LINES {
        kept.pop_front();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_lines_give_objects_and_bytes() {
        let mut progress = Progress::default();
        read_progress("Receiving objects:  45% (450/1000), 1.50 MiB | 2.00 MiB/s", &mut progress);
        assert_eq!(progress.objects, 450);
        assert_eq!(progress.total_objects, 1000);
        assert_eq!(progress.received_bytes, 1024 * 1024 * 3 / 2);
        read_progress("Resolving deltas:  10% (1/10)", &mut progress);
        assert_eq!(progress.objects, 450, "other lines change nothing");
        read_progress(
            "Receiving objects: 100% (1000/1000), 12 bytes | 1 bytes/s, done.",
            &mut progress,
        );
        assert_eq!(progress.objects, 1000);
        assert_eq!(progress.received_bytes, 12);
    }

    #[test]
    fn failures_are_told_apart() {
        let auth = Failure {
            lines: vec![
                "cmux github credential: o/n: needs_github: install the cmux app at https://github.com/apps/cmux/installations/new.".into(),
                "fatal: could not read Username for 'https://github.com': terminal prompts disabled".into(),
            ],
        };
        assert!(auth.auth());
        assert!(!auth.disk_full());
        assert_eq!(
            auth.install_url().as_deref(),
            Some("https://github.com/apps/cmux/installations/new")
        );
        assert!(auth.message().starts_with("fatal: could not read Username"));
        let full = Failure::of("fatal: write error: No space left on device");
        assert!(full.disk_full());
        assert!(!full.auth());
        assert_eq!(full.install_url(), None);
    }
}
