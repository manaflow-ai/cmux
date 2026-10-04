//! [`OpenSshTransfer`]: the real [`Transfer`], with the system OpenSSH
//! (`ssh-agent`, `ssh-add`, `scp`).
//!
//! The private key never touches the disk or argv: a private `ssh-agent`
//! runs for this transfer only, `ssh-add -` reads the key on stdin, and
//! `scp` uses that agent (`IdentityAgent`). The pinned host key goes into a
//! `known_hosts` file in an owner-only folder (a public key, not a secret).
//! The folder, the agent and the key are gone when the transfer ends.
//!
//! UNVERIFIED live: needs a Cloud machine (no non-production account yet).

use super::key::TransferKey;
use super::transfer::{Direction, Transfer, TransferError, TransferJob};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

/// Variables the OpenSSH processes keep; everything else is cleared (no
/// inherited agent, no inherited config).
const KEPT_ENV: &[&str] = &["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"];
const HOST_ALIAS: &str = "cmux-scp";

#[derive(Debug, Clone)]
pub struct OpenSshTransfer {
    pub ssh_agent: PathBuf,
    pub ssh_add: PathBuf,
    pub scp: PathBuf,
}

impl Default for OpenSshTransfer {
    fn default() -> Self {
        Self {
            ssh_agent: PathBuf::from("/usr/bin/ssh-agent"),
            ssh_add: PathBuf::from("/usr/bin/ssh-add"),
            scp: PathBuf::from("/usr/bin/scp"),
        }
    }
}

/// The `scp` arguments for `job`: no key material, the host key pinned by
/// alias, the private agent only, no config file.
pub fn scp_args(
    job: &TransferJob,
    agent_socket: &Path,
    known_hosts: &Path,
    identity_pub: &Path,
) -> Vec<String> {
    let option = |o: String| ["-o".to_owned(), o];
    // Quoted (a space would split the value) with `%` escaped (ssh tokens).
    let escape = |p: &Path| format!("\"{}\"", p.to_string_lossy().replace('%', "%%"));
    // `-s`: the SFTP protocol, so the guest shell never reads the path
    // (the legacy protocol passes it to a remote shell).
    let mut args = vec!["-s".to_owned(), "-F".to_owned(), "/dev/null".to_owned()];
    args.extend(["-P".to_owned(), job.route.port().to_string()]);
    for o in [
        "StrictHostKeyChecking=yes".to_owned(),
        "HostKeyAlgorithms=ssh-ed25519".to_owned(),
        format!("HostKeyAlias={HOST_ALIAS}"),
        format!("UserKnownHostsFile={}", escape(known_hosts)),
        "GlobalKnownHostsFile=/dev/null".to_owned(),
        format!("IdentityAgent={}", escape(agent_socket)),
        // Only the transfer key: the public half names the agent's key, so
        // ssh never offers the user's own keys to the guest.
        "IdentitiesOnly=yes".to_owned(),
        format!("IdentityFile={}", escape(identity_pub)),
        "PreferredAuthentications=publickey".to_owned(),
        "BatchMode=yes".to_owned(),
        "LogLevel=ERROR".to_owned(),
        "ConnectTimeout=15".to_owned(),
        "ServerAliveInterval=15".to_owned(),
        "ServerAliveCountMax=3".to_owned(),
        "ControlMaster=no".to_owned(),
        "ControlPath=none".to_owned(),
        "ForwardAgent=no".to_owned(),
    ] {
        args.extend(option(o));
    }
    let remote = format!("{}@{}:{}", job.endpoint.username, job.route.ip(), job.guest);
    let local = job.local.to_string_lossy().into_owned();
    args.push("--".to_owned());
    match job.direction {
        Direction::Push => args.extend([local, remote]),
        Direction::Pull => args.extend([remote, local]),
    }
    args
}

/// An owner-only folder that is removed on drop.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> std::io::Result<Self> {
        let mut nonce = [0u8; 8];
        getrandom::fill(&mut nonce).map_err(|e| std::io::Error::other(e.to_string()))?;
        let name: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-cloud-{name}"));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&path)?;
        Ok(Self(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The private agent; killed on drop.
struct Agent(Child);

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn command(program: &Path) -> Command {
    let mut command = Command::new(program);
    command.env_clear();
    for key in KEPT_ENV {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command
}

fn failed(what: &str, detail: &str) -> TransferError {
    let tail: String =
        detail.chars().rev().take(2000).collect::<Vec<_>>().into_iter().rev().collect();
    TransferError { message: format!("{what}: {}", tail.trim()), retryable: false }
}

impl OpenSshTransfer {
    fn start_agent(&self, socket: &Path) -> Result<Agent, TransferError> {
        let mut child = command(&self.ssh_agent)
            .args(["-D", "-a"])
            .arg(socket)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| failed("ssh-agent did not start", &e.to_string()))?;
        let stdout = child.stdout.take();
        let agent = Agent(child);
        // The agent prints its socket line once it listens: that line is the
        // ready signal (no sleep, no polling).
        let mut line = String::new();
        let ready = stdout
            .map(BufReader::new)
            .is_some_and(|mut r| r.read_line(&mut line).is_ok() && line.contains("SSH_AUTH_SOCK"));
        if !ready {
            return Err(failed("ssh-agent did not become ready", ""));
        }
        Ok(agent)
    }

    fn add_key(&self, socket: &Path, key: &TransferKey) -> Result<(), TransferError> {
        let mut child = command(&self.ssh_add)
            .env("SSH_AUTH_SOCK", socket)
            .arg("-q")
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| failed("ssh-add did not start", &e.to_string()))?;
        if let Some(mut stdin) = child.stdin.take() {
            let text = key.private_openssh();
            let _ = stdin.write_all(text.as_bytes());
        }
        let output = child.wait_with_output().map_err(|e| failed("ssh-add", &e.to_string()))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(failed(
                "ssh-add refused the transfer key",
                &String::from_utf8_lossy(&output.stderr),
            ))
        }
    }
}

impl Transfer for OpenSshTransfer {
    fn run(&mut self, job: &TransferJob, key: &TransferKey) -> Result<u64, TransferError> {
        let scratch = Scratch::new().map_err(|e| failed("no private folder", &e.to_string()))?;
        let socket = scratch.0.join("agent.sock");
        let known_hosts = scratch.0.join("known_hosts");
        let identity_pub = scratch.0.join("transfer.pub");
        std::fs::write(&identity_pub, format!("{}\n", key.public_openssh()))
            .map_err(|e| failed("transfer.pub", &e.to_string()))?;
        let pinned = format!("{HOST_ALIAS} {}\n", job.endpoint.host_public_key);
        std::fs::write(&known_hosts, pinned).map_err(|e| failed("known_hosts", &e.to_string()))?;
        let _agent = self.start_agent(&socket)?;
        self.add_key(&socket, key)?;
        let mut child = command(&self.scp)
            .args(scp_args(job, &socket, &known_hosts, &identity_pub))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| failed("scp did not start", &e.to_string()))?;
        let mut stderr = String::new();
        if let Some(mut pipe) = child.stderr.take() {
            let _ = pipe.read_to_string(&mut stderr);
        }
        let status = child.wait().map_err(|e| failed("scp", &e.to_string()))?;
        if !status.success() {
            return Err(TransferError { retryable: true, ..failed("scp failed", &stderr) });
        }
        // The local file has the bytes in both directions once scp is done.
        Ok(std::fs::metadata(&job.local).map(|m| m.len()).unwrap_or(0))
    }
}
