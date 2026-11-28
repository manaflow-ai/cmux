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
            (r.executable.file_name().unwrap().to_string_lossy().into_owned(), r.arguments.clone())
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
    let helper =
        Path::new("/A.app/Contents/Frameworks/A Helper (GPU).app/Contents/MacOS/A Helper (GPU)");
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
