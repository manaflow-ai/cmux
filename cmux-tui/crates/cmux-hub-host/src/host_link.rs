//! Whether the running screen host (`cmux-rd linux-host run`) holds its hub link, as the
//! acpmux daemon that set it up reads it (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md,
//! L1: the daemon supervises the host it installed). `systemctl is-active` says only that the
//! process runs: a host that runs but never reaches the hub (its sign-in refused, the network,
//! another deployment) is active and off the hub, so the machine is not shareable. The host
//! writes [`LINK_FILE`] in its config directory when its User DO socket opens and when it
//! drops; the daemon reads it and sets the host up again (which restarts it) when it has been
//! off the hub longer than a reconnect takes.

use crate::identity;
use crate::Res;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// In the host's config directory, beside its device: the link's state.
pub const LINK_FILE: &str = "link.json";

/// The host's hub link as it last wrote it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Link {
    /// Whether the User DO socket is open.
    pub online: bool,
    /// Unix ms since which it has been as `online` says: an offline host keeps the time it
    /// went offline (or started) through its reconnect attempts.
    pub since_ms: u64,
    /// Why it is offline: the last link error, or that it is starting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Link {
    /// The link of the host whose config directory is `dir`; None when no host wrote one (an
    /// older cmux-rd, or none ran) or it cannot be read.
    pub fn read(dir: &Path) -> Option<Link> {
        let bytes = identity::read_private(&dir.join(LINK_FILE)).ok().flatten()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Since when this host has been off the hub, if it is.
    pub fn offline_since(&self) -> Option<u64> {
        (!self.online).then_some(self.since_ms)
    }
}

/// What the running host writes: it keeps the time it went offline across failed reconnects.
#[derive(Debug)]
pub struct Reporter {
    path: PathBuf,
    offline_since: Option<u64>,
}

impl Reporter {
    /// The host starting with config directory `dir`, at `now_ms`: offline until its socket
    /// opens.
    pub fn starting(dir: &Path, now_ms: u64) -> Reporter {
        let mut reporter = Reporter { path: dir.join(LINK_FILE), offline_since: None };
        reporter.offline("starting", now_ms);
        reporter
    }

    /// The socket opened at `now_ms`.
    pub fn online(&mut self, now_ms: u64) {
        self.offline_since = None;
        self.write(&Link { online: true, since_ms: now_ms, error: None });
    }

    /// The socket is down (or did not open) at `now_ms`, because of `error`.
    pub fn offline(&mut self, error: &str, now_ms: u64) {
        let since_ms = *self.offline_since.get_or_insert(now_ms);
        self.write(&Link { online: false, since_ms, error: Some(crate::printable(error)) });
    }

    fn write(&self, link: &Link) {
        if let Err(e) = write(&self.path, link) {
            eprintln!("linux-host: {}: {e}", self.path.display());
        }
    }
}

fn write(path: &Path, link: &Link) -> Res<()> {
    identity::write_private(path, &serde_json::to_vec(link)?)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn an_offline_host_keeps_when_it_went_offline_until_it_links() {
        let dir = tempdir();
        let mut reporter = Reporter::starting(&dir, 1_000);
        assert_eq!(Link::read(&dir).and_then(|l| l.offline_since()), Some(1_000));
        reporter.offline("hub link: 401", 5_000);
        let link = Link::read(&dir).unwrap();
        assert_eq!(
            (link.offline_since(), link.error.as_deref()),
            (Some(1_000), Some("hub link: 401"))
        );
        reporter.online(6_000);
        assert_eq!(Link::read(&dir), Some(Link { online: true, since_ms: 6_000, error: None }));
        reporter.offline("socket closed", 9_000);
        assert_eq!(Link::read(&dir).and_then(|l| l.offline_since()), Some(9_000));
    }

    #[test]
    fn no_file_reads_as_unknown() {
        assert_eq!(Link::read(&tempdir()), None);
    }

    fn tempdir() -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "host-link-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        identity::private_dir(&dir).unwrap();
        dir
    }
}
