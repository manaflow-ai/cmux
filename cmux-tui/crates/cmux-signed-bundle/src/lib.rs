//! A verified copy of a signed macOS helper bundle, run from outside the app that carries it:
//! the bundle's content digest (its executable, its seal and its Info.plist), its signature
//! checked by `codesign` against a code requirement, one staged copy per digest under a
//! private root (copied with `ditto`, checked again, renamed into place), and the old copies
//! pruned. cmux Remote (`cmux-tui-core` `remote_host`) and the acpmux share host's Screen
//! Sharing helper stage their helpers through it, each with its own bundle ids, names and
//! requirement. The tools it runs exist on macOS only; elsewhere every call that runs one
//! fails, and the rest (the digest, the slots, the pruning) is tested on any Unix.

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
pub fn parse_designated(output: &str) -> Option<String> {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix("designated =>"))
        .map(|requirement| requirement.trim().to_owned())
        .filter(|requirement| !requirement.is_empty())
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
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
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
    root: &Path,
    parts: &[String],
    check: impl Fn(&Path) -> Result<(), String>,
) -> Result<Staged, String> {
    stage_with(source, root, parts, ditto, check)
}

/// A verified copy of `source` under `root/<first 16 hex of its digest>/<bundle name>`,
/// reused while the source is the same (its `.verified` marker and its own digest say so);
/// never followed through a symlink. A new copy is made beside it with `copy`, passes `check`
/// (the signature) and the digest again, then is renamed into its slot. The two newest copies
/// are kept ([`prune`]): a process of the previous build may still run from one.
pub fn stage_with(
    source: &Path,
    root: &Path,
    parts: &[String],
    copy: impl Fn(&Path, &Path) -> Result<(), String>,
    check: impl Fn(&Path) -> Result<(), String>,
) -> Result<Staged, String> {
    let digest = digest_of(source, parts)?;
    private_dir(root)?;
    let name = source.file_name().ok_or("bad bundle name")?;
    let slot = root.join(digest.get(..16).unwrap_or(&digest));
    let app = slot.join(name);
    let marker = slot.join(".verified");
    let ready = std::fs::read_to_string(&marker).is_ok_and(|text| text.trim() == digest)
        && digest_of(&app, parts).is_ok_and(|copied| copied == digest);
    if !ready {
        let temporary = root.join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).map_err(|e| format!("{e}"))?;
        let copied = temporary.join(name);
        if let Err(e) = copy(source, &copied) {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err(e);
        }
        if let Err(e) = check(&copied).and_then(|()| {
            (digest_of(&copied, parts)? == digest)
                .then_some(())
                .ok_or_else(|| "the copy differs from the source bundle".to_owned())
        }) {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err(e);
        }
        std::fs::write(temporary.join(".verified"), &digest).map_err(|e| format!("{e}"))?;
        let _ = std::fs::remove_dir_all(&slot);
        std::fs::rename(&temporary, &slot).map_err(|e| format!("{e}"))?;
    }
    prune(root, &slot);
    Ok(Staged { app, digest })
}

/// Keeps `current` and the newest other copy under `root`; removes the rest. Names starting
/// with `.` (a staging in progress) are left alone.
pub fn prune(root: &Path, current: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    let mut others: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path != current
                && !path.file_name().is_some_and(|name| name.to_string_lossy().starts_with('.'))
        })
        .filter_map(|path| Some((std::fs::metadata(&path).ok()?.modified().ok()?, path)))
        .collect();
    others.sort();
    others.pop();
    for (_, path) in others {
        let _ = std::fs::remove_dir_all(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake bundle `<dir>/<name>` whose executable holds `body`.
    fn bundle(dir: &Path, name: &str, body: &str) -> PathBuf {
        let app = dir.join(name);
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::create_dir_all(app.join("Contents/_CodeSignature")).unwrap();
        std::fs::write(app.join("Contents/MacOS/helper"), body).unwrap();
        std::fs::write(app.join("Contents/_CodeSignature/CodeResources"), "seal").unwrap();
        std::fs::write(app.join("Contents/Info.plist"), "plist").unwrap();
        app
    }

    fn copy_tree(from: &Path, to: &Path) -> Result<(), String> {
        std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
        for entry in std::fs::read_dir(from).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let target = to.join(entry.file_name());
            if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
                copy_tree(&entry.path(), &target)?;
            } else {
                std::fs::copy(entry.path(), target).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    #[test]
    fn the_digest_covers_the_executable_seal_and_plist() {
        let dir = tempfile::tempdir().unwrap();
        let parts = digest_parts("helper");
        let one = digest_of(&bundle(dir.path(), "A.app", "one"), &parts).unwrap();
        let two = digest_of(&bundle(dir.path(), "B.app", "two"), &parts).unwrap();
        assert_eq!(one.len(), 64);
        assert_ne!(one, two);
        assert!(digest_of(&dir.path().join("missing.app"), &parts).is_err());
    }

    #[test]
    fn a_copy_is_staged_once_per_digest_and_old_ones_pruned() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        let parts = digest_parts("helper");
        let first = bundle(&dir.path().join("v1"), "Helper.app", "one");
        let staged = stage_with(&first, &root, &parts, copy_tree, |_| Ok(())).unwrap();
        assert!(staged.executable("helper").is_file());
        assert!(staged.app.starts_with(&root));
        // Reused: a copier that fails is never asked.
        let again =
            stage_with(&first, &root, &parts, |_, _| Err("copied".into()), |_| Ok(())).unwrap();
        assert_eq!(again, staged);
        // Two more builds: the oldest copy goes, the two newest stay.
        for (n, body) in [(2, "two"), (3, "three")] {
            std::thread::sleep(std::time::Duration::from_millis(20));
            let next = bundle(&dir.path().join(format!("v{n}")), "Helper.app", body);
            stage_with(&next, &root, &parts, copy_tree, |_| Ok(())).unwrap();
        }
        let slots = std::fs::read_dir(&root).unwrap().count();
        assert_eq!(slots, 2);
        assert!(!staged.app.exists());
    }

    #[test]
    fn a_copy_that_fails_its_check_is_never_kept() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        let parts = digest_parts("helper");
        let source = bundle(dir.path(), "Helper.app", "one");
        let refused = stage_with(&source, &root, &parts, copy_tree, |_| Err("unsigned".into()));
        assert_eq!(refused, Err("unsigned".into()));
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
        // A copier that changes the bytes is caught by the digest.
        let tamper = |from: &Path, to: &Path| {
            copy_tree(from, to)?;
            std::fs::write(to.join("Contents/MacOS/helper"), "evil").map_err(|e| e.to_string())
        };
        let refused = stage_with(&source, &root, &parts, tamper, |_| Ok(()));
        assert_eq!(refused, Err("the copy differs from the source bundle".into()));
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_root_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        std::fs::create_dir_all(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(private_dir(&link).is_err());
        assert!(private_dir(&real).is_ok());
    }

    #[test]
    fn requirements_read_and_write_as_codesign_does() {
        assert_eq!(
            team_requirement("com.cmuxterm.app.screen-sharing", "7WLXT3NR37"),
            "identifier \"com.cmuxterm.app.screen-sharing\" and anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\""
        );
        let printed = "Executable=/x/Helper.app/Contents/MacOS/helper\n# designated => cdhash H\"ab\"\ndesignated => identifier \"a.b\" and anchor apple generic\n";
        assert_eq!(
            parse_designated(printed).as_deref(),
            Some("identifier \"a.b\" and anchor apple generic")
        );
        assert_eq!(parse_designated("Executable=/x\n"), None);
    }
}
