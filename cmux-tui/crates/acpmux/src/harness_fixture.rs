//! A capture fixture for the harness catalog and its health
//! (`ACPMUX_HARNESS_FIXTURE`): a JSON file the daemon reads once at start
//! when the variable names it, so a screenshot rig's before and after builds
//! show the same harnesses with the same health on any host.
//!
//! ```json
//! {"harnesses": {"codex": {"argv": ["codex-acp"], "description": "found on PATH"}},
//!  "health": [{"id": "codex", "program": "codex-acp", "channel": "npm", ...}]}
//! ```
//!
//! `harnesses` are `HarnessProfile`s that stand in for what PATH, `~/.acpx`
//! and the ACP Registry would add (profile files still join); `health` are
//! `HarnessHealth` rows served as the daemon's check. While a fixture is
//! set nothing about a fixture harness is read from this machine: no
//! version, sign-in or newest-version check, no model probe of it, no
//! saved health copy, and every update (auto, requested or prepared) is
//! refused, since its commands describe no real install. Nor does the daemon
//! verify launchers (`config/launchers.rs`), probe live model lists, read
//! the ACP Registry or add a harness while a fixture is set.
//!
//! Unset (every normal run), nothing here is read and every path is the
//! one it always was. A signed app never passes the variable to its daemon
//! (`AcpmuxDaemonLauncher.signedInheritedKeys`). A set variable whose file
//! cannot be read stops the daemon at start (`check`), so a capture never
//! silently shows the host's harnesses instead.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use serde::Deserialize;

use crate::config::HarnessProfile;
use crate::harness_health::HarnessHealth;

/// The variable that names the fixture file.
pub const ENV: &str = "ACPMUX_HARNESS_FIXTURE";

/// The largest fixture file read (a real one is a few KiB).
pub const MAX_BYTES: u64 = 1 << 20;

/// Why a requested update of a fixture harness is refused.
pub const REFUSAL: &str = "a capture fixture's harness: nothing is installed to update";

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Fixture {
    /// The harnesses PATH, `~/.acpx` and the ACP Registry would add.
    #[serde(default)]
    pub harnesses: BTreeMap<String, HarnessProfile>,
    /// The health rows `_acpmux/harness/health` serves.
    #[serde(default)]
    pub health: Vec<HarnessHealth>,
}

impl Fixture {
    /// Reads and parses a fixture file.
    /// The file itself, never a link (a capture app can write the folder
    /// that holds it).
    pub fn read(path: &Path) -> Result<Self, String> {
        let text = open_no_follow(path)
            .and_then(|file| {
                // A regular file only (never a FIFO or a device that never ends), read bounded.
                if !file.metadata()?.is_file() {
                    return Err(std::io::Error::other("not a regular file"));
                }
                let mut text = Vec::new();
                std::io::Read::read_to_end(
                    &mut std::io::Read::take(file, MAX_BYTES + 1),
                    &mut text,
                )?;
                if text.len() as u64 > MAX_BYTES {
                    return Err(std::io::Error::other(format!("over {MAX_BYTES} bytes")));
                }
                Ok(text)
            })
            .map_err(|e| format!("{ENV}: cannot read {}: {e}", path.display()))?;
        serde_json::from_slice(&text)
            .map_err(|e| format!("{ENV}: {} is not a harness fixture: {e}", path.display()))
    }

    /// Whether `id` is one of the fixture's harnesses (never started or probed).
    pub fn names(&self, id: &str) -> bool {
        self.harnesses.contains_key(id) || self.health.iter().any(|row| row.id == id)
    }
}

#[cfg(unix)]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

/// The fixture file's outcome, read once per process: None when the
/// variable is unset or empty.
fn loaded() -> &'static Option<Result<Fixture, String>> {
    static LOADED: OnceLock<Option<Result<Fixture, String>>> = OnceLock::new();
    LOADED.get_or_init(|| {
        // Set but empty is a mistake, never "unset": the capture would show
        // this host's harnesses.
        let path = std::env::var_os(ENV)?;
        if path.is_empty() {
            return Some(Err(format!("{ENV} is set but empty")));
        }
        Some(Fixture::read(Path::new(&path)))
    })
}

/// The fixture this process runs with, or None (the variable is unset).
/// It is per process: the daemon and the acpmux processes it starts read it
/// (the app passes it only to its daemon); a CLI run without the variable
/// sees the host as always. A
/// fixture that could not be read is an empty one here, so a client
/// process still reads nothing live; the daemon refuses to start (`check`).
pub fn active() -> Option<&'static Fixture> {
    static EMPTY: OnceLock<Fixture> = OnceLock::new();
    match loaded() {
        None => None,
        Some(Ok(fixture)) => Some(fixture),
        Some(Err(_)) => Some(EMPTY.get_or_init(Fixture::default)),
    }
}

/// The daemon's start check: an error when the variable is set and its file
/// cannot be read or parsed.
pub fn check() -> Result<(), String> {
    match loaded() {
        Some(Err(why)) => Err(why.clone()),
        Some(Ok(fixture)) => {
            tracing::warn!(
                harnesses = fixture.harnesses.len(),
                health = fixture.health.len(),
                "{ENV}: serving a capture fixture's harnesses; nothing about them is read from this machine"
            );
            Ok(())
        }
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness_health::{HealthService, Settings};
    use serde_json::json;

    fn fixture() -> Fixture {
        serde_json::from_value(json!({
            "harnesses": {"codex": {"argv": ["codex-acp"], "description": "found on PATH"}},
            "health": [{
                "id": "codex", "program": "codex-acp", "path": "/opt/fixture/bin/codex-acp",
                "channel": "npm", "package": "@zed-industries/codex-acp",
                "version": "0.9.0", "latest": "0.10.0", "latestCheckedAt": 1, "outdated": true,
                "auth": "signedIn", "authDetail": null, "login": "codex login",
                "update": {"argv": ["/bin/false"], "command": "npm install -g @zed-industries/codex-acp@latest", "elevated": false},
                "problem": null, "checkedAt": 1
            }]
        }))
        .unwrap()
    }

    #[test]
    fn a_fixture_file_parses_and_refuses_unknown_fields() {
        let dir = std::env::temp_dir().join(format!("amx-harness-fixture-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("fixture.json");
        std::fs::write(&file, serde_json::to_vec(&json!({"harnesses": {}, "health": []})).unwrap())
            .unwrap();
        assert_eq!(Fixture::read(&file).unwrap(), Fixture::default());
        std::fs::write(&file, br#"{"harness": {}}"#).unwrap();
        assert!(Fixture::read(&file).unwrap_err().contains("not a harness fixture"));
        assert!(Fixture::read(&dir.join("missing.json")).unwrap_err().contains("cannot read"));
        #[cfg(unix)]
        {
            let link = dir.join("link.json");
            let _ = std::fs::remove_file(&link);
            std::os::unix::fs::symlink(&file, &link).unwrap();
            assert!(
                Fixture::read(&link).unwrap_err().contains("cannot read"),
                "a link was followed"
            );
            // O_NONBLOCK: a FIFO opens without a writer, then the type check refuses it.
            assert!(Fixture::read(&dir).unwrap_err().contains("not a regular file"));
            assert!(
                Fixture::read(Path::new("/dev/zero")).unwrap_err().contains("not a regular file")
            );
            std::fs::write(&file, vec![b' '; MAX_BYTES as usize + 1]).unwrap();
            assert!(Fixture::read(&file).unwrap_err().contains("over"));
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    /// The fixture's rows are the check, whatever the subjects; no update runs.
    #[tokio::test]
    async fn a_fixture_service_serves_its_rows_and_runs_no_update() {
        let fixture = fixture();
        let service = HealthService::new();
        service.attach(Settings { fixture: Some(fixture.health.clone()), ..Settings::default() });
        assert_eq!(service.rows(), fixture.health);
        let subject = crate::harness_health::Subject {
            id: "other".into(),
            program: "/nonexistent/other".into(),
            family: "other".into(),
            check: vec![],
            env: Default::default(),
            login: None,
            unresolved: vec![],
            probe_error: None,
        };
        assert_eq!(service.check(vec![subject], true).await, fixture.health);
        assert!(service.run_auto_updates().await.is_empty());
        let (rows, ran) = service.run_updates(async { vec![] }, None).await;
        assert_eq!(rows, fixture.health);
        assert_eq!(ran.len(), 1);
        assert!(
            matches!(&ran[0].1, crate::harness_health::auto::Requested::Refused(why) if why == REFUSAL)
        );
        assert!(service.cached_update_plan("codex").is_err());
        assert!(service.prepare_update("codex").is_err());
        assert!(fixture.names("codex") && !fixture.names("claude"));
    }

    /// The catalog takes the fixture's harnesses instead of discovery.
    #[test]
    fn a_fixture_catalog_joins_only_its_harnesses() {
        let mut cfg = crate::config::Config::default();
        cfg.join_fixture(&fixture());
        assert_eq!(cfg.harnesses.keys().collect::<Vec<_>>(), ["codex"]);
        assert!(cfg.discovered.contains("codex"));
        assert_eq!(cfg.default_harness.as_deref(), Some("codex"));
    }
}
