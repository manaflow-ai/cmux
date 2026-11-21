//! A joined Linux machine's screen-share host, set up by its daemon with no step on the machine
//! (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md, Linux, L1).
//!
//! Leo, 2026-11-16: "ok cool well what about linux stuf", after "if you've connected to a
//! headlessly running mini why... would it need anything?"
//!
//! At daemon start on a joined Linux machine, [`set_up`] installs `cmux-rd` (the pinned
//! release, checked against its sha256 before it is written) as `~/.local/bin/cmux-rd`, where
//! the host's user unit runs it, and runs `cmux-rd linux-host enable --non-interactive` with
//! this daemon's `ACPMUX_HOME`, once per pinned version. That command signs the machine in to
//! the device hub with the machine credential the join left here, registers it, turns sharing
//! on, sets up a virtual display when there is no graphical session, and installs and starts
//! the host unit. What it said is kept in `screen-sharing/linux-host.json` beside the daemon's
//! state. Nothing here needs a person, sudo, or a token of anyone's.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context as _, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// The cmux-rd release a joined Linux machine runs: its version, archive URL and the archive's
/// sha256 (the release's `checksums.txt`). A new release moves all three together.
#[derive(Clone, Copy, Debug)]
pub struct Release {
    pub version: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
}

/// The release this build installs, for the machine's architecture. None on an architecture
/// cmux-rd has no release for: the share host is then not set up, and the status says so.
pub fn pinned() -> Option<Release> {
    match std::env::consts::ARCH {
        "x86_64" => Some(Release {
            version: "0.2.6",
            url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-rd-v0.2.6/cmux-rd-0.2.6-x86_64-unknown-linux-gnu.tar.gz",
            sha256: PINNED_SHA256_X86_64,
        }),
        _ => None,
    }
}

/// `checksums.txt` of the cmux-rd-v0.2.6 release, for the x86_64 archive.
const PINNED_SHA256_X86_64: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

/// The archive's member that is the binary.
const ARCHIVE_BINARY: &str = "bin/cmux-rd";
/// How long the download may take.
const DOWNLOAD_WITHIN: Duration = Duration::from_secs(300);
/// The largest archive accepted (the release is about 10 MB).
const MAX_ARCHIVE: u64 = 128 << 20;
/// How long `enable --non-interactive` may run (it waits a minute at most on a portal dialog).
const ENABLE_WITHIN: Duration = Duration::from_secs(180);

/// What the last set-up did, kept in `screen-sharing/linux-host.json`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    /// The cmux-rd version set up.
    pub version: String,
    /// `enable --non-interactive` finished and installed the host.
    pub installed: bool,
    /// The lines it printed (or why it did not run), for `status` and the machine row.
    pub lines: Vec<String>,
    pub at_ms: u64,
}

impl Outcome {
    pub fn path(home: &Path) -> PathBuf {
        home.join("screen-sharing").join("linux-host.json")
    }

    pub fn load(home: &Path) -> Option<Self> {
        serde_json::from_slice(&std::fs::read(Self::path(home)).ok()?).ok()
    }

    fn save(&self, home: &Path) -> Result<()> {
        let path = Self::path(home);
        crate::config::private_state_dir(path.parent().context("no parent")?)?;
        let tmp = path.with_extension(format!("tmp{}", std::process::id()));
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }
}

/// Whether the host still needs setting up for `release`: the last outcome is another version
/// or did not install the host.
pub fn needs_set_up(last: Option<&Outcome>, release: &Release) -> bool {
    !last.is_some_and(|o| o.installed && o.version == release.version)
}

/// Whether `enable --non-interactive`'s output says it installed the host: it never fails the
/// join, and prints one `not_installed:` line for what it could not do.
pub fn enable_installed(stdout: &str) -> bool {
    !stdout.lines().any(|l| l.starts_with("not_installed:"))
}

/// Where the host unit runs cmux-rd from (`ExecStart=%h/.local/bin/cmux-rd`).
pub fn binary_path(account_home: &Path) -> PathBuf {
    account_home.join(".local").join("bin").join("cmux-rd")
}

/// sha256 of `bytes`, lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The binary inside a release archive (`.tar.gz`), after the archive matched `want_sha256`.
pub fn unpack(archive: &[u8], want_sha256: &str) -> Result<Vec<u8>> {
    let got = sha256_hex(archive);
    ensure!(
        got == want_sha256,
        "cmux-rd archive sha256 {got}, the pinned release says {want_sha256}"
    );
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
    for entry in tar.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();
        let name = path.to_string_lossy();
        if name.trim_start_matches("./") == ARCHIVE_BINARY
            || name.split_once('/').is_some_and(|(_, rest)| rest == ARCHIVE_BINARY)
        {
            let mut bytes = Vec::new();
            entry.read_to_end(&mut bytes)?;
            return Ok(bytes);
        }
    }
    bail!("the cmux-rd archive has no {ARCHIVE_BINARY}")
}

/// Writes `binary` to `path` (0755) through a temporary file and a rename, unless it is
/// already there.
pub fn install_binary(path: &Path, binary: &[u8]) -> Result<bool> {
    if std::fs::read(path).ok().as_deref() == Some(binary) {
        return Ok(false);
    }
    use std::os::unix::fs::PermissionsExt as _;
    let dir = path.parent().context("no parent")?;
    std::fs::create_dir_all(dir)?;
    let tmp = path.with_extension(format!("new{}", std::process::id()));
    std::fs::write(&tmp, binary)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    std::fs::rename(&tmp, path)?;
    Ok(true)
}

async fn download(url: &str) -> Result<Vec<u8>> {
    let client =
        reqwest::Client::builder().timeout(DOWNLOAD_WITHIN).build().context("http client")?;
    let response = client.get(url).send().await?.error_for_status()?;
    if response.content_length().is_some_and(|n| n > MAX_ARCHIVE) {
        bail!("the cmux-rd archive is larger than {MAX_ARCHIVE} bytes");
    }
    let bytes = response.bytes().await?;
    ensure!((bytes.len() as u64) <= MAX_ARCHIVE, "the cmux-rd archive is too large");
    Ok(bytes.to_vec())
}

/// Installs the pinned cmux-rd and runs `enable --non-interactive` when this joined machine
/// has not been set up for this version; the outcome, also kept beside the daemon's state.
/// Never touches a machine that is not joined (or whose record was copied from another box).
pub async fn set_up(home: &Path) -> Result<Option<Outcome>> {
    if crate::machine_record::machine_credential()?.is_none() {
        return Ok(None);
    }
    let Some(release) = pinned() else {
        let outcome = Outcome {
            lines: vec![format!(
                "not_installed: cmux-rd has no release for {}",
                std::env::consts::ARCH
            )],
            at_ms: now_ms(),
            ..Outcome::default()
        };
        outcome.save(home)?;
        return Ok(Some(outcome));
    };
    if !needs_set_up(Outcome::load(home).as_ref(), &release) {
        return Ok(None);
    }
    let account_home = dirs::home_dir().context("no home folder")?;
    let binary = binary_path(&account_home);
    let archive = download(release.url).await?;
    install_binary(&binary, &unpack(&archive, release.sha256)?)?;
    let mut command = tokio::process::Command::new(&binary);
    command
        .args(["linux-host", "enable", "--non-interactive"])
        .env("ACPMUX_HOME", home)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(ENABLE_WITHIN, command.output())
        .await
        .context("cmux-rd linux-host enable did not finish")??;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut lines: Vec<String> = stdout.lines().map(str::to_owned).collect();
    if !output.status.success() {
        lines.push(format!(
            "not_installed: cmux-rd linux-host enable exited {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let outcome = Outcome {
        version: release.version.to_owned(),
        installed: output.status.success() && enable_installed(&stdout),
        lines,
        at_ms: now_ms(),
    };
    outcome.save(home)?;
    Ok(Some(outcome))
}

/// [`set_up`] in the background at daemon start, owned by the daemon's scope (a stop drops it,
/// and the next start redoes it), logging what it did.
pub fn spawn_set_up(scope: &cmux_scope::Scope, home: PathBuf) {
    drop(scope.spawn_until_cancelled("linux-screen-host-set-up", async move {
        match set_up(&home).await {
            Ok(Some(outcome)) => tracing::info!(
                version = outcome.version,
                installed = outcome.installed,
                lines = ?outcome.lines,
                "linux screen-share host set up"
            ),
            Ok(None) => {}
            Err(error) => tracing::warn!(%error, "linux screen-share host not set up"),
        }
    }));
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

#[cfg(test)]
#[path = "linux_screen_host_tests.rs"]
mod tests;
