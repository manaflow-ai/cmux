//! The content-addressed store (server.md 4.3 to 4.5; lane 1 vm-image.md
//! 4.5): `store/<sha256>/` (immutable packages), `profiles/<generation>/`
//! and `current`, flipped with one `rename(2)`.
//!
//! [`Store::apply`] takes the raw manifest bytes and signature and calls
//! `cmux_server_core::manifest::verify` itself, under the store lock, with
//! the persisted last applied `(sequence, sha256)`. So nothing can change
//! that record between verification and apply, and everything core refuses
//! (bad signature, expiry, other channel, lower sequence, a reused
//! sequence) is refused here.

pub mod fetch;
pub mod profile;
pub mod state;
pub mod unpack;

use std::fs;
use std::path::{Path, PathBuf};

use cmux_server_core::layout::Layout;
use cmux_server_core::manifest::{
    self, Applied, ManifestError, Package, TrustedKey, VerifyContext,
};
use cmux_server_core::reexec;

use crate::error::{Error, Result};
use crate::fsx;
use fetch::Fetch;
use profile::Entry;
use state::StoreLock;

/// Profiles kept after an apply (plus `current` when it is older).
pub const KEEP_PROFILES: usize = 3;
/// The largest manifest or signature file accepted.
pub const MANIFEST_LIMIT: u64 = 1 << 20;
const MARKER: &str = ".cmux-package";

/// The paths of one store root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Store {
    pub root: PathBuf,
    pub store: PathBuf,
    pub profiles: PathBuf,
    pub current: PathBuf,
    /// `<state>/updater.json`.
    pub record: PathBuf,
    /// The re-exec binary's file name on this layout's platform.
    pub reexec_binary: String,
}

/// One manifest to apply.
pub struct ApplyRequest<'a> {
    pub manifest: &'a [u8],
    pub signature: &'a [u8],
    pub keys: &'a [TrustedKey],
    /// The machine's `server.channel`.
    pub channel: &'a str,
    /// The running `cmux` version.
    pub running_cmux: &'a str,
    /// The machine's roles; packages for other roles are skipped.
    pub roles: &'a [&'a str],
    pub now_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyReport {
    pub from: Option<u64>,
    pub to: u64,
    /// `current` moved.
    pub changed: bool,
    /// The same bytes as the last applied manifest.
    pub reapply: bool,
    pub fetched: Vec<String>,
    pub store_hits: Vec<String>,
    pub removed_profiles: Vec<u64>,
    pub removed_packages: Vec<String>,
}

/// What a verified manifest led to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplyOutcome {
    Applied(ApplyReport),
    /// The manifest needs a newer `cmux` (decision SV-R2): only its `cmux`
    /// package was fetched, verified and put in the store; `current` and
    /// the updater record did not move.
    NeedsNewerCmux(StagedCmux),
}

/// The verified `cmux` package of a manifest this binary cannot apply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StagedCmux {
    pub package: Package,
    pub min_cmux_version: String,
    pub sequence: u64,
    pub manifest_sha256: [u8; 32],
    /// `<store>/<sha256>`.
    pub dir: PathBuf,
    /// The package's `bin/cmux-server` (`reexec::REEXEC_BINARY`), resolved
    /// and checked by [`Store::verified_package_file`] while the store lock
    /// was held; `Err` says why it cannot run.
    pub program: std::result::Result<PathBuf, String>,
}

impl StagedCmux {
    /// The "needs newer cmux" refusal (exit 4), with `why` appended.
    pub fn refusal(&self, why: &str) -> Error {
        Error::rejected(format!(
            "manifest needs cmux {} or newer; the verified package is at {}. Run `{}/bin/cmux server upgrade` to apply it{why}",
            self.min_cmux_version,
            self.dir.display(),
            self.dir.display()
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Flip {
    pub from: Option<u64>,
    pub to: u64,
}

/// Exit classes for core's refusals: tampering, expiry and replays are
/// verification failures (7); a well-signed manifest that breaks a field
/// rule is rejected (4).
pub fn manifest_error(e: ManifestError) -> Error {
    match e {
        ManifestError::BadSignature => {
            Error::verification("manifest signature is invalid for every baked release key")
        }
        ManifestError::Parse(m) => Error::rejected(format!("manifest does not parse: {m}")),
        ManifestError::Invalid(m) => Error::rejected(format!("manifest is invalid: {m}")),
        ManifestError::Expired { expires_at_ms, now_ms } => Error::verification(format!(
            "manifest expired at {expires_at_ms} ms (now {now_ms} ms); refusing"
        )),
        ManifestError::Rollback { sequence, last_applied } => Error::verification(format!(
            "manifest sequence {sequence} is lower than the last applied {last_applied} \
             (downgrade or replay); refusing. Use `cmux server rollback` for an installed generation"
        )),
        ManifestError::SequenceReused { sequence } => Error::verification(format!(
            "manifest sequence {sequence} was applied before with other bytes; refusing"
        )),
        ManifestError::ChannelMismatch { expected, got } => Error::verification(format!(
            "manifest is for channel {got}, this server follows {expected}; refusing"
        )),
    }
}

impl Store {
    pub fn new(layout: &Layout) -> Store {
        Store {
            root: fsx::local(&layout.root),
            store: fsx::local(&layout.store),
            profiles: fsx::local(&layout.profiles),
            current: fsx::local(&layout.current),
            record: fsx::local(&layout.state).join("updater.json"),
            reexec_binary: reexec::reexec_binary(layout.platform),
        }
    }

    pub fn current_generation(&self) -> Option<u64> {
        profile::current_generation(&self.current)
    }

    pub fn generations(&self) -> Vec<u64> {
        profile::generations(&self.profiles)
    }

    pub fn last_applied(&self) -> Result<Option<Applied>> {
        state::load_applied(&self.record)
    }

    /// The packages of the current profile.
    pub fn current_entries(&self) -> Result<Vec<Entry>> {
        match self.current_generation() {
            Some(g) => profile::read_entries(&profile::profile_dir(&self.profiles, g)),
            None => Ok(Vec::new()),
        }
    }

    /// `<current>/pkgs/<name>`, when the current profile has that package.
    pub fn current_package(&self, name: &str) -> Option<PathBuf> {
        let path = self.current.join("pkgs").join(name);
        path.exists().then_some(path)
    }

    fn package_dir(&self, sha256: &str) -> PathBuf {
        self.store.join(sha256)
    }

    fn has_package(&self, sha256: &str) -> bool {
        self.package_dir(sha256).join(MARKER).is_file()
    }

    /// Verifies and applies one manifest; see the module docs. A manifest
    /// that needs a newer `cmux` stages that package and is refused here
    /// (exit 4); [`Store::apply_outcome`] returns it instead.
    pub fn apply(&self, req: &ApplyRequest<'_>, fetcher: &dyn Fetch) -> Result<ApplyReport> {
        match self.apply_outcome(req, fetcher)? {
            ApplyOutcome::Applied(report) => Ok(report),
            ApplyOutcome::NeedsNewerCmux(staged) => Err(staged.refusal("")),
        }
    }

    /// Like [`Store::apply`], but a manifest that needs a newer `cmux` is
    /// an outcome: its verified `cmux` package is staged in the store and
    /// returned, so the caller can re-exec into it (decision SV-R2).
    pub fn apply_outcome(
        &self,
        req: &ApplyRequest<'_>,
        fetcher: &dyn Fetch,
    ) -> Result<ApplyOutcome> {
        let _lock = StoreLock::acquire(&self.root)?;
        let last = self.last_applied()?;
        let ctx = VerifyContext {
            keys: req.keys,
            now_ms: req.now_ms,
            expected_channel: req.channel,
            last_applied: last,
            running_cmux: req.running_cmux,
        };
        let verified =
            manifest::verify(req.manifest, req.signature, &ctx).map_err(manifest_error)?;
        let packages: Vec<&Package> = verified.manifest.packages_for(req.roles).collect();
        if verified.needs_newer_cmux {
            return self
                .stage_newer_cmux(&verified, req.roles, fetcher)
                .map(ApplyOutcome::NeedsNewerCmux);
        }
        fsx::ensure_dir(&self.store, 0o755)?;
        let mut report = ApplyReport {
            from: self.current_generation(),
            to: verified.manifest.sequence,
            changed: false,
            reapply: verified.reapply,
            fetched: Vec::new(),
            store_hits: Vec::new(),
            removed_profiles: Vec::new(),
            removed_packages: Vec::new(),
        };
        let mut entries = Vec::new();
        for package in &packages {
            if self.has_package(&package.sha256) {
                report.store_hits.push(package.name.clone());
            } else {
                self.fetch_package(package, fetcher)?;
                report.fetched.push(package.name.clone());
            }
            entries.push(Entry {
                name: package.name.clone(),
                version: package.version.clone(),
                sha256: package.sha256.clone(),
            });
        }
        let manifest_sha256 = crate::host::hex(&verified.sha256);
        let input = profile::ProfileInput {
            generation: report.to,
            entries: &entries,
            manifest: req.manifest,
            signature: req.signature,
            manifest_sha256: &manifest_sha256,
        };
        profile::build(&self.store, &self.profiles, &input)?;
        if report.from != Some(report.to) {
            self.flip_locked(report.to)?;
            report.changed = true;
        }
        state::save_applied(&self.record, verified.applied())?;
        let (profiles, packages) = self.gc_locked(KEEP_PROFILES)?;
        report.removed_profiles = profiles;
        report.removed_packages = packages;
        Ok(ApplyOutcome::Applied(report))
    }

    /// The manifest needs a newer `cmux`: put only that package in the
    /// store (the same streaming SHA-256, size check and safe unpack as
    /// every package) and return it.
    fn stage_newer_cmux(
        &self,
        verified: &manifest::Verified,
        roles: &[&str],
        fetcher: &dyn Fetch,
    ) -> Result<StagedCmux> {
        let manifest = &verified.manifest;
        let Some(cmux) = reexec::cmux_package(manifest, roles) else {
            return Err(Error::rejected(format!(
                "manifest needs cmux {} or newer and has no cmux package",
                manifest.min_cmux_version
            )));
        };
        fsx::ensure_dir(&self.store, 0o755)?;
        if !self.has_package(&cmux.sha256) {
            self.fetch_package(cmux, fetcher)?;
        }
        let dir = self.package_dir(&cmux.sha256);
        let program = self
            .verified_package_file(cmux, &dir.join("bin").join(&self.reexec_binary))
            .map_err(|e| e.message);
        Ok(StagedCmux {
            package: cmux.clone(),
            min_cmux_version: manifest.min_cmux_version.clone(),
            sequence: manifest.sequence,
            manifest_sha256: verified.sha256,
            dir,
            program,
        })
    }

    /// Checks a file of a staged package before it is executed: the
    /// package directory carries the marker that only a verified unpack
    /// writes, for this exact SHA-256 and name, and `file` resolves (links
    /// followed) to a regular, executable file inside that directory.
    pub fn verified_package_file(&self, package: &Package, file: &Path) -> Result<PathBuf> {
        let refuse = |what: String| Error::verification(format!("refusing to run {what}"));
        let dir = self.package_dir(&package.sha256);
        let marker: serde_json::Value = fs::read(dir.join(MARKER))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .ok_or_else(|| refuse(format!("{}: no verified package marker", dir.display())))?;
        if marker["sha256"] != package.sha256.as_str() || marker["name"] != package.name.as_str() {
            return Err(refuse(format!("{}: the marker names another package", dir.display())));
        }
        let real_dir = fs::canonicalize(&dir).map_err(|e| Error::io(dir.display(), e))?;
        let real = fs::canonicalize(file)
            .map_err(|_| refuse(format!("{}: it does not exist in the package", file.display())))?;
        let meta = fs::metadata(&real).map_err(|e| Error::io(real.display(), e))?;
        if !real.starts_with(&real_dir) || !meta.is_file() || fsx::mode_of(&meta) & 0o111 == 0 {
            return Err(refuse(format!(
                "{}: not an executable file inside the verified package",
                file.display()
            )));
        }
        Ok(real)
    }

    /// Downloads, verifies and unpacks one package into `store/<sha256>`.
    fn fetch_package(&self, package: &Package, fetcher: &dyn Fetch) -> Result<()> {
        let downloads = self.root.join(".downloads");
        fsx::ensure_dir(&downloads, 0o700)?;
        let archive = fsx::temp_sibling(&downloads.join(&package.sha256), "part");
        fetch::download_verified(fetcher, &package.url, package.size, &package.sha256, &archive)?;
        let target = self.package_dir(&package.sha256);
        let staging = fsx::temp_sibling(&target, "staging");
        let result = (|| {
            unpack::unpack(&archive, &staging, unpack::Limits::for_archive(package.size))?;
            let marker = serde_json::json!({
                "name": package.name, "version": package.version, "sha256": package.sha256,
            });
            let bytes = serde_json::to_vec(&marker).map_err(|e| Error::internal(e.to_string()))?;
            fsx::atomic_write(&staging.join(MARKER), &bytes, 0o444)?;
            fsx::make_read_only(&staging)?;
            // A leftover directory without a marker is an interrupted unpack.
            fsx::remove_tree(&target)?;
            fs::rename(&staging, &target).map_err(|e| Error::io(target.display(), e))?;
            crate::sys::fsync_dir(&self.store).map_err(|e| Error::io(self.store.display(), e))
        })();
        let _ = fs::remove_file(&archive);
        if result.is_err() {
            let _ = fsx::remove_tree(&staging);
        }
        result
    }

    fn flip_locked(&self, generation: u64) -> Result<()> {
        let target = Path::new("profiles").join(generation.to_string());
        fsx::swap_symlink_pinned(&self.current, &target)
    }

    /// Points `current` at an installed generation (`upgrade --generation`).
    pub fn switch_to(&self, generation: u64) -> Result<Flip> {
        let _lock = StoreLock::acquire_existing(&self.root)?;
        self.switch_locked(generation)
    }

    fn switch_locked(&self, generation: u64) -> Result<Flip> {
        if !self.generations().contains(&generation) {
            return Err(Error::not_found(format!("generation {generation} is not installed")));
        }
        let from = self.current_generation();
        if from != Some(generation) {
            self.flip_locked(generation)?;
        }
        Ok(Flip { from, to: generation })
    }

    /// Flips back to `generation`, or to the newest generation older than
    /// the current one. The target is chosen under the lock, so a
    /// concurrent apply cannot move `current` in between.
    pub fn rollback(&self, generation: Option<u64>) -> Result<Flip> {
        let _lock = StoreLock::acquire_existing(&self.root)?;
        let target = match generation {
            Some(g) => g,
            None => {
                let current = self
                    .current_generation()
                    .ok_or_else(|| Error::not_found("nothing is installed"))?;
                self.generations()
                    .into_iter()
                    .filter(|g| *g < current)
                    .max()
                    .ok_or_else(|| Error::not_found("no earlier generation to roll back to"))?
            }
        };
        self.switch_locked(target)
    }

    /// Removes old profiles and unreferenced packages.
    pub fn gc(&self, keep: usize) -> Result<(Vec<u64>, Vec<String>)> {
        let _lock = StoreLock::acquire_existing(&self.root)?;
        self.gc_locked(keep)
    }

    fn gc_locked(&self, keep: usize) -> Result<(Vec<u64>, Vec<String>)> {
        let generations = self.generations();
        let current = self.current_generation();
        let keep_from = generations.len().saturating_sub(keep);
        let mut removed_profiles = Vec::new();
        for (i, g) in generations.iter().enumerate() {
            if i < keep_from && Some(*g) != current {
                fsx::remove_tree(&profile::profile_dir(&self.profiles, *g))?;
                removed_profiles.push(*g);
            }
        }
        let mut referenced = std::collections::BTreeSet::new();
        for g in self.generations() {
            for entry in profile::read_entries(&profile::profile_dir(&self.profiles, g))? {
                referenced.insert(entry.sha256);
            }
        }
        let mut removed_packages = Vec::new();
        for entry in fs::read_dir(&self.store).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let leftover = name.starts_with('.');
            let unreferenced = manifest::valid_sha256(&name) && !referenced.contains(&name);
            if leftover || unreferenced {
                fsx::remove_tree(&entry.path())?;
                if unreferenced {
                    removed_packages.push(name);
                }
            }
        }
        for entry in fs::read_dir(&self.profiles).into_iter().flatten().flatten() {
            if entry.file_name().to_string_lossy().starts_with('.') {
                fsx::remove_tree(&entry.path())?;
            }
        }
        fsx::prune_pins(&self.current, fsx::PIN_MAX_AGE)?;
        Ok((removed_profiles, removed_packages))
    }

    /// Uninstall: removes `current`, the profiles, the store, the lock and
    /// the root when it is then empty. State is elsewhere and stays.
    pub fn remove_all(&self) -> Result<()> {
        if !self.root.is_dir() {
            return Ok(());
        }
        {
            let _lock = StoreLock::acquire(&self.root)?;
            fsx::remove_tree(&self.current)?;
            fsx::prune_pins(&self.current, std::time::Duration::ZERO)?;
            fsx::remove_tree(&self.profiles)?;
            fsx::remove_tree(&self.store)?;
            fsx::remove_tree(&self.root.join(".downloads"))?;
        }
        fsx::remove_tree(&self.root.join(".lock"))?;
        let _ = fs::remove_dir(&self.root);
        Ok(())
    }
}
