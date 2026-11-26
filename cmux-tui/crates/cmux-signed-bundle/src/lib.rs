//! A verified copy of a signed macOS helper bundle, run from outside the app that carries it:
//! the bundle's content digest (its executable, its seal and its Info.plist), its signature
//! checked by `codesign` against a code requirement, and ONE copy per helper bundle id at a
//! fixed path, [`helper_folder`] (`~/Library/Application Support/cmux-next/helper/<bundle
//! id>/<bundle name>.app`).
//!
//! The path never changes between builds: macOS keeps a screen-capture approval per executable
//! path (replayd's `ScreenCaptureApprovals.plist`), so a copy per build digest asked the person
//! again after every update ("is requesting to bypass the system private window picker"). A
//! build whose helper differs replaces the copy in place instead: a temporary copy is checked
//! against the requirement and the digest, then swapped in with one `renamex_np(RENAME_SWAP)`.
//! A process of the old build keeps its open files; the next start runs the new copy.
//!
//! Every stager of a folder (the cmux-tui daemon's Computer Use, the acpmux share host, the
//! app's `SignedHelperStaging.swift`, the DEV files host) takes an exclusive `flock` on the
//! folder's `.lock` first, so two never swap at once. The marker `.verified` holds the digest
//! the copy was checked to have.
//!
//! The tools it runs exist on macOS only; elsewhere every call that runs one fails, and the
//! rest (the digest, the folder, the swap, the lock, the old-copy cleanup) is tested on any Unix.

use cmux_process::{Command, Stdio};
use std::io::Read;
use std::path::{Path, PathBuf};

/// A staged copy: the bundle and the content digest it was checked to have.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Staged {
    pub app: PathBuf,
    /// Lowercase hex SHA-256 over the bundle's digest parts.
    pub digest: String,
}

impl Staged {
    /// The executable `Contents/MacOS/<executable>` of the copy.
    pub fn executable(&self, executable: &str) -> PathBuf {
        self.app.join("Contents/MacOS").join(executable)
    }
}

/// The names a channel's helper bundle ends with, preferred first: `<app> Helper.app` (`cmux
/// NIGHTLY Helper.app`), then the name builds before it carried, `<app> Screen Sharing.app`
/// (an older installed app). The bundle id, `<app id>.screen-sharing`, is the same in both.
pub const HELPER_BUNDLE_SUFFIXES: [&str; 2] = [" Helper.app", " Screen Sharing.app"];
/// The installed apps whose helper a daemon outside any app may run, in order.
pub const INSTALLED_APPS: [&str; 2] = ["/Applications/cmux NIGHTLY.app", "/Applications/cmux.app"];

/// The folder that holds the one copy of the helper with bundle id `bundle_id`:
/// `~/Library/Application Support/cmux-next/helper/<bundle_id>`. The app's
/// `SignedHelperStaging.screenSharing` names the same folder.
pub fn helper_folder(user_home: &Path, bundle_id: &str) -> PathBuf {
    user_home.join("Library/Application Support/cmux-next/helper").join(bundle_id)
}

/// The app bundle holding `executable` (`X.app/Contents/Resources/bin/acpmux` -> `X.app`).
pub fn app_of(executable: &Path) -> Option<PathBuf> {
    executable
        .ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"))
        .map(Path::to_path_buf)
}

/// The rank of a helper bundle name in [`HELPER_BUNDLE_SUFFIXES`], or None for another name.
fn suffix_rank(name: &str) -> Option<usize> {
    HELPER_BUNDLE_SUFFIXES.iter().position(|suffix| name.ends_with(suffix))
}

/// The helper bundles `app` carries in `Contents/Library` (names ending in one of
/// [`HELPER_BUNDLE_SUFFIXES`] with `Contents/MacOS/<executable>` inside): the current name
/// first, then sorted.
pub fn helpers_in(app: &Path, executable: &str) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(app.join("Contents/Library")) else { return Vec::new() };
    let mut found: Vec<(usize, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.join("Contents/MacOS").join(executable).is_file())
        .filter_map(|p| Some((suffix_rank(&p.file_name()?.to_string_lossy())?, p)))
        .collect();
    found.sort();
    found.into_iter().map(|(_, path)| path).collect()
}

/// The apps to look in for a helper, in order: the app holding `exe`, then `installed`
/// (without repeating one).
pub fn search_apps(exe: &Path, installed: &[&str]) -> Vec<PathBuf> {
    let mut apps: Vec<PathBuf> = app_of(exe).into_iter().collect();
    for app in installed.iter().map(PathBuf::from) {
        if !apps.contains(&app) {
            apps.push(app);
        }
    }
    apps
}

/// The first helper bundle found in `apps`, in order.
pub fn first_helper(apps: &[PathBuf], executable: &str) -> Option<PathBuf> {
    apps.iter().find_map(|app| helpers_in(app, executable).into_iter().next())
}

/// The parts of a bundle whose bytes make its digest, for an executable named `executable`:
/// the executable, the seal (`_CodeSignature/CodeResources`) and the Info.plist.
pub fn digest_parts(executable: &str) -> [String; 3] {
    [
        format!("Contents/MacOS/{executable}"),
        "Contents/_CodeSignature/CodeResources".to_owned(),
        "Contents/Info.plist".to_owned(),
    ]
}

/// The SHA-256 of `parts` of `app`, read in order, as lowercase hex.
pub fn digest_of(app: &Path, parts: &[String]) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    for part in parts {
        let mut file = std::fs::File::open(app.join(part)).map_err(|e| format!("{part}: {e}"))?;
        let mut buffer = vec![0_u8; 1 << 20];
        loop {
            let count = file.read(&mut buffer).map_err(|e| format!("{part}: {e}"))?;
            let Some(read) = buffer.get(..count).filter(|read| !read.is_empty()) else { break };
            hasher.update(read);
        }
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// The bundle's `CFBundleIdentifier`, read by `plutil`.
pub fn bundle_id(app: &Path) -> Option<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleIdentifier", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .stdin(Stdio::null())
        .output()
        .ok()?;
    let id = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (output.status.success() && !id.is_empty()).then_some(id)
}

/// The requirement of a bundle `id` signed by Apple-issued certificates of `team`: what a
/// Developer ID (or pinned Apple Development) build of cmux carries.
pub fn team_requirement(id: &str, team: &str) -> String {
    format!(
        "identifier \"{id}\" and anchor apple generic and certificate leaf[subject.OU] = \"{team}\""
    )
}

/// The designated requirement in `codesign -d -r-`'s output (`designated => <requirement>`).
/// An ad-hoc signature (a CI or "sign to run locally" DEV build) has no explicit one, and
/// codesign prints its implied requirement commented out, `# designated => cdhash H"…"`: that
/// one is read when no explicit one is printed, so a copy checked against it must be the very
/// same code (its code directory hash), which is stricter than any signer's requirement.
pub fn parse_designated(output: &str) -> Option<String> {
    let found = |prefix: &str| {
        output
            .lines()
            .find_map(|line| line.trim().strip_prefix(prefix))
            .map(|requirement| requirement.trim().to_owned())
            .filter(|requirement| !requirement.is_empty())
    };
    found("designated =>")
        .or_else(|| found("# designated =>").filter(|implied| implied.starts_with("cdhash H\"")))
}

/// `app`'s own designated requirement, as `codesign -d -r-` prints it. A copy checked against
/// it is the same code, signed the same way, whatever certificate signed it (a DEV build's
/// too).
pub fn designated_requirement(app: &Path) -> Result<String, String> {
    let output = Command::new("/usr/bin/codesign")
        .args(["-d", "-r-"])
        .arg(app)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if !output.status.success() {
        return Err(format!("its signature: {}", text.trim()));
    }
    parse_designated(&text).ok_or_else(|| "it has no designated requirement".to_owned())
}

/// Whether `app` is validly signed, sealed (deep, strict) and satisfies `requirement`.
pub fn verify(app: &Path, requirement: &str) -> Result<(), String> {
    let output = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--deep", "-R"])
        .arg(format!("={requirement}"))
        .arg(app)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("signature: {}", String::from_utf8_lossy(&output.stderr).trim()))
    }
}

/// Creates `dir` (and its parents) and makes it a 0700 directory; refuses a symlink or a file.
pub fn private_dir(dir: &Path) -> Result<(), String> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    // Every folder it makes is 0700, whatever the umask: the app's stager refuses a parent
    // with group or world write.
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let meta = std::fs::symlink_metadata(dir).map_err(|e| format!("{e}"))?;
    if !meta.is_dir() {
        return Err(format!("{} is not a directory", dir.display()));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

/// Copies `source` to `copy` with `ditto`, without resource forks or quarantine.
pub fn ditto(source: &Path, copy: &Path) -> Result<(), String> {
    let status = Command::new("/usr/bin/ditto")
        .args(["--norsrc", "--noqtn"])
        .arg(source)
        .arg(copy)
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("ditto: {e}"))?;
    if status.success() { Ok(()) } else { Err("cannot copy the bundle out of the app".into()) }
}

/// [`stage_with`] copying with [`ditto`].
pub fn stage(
    source: &Path,
    folder: &Path,
    parts: &[String],
    check: impl Fn(&Path) -> Result<(), String>,
) -> Result<Staged, String> {
    stage_with(source, folder, parts, ditto, check)
}

/// The lock every stager of a folder takes, and how long one waits for another.
const LOCK: &str = ".lock";
const LOCK_BUDGET: std::time::Duration = std::time::Duration::from_secs(120);
/// The marker beside the copy: the digest it was checked to have.
const MARKER: &str = ".verified";
/// The prefix of a stager's temporary folder.
const STAGING: &str = ".staging-";

/// The one verified copy of `source` at `folder/<bundle name>` (a fixed path: see the crate's
/// doc), under `folder`'s lock. Reused while its marker and its own digest say it is the
/// source's; never followed through a symlink. Otherwise a new copy is made in a temporary
/// folder beside it with `copy`, passes `check` (the signature) and the digest again, and is
/// swapped in atomically. Copies of the old per-digest layout in `folder` are removed.
pub fn stage_with(
    source: &Path,
    folder: &Path,
    parts: &[String],
    copy: impl Fn(&Path, &Path) -> Result<(), String>,
    check: impl Fn(&Path) -> Result<(), String>,
) -> Result<Staged, String> {
    let name =
        source.file_name().filter(|name| Path::new(name).extension().is_some_and(|e| e == "app"));
    let name = name.ok_or("bad bundle name")?;
    let digest = digest_of(source, parts)?;
    private_dir(folder)?;
    let _lock = lock(folder)?;
    remove_legacy_slots(folder);
    let app = folder.join(name);
    let marker = folder.join(MARKER);
    let ready = std::fs::symlink_metadata(&app).is_ok_and(|meta| meta.is_dir())
        && std::fs::read_to_string(&marker).is_ok_and(|text| text.trim() == digest)
        && digest_of(&app, parts).is_ok_and(|copied| copied == digest);
    if ready {
        return Ok(Staged { app, digest });
    }
    let temporary = folder.join(format!("{STAGING}{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&temporary);
    std::fs::create_dir_all(&temporary).map_err(|e| format!("{}: {e}", temporary.display()))?;
    let copied = temporary.join(name);
    let result = copy_checked(source, &copied, parts, &digest, &copy, &check)
        .and_then(|()| replace(&copied, &app, &marker, &digest));
    // After a swap the temporary folder holds the old copy: a process still running it keeps
    // its open files.
    let _ = std::fs::remove_dir_all(&temporary);
    result.map(|()| Staged { app, digest })
}

/// Copies `source` to `copied` and checks the copy: `check`, then its digest.
fn copy_checked(
    source: &Path,
    copied: &Path,
    parts: &[String],
    digest: &str,
    copy: &impl Fn(&Path, &Path) -> Result<(), String>,
    check: &impl Fn(&Path) -> Result<(), String>,
) -> Result<(), String> {
    copy(source, copied)?;
    check(copied)?;
    if digest_of(copied, parts)? == digest {
        Ok(())
    } else {
        Err("the copy differs from the source bundle".to_owned())
    }
}

/// Swaps the checked copy `copied` in at `app` and marks it with `digest`. The marker goes
/// first: a stager that stops between the swap and the new marker leaves a copy the next one
/// makes again, never a stale marker on a new copy.
fn replace(copied: &Path, app: &Path, marker: &Path, digest: &str) -> Result<(), String> {
    let _ = std::fs::remove_file(marker);
    swap_into(copied, app).map_err(|e| format!("{}: {e}", app.display()))?;
    let written = marker.with_extension(std::process::id().to_string());
    std::fs::write(&written, digest).map_err(|e| format!("{}: {e}", written.display()))?;
    std::fs::rename(&written, marker).map_err(|e| format!("{}: {e}", marker.display()))
}

/// Takes `folder`'s exclusive lock, waiting up to [`LOCK_BUDGET`] for another stager.
fn lock(folder: &Path) -> Result<cmux_file_lock::FileLock, String> {
    let path = folder.join(LOCK);
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    cmux_file_lock::FileLock::take_within(
        file,
        cmux_file_lock::Kind::Exclusive,
        LOCK_BUDGET,
        std::time::Duration::from_millis(50),
    )
    .map_err(|e| format!("{}: {e}", path.display()))
}

/// Puts the directory `new` at `dest`. A directory at `dest` is exchanged with `new` in one
/// step (`renamex_np(RENAME_SWAP)` on macOS), so `new` then holds the old copy and a launch
/// never meets a missing or half-written one; anything else there (a file, a symlink) is
/// unlinked, never followed; nothing there is a plain rename.
pub fn swap_into(new: &Path, dest: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(dest) {
        Ok(meta) if meta.is_dir() => exchange(new, dest),
        Ok(_) => {
            std::fs::remove_file(dest)?;
            std::fs::rename(new, dest)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => std::fs::rename(new, dest),
        Err(e) => Err(e),
    }
}

#[cfg(target_os = "macos")]
fn exchange(a: &Path, b: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let a = std::ffi::CString::new(a.as_os_str().as_bytes())?;
    let b = std::ffi::CString::new(b.as_os_str().as_bytes())?;
    // SAFETY: two NUL-terminated paths that outlive the call.
    let status = unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_SWAP) };
    if status == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

/// Elsewhere (the tests' platforms): the old copy moves into `a`'s place, then `a`'s into `b`'s.
#[cfg(not(target_os = "macos"))]
fn exchange(a: &Path, b: &Path) -> std::io::Result<()> {
    let aside = a.with_extension("old");
    std::fs::rename(b, &aside)?;
    std::fs::rename(a, b)?;
    std::fs::rename(&aside, a)
}

/// Whether `name` is a slot of the old per-digest layout (the first 16 hex of a digest).
fn is_legacy_slot(name: &str) -> bool {
    name.len() == 16 && name.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Removes the old per-digest copies (`<16 hex>/`) and stale staging folders in `root`, a
/// staging folder of ours, and nothing else; logs each. Under the folder's lock every staging
/// folder in it is a dead stager's. Returns what it removed.
pub fn remove_legacy_slots(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    let mut removed = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_dir = entry.file_type().is_ok_and(|kind| kind.is_dir());
        if is_dir && (is_legacy_slot(&name) || name.starts_with(STAGING)) {
            let path = entry.path();
            if std::fs::remove_dir_all(&path).is_ok() {
                eprintln!("cmux-signed-bundle: removed the old helper copy {}", path.display());
                removed.push(path);
            }
        }
    }
    removed
}

/// Removes an old per-digest staging root of ours (`legacy`: its `<16 hex>/` copies and staging
/// folders, [`remove_legacy_slots`]), then `legacy` and each parent below `stop` once empty.
/// Nothing else in them is touched. Returns the copies it removed.
pub fn remove_legacy_root(legacy: &Path, stop: &Path) -> Vec<PathBuf> {
    if !std::fs::symlink_metadata(legacy).is_ok_and(|meta| meta.is_dir()) {
        return Vec::new();
    }
    let removed = remove_legacy_slots(legacy);
    let mut dir = Some(legacy);
    while let Some(path) = dir.filter(|path| path.starts_with(stop) && *path != stop) {
        // Fails, and stops, on a folder that still holds anything.
        if std::fs::remove_dir(path).is_err() {
            break;
        }
        dir = path.parent();
    }
    removed
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
