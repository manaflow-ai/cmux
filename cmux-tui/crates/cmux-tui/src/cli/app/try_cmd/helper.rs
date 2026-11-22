//! The Screen Sharing helper a live try carries: `mac-live.json`'s top-level
//! `screen_sharing_helper` (a key every older CLI ignores, so its payloads stay
//! readable to them), the signed `<app> Screen Sharing.app` of the commit's
//! cmux-rd host (plans/cmux-next/screen-sharing-helper.md).
//!
//! The app and the daemon never fall back to `bin/cmux rd serve` once a helper
//! is bundled, so a try that changes the host's code changes this bundle. It is
//! zipped by CI (cmux-tui-team-signed.yml: the NEXT nightly's bundle id and
//! Developer ID team, so the Screen Recording and Accessibility grants carry
//! over) and checked here against the INSTALLED helper's own designated
//! requirement before it replaces the installed bundle by rename. No key, no
//! helper in the app, another bundle id or an ad hoc installed helper leaves
//! the app's helper as it is: nothing is ever removed.
//!
//! One identity, as cmux#47409's release guard (check-screen-share-identity.sh) keeps it: the
//! key names the requirement CI read back from `codesign -d -r-`, byte for byte the Developer
//! ID form [`developer_id_requirement`] builds (identifier, anchor apple generic, the Developer
//! ID intermediate and leaf fields, the team's OU; never a cdhash), and the installed helper's
//! own requirement must be that same string, or the try is refused.

use std::fs;
use std::path::{Component, Path, PathBuf};

use cmux_host::updater::channel::{self, Binary};
use serde::Deserialize;
use serde_json::{Value, json};

use super::live::{self, Store, Wanted};

/// The payload's key.
pub(super) const KEY: &str = "screen_sharing_helper";
/// The zip CI publishes under the commit (`cmux-tui/<commit>/<ZIP>`).
pub(super) const ZIP: &str = "cmux-screen-sharing-helper-aarch64-apple-darwin.zip";
/// The app's folder that holds the helper.
pub(super) const LIBRARY: &str = "Contents/Library";
/// Every channel's helper bundle ends with this (`cmux NIGHTLY Screen Sharing.app`).
pub(super) const SUFFIX: &str = " Screen Sharing.app";
/// The helper's executable (bundle-screen-sharing-helper.sh `EXECUTABLE`).
pub(super) const EXECUTABLE: &str = "cmux-screen-sharing";
/// A helper zip is a few megabytes.
pub(super) const ZIP_MAX_BYTES: u64 = 128 * 1024 * 1024;
/// The staging folder's prefix beside the installed helper (hidden: no glob of `* Screen Sharing.app` sees it).
const STAGING_PREFIX: &str = ".app-try-helper-";

/// `screen_sharing_helper` in `mac-live.json`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct HelperFile {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    /// The bundle id CI signed it as (`<app id>.screen-sharing`).
    pub bundle_id: String,
    /// The Developer ID team CI signed it with.
    #[serde(default)]
    pub team: Option<String>,
    /// The designated requirement CI read back from the signed helper (`codesign -d -r-`):
    /// [`developer_id_requirement`] of `bundle_id` and `team`, byte for byte.
    #[serde(default)]
    pub designated_requirement: Option<String>,
}

/// The designated requirement of a Developer ID signed bundle `id` of `team`, exactly as
/// `codesign -d -r-` prints it for the NIGHTLY's helper: the identifier, Apple's anchor, the
/// Developer ID intermediate (`certificate 1[field.1.2.840.113635.100.6.2.6]`), the Developer
/// ID Application leaf (`certificate leaf[field.1.2.840.113635.100.6.1.13]`) and the team's OU.
/// CI compares the helper it signed against the same string (screen_sharing_helper_release.py).
pub(super) fn developer_id_requirement(id: &str, team: &str) -> String {
    format!(
        "identifier \"{id}\" and anchor apple generic and \
         certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and \
         certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and \
         certificate leaf[subject.OU] = \"{team}\""
    )
}

/// A Developer ID team id: ten upper-case letters and digits.
fn plain_team(team: &str) -> bool {
    team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

/// The helper a live plan brings, its url checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct WantedHelper {
    pub file: HelperFile,
    pub fetch_url: String,
}

/// The helper of `helper` (the payload's key), checked as the binaries are: its url is the
/// commit's own publication, its sha256 a sha256, its size in range. `None` when the build
/// carries none.
pub(super) fn wanted(
    helper: Option<&HelperFile>,
    commit: &str,
    base: &str,
) -> Result<Option<WantedHelper>, String> {
    let Some(file) = helper else { return Ok(None) };
    let url = format!("{}{commit}/{ZIP}", channel::FILES_PREFIX);
    if file.url != url {
        return Err(format!("{ZIP}: the url is not {url}"));
    }
    if !channel::lower_hex(&file.sha256, 64) {
        return Err(format!("{ZIP}: the sha256 is not a sha256"));
    }
    if file.size == 0 || file.size > ZIP_MAX_BYTES {
        return Err(format!("{ZIP}: size {} is out of range", file.size));
    }
    if !plain_bundle_id(&file.bundle_id) || !file.bundle_id.ends_with(".screen-sharing") {
        return Err(format!(
            "{ZIP}: {} is not a Screen Sharing helper's bundle id",
            file.bundle_id
        ));
    }
    let team = file.team.as_deref().unwrap_or_default();
    if !plain_team(team) {
        return Err(format!("{ZIP}: the team '{team}' is not a Developer ID team"));
    }
    let want = developer_id_requirement(&file.bundle_id, team);
    if file.designated_requirement.as_deref() != Some(want.as_str()) {
        return Err(format!(
            "{ZIP}: the designated requirement {:?} is not the Developer ID form {want:?}",
            file.designated_requirement.as_deref().unwrap_or("(none)")
        ));
    }
    let fetch_url = url.replacen(channel::FILES_PREFIX, base, 1);
    Ok(Some(WantedHelper { file: file.clone(), fetch_url }))
}

fn plain_bundle_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    !bytes.is_empty()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'.' || *b == b'-')
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
}

// ------------------------------------------------------------------ signatures

/// The tools a helper swap runs (`ditto`, `zipinfo` and `codesign` on a Mac; fakes in tests).
pub(super) trait Signing {
    /// Unpacks `zip` into the empty folder `into`, refusing an entry that leaves it.
    fn unpack(&self, zip: &Path, into: &Path) -> Result<(), String>;
    /// `bundle`'s own designated requirement.
    fn requirement(&self, bundle: &Path) -> Result<String, String>;
    /// Whether `bundle` is validly signed, sealed and satisfies `requirement`.
    fn verify(&self, bundle: &Path, requirement: &str) -> Result<(), String>;
}

/// The real tools: the same checks the share host's staging runs (share_host/helper.rs).
pub(super) struct SystemSigning;

impl Signing for SystemSigning {
    fn unpack(&self, zip: &Path, into: &Path) -> Result<(), String> {
        let listing = cmux_process::Command::new("/usr/bin/zipinfo")
            .arg("-1")
            .arg(zip)
            .stdin(cmux_process::Stdio::null())
            .output()
            .map_err(|e| format!("zipinfo: {e}"))?;
        if !listing.status.success() {
            return Err(format!("{} is not a zip", zip.display()));
        }
        let names = String::from_utf8_lossy(&listing.stdout);
        safe_entries(names.lines())?;
        let status = cmux_process::Command::new("/usr/bin/ditto")
            .args(["-x", "-k", "--norsrc", "--noqtn"])
            .arg(zip)
            .arg(into)
            .stdin(cmux_process::Stdio::null())
            .status()
            .map_err(|e| format!("ditto: {e}"))?;
        if status.success() { Ok(()) } else { Err(format!("ditto could not unpack {ZIP}")) }
    }

    fn requirement(&self, bundle: &Path) -> Result<String, String> {
        cmux_signed_bundle::designated_requirement(bundle)
    }

    fn verify(&self, bundle: &Path, requirement: &str) -> Result<(), String> {
        cmux_signed_bundle::verify(bundle, requirement)
    }
}

/// Refuses a zip entry that is absolute or climbs out (`..`): unpacked, it would land outside the staging folder.
pub(super) fn safe_entries<'a>(names: impl Iterator<Item = &'a str>) -> Result<(), String> {
    for name in names {
        let path = Path::new(name);
        if path.components().any(|part| !matches!(part, Component::Normal(_) | Component::CurDir)) {
            return Err(format!("{ZIP} holds the entry {name}, outside its folder"));
        }
    }
    Ok(())
}

// ------------------------------------------------------------------ the bundle

/// A bundle's `CFBundleIdentifier`.
pub(super) fn bundle_id(bundle: &Path) -> Option<String> {
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    let id = info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?.trim().to_owned();
    (!id.is_empty()).then_some(id)
}

/// The content digest that names a helper build (its executable, seal and Info.plist).
pub(super) fn digest(bundle: &Path) -> Result<String, String> {
    cmux_signed_bundle::digest_of(bundle, &cmux_signed_bundle::digest_parts(EXECUTABLE))
}

/// Copies the tree at `from` to the new path `to`: folders, files (with their modes) and links.
pub(super) fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(from).map_err(|e| format!("{}: {e}", from.display()))?;
    if meta.file_type().is_symlink() {
        let target = fs::read_link(from).map_err(|e| format!("{}: {e}", from.display()))?;
        return std::os::unix::fs::symlink(target, to)
            .map_err(|e| format!("{}: {e}", to.display()));
    }
    if meta.is_dir() {
        fs::create_dir(to).map_err(|e| format!("{}: {e}", to.display()))?;
        for entry in fs::read_dir(from).map_err(|e| format!("{}: {e}", from.display()))? {
            let entry = entry.map_err(|e| e.to_string())?;
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        }
        return fs::set_permissions(to, meta.permissions())
            .map_err(|e| format!("{}: {e}", to.display()));
    }
    fs::copy(from, to).map(|_| ()).map_err(|e| format!("{}: {e}", from.display()))
}

/// What a try does with the helper.
#[derive(Debug)]
pub(super) enum Prepared {
    /// The app's helper stays as it is, and why.
    Untouched(String),
    /// A checked bundle staged beside the installed one, to rename over it.
    Swap(Swap),
}

impl Prepared {
    pub(super) fn swap(&self) -> Option<&Swap> {
        match self {
            Self::Swap(swap) => Some(swap),
            Self::Untouched(_) => None,
        }
    }

    /// The receipt's `steps.screen_sharing_helper` when the swap did not run.
    pub(super) fn untouched_step(&self) -> Option<Value> {
        match self {
            Self::Untouched(why) => Some(json!({ "did": "untouched", "why": why })),
            Self::Swap(_) => None,
        }
    }
}

/// One swap of the app's helper bundle: the staged bundle, checked, renamed over the
/// installed one; the installed one kept aside in the staging folder until the try holds.
#[derive(Debug)]
pub(super) struct Swap {
    /// Removed with whatever is still in it when the swap is dropped.
    staging: tempfile::TempDir,
    pub installed: PathBuf,
    staged: PathBuf,
    aside: PathBuf,
    /// The installed bundle's digest before the swap, and the staged one's.
    pub from: String,
    pub to: String,
}

impl Swap {
    fn new(
        installed: PathBuf,
        staging: tempfile::TempDir,
        staged: PathBuf,
    ) -> Result<Self, String> {
        let from = digest(&installed)?;
        let to = digest(&staged)?;
        let aside = staging.path().join("prior.app");
        Ok(Self { staging, installed, staged, aside, from, to })
    }

    /// Renames the installed bundle aside and the staged one into its place; on a failure
    /// the installed one goes back.
    pub(super) fn swap(&self) -> Result<(), String> {
        fs::rename(&self.installed, &self.aside)
            .map_err(|e| format!("{}: {e}", self.installed.display()))?;
        if let Err(error) = fs::rename(&self.staged, &self.installed) {
            let path = self.installed.display();
            return Err(match fs::rename(&self.aside, &self.installed) {
                Ok(()) => format!("{path}: {error}"),
                Err(back) => format!("{path}: {error}; putting the helper back failed too: {back}"),
            });
        }
        Ok(())
    }

    /// Puts the installed bundle from before the swap back (a later check failed).
    pub(super) fn put_back(&self) -> Result<(), String> {
        let rejected = self.staging.path().join("rejected.app");
        fs::rename(&self.installed, &rejected)
            .map_err(|e| format!("{}: {e}", self.installed.display()))?;
        fs::rename(&self.aside, &self.installed)
            .map_err(|e| format!("{}: {e}", self.installed.display()))
    }

    /// Keeps the bundle from before the swap in the store (`helpers/<digest>/<name>`) for
    /// `undo`, and gives the receipt's step and undo record.
    pub(super) fn finish(&self, store: &Store) -> (Value, Value) {
        let step = json!({
            "did": "swapped", "bundle": self.installed.to_string_lossy(),
            "from": self.from, "to": self.to,
        });
        let name = self.installed.file_name().map(PathBuf::from).unwrap_or_default();
        let kept = store.root.join("helpers").join(&self.from).join(name);
        let keep = || -> Result<(), String> {
            if kept.is_dir() && digest(&kept).is_ok_and(|have| have == self.from) {
                return Ok(());
            }
            let dir = kept.parent().ok_or("the store has no folder")?;
            fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            let _ = fs::remove_dir_all(&kept);
            if fs::rename(&self.aside, &kept).is_err() {
                copy_tree(&self.aside, &kept)?;
            }
            Ok(())
        };
        let undo = match keep() {
            Ok(()) => json!({
                "bundle": self.installed.to_string_lossy(), "copy": kept.to_string_lossy(),
                "digest": self.from, "set": self.to,
            }),
            Err(error) => {
                json!({ "bundle": self.installed.to_string_lossy(), "copy": null, "error": error })
            }
        };
        (step, undo)
    }
}

/// A fresh hidden staging folder beside the installed helper (the same volume, so the swap is a rename).
fn staging_for(installed: &Path) -> Result<tempfile::TempDir, String> {
    let library = installed.parent().ok_or("the helper has no folder")?;
    tempfile::Builder::new()
        .prefix(STAGING_PREFIX)
        .tempdir_in(library)
        .map_err(|e| format!("{}: {e}", library.display()))
}

/// Downloads and checks the build's helper and stages it beside the app's: its zip's size and
/// sha256, its one bundle, its bundle id the installed helper's, and its signature against the
/// installed helper's own designated requirement. Nothing in the app changes here; an error is
/// a refused try.
pub(super) fn prepare(
    app: &Path,
    wanted: Option<&WantedHelper>,
    store: &Store,
    signing: &dyn Signing,
) -> Result<Prepared, String> {
    let Some(wanted) = wanted else {
        return Ok(Prepared::Untouched("the build carries no Screen Sharing helper".to_owned()));
    };
    // Two helpers, or cmux Computer Use.app beside one, refuse: a try never picks a holder.
    let Some(installed) = live::library_helper(app)? else {
        return Ok(Prepared::Untouched("the app bundles no Screen Sharing helper".to_owned()));
    };
    let have_id = bundle_id(&installed).unwrap_or_default();
    if have_id != wanted.file.bundle_id {
        return Ok(Prepared::Untouched(format!(
            "the app's helper is {have_id}, the build's {}",
            wanted.file.bundle_id
        )));
    }
    // The installed helper is the trust anchor: with no requirement of its own there is
    // nothing to check the build's against, so it stays.
    let requirement = match signing.requirement(&installed) {
        Ok(requirement) => requirement,
        Err(error) => {
            return Ok(Prepared::Untouched(format!(
                "the app's helper has no requirement ({error})"
            )));
        }
    };
    if requirement.contains("cdhash") {
        // An ad hoc helper's requirement is its own cdhash: no other build ever meets it.
        return Ok(Prepared::Untouched("the app's helper is signed ad hoc".to_owned()));
    }
    // One identity (cmux#47409): the installed helper's requirement is the one CI signed the
    // build's under, byte for byte, its Developer ID clauses included.
    let built = wanted.file.designated_requirement.as_deref().unwrap_or_default();
    if requirement != built {
        return Err(format!(
            "the installed Screen Sharing helper's requirement ({requirement}) is not the build's ({built}); nothing was swapped"
        ));
    }
    let zip = Wanted {
        file: ZIP.to_owned(),
        binary: Some(Binary {
            url: wanted.file.url.clone(),
            sha256: wanted.file.sha256.clone(),
            size: wanted.file.size,
        }),
        fetch_url: Some(wanted.fetch_url.clone()),
    };
    let zip = store.fetch(&zip)?.ok_or("the helper zip was not fetched")?;
    let staging = staging_for(&installed)?;
    let unpacked = staging.path().join("unpacked");
    fs::create_dir(&unpacked).map_err(|e| format!("{}: {e}", unpacked.display()))?;
    signing.unpack(&zip, &unpacked)?;
    let mut bundles = Vec::new();
    for entry in fs::read_dir(&unpacked).map_err(|e| e.to_string())?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name == "__MACOSX" {
            continue;
        }
        let real_dir = entry.file_type().is_ok_and(|kind| kind.is_dir());
        if !real_dir || !name.ends_with(SUFFIX) {
            return Err(format!("{ZIP} holds {name}, not only a Screen Sharing helper"));
        }
        bundles.push(entry.path());
    }
    let [staged] = bundles.as_slice() else {
        return Err(format!("{ZIP} holds {} Screen Sharing helpers, not one", bundles.len()));
    };
    let staged_id = bundle_id(staged).unwrap_or_default();
    if staged_id != have_id {
        return Err(format!("{ZIP}'s helper is {staged_id}, not {have_id}"));
    }
    if !staged.join("Contents/MacOS").join(EXECUTABLE).is_file() {
        return Err(format!("{ZIP}'s helper has no Contents/MacOS/{EXECUTABLE}"));
    }
    signing.verify(staged, &requirement).map_err(|e| {
        format!(
            "{ZIP}'s helper does not meet the installed helper's requirement ({requirement}): {e}"
        )
    })?;
    let swap = Swap::new(installed, staging, staged.clone())?;
    if swap.from == swap.to {
        return Ok(Prepared::Untouched("the app's helper is already the build's".to_owned()));
    }
    Ok(Prepared::Swap(swap))
}

/// The swap that puts back the helper a receipt's `undo.screen_sharing_helper` names, when
/// the installed one is still the one the try set; `None` when the try set none.
pub(super) fn undo(receipt: &Value) -> Result<Option<Swap>, String> {
    let Some(record) = receipt.pointer("/undo/screen_sharing_helper").filter(|v| !v.is_null())
    else {
        return Ok(None);
    };
    let field = |key: &str| record.get(key).and_then(Value::as_str);
    let bundle = PathBuf::from(field("bundle").ok_or("the receipt names no helper bundle")?);
    let Some(copy) = field("copy").map(PathBuf::from) else {
        return Err(format!(
            "the try kept no copy of {}: {}",
            bundle.display(),
            field("error").unwrap_or("no copy")
        ));
    };
    let (was, set) = (field("digest").unwrap_or_default(), field("set").unwrap_or_default());
    if !bundle.file_name().is_some_and(|name| name.to_string_lossy().ends_with(SUFFIX)) {
        return Err(format!("the receipt names {}, not a Screen Sharing helper", bundle.display()));
    }
    if digest(&bundle).ok().as_deref() != Some(set) {
        return Err(format!(
            "{} changed since the try (an update?): nothing was put back",
            bundle.display()
        ));
    }
    if digest(&copy).ok().as_deref() != Some(was) {
        return Err(format!("the kept {} is no longer the helper from before", copy.display()));
    }
    let staging = staging_for(&bundle)?;
    let staged = staging.path().join(bundle.file_name().unwrap_or_default());
    copy_tree(&copy, &staged)?;
    Swap::new(bundle, staging, staged).map(Some)
}
