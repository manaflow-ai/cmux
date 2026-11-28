use super::*;
use std::process::{Child, Command};
use std::time::Duration;

/// A fresh folder with an `X` folder and an `Applications` folder in it under
/// the system temp dir, removed on drop.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("sign-clone-sweep-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(dir.join("X")).unwrap();
        std::fs::create_dir_all(dir.join("Applications")).unwrap();
        Self(dir.canonicalize().unwrap())
    }

    fn x(&self) -> PathBuf {
        self.0.join("X")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The tests' machine: Linux's form of the kernel's "a program runs this file"
/// answer (opening a running executable for writing fails with ETXTBSY), and
/// one Applications folder.
struct TestProbe {
    applications: PathBuf,
}

impl Probe for TestProbe {
    fn open_elsewhere(&mut self, path: &Path) -> Option<bool> {
        const ETXTBSY: i32 = 26;
        match std::fs::OpenOptions::new().write(true).open(path) {
            Ok(_) => Some(false),
            Err(error) if error.raw_os_error() == Some(ETXTBSY) => Some(true),
            Err(_) => None,
        }
    }

    fn installed_apps(&mut self, app_name: &OsStr) -> Vec<PathBuf> {
        vec![self.applications.join(app_name)]
    }
}

fn probe(scratch: &Scratch) -> TestProbe {
    TestProbe { applications: scratch.0.join("Applications") }
}

/// A child process running from an executable; killed on drop.
struct Running(Child);

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn info_plist(id: &str) -> String {
    format!(
        "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict>\n\
         <key>CFBundleExecutable</key><string>cmux</string>\n\
         <key>CFBundleIdentifier</key>\n\t<string>{id}</string>\n</dict></plist>\n"
    )
}

fn write_exe(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// An installed `cmux NIGHTLY.app` of `id` in the scratch Applications folder;
/// returns its main executable.
fn install(scratch: &Scratch, id: &str) -> PathBuf {
    let contents = scratch.0.join("Applications/cmux NIGHTLY.app/Contents");
    let _ = std::fs::remove_dir_all(contents.parent().unwrap());
    std::fs::create_dir_all(&contents).unwrap();
    std::fs::write(contents.join("Info.plist"), info_plist(id)).unwrap();
    let main = contents.join("MacOS/cmux");
    write_exe(&main, b"main");
    main
}

/// A clone of `root_id`'s app, its `Info.plist` naming `plist_id`, with a
/// helper executable (a copy of `sleep`, so it can run) and, when `main` is
/// given, the main executable as a hard link to it, as Chromium makes one.
/// Returns the clone and the helper.
fn make_clone(
    x: &Path,
    root_id: &str,
    plist_id: &str,
    suffix: &str,
    main: Option<&Path>,
) -> (PathBuf, PathBuf) {
    let clone = x.join(format!("{root_id}.code_sign_clone/code_sign_clone.{suffix}"));
    let contents = clone.join("cmux NIGHTLY.app.bundle/Contents");
    let helper = contents.join("Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper");
    std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
    std::fs::write(contents.join("Info.plist"), info_plist(plist_id)).unwrap();
    std::fs::copy("/bin/sleep", &helper).unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    if let Some(main) = main {
        std::fs::create_dir_all(contents.join("MacOS")).unwrap();
        std::fs::hard_link(main, contents.join("MacOS/cmux")).unwrap();
    }
    (clone, helper)
}

/// Another app instance: a process running the clone's helper.
fn run_from(helper: &Path) -> Running {
    let child = Running(Command::new(helper).arg("60").spawn().unwrap());
    std::thread::sleep(Duration::from_millis(200));
    child
}

/// Birth and change times are whole ticks of the file system's clock.
fn tick() {
    std::thread::sleep(Duration::from_millis(50));
}

fn verdict_of<'a>(rows: &'a [Row], clone: &Path) -> &'a Verdict {
    &rows.iter().find(|row| row.path == clone).unwrap().verdict
}

#[test]
fn sign_clone_sweep_removes_only_the_old_unused_clone() {
    let scratch = Scratch::new("regression");
    let x = scratch.x();
    let id = "com.cmuxterm.app.nightly";
    let main = install(&scratch, id);
    // Earlier launches: one left over, one whose instance still runs.
    let (old, _) = make_clone(&x, id, id, "OldAbc", Some(&main));
    let (busy, busy_helper) = make_clone(&x, id, id, "Busy12", Some(&main));
    let other_instance = run_from(&busy_helper);
    tick();
    let started = SystemTime::now();
    tick();
    // This launch's own clone, made after the process started.
    let (own, _) = make_clone(&x, id, id, "New_99", Some(&main));

    let (rows, report) = pass(&x, started, Budget::UNLIMITED, false, &mut probe(&scratch));

    assert!(!old.exists(), "the leftover clone goes");
    assert!(busy.exists(), "a clone another instance runs from stays");
    assert!(own.exists(), "this launch's clone stays");
    assert_eq!((report.removed, report.kept_in_use), (1, 1), "{report:?}");
    assert!(report.reclaimed_bytes > 0, "{report:?}");
    assert_eq!(
        verdict_of(&rows, &old),
        &Verdict::Removed { reason: Reason::Leftover, dry_run: false }
    );
    assert!(matches!(verdict_of(&rows, &busy), Verdict::InUse { open } if open == &busy_helper));
    assert_eq!(verdict_of(&rows, &own), &Verdict::TooNew);
    drop(other_instance);
}

#[test]
fn sign_clone_sweep_two_instances_keep_each_others_clone_until_exit() {
    let scratch = Scratch::new("two-instances");
    let x = scratch.x();
    // A release and a nightly running side by side, both older than this sweep.
    let (release, release_helper) = make_clone(&x, FAMILY, FAMILY, "RelAaa", None);
    let nightly_id = "com.cmuxterm.app.nightly";
    let (nightly, nightly_helper) = make_clone(&x, nightly_id, nightly_id, "NigBbb", None);
    let release_instance = run_from(&release_helper);
    let nightly_instance = run_from(&nightly_helper);
    tick();

    let (_, report) = pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!((report.removed, report.kept_in_use), (0, 2), "{report:?}");
    assert!(release.exists() && nightly.exists());

    // The nightly quits: its clone is now a leftover; the release's stays.
    drop(nightly_instance);
    let (_, report) = pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!((report.removed, report.kept_in_use), (1, 1), "{report:?}");
    assert!(!nightly.exists());
    assert!(release.exists(), "the running release keeps its clone");
    drop(release_instance);
}

#[test]
fn sign_clone_sweep_names_superseded_clones_and_never_takes_a_live_one() {
    let scratch = Scratch::new("superseded");
    let x = scratch.x();
    let id = "com.cmuxterm.app.nightly";
    let old_main = install(&scratch, id);
    let (gone, _) = make_clone(&x, id, id, "Gone01", Some(&old_main));
    let (live, live_helper) = make_clone(&x, id, id, "Live01", Some(&old_main));
    let still_running = run_from(&live_helper);
    // An update replaces the installed app: a new main executable.
    let new_main = install(&scratch, id);
    let (current, _) = make_clone(&x, id, id, "Curr01", Some(&new_main));
    tick();

    let (rows, report) = pass(&x, SystemTime::now(), Budget::UNLIMITED, true, &mut probe(&scratch));
    assert_eq!(
        verdict_of(&rows, &gone),
        &Verdict::Removed { reason: Reason::Superseded, dry_run: true }
    );
    assert_eq!(
        verdict_of(&rows, &current),
        &Verdict::Removed { reason: Reason::Leftover, dry_run: true }
    );
    assert!(matches!(verdict_of(&rows, &live), Verdict::InUse { .. }), "superseded but alive");
    assert_eq!((report.removed, report.removed_superseded, report.kept_in_use), (2, 1, 1));
    assert!(gone.exists() && current.exists() && live.exists(), "a dry run removes nothing");

    let (_, report) = pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!((report.removed, report.removed_superseded), (2, 1), "{report:?}");
    assert!(!gone.exists() && !current.exists() && live.exists());
    drop(still_running);
}

#[test]
fn sign_clone_sweep_never_touches_another_apps_clones() {
    let scratch = Scratch::new("foreign");
    let x = scratch.x();
    // Another Chromium app's root beside ours, a look-alike id, and a clone
    // under a family root whose bundle is not that id.
    let browser = "org.example.Browser";
    let (other_app, _) = make_clone(&x, browser, browser, "Foreig", None);
    let (lookalike, _) = make_clone(&x, "com.cmuxterm.appx", "com.cmuxterm.appx", "Looks1", None);
    let tag = "com.cmuxterm.app.debug.tag";
    let (mislabeled, _) = make_clone(&x, tag, browser, "Mislab", None);
    let (ours, _) = make_clone(&x, tag, tag, "Ours12", None);
    tick();

    let (rows, report) =
        pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));

    assert!(other_app.exists() && lookalike.exists() && mislabeled.exists());
    assert!(!ours.exists());
    assert_eq!((report.removed, report.kept_foreign), (1, 1), "{report:?}");
    assert_eq!(rows.len(), 2, "other roots are not even listed: {rows:?}");
    assert_eq!(verdict_of(&rows, &mislabeled), &Verdict::Foreign { found: Some(browser.into()) });
}

#[test]
fn sign_clone_sweep_stops_at_its_budget_and_finishes_in_later_passes() {
    let scratch = Scratch::new("budget");
    let x = scratch.x();
    let id = "com.cmuxterm.app.debug";
    let root = x.join(format!("{id}.code_sign_clone"));
    for suffix in ["aaaaa1", "aaaaa2", "aaaaa3"] {
        make_clone(&x, id, id, suffix, None);
        tick();
    }
    let two = Budget { max_bytes: u64::MAX, max_clones: 2 };
    let (rows, first) = pass(&x, SystemTime::now(), two, false, &mut probe(&scratch));
    assert_eq!((first.removed, first.more), (2, true), "{first:?}");
    assert!(root.join("code_sign_clone.aaaaa3").exists(), "oldest first");
    assert_eq!(verdict_of(&rows, &root.join("code_sign_clone.aaaaa3")), &Verdict::NotReached);
    let (_, second) = pass(&x, SystemTime::now(), two, false, &mut probe(&scratch));
    assert_eq!((second.removed, second.more), (1, false), "{second:?}");
    // A byte budget stops the pass once reached.
    for suffix in ["bbbbb1", "bbbbb2"] {
        make_clone(&x, id, id, suffix, None);
    }
    tick();
    let one_byte = Budget { max_bytes: 1, max_clones: u32::MAX };
    let (_, third) = pass(&x, SystemTime::now(), one_byte, false, &mut probe(&scratch));
    assert_eq!((third.removed, third.more), (1, true), "{third:?}");
}

#[test]
fn sign_clone_sweep_skips_other_names_files_and_links() {
    let scratch = Scratch::new("names");
    let x = scratch.x();
    let root = x.join("com.cmuxterm.app.code_sign_clone");
    std::fs::create_dir_all(&root).unwrap();
    let outside = scratch.0.join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    for name in ["code_sign_clone.short", "code_sign_clone.toolong7", "other.abcdef"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
    }
    std::fs::write(root.join("code_sign_clone.file01"), b"").unwrap();
    std::os::unix::fs::symlink(&outside, root.join("code_sign_clone.link01")).unwrap();
    // A family root that is a link is not followed either.
    let dev = "com.cmuxterm.app.dev";
    let (linked_clone, _) = make_clone(&outside, dev, dev, "Linked", None);
    std::os::unix::fs::symlink(
        outside.join(format!("{dev}.code_sign_clone")),
        x.join(format!("{dev}.code_sign_clone")),
    )
    .unwrap();
    tick();
    let (rows, report) =
        pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!((rows, report), (Vec::new(), Report::default()));
    assert!(outside.is_dir() && linked_clone.exists(), "a link is never followed");
}

#[test]
fn sign_clone_scan_asks_only_single_name_executables() {
    let scratch = Scratch::new("scan");
    let clone = scratch.0.join("code_sign_clone.abcdef");
    let helper = clone.join("b.app.bundle/Contents/Frameworks/h.app/Contents/MacOS/h");
    write_exe(&helper, b"exe");
    // Not executable: never asked.
    std::fs::write(clone.join("b.app.bundle/Contents/Info.plist"), b"").unwrap();
    // The hard-linked main executable: the installed app's own file, never asked.
    let installed = scratch.0.join("installed-main");
    write_exe(&installed, b"main");
    std::fs::create_dir_all(clone.join("b.app.bundle/Contents/MacOS")).unwrap();
    std::fs::hard_link(&installed, clone.join("b.app.bundle/Contents/MacOS/b")).unwrap();
    // A link to a file outside: never followed.
    std::os::unix::fs::symlink(&installed, clone.join("link")).unwrap();

    let mut asked = Vec::new();
    let bytes = scan_clone(&clone, |file| {
        asked.push(file.to_path_buf());
        Some(false)
    });
    assert!(bytes.is_ok());
    assert_eq!(asked, vec![helper.clone()]);
    assert_eq!(scan_clone(&clone, |_| Some(true)), Err(Verdict::InUse { open: helper.clone() }));
    assert_eq!(scan_clone(&clone, |_| None), Err(Verdict::Unknown { at: helper }));
    let missing = scratch.0.join("missing");
    assert_eq!(scan_clone(&missing, |_| Some(false)), Err(Verdict::Unknown { at: missing }));
}

#[test]
fn sign_clone_family_is_the_cmux_ids_only() {
    for good in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.debug.pr-123_tag",
    ] {
        assert!(in_family(good), "{good}");
    }
    for bad in [
        "",
        "com.cmuxterm.appx",
        "com.cmuxterm.app.",
        "com.cmuxterm.app..x",
        "com.cmuxterm.app.a/b",
        "org.example.Browser",
        "xcom.cmuxterm.app",
    ] {
        assert!(!in_family(bad), "{bad}");
    }
}

#[test]
fn sign_clone_name_is_prefix_and_six_mkdtemp_characters() {
    for good in ["code_sign_clone.9gP34C", "code_sign_clone.a.b_c-", "code_sign_clone.tKdILk"] {
        assert!(is_clone_name(OsStr::new(good)), "{good}");
    }
    for bad in [
        "code_sign_clone.",
        "code_sign_clone.abc",
        "code_sign_clone.abcdefg",
        "code_sign_clone.ab cd!",
        "x.code_sign_clone.abcdef",
    ] {
        assert!(!is_clone_name(OsStr::new(bad)), "{bad}");
    }
}

#[test]
fn sign_clone_x_dir_resolves_only_under_the_allowed_root() {
    let scratch = Scratch::new("root");
    let allowed = scratch.0.join("folders");
    let user_temp = allowed.join("ab/cd/T");
    let x = allowed.join("ab/cd/X");
    std::fs::create_dir_all(&user_temp).unwrap();
    std::fs::create_dir_all(&x).unwrap();
    assert_eq!(x_dir(&user_temp, &allowed), Some(x));
    let elsewhere = scratch.0.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    assert_eq!(x_dir(&user_temp, &elsewhere), None);
    // An X that links out of the allowed root is resolved before the check.
    let other = allowed.join("ef/gh");
    std::fs::create_dir_all(other.join("T")).unwrap();
    std::os::unix::fs::symlink(scratch.x(), other.join("X")).unwrap();
    assert_eq!(x_dir(&other.join("T"), &allowed), None);
    assert_eq!(x_dir(&allowed.join("missing/T"), &allowed), None);
}

#[test]
fn sign_clone_plist_reads_xml_and_binary() {
    let xml = b"<?xml version=\"1.0\"?><plist><dict><key>CFBundleName</key>\
                <string>cmux</string><key>CFBundleIdentifier</key>\n  \
                <string>com.cmuxterm.app</string></dict></plist>";
    assert_eq!(plist_string(xml, "CFBundleIdentifier").as_deref(), Some("com.cmuxterm.app"));
    assert_eq!(plist_string(xml, "CFBundleExecutable"), None);
    // plistlib.dumps({...}, fmt=FMT_BINARY) of CFBundleExecutable (cmux),
    // CFBundleIdentifier (com.cmuxterm.app.nightly) and LSMinimumSystemVersion.
    let binary =
        hex("62706c6973743030d30102030405065f1012434642756e646c6545786563757461626c655f10124346\
         42756e646c654964656e7469666965725f10164c534d696e696d756d53797374656d56657273696f6e\
         54636d75785f1018636f6d2e636d75787465726d2e6170702e6e696768746c795431342e30080f2439\
         5257720000000000000101000000000000000700000000000000000000000000000077");
    let id = plist_string(&binary, "CFBundleIdentifier");
    assert_eq!(id.as_deref(), Some("com.cmuxterm.app.nightly"));
    assert_eq!(plist_string(&binary, "CFBundleExecutable").as_deref(), Some("cmux"));
    let cut = [&binary[..40], &binary[..binary.len() - 1], b"bplist00".as_slice(), b""];
    for truncated in cut {
        assert_eq!(plist_string(truncated, "CFBundleIdentifier"), None);
    }
}

fn hex(text: &str) -> Vec<u8> {
    let digits: Vec<u8> = text.bytes().filter(u8::is_ascii_hexdigit).collect();
    digits
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}

#[test]
fn sign_clone_removal_is_bound_to_the_checked_folder() {
    let scratch = Scratch::new("bound");
    let checked = scratch.0.join("code_sign_clone.Chk001");
    write_exe(&checked.join("b.app.bundle/Contents/MacOS/h"), b"exe");
    let outside = scratch.0.join("outside-file");
    std::fs::write(&outside, b"keep").unwrap();
    std::os::unix::fs::symlink(&outside, checked.join("b.app.bundle/link")).unwrap();
    let identity = Ident::of(&std::fs::symlink_metadata(&checked).unwrap());

    // The checked folder moves away and another, with saved files, takes its name.
    let moved = scratch.0.join("moved-away");
    std::fs::rename(&checked, &moved).unwrap();
    std::fs::create_dir_all(checked.join("docs")).unwrap();
    std::fs::write(checked.join("docs/saved.txt"), b"saved").unwrap();
    assert!(at::remove_checked(&checked, identity).is_err());
    assert_eq!(std::fs::read(checked.join("docs/saved.txt")).unwrap(), b"saved");

    // The checked folder itself goes, with everything in it; a link's target stays.
    at::remove_checked(&moved, identity).unwrap();
    assert!(!moved.exists());
    assert_eq!(std::fs::read(&outside).unwrap(), b"keep");
}

#[test]
fn sign_clone_dry_run_counts_the_bytes_the_real_pass_frees() {
    let scratch = Scratch::new("dry-bytes");
    let x = scratch.x();
    let id = "com.cmuxterm.app.nightly";
    let old_main = install(&scratch, id);
    write_exe(&old_main, &vec![7u8; 256 * 1024]);
    let (first, _) = make_clone(&x, id, id, "Old001", Some(&old_main));
    let (second, _) = make_clone(&x, id, id, "Old002", Some(&old_main));
    // An update replaces the installed app: the clones hold the old executable's only names.
    install(&scratch, id);
    tick();

    let (rows, dry) = pass(&x, SystemTime::now(), Budget::UNLIMITED, true, &mut probe(&scratch));
    assert_eq!(dry.removed, 2, "{rows:?}");
    assert!(first.exists() && second.exists());
    let (_, real) = pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!(real.removed, 2);
    assert!(real.reclaimed_bytes >= 256 * 1024, "{real:?}");
    assert_eq!(dry.reclaimed_bytes, real.reclaimed_bytes);
}

#[test]
fn sign_clone_too_new_clone_still_names_its_own_bundle() {
    let scratch = Scratch::new("too-new");
    let x = scratch.x();
    let id = "com.cmuxterm.app";
    let started = SystemTime::now() - Duration::from_secs(3600);
    let (ours, _) = make_clone(&x, id, id, "New001", None);
    let (mismatched, _) = make_clone(&x, id, "org.example.Browser", "New002", None);
    let (rows, _) = pass(&x, started, Budget::UNLIMITED, false, &mut probe(&scratch));
    assert_eq!(verdict_of(&rows, &ours), &Verdict::TooNew);
    assert_eq!(
        verdict_of(&rows, &mismatched),
        &Verdict::Foreign { found: Some("org.example.Browser".into()) }
    );
    assert!(ours.exists() && mismatched.exists());
}

#[test]
fn sign_clone_unreadable_folder_is_a_row_not_an_empty_folder() {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        return; // root reads any folder: nothing to show
    }
    let scratch = Scratch::new("unreadable");
    let x = scratch.x();
    let id = "com.cmuxterm.app";
    let (clone, _) = make_clone(&x, id, id, "Lock01", None);
    let root = clone.parent().unwrap().to_path_buf();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
    let (rows, report) =
        pass(&x, SystemTime::now(), Budget::UNLIMITED, false, &mut probe(&scratch));
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(verdict_of(&rows, &root), &Verdict::Unknown { at: root.clone() });
    assert_eq!(report.kept_in_use, 1);
    assert!(clone.exists());
}

#[test]
fn sign_clone_plist_reads_only_the_top_level_dictionary() {
    let read = |xml: &str| plist_string(xml.as_bytes(), "CFBundleIdentifier");
    let top = |inner: &str| {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD \
             PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist \
             version=\"1.0\"><dict>{inner}</dict></plist>\n"
        )
    };
    // A nested dictionary, an array and a comment come first; only the top-level key answers.
    let nested = top("<!-- <key>CFBundleIdentifier</key><string>com.cmuxterm.app</string> -->\
         <key>CFBundleURLTypes</key><array><dict><key>CFBundleIdentifier</key>\
         <string>com.cmuxterm.app</string></dict></array>\
         <key>Inner</key><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app</string></dict>\
         <key>LSUIElement</key><true/>\
         <key>CFBundleIdentifier</key><string>org.example.Browser</string>");
    assert_eq!(read(&nested).as_deref(), Some("org.example.Browser"));
    // Only nested ones: no answer.
    let only_nested = top(
        "<key>Inner</key><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app</string></dict>",
    );
    assert_eq!(read(&only_nested), None);
    // Malformed, a key given twice, an entity of a DTD, a root that is not a dictionary.
    let bad = [
        top("<key>CFBundleIdentifier</key><string>com.cmuxterm.app</string><key>Open</key><dict>"),
        top("<key>CFBundleIdentifier</key><string>com.cmuxterm.app</string>\
             <key>CFBundleIdentifier</key><string>com.cmuxterm.app</string>"),
        top("<key>CFBundleIdentifier</key><string>&cmux;</string>"),
        "<plist><array><string>com.cmuxterm.app</string></array></plist>".to_owned(),
        "<!DOCTYPE plist [<!ENTITY id \"com.cmuxterm.app\">]><plist><dict>\
         <key>CFBundleIdentifier</key><string>&id;</string></dict></plist>"
            .to_owned(),
    ];
    for xml in &bad {
        assert_eq!(read(xml), None, "{xml}");
    }
    assert_eq!(
        read(&top("<key>CFBundleIdentifier</key><string>com.cmuxterm.app.debug.a&amp;b</string>"))
            .as_deref(),
        Some("com.cmuxterm.app.debug.a&b")
    );
}

#[test]
fn sign_clone_cutoff_keeps_the_last_ten_minutes() {
    let now = SystemTime::now();
    assert_eq!(cutoff(now, now), now - MIN_AGE);
    let long_ago = now - Duration::from_secs(86_400);
    assert_eq!(cutoff(long_ago, now), long_ago);
}
