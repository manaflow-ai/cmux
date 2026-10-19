//! An explicitly configured link belongs to this daemon, never a pid file.
//! Its inherited socket carries startup configuration and closes with the daemon.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context as _, bail};
use cmux_link::token::VerifierConfig;
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    verifier: String,
}

pub(super) struct SupervisedLink {
    child: Arc<cmux_link::caller::SupervisedChild>,
    // Keeping this endpoint open is the child's lifetime lease.
    _lease: UnixStream,
}

impl SupervisedLink {
    pub(super) fn start(
        state: &Path,
        session: &Path,
        mode: VerifierConfig,
    ) -> anyhow::Result<Self> {
        // Refuse an uninitialized identity; starting a daemon must not create one.
        super::state::check_socket_dir(state)?;
        let existing = super::state::LinkState::open(Some(state.to_owned()))?;
        existing.config()?;
        existing.private_key()?;
        let (mut parent, inherited) = UnixStream::pair()?;
        parent.set_read_timeout(Some(Duration::from_secs(20)))?;
        let lease = parent.try_clone()?;
        let child = Command::new(std::env::current_exe()?)
            .args(["link", "serve", "--supervised", "--state-dir"])
            .arg(state)
            .arg("--session-socket")
            .arg(session)
            .env_remove(cmux_link::token::VERIFIER_ENV)
            .stdin(Stdio::from(OwnedFd::from(inherited)))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .context("link.supervised.start_failed")?;
        let child = Arc::new(cmux_link::caller::SupervisedChild::capture(child)?);
        let owned = Self { child, _lease: lease };
        let verifier = match mode {
            VerifierConfig::DenyAll => "deny_all",
            VerifierConfig::ControlPlane => "control_plane",
        };
        writeln!(
            parent,
            "{}",
            serde_json::to_string(&Configuration { verifier: verifier.into() })?
        )?;
        let mut ready = String::new();
        BufReader::new((&parent).take(4096)).read_line(&mut ready)?;
        let ready: serde_json::Value =
            serde_json::from_str(&ready).context("link.supervised.invalid_readiness")?;
        if ready["event"] != "link-ready"
            || ready["pid"].as_u64() != Some(u64::from(owned.child.id()))
            || ready["verifier"] != verifier
        {
            bail!("link.supervised.not_ready");
        }
        Ok(owned)
    }
}

impl SupervisedLink {
    pub(super) fn process(&self) -> Arc<cmux_link::caller::SupervisedChild> {
        self.child.clone()
    }
}

pub(super) struct Bootstrap {
    stream: UnixStream,
    // Kept separate from inherited environment and caller-supplied hellos.
    verifier: VerifierConfig,
}

impl Bootstrap {
    pub(super) fn receive() -> anyhow::Result<Self> {
        use std::os::fd::{AsFd as _, AsRawFd as _};
        let stdin = std::io::stdin();
        let stream = UnixStream::from(stdin.as_fd().try_clone_to_owned()?);
        cmux_link::caller::verify(&stream)?;
        // An inherited socket pair names the daemon that created it. A peer
        // process cannot substitute a public endpoint or a claimed parent pid.
        cmux_link::caller::verify_inherited_parent(stream.as_raw_fd())?;
        let mut line = String::new();
        BufReader::new((&stream).take(4096)).read_line(&mut line)?;
        let config: Configuration = serde_json::from_str(&line)?;
        let mode = match config.verifier.as_str() {
            "deny_all" => VerifierConfig::DenyAll,
            "control_plane" => VerifierConfig::ControlPlane,
            _ => bail!("link.supervised.invalid_configuration"),
        };
        // The duplicate and original stdin must not leak into later execs.
        // SAFETY: fcntl only changes this process's inherited descriptor flags.
        if unsafe { libc::fcntl(stdin.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self { stream, verifier: mode })
    }

    pub(super) fn ready(
        mut self,
        line: &serde_json::Value,
    ) -> anyhow::Result<tokio::net::UnixStream> {
        let mut line = line.clone();
        line["verifier"] = match self.verifier {
            VerifierConfig::DenyAll => "deny_all",
            VerifierConfig::ControlPlane => "control_plane",
        }
        .into();
        writeln!(self.stream, "{line}")?;
        self.stream.set_nonblocking(true)?;
        Ok(tokio::net::UnixStream::from_std(self.stream)?)
    }
}

pub(super) async fn parent_closed(lease: Option<tokio::net::UnixStream>) {
    use tokio::io::AsyncReadExt as _;
    match lease {
        Some(mut lease) => {
            // EOF, an error, or unexpected data all end this child.
            let _ = lease.read(&mut [0]).await;
        }
        None => std::future::pending().await,
    }
}
