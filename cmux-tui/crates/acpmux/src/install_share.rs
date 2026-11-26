//! Sharing install counts with cmux: opt-in, off by default (Leo, 2026-11-05:
//! "Like just an option in settings, like, Hey, you can do this to improve
//! CMux"). With `diagnostics.shareInstallCounts` on, this machine sends cmux
//! how many times agents installed each package (`npm:react` 3), so new Cloud
//! machines can come with the common ones already downloaded
//! (`web/scripts/cmux-vm-image/install-census.ts` reads the aggregate).
//!
//! - What is sent: registry package names and counts (`hub/tool_installs.rs`
//!   keys, which pass `cmux_usage_patterns::clean_key`), counts of manifest
//!   installs per manager, and a random install id made on this machine
//!   (not derived from the person, the machine or anything else). Never a
//!   prompt, command line, path, file name, project name or account.
//! - Where it goes: cmux-platform `/v1/install-counts`. The platform keeps only
//!   totals per package with no person or machine on them, and shows a
//!   package only once at least three machines installed it.
//! - Who decides: the person, on their Mac. This daemon tells the platform the
//!   choice (`PUT /consent`, with the person's token) whenever it changes; a
//!   Cloud machine has no settings of its own here, so it asks the platform
//!   (`GET /consent`, with its join credential) and counts only while the
//!   answer is yes. The platform refuses an upload from anyone who has not
//!   said yes, so a stale answer can't send anything.
//! - Each upload is a batch with its own id, resent unchanged until the
//!   platform accepts it, so a lost answer never counts twice.
//! - Turning it off drops what was not sent yet.
//!
//! Cost: nothing is counted while off (one atomic load per shell call). One
//! task per daemon wakes when the settings file changes and every
//! [`SYNC_EVERY`]; pending counts are bounded to [`MAX_KEYS`] keys and written
//! to one small file.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// The setting (a toggle, default off).
pub const SETTING_KEY: &str = "diagnostics.shareInstallCounts";
/// How often the consent is checked and pending counts are sent.
pub const SYNC_EVERY: Duration = Duration::from_secs(6 * 3600);
/// Package keys one upload (and the pending file) holds; later new keys wait.
pub const MAX_KEYS: usize = 500;
/// The longest a platform call may take.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

static SHARING: AtomicBool = AtomicBool::new(false);
static PENDING: OnceLock<Mutex<Pending>> = OnceLock::new();

/// Counts not sent yet, as stored in [`pending_path`].
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Pending {
    /// 24 lowercase hex, random, made once on this machine.
    #[serde(default)]
    pub install: String,
    #[serde(default)]
    pub counts: BTreeMap<String, u64>,
    #[serde(default)]
    pub manifests: BTreeMap<String, u64>,
    /// The upload in flight: what it carries and its batch id (24 hex), kept
    /// until the platform accepts it, so a retry after a lost answer resends
    /// the same batch and the platform counts it once.
    #[serde(default)]
    pub sending: Option<Box<Batch>>,
}

/// One upload: its id and the counts it carries.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Batch {
    pub id: String,
    pub counts: BTreeMap<String, u64>,
    pub manifests: BTreeMap<String, u64>,
}

impl Pending {
    /// Adds one install of `key` (a `manager:name` key) or, for `None`, one
    /// manifest install of `manager`. A new key past [`MAX_KEYS`] is dropped.
    pub fn add(&mut self, manager: &str, key: Option<&str>) {
        match key {
            Some(key) => {
                if cmux_usage_patterns::clean_key(key) != key {
                    return;
                }
                if !self.counts.contains_key(key) && self.counts.len() >= MAX_KEYS {
                    return;
                }
                let n = self.counts.entry(key.to_owned()).or_default();
                *n = n.saturating_add(1);
            }
            None => {
                if !manager.bytes().all(|b| b.is_ascii_lowercase()) || manager.len() > 16 {
                    return;
                }
                let n = self.manifests.entry(manager.to_owned()).or_default();
                *n = n.saturating_add(1);
            }
        }
    }

    /// The upload to send: the one in flight, else a new batch of everything
    /// pending (moved out of the pending counts), else None.
    pub fn next_batch(&mut self, new_id: impl FnOnce() -> Option<String>) -> Option<Batch> {
        if let Some(batch) = &self.sending {
            return Some((**batch).clone());
        }
        if self.is_empty() {
            return None;
        }
        let batch = Batch {
            id: new_id()?,
            counts: std::mem::take(&mut self.counts),
            manifests: std::mem::take(&mut self.manifests),
        };
        self.sending = Some(Box::new(batch.clone()));
        Some(batch)
    }

    fn is_empty(&self) -> bool {
        self.counts.is_empty() && self.manifests.is_empty() && self.sending.is_none()
    }
}

/// Whether installs are counted for sharing now (one atomic load).
pub fn sharing() -> bool {
    SHARING.load(Ordering::Relaxed)
}

/// Counts one install for sharing (nothing while sharing is off).
pub fn count(manager: &str, key: Option<&str>) {
    if !sharing() {
        return;
    }
    let mut pending = pending().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    pending.add(manager, key);
}

fn pending() -> &'static Mutex<Pending> {
    PENDING.get_or_init(|| Mutex::new(pending_path().map(|p| read_pending(&p)).unwrap_or_default()))
}

/// `install-counts.json` beside the daemons' `sessions` state directory.
fn pending_path() -> Option<PathBuf> {
    let sessions = cmux_tui_platform::platform::workspace_state_dir()?;
    Some(sessions.parent().unwrap_or(&sessions).join("install-counts.json"))
}

fn read_pending(path: &Path) -> Pending {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn write_pending(path: &Path, pending: &Pending) {
    let Ok(bytes) = serde_json::to_vec(pending) else { return };
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, bytes).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// A random install id: 24 lowercase hex from 12 bytes of the OS's randomness
/// (`/dev/urandom`, on macOS and Linux alike); None when it can't be read.
fn new_install_id() -> Option<String> {
    use std::io::Read;
    let mut bytes = [0u8; 12];
    std::fs::File::open("/dev/urandom").ok()?.read_exact(&mut bytes).ok()?;
    Some(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Whether the person's settings file says to share: `diagnostics.shareInstallCounts`, nested or dotted.
pub fn setting_on(config: &Path) -> bool {
    let Some(root) =
        std::fs::read_to_string(config).ok().and_then(|text| cmux_config::jsonc::parse(&text).ok())
    else {
        return false;
    };
    let nested = cmux_config::value::value_at(&root, &["diagnostics", "shareInstallCounts"]);
    nested.or(root.get(SETTING_KEY)).and_then(serde_json::Value::as_bool) == Some(true)
}

/// What this daemon last told the platform about the person's choice (a Mac),
/// kept beside the pending counts so a restart doesn't ask again. A person who
/// never turned sharing on is never asked about: no call is made for them.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Told(pub Option<bool>);

/// The daemon-long scope that owns [`start`]'s task.
static TASKS: OnceLock<cmux_scope::Scope> = OnceLock::new();

/// Starts the one task that follows the choice and sends pending counts
/// (inside the daemon's runtime). Lives as long as the daemon; a second call
/// starts nothing.
pub fn start() {
    let Some(path) = pending_path() else { return };
    if TASKS.get().is_some() {
        return;
    }
    let tasks = TASKS.get_or_init(|| cmux_scope::Scope::new("install-share"));
    tasks.spawn_until_cancelled("install-share", run(path));
}

async fn run(path: PathBuf) {
    let config = cmux_config::config_path();
    let cloud = crate::cloud_host::is_cloud_vm();
    let changed = std::sync::Arc::new(tokio::sync::Notify::new());
    // A Mac follows its settings file (a kernel watch, no timer); a Cloud machine has none.
    let _watch = (!cloud)
        .then(|| {
            let changed = std::sync::Arc::clone(&changed);
            cmux_config::watch::Watcher::start(vec![config.clone()], move || changed.notify_one())
                .ok()
        })
        .flatten();
    let mut told = read_told(&path);
    loop {
        let share = if cloud {
            ask_owner().await.unwrap_or(false)
        } else {
            let on = setting_on(&config);
            // Tell the platform only a change, and never a never-on "off".
            if told.0 != Some(on) && (on || told.0 == Some(true)) && tell(on).await.is_ok() {
                told = Told(Some(on));
                write_told(&path, told);
            }
            on
        };
        set_sharing(share, &path);
        if share {
            send_pending(&path, cloud).await;
        }
        tokio::select! {
            () = changed.notified() => {}
            () = tokio::time::sleep(SYNC_EVERY) => {}
        }
    }
}

/// Turns counting on or off; off drops what was not sent (and its file).
fn set_sharing(share: bool, path: &Path) {
    SHARING.store(share, Ordering::Relaxed);
    if !share {
        let mut pending = pending().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !pending.is_empty() {
            *pending = Pending { install: pending.install.clone(), ..Pending::default() };
            // (the batch in flight goes too)
            write_pending(path, &pending);
        }
    }
}

/// Sends what is pending as one batch; an accepted (or already counted) batch
/// is done, and a failed one is resent with the same id next time.
async fn send_pending(path: &Path, cloud: bool) {
    let (install, batch) = {
        let mut pending = pending().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if pending.install.is_empty() {
            let Some(id) = new_install_id() else { return };
            pending.install = id;
        }
        let batch = pending.next_batch(new_install_id);
        write_pending(path, &pending);
        let Some(batch) = batch else { return };
        (pending.install.clone(), batch)
    };
    match upload(&install, &batch, cloud).await {
        Ok(()) => {
            let mut pending = pending().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if pending.sending.as_ref().is_some_and(|sent| sent.id == batch.id) {
                pending.sending = None;
            }
            write_pending(path, &pending);
        }
        // The platform says the owner does not share: stop and drop.
        Err(Refused::NotShared) => set_sharing(false, path),
        Err(Refused::Other) => {}
    }
}

enum Refused {
    NotShared,
    Other,
}

/// The platform origin and bearer this machine calls with: a Cloud machine's
/// join credential (to its own hub), else the person's token from the app.
async fn caller(cloud: bool) -> Option<(String, zeroize::Zeroizing<String>)> {
    if cloud {
        let (origin, bearer) = crate::deps::remote::Remote::joined_bearer().ok().flatten()?;
        return Some((origin, zeroize::Zeroizing::new(bearer)));
    }
    let (token, origin) = crate::hosted_mcp::person_token().await.ok()?;
    Some((origin, zeroize::Zeroizing::new(token.as_str().to_owned())))
}

fn client() -> Option<reqwest::Client> {
    // The TLS provider reqwest's rustls needs, as `deps/remote.rs` installs it.
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .timeout(CALL_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()
}

async fn upload(install: &str, batch: &Batch, cloud: bool) -> Result<(), Refused> {
    let (origin, bearer) = caller(cloud).await.ok_or(Refused::Other)?;
    let response = client()
        .ok_or(Refused::Other)?
        .post(format!("{origin}/v1/install-counts"))
        .bearer_auth(bearer.as_str())
        .json(&serde_json::json!({
            "install": install,
            "batch": batch.id,
            "counts": batch.counts,
            "manifests": batch.manifests,
        }))
        .send()
        .await
        .map_err(|_| Refused::Other)?;
    match response.status().as_u16() {
        200..=299 => Ok(()),
        403 => Err(Refused::NotShared),
        _ => Err(Refused::Other),
    }
}

/// Tells the platform the person's choice (a Mac, the person's token).
async fn tell(share: bool) -> Result<(), ()> {
    let (origin, bearer) = caller(false).await.ok_or(())?;
    let response = client()
        .ok_or(())?
        .put(format!("{origin}/v1/install-counts/consent"))
        .bearer_auth(bearer.as_str())
        .json(&serde_json::json!({ "share": share }))
        .send()
        .await
        .map_err(|_| ())?;
    response.status().is_success().then_some(()).ok_or(())
}

/// Asks the platform whether this Cloud machine's owner shares.
async fn ask_owner() -> Option<bool> {
    let (origin, bearer) = caller(true).await?;
    let response = client()?
        .get(format!("{origin}/v1/install-counts/consent"))
        .bearer_auth(bearer.as_str())
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let answer: serde_json::Value = response.json().await.ok()?;
    answer.get("share").and_then(serde_json::Value::as_bool)
}

fn told_path(path: &Path) -> PathBuf {
    path.with_file_name("install-counts-told.json")
}

fn read_told(path: &Path) -> Told {
    std::fs::read(told_path(path))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn write_told(path: &Path, told: Told) {
    if let Ok(bytes) = serde_json::to_vec(&told) {
        let _ = std::fs::write(told_path(path), bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_keeps_clean_keys_bounded() {
        let mut pending = Pending::default();
        pending.add("npm", Some("npm:react"));
        pending.add("npm", Some("npm:react"));
        pending.add("npm", Some("npm:@bad"));
        pending.add("npm", Some("a path/with spaces"));
        pending.add("uv", None);
        pending.add("Bad Manager", None);
        assert_eq!(pending.counts.get("npm:react"), Some(&2));
        assert_eq!(pending.counts.len(), 1, "unclean keys are never kept: {pending:?}");
        assert_eq!(pending.manifests.get("uv"), Some(&1));
        assert_eq!(pending.manifests.len(), 1);

        let mut full = Pending::default();
        for i in 0..MAX_KEYS + 5 {
            full.add("npm", Some(&format!("npm:p{i}")));
        }
        assert_eq!(full.counts.len(), MAX_KEYS);
        full.add("npm", Some("npm:p0"));
        assert_eq!(full.counts.get("npm:p0"), Some(&2), "a known key still counts past the cap");
    }

    #[test]
    fn a_batch_is_resent_with_its_id_until_accepted() {
        let mut pending = Pending::default();
        assert!(
            pending.next_batch(|| Some("a".repeat(24))).is_none(),
            "nothing pending: no upload"
        );
        pending.add("npm", Some("npm:react"));
        let first = pending.next_batch(|| Some("a".repeat(24))).unwrap();
        assert_eq!(first.counts.get("npm:react"), Some(&1));
        assert!(pending.counts.is_empty(), "the batch took the counts");
        // A count made while the batch is out waits for the next batch.
        pending.add("npm", Some("npm:zod"));
        let retry = pending.next_batch(|| Some("b".repeat(24))).unwrap();
        assert_eq!(retry, first, "a retry resends the same batch and id");
        pending.sending = None;
        let next = pending.next_batch(|| Some("b".repeat(24))).unwrap();
        assert_eq!(next.id, "b".repeat(24));
        assert_eq!(next.counts.keys().collect::<Vec<_>>(), ["npm:zod"]);
    }

    #[test]
    fn the_setting_reads_nested_or_dotted_and_is_off_by_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cmux.json");
        assert!(!setting_on(&path), "no file: off");
        std::fs::write(&path, r#"{"diagnostics": {"shareInstallCounts": true}}"#).unwrap();
        assert!(setting_on(&path));
        std::fs::write(&path, r#"{"diagnostics.shareInstallCounts": true}"#).unwrap();
        assert!(setting_on(&path));
        std::fs::write(&path, r#"{"diagnostics": {"usagePatterns": true}}"#).unwrap();
        assert!(!setting_on(&path), "Usage Patterns alone shares nothing");
    }

    #[test]
    fn install_ids_are_24_hex_and_differ() {
        let a = new_install_id().unwrap();
        let b = new_install_id().unwrap();
        assert_eq!(a.len(), 24);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(a, b);
    }
}
