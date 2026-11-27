//! A staged update's pre-warm (goal next-launch-instant, CMUX-571): what the
//! app's `StagedUpdatePrewarm` (CmuxNextUpdater) finds, runs and reads, so the
//! first launch after the update pays none of a new executable's first exec.
//!
//! - [`scan`]: the newest staged bundle of a build in Sparkle's installation
//!   folders, and the runs for it.
//! - [`read_pages`]: every page of the bundle's frameworks, read once.
//! - [`describe_exit`]: a run's exit status for the update log.
//! - [`write_marker`] / [`consume_marker`]: the build the last pre-warm ran,
//!   until that build's first launch takes it.
//!
//! The app starts the runs itself (its process runner, priority and caps);
//! everything here is blocking file I/O the app calls on its files lane.

use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The argument a pre-warm starts the staged app with: `CmuxNextApp.main()`
/// exits on it before anything else, so exec, dyld and static initializers run
/// and nothing more.
pub const ARGUMENT: &str = "--cmux-prewarm-launch";
/// The argument the last run starts the staged app with: Chromium's first
/// start in that copy, in a throwaway profile.
pub const CHROMIUM_ARGUMENT: &str = "--cmux-prewarm-chromium";
/// The bundled executables run once with `--version` (`Contents/Resources/bin`).
pub const BUNDLED_EXECUTABLES: [&str; 2] = ["cmux", "cmux-tui"];

/// One process the pre-warm starts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Run {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
}

/// The staged bundle a scan found and what runs for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Staged {
    pub bundle: PathBuf,
    pub runs: Vec<Run>,
}

/// What [`read_pages`] read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Pages {
    pub files: u64,
    pub pages: u64,
}

/// A request naming the staged build.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanRequest {
    /// Sparkle's staged installation folders, the app's own first.
    pub installations: Vec<PathBuf>,
    pub bundle_identifier: String,
    /// The staged build (`CFBundleVersion`).
    pub build: String,
}

/// The newest staged bundle of `request.build` and its runs, or None. Sparkle
/// 2's installer extracts each update two folders under the installation
/// folder (`Installation/<unique>/<unique>/<name>.app`, `AppInstaller`); the
/// newest bundle with this bundle id and build, in any installation folder,
/// wins.
pub fn scan(request: &ScanRequest) -> Option<Staged> {
    let mut newest: Option<(SystemTime, PathBuf)> = None;
    for installation in &request.installations {
        for one in children(installation) {
            for two in children(&one) {
                for bundle in children(&two) {
                    if bundle.extension().is_none_or(|e| e != "app") {
                        continue;
                    }
                    let Some(info) = info(&bundle) else { continue };
                    if string(&info, "CFBundleIdentifier") != Some(&request.bundle_identifier)
                        || string(&info, "CFBundleVersion") != Some(&request.build)
                    {
                        continue;
                    }
                    let modified = fs::metadata(&bundle)
                        .and_then(|m| m.modified())
                        .unwrap_or(SystemTime::UNIX_EPOCH);
                    if newest.as_ref().is_none_or(|(at, _)| modified > *at) {
                        newest = Some((modified, bundle));
                    }
                }
            }
        }
    }
    let (_, bundle) = newest?;
    let runs = runs(&bundle);
    Some(Staged { bundle, runs })
}

/// What runs for `bundle`: its executable with [`ARGUMENT`], each bundled
/// executable there with `--version`, each Chromium helper app with
/// `--version` (with no `--type` it loads the CEF framework and returns,
/// CEFShim/src/helper_main.mm), and last, with the framework's first load
/// paid, the app with [`CHROMIUM_ARGUMENT`].
pub fn runs(bundle: &Path) -> Vec<Run> {
    let mut runs = Vec::new();
    let app = info(bundle)
        .and_then(|info| string(&info, "CFBundleExecutable").cloned())
        .map(|name| bundle.join("Contents/MacOS").join(name))
        .filter(|path| executable(path));
    if let Some(app) = &app {
        runs.push(Run { executable: app.clone(), arguments: vec![ARGUMENT.into()] });
    }
    let version = || vec!["--version".to_owned()];
    for name in BUNDLED_EXECUTABLES {
        let path = bundle.join("Contents/Resources/bin").join(name);
        if executable(&path) {
            runs.push(Run { executable: path, arguments: version() });
        }
    }
    let mut helpers: Vec<PathBuf> = children(&bundle.join("Contents/Frameworks"))
        .into_iter()
        .filter(|p| {
            p.extension().is_some_and(|e| e == "app")
                && p.file_name().is_some_and(|n| n.to_string_lossy().contains(" Helper"))
        })
        .collect();
    helpers.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    for helper in helpers {
        let Some(name) = helper.file_stem() else { continue };
        let path = helper.join("Contents/MacOS").join(name);
        if executable(&path) {
            runs.push(Run { executable: path, arguments: version() });
        }
    }
    if let Some(app) = app {
        runs.push(Run { executable: app, arguments: vec![CHROMIUM_ARGUMENT.into()] });
    }
    runs
}

/// A run's exit status for the update log. A Chromium helper with no `--type`
/// exits 255 once it has loaded the CEF framework (`CefExecuteProcess` returns
/// -1; a failed load exits 1), so 255 there is the run doing its job.
pub fn describe_exit(executable: &Path, status: i32) -> String {
    let helper = executable.components().any(|c| {
        let c = c.as_os_str().to_string_lossy();
        c.ends_with(".app") && c.contains(" Helper")
    });
    if helper && status == 255 {
        "exit 255 (framework loaded)".to_owned()
    } else {
        format!("exit {status}")
    }
}

/// Reads one byte of each page of every regular file under `root` (symbolic
/// links not followed) through a read-only mapping. Run on
/// `Contents/Frameworks` after the helpers, so each page faulted in here is
/// resident and checked when the first launch after the update maps it. The
/// pages are file-backed and clean: the system drops them first under memory
/// pressure.
pub fn read_pages(root: &Path) -> Pages {
    // SAFETY: getpagesize has no preconditions.
    let page = usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(4096).max(1);
    let mut result = Pages::default();
    let mut fold = 0u8;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                stack.push(path);
            } else if kind.is_file()
                && let Some(pages) = map_and_touch(&path, page, &mut fold)
            {
                result.files += 1;
                result.pages += pages;
            }
        }
    }
    std::hint::black_box(fold);
    result
}

/// The pages of one file, each read once through a private read-only mapping.
fn map_and_touch(path: &Path, page: usize, fold: &mut u8) -> Option<u64> {
    let size = usize::try_from(fs::symlink_metadata(path).ok()?.len()).ok()?;
    if size == 0 {
        return None;
    }
    let name = CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: a NUL-terminated path; the descriptor is closed below.
    let fd = unsafe { libc::open(name.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    // SAFETY: a fresh read-only private mapping of `size` bytes of `fd`.
    let base = unsafe {
        libc::mmap(std::ptr::null_mut(), size, libc::PROT_READ, libc::MAP_PRIVATE, fd, 0)
    };
    // SAFETY: `fd` is open and closed once; the mapping outlives it.
    unsafe { libc::close(fd) };
    if base == libc::MAP_FAILED {
        return None;
    }
    let mut pages = 0u64;
    let mut offset = 0usize;
    while offset < size {
        // SAFETY: `offset < size`, inside the mapping.
        *fold ^= unsafe { std::ptr::read_volatile(base.cast::<u8>().add(offset)) };
        pages += 1;
        offset += page;
    }
    // SAFETY: the mapping made above, unmapped once.
    unsafe { libc::munmap(base, size) };
    Some(pages)
}

/// Leaves `build` at `marker` (one line), its folder made first. A failure
/// leaves no marker: that launch records itself as not pre-warmed.
pub fn write_marker(build: &str, marker: &Path) -> bool {
    if let Some(parent) = marker.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let staging = marker.with_extension("staging");
    fs::write(&staging, format!("{build}\n")).is_ok() && fs::rename(&staging, marker).is_ok()
}

/// Whether the marker names `build` (a pre-warm ran this build before this,
/// its first launch); it is then removed, so a relaunch of the same build is
/// not pre-warmed. A marker of another build (a staged update not installed
/// yet) stays.
pub fn consume_marker(build: &str, marker: &Path) -> bool {
    if build.is_empty() {
        return false;
    }
    let Ok(text) = fs::read_to_string(marker) else { return false };
    if text.trim() != build {
        return false;
    }
    let _ = fs::remove_file(marker);
    true
}

/// The entries of a folder, hidden ones left out; empty when it cannot be read.
fn children(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| !e.file_name().as_bytes().starts_with(b"."))
        .map(|e| e.path())
        .collect()
}

/// A bundle's Info.plist, or None.
fn info(bundle: &Path) -> Option<plist::Dictionary> {
    plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?.into_dictionary()
}

fn string<'a>(info: &'a plist::Dictionary, key: &str) -> Option<&'a String> {
    match info.get(key)? {
        plist::Value::String(s) => Some(s),
        _ => None,
    }
}

/// Whether `path` is a file this process may execute (`access(X_OK)`, as
/// Foundation's `isExecutableFile`).
fn executable(path: &Path) -> bool {
    let Ok(name) = CString::new(path.as_os_str().as_bytes()) else { return false };
    // SAFETY: a NUL-terminated path.
    fs::metadata(path).is_ok_and(|m| m.is_file())
        && unsafe { libc::access(name.as_ptr(), libc::X_OK) } == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-prewarm-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn exe(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn bundle(at: &Path, id: &str, build: &str, executable: &str) {
        let mut info = plist::Dictionary::new();
        info.insert("CFBundleIdentifier".into(), id.into());
        info.insert("CFBundleVersion".into(), build.into());
        info.insert("CFBundleExecutable".into(), executable.into());
        fs::create_dir_all(at.join("Contents")).unwrap();
        plist::Value::Dictionary(info).to_file_xml(at.join("Contents/Info.plist")).unwrap();
    }

    #[test]
    fn scan_finds_the_build_two_folders_down_and_plans_its_runs() {
        let root = temp("scan");
        let app = root.join("a/b/cmux NEXT.app");
        bundle(&app, "com.cmux.next", "42", "cmux NEXT");
        exe(&app.join("Contents/MacOS/cmux NEXT"));
        exe(&app.join("Contents/Resources/bin/cmux"));
        exe(&app.join("Contents/Frameworks/cmux NEXT Helper (Renderer).app/Contents/MacOS/cmux NEXT Helper (Renderer)"));
        exe(&app.join("Contents/Frameworks/cmux NEXT Helper.app/Contents/MacOS/cmux NEXT Helper"));
        // Another build and another app id are not it.
        bundle(&root.join("c/d/old.app"), "com.cmux.next", "41", "x");
        bundle(&root.join("e/f/other.app"), "com.other", "42", "x");
        let request = ScanRequest {
            installations: vec![root.join("missing"), root.clone()],
            bundle_identifier: "com.cmux.next".into(),
            build: "42".into(),
        };
        let staged = scan(&request).expect("staged");
        assert_eq!(staged.bundle, app);
        let names: Vec<(String, Vec<String>)> = staged
            .runs
            .iter()
            .map(|r| {
                (
                    r.executable.file_name().unwrap().to_string_lossy().into_owned(),
                    r.arguments.clone(),
                )
            })
            .collect();
        assert_eq!(
            names,
            vec![
                ("cmux NEXT".into(), vec![ARGUMENT.into()]),
                ("cmux".into(), vec!["--version".into()]),
                ("cmux NEXT Helper (Renderer)".into(), vec!["--version".into()]),
                ("cmux NEXT Helper".into(), vec!["--version".into()]),
                ("cmux NEXT".into(), vec![CHROMIUM_ARGUMENT.into()]),
            ]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn scan_without_the_build_is_none_and_no_executable_means_no_app_runs() {
        let root = temp("none");
        let app = root.join("a/b/x.app");
        bundle(&app, "id", "1", "x");
        let request = |build: &str| ScanRequest {
            installations: vec![root.clone()],
            bundle_identifier: "id".into(),
            build: build.into(),
        };
        assert_eq!(scan(&request("2")), None);
        assert_eq!(scan(&request("1")).map(|s| s.runs), Some(vec![]));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn describe_exit_reads_a_helpers_255_as_loaded() {
        let helper = Path::new(
            "/A.app/Contents/Frameworks/A Helper (GPU).app/Contents/MacOS/A Helper (GPU)",
        );
        assert_eq!(describe_exit(helper, 255), "exit 255 (framework loaded)");
        assert_eq!(describe_exit(helper, 1), "exit 1");
        assert_eq!(describe_exit(Path::new("/A.app/Contents/MacOS/A"), 255), "exit 255");
    }

    #[test]
    fn read_pages_counts_each_regular_file_and_page() {
        let root = temp("pages");
        fs::create_dir_all(root.join("sub")).unwrap();
        fs::write(root.join("one"), vec![1u8; 10]).unwrap();
        fs::write(root.join("sub/two"), vec![2u8; 3 * 4096 + 1]).unwrap();
        fs::write(root.join("empty"), b"").unwrap();
        let page = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap();
        let pages = read_pages(&root);
        assert_eq!(pages.files, 2);
        assert_eq!(pages.pages, 1 + (3 * 4096 + 1u64).div_ceil(page));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_marker_is_taken_once_by_its_own_build() {
        let root = temp("marker");
        let marker = root.join("support/launch-prewarm");
        assert!(write_marker("42", &marker));
        assert!(!consume_marker("41", &marker));
        assert!(!consume_marker("", &marker));
        assert!(consume_marker("42", &marker));
        assert!(!consume_marker("42", &marker));
        let _ = fs::remove_dir_all(&root);
    }
}
