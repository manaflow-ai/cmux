//! `cmux ext`: argument parsing, the scaffold passing validation, and
//! `ext dev --once` results and exit codes against a fake daemon that
//! answers as the real one does (apps-list's `local_dir`, `apps-changed`
//! with `local-reload` once the copied files land, a mount's scene or its
//! init failure).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::dev::{self, Phase};
use super::{DevOptions, Request, exit, parse, scaffold};
use crate::cli::GlobalArgs;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

fn dev_options(dir: &Path) -> DevOptions {
    DevOptions {
        dir: dir.to_path_buf(),
        once: true,
        remove_on_exit: false,
        install: false,
        build: None,
        build_timeout: dev::BUILD_TIMEOUT,
        bun: None,
    }
}

fn global(socket: &Path) -> GlobalArgs {
    GlobalArgs { socket: Some(socket.to_path_buf()), ..GlobalArgs::default() }
}

#[test]
fn parses_new_dev_list_remove_and_help() {
    assert_eq!(parse(&[]), Ok(Request::Help));
    assert_eq!(parse(&words("dev --help")), Ok(Request::Help));
    assert_eq!(
        parse(&words("new my-prs")),
        Ok(Request::New { name: "my-prs".into(), kind: "section".into(), dir: None })
    );
    assert_eq!(
        parse(&words("new w --kind section --dir /tmp/w")),
        Ok(Request::New { name: "w".into(), kind: "section".into(), dir: Some("/tmp/w".into()) })
    );
    let Ok(Request::Dev(options)) = parse(&words("dev")) else { panic!("dev") };
    assert_eq!(options.dir, PathBuf::from("."));
    assert!(!options.once && !options.remove_on_exit && options.install);
    let Ok(Request::Dev(options)) =
        parse(&words("dev ext/x --once --remove-on-exit --no-install --build make"))
    else {
        panic!("dev with options")
    };
    assert_eq!(options.dir, PathBuf::from("ext/x"));
    assert!(options.once && options.remove_on_exit && !options.install);
    assert_eq!(options.build.as_deref(), Some("make"));
    let Ok(Request::Dev(options)) = parse(&words("dev --remove-on-exit --keep")) else {
        panic!("keep")
    };
    assert!(!options.remove_on_exit, "--keep after --remove-on-exit keeps");
    assert_eq!(options.build_timeout, dev::BUILD_TIMEOUT);
    let Ok(Request::Dev(options)) = parse(&words("dev --build-timeout 5")) else {
        panic!("build timeout")
    };
    assert_eq!(options.build_timeout, std::time::Duration::from_secs(5));
    assert_eq!(parse(&words("list")), Ok(Request::List));
    assert_eq!(parse(&words("remove local/x")), Ok(Request::Remove { app: "local/x".into() }));
    for bad in [
        "new",
        "new Bad_Name",
        "new customize",
        "new a b",
        "new a --kind pane",
        "new a --kind widget",
        "dev a b",
        "dev --bogus",
        "dev --build",
        "dev --build-timeout",
        "dev --build-timeout 0",
        "dev --build-timeout soon",
        "remove",
        "remove acme/x",
        // An id names one folder in the local apps folder, never a path out of it.
        "remove local/../..",
        "remove local/../other",
        "remove local/local/x",
        "remove local/a/b",
        "remove local/",
        "remove local/customize",
        "list extra",
        "frobnicate",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn ext_leaves_other_commands_alone() {
    assert_eq!(super::run_if_requested(&words("apps list")), None);
    assert_eq!(super::run_if_requested(&words("extensions")), None);
}

/// A new extension, as `ext new` writes it.
fn new_extension(root: &Path, name: &str) -> PathBuf {
    let dir = root.join(name);
    scaffold::scaffold(&dir, name, "section").unwrap();
    dir
}

#[test]
fn the_scaffold_is_a_valid_package_with_its_export_built() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "my-prs");
    let pkg = dev::load_package(&dir).unwrap_or_else(|errors| panic!("{errors:?}"));
    assert_eq!(pkg.id, "local/my-prs");
    assert_eq!(pkg.name, "my-prs");
    assert_eq!(pkg.manifest["name"], "My prs");
    assert_eq!(pkg.manifest["manifestVersion"], 2);
    let export = pkg.manifest["implements"]["cmux.section/1"]["export"].as_str().unwrap();
    let main = std::fs::read_to_string(dir.join("dist/main.js")).unwrap();
    let source = std::fs::read_to_string(dir.join("src/main.ts")).unwrap();
    assert!(source.contains(&format!("export function {export}(")), "{export} in src/main.ts");
    assert!(main.contains(&format!("{export}: () => {export}")), "{export} is packed");
    assert!(main.contains("globalThis.__cmuxAppExports"), "dist/main.js hands its exports over");
    assert!(dir.join("cmux-app.d.ts").is_file() && dir.join("README.md").is_file());
    // Only what the daemon loads is copied: no sources, no types.
    let files = dev::package_files(&pkg).unwrap();
    assert_eq!(files, vec![PathBuf::from("cmux-app.json"), PathBuf::from("dist/main.js")]);
    assert!(scaffold::scaffold(&dir, "my-prs", "section").is_err(), "a folder with files stays");
}

#[test]
fn package_files_refuse_links_and_paths_out_of_the_folder() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "linked");
    let secret = root.path().join("secret.txt");
    std::fs::write(&secret, "not the extension's").unwrap();
    let path = dir.join("cmux-app.json");
    let original: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let with_files = |files: Value| {
        let mut manifest = original.clone();
        manifest["files"] = files;
        std::fs::write(&path, manifest.to_string()).unwrap();
        dev::load_package(&dir).unwrap_or_else(|errors| panic!("{errors:?}"))
    };

    // A `files` entry that is a link to a file outside the folder.
    std::os::unix::fs::symlink(&secret, dir.join("notes.txt")).unwrap();
    let error = dev::package_files(&with_files(json!(["dist/", "notes.txt"]))).unwrap_err();
    assert_eq!(error.file.as_deref(), Some("notes.txt"), "{error:?}");
    assert!(error.message.contains("symbolic link"), "{error:?}");

    // A link inside a listed folder is refused by its path too.
    std::os::unix::fs::symlink(&secret, dir.join("dist/leak.js")).unwrap();
    let error = dev::package_files(&with_files(json!(["dist/"]))).unwrap_err();
    assert_eq!(error.file.as_deref(), Some("dist/leak.js"), "{error:?}");
    std::fs::remove_file(dir.join("dist/leak.js")).unwrap();

    // A linked folder, and a path that climbs out.
    std::os::unix::fs::symlink(root.path(), dir.join("assets")).unwrap();
    let error = dev::package_files(&with_files(json!(["dist/", "assets/secret.txt"]))).unwrap_err();
    assert!(error.message.contains("symbolic link"), "{error:?}");
    // The manifest check may refuse a climbing path first; either way it is
    // never copied.
    let mut manifest = original.clone();
    manifest["files"] = json!(["dist/", "../secret.txt"]);
    std::fs::write(&path, manifest.to_string()).unwrap();
    if let Ok(pkg) = dev::load_package(&dir) {
        let error = dev::package_files(&pkg).unwrap_err();
        assert!(error.message.contains("outside the extension folder"), "{error:?}");
    }

    // Nothing linked: the listed files only.
    let files = dev::package_files(&with_files(json!(["dist/"]))).unwrap();
    assert_eq!(files, vec![PathBuf::from("cmux-app.json"), PathBuf::from("dist/main.js")]);
}

#[test]
fn an_invalid_manifest_names_its_file_and_field_and_exits_4() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "broken");
    let path = dir.join("cmux-app.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.section/1"]["options"]["defaultRegion"] = json!("left");
    std::fs::write(&path, manifest.to_string()).unwrap();
    // No daemon is needed to say so.
    let outcome =
        dev::once(&global(Path::new("/nonexistent/cmux.sock")), &dev_options(&dir), false);
    assert_eq!(outcome.phase, Phase::Manifest);
    assert_eq!(outcome.exit_code(), exit::MANIFEST_INVALID);
    let error = &outcome.errors[0];
    assert_eq!(error.file.as_deref(), Some("cmux-app.json"));
    assert!(error.field.as_deref().unwrap_or("").contains("defaultRegion"), "{error:?}");
    let json = outcome.to_json(&dir);
    assert_eq!(json["ok"], false);
    assert_eq!(json["phase"], "manifest");
    assert_eq!(json["exitCode"], 4);

    // A third-party id is refused: the local folder holds local/ apps only.
    manifest["implements"]["cmux.section/1"]["options"]["defaultRegion"] = json!("bottom");
    manifest["id"] = json!("acme/broken");
    manifest["repository"] = json!("https://github.com/acme/broken");
    std::fs::write(&path, manifest.to_string()).unwrap();
    let errors = dev::load_package(&dir).unwrap_err();
    assert_eq!(errors[0].field.as_deref(), Some("/id"));
    assert!(errors[0].message.contains("local/broken"), "{errors:?}");
}

#[test]
fn a_failed_build_names_file_and_line_and_exits_5() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "nobuild");
    let mut options = dev_options(&dir);
    options.build = Some("echo 'src/main.ts:3:9: Expected \";\"' >&2; exit 1".into());
    let outcome = dev::once(&global(Path::new("/nonexistent/cmux.sock")), &options, false);
    assert_eq!(outcome.phase, Phase::Build);
    assert_eq!(outcome.exit_code(), exit::BUILD_FAILED);
    let error = &outcome.errors[0];
    assert_eq!(
        (error.file.as_deref(), error.line, error.column),
        (Some("src/main.ts"), Some(3), Some(9))
    );
    assert!(error.message.contains("Expected"), "{error:?}");

    // A build that hangs is stopped at its deadline, with what it started.
    let mut options = dev_options(&dir);
    options.build = Some("sleep 600 & sleep 600".into());
    options.build_timeout = std::time::Duration::from_secs(1);
    let started = std::time::Instant::now();
    let outcome = dev::once(&global(Path::new("/nonexistent/cmux.sock")), &options, false);
    assert!(started.elapsed() < std::time::Duration::from_secs(10), "{:?}", started.elapsed());
    assert_eq!(outcome.phase, Phase::Build);
    assert_eq!(outcome.exit_code(), exit::BUILD_FAILED);
    assert!(outcome.errors[0].message.contains("--build-timeout"), "{:?}", outcome.errors);
}

#[test]
fn build_output_positions_are_read_in_both_shapes() {
    let dir = Path::new("/work/ext");
    let bun = "1 | const a b = 2\n            ^\nerror: Expected \";\" but found \"b\"\n    at /work/ext/src/main.ts:1:9\n";
    let problems = dev::build_problems(bun, dir);
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert_eq!(problems[0].file.as_deref(), Some("src/main.ts"));
    assert_eq!((problems[0].line, problems[0].column), (Some(1), Some(9)));
    assert_eq!(problems[0].message, "Expected \";\" but found \"b\"");
    let none = dev::build_problems("something broke\n", dir);
    assert_eq!(none[0].file, None);
    assert_eq!(none[0].message, "something broke");
    let load = dev::load_problem("init: dist/main.js:2:12 SyntaxError: unexpected token");
    assert_eq!(
        (load.file.as_deref(), load.line, load.column),
        (Some("dist/main.js"), Some(2), Some(12))
    );
}

#[test]
fn no_daemon_exits_3_with_the_reason() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "alone");
    let outcome = dev::once(&global(&root.path().join("missing.sock")), &dev_options(&dir), false);
    assert_eq!(outcome.phase, Phase::Daemon);
    assert_eq!(outcome.exit_code(), exit::NO_DAEMON);
    assert_eq!(outcome.app.as_deref(), Some("local/alone"));
    assert!(!outcome.errors[0].message.is_empty());
}

#[test]
fn the_watch_skips_reads_dot_files_and_node_modules() {
    use notify::event::{
        AccessKind, AccessMode, CreateKind, DataChange, Event, EventKind, ModifyKind,
    };
    let root = PathBuf::from("/work/ext");
    let roots = vec![root.clone()];
    let on = |kind, path: &str| Ok(Event::new(kind).add_path(root.join(path)));
    let write = || EventKind::Modify(ModifyKind::Data(DataChange::Any));
    assert!(dev::relevant(&on(write(), "src/main.ts"), &roots));
    assert!(dev::relevant(
        &on(EventKind::Access(AccessKind::Close(AccessMode::Write)), "cmux-app.json"),
        &roots
    ));
    assert!(!dev::relevant(
        &on(EventKind::Access(AccessKind::Open(AccessMode::Any)), "src/main.ts"),
        &roots
    ));
    assert!(!dev::relevant(&on(write(), "src/.main.ts.swp"), &roots));
    assert!(
        !dev::relevant(&on(write(), "src/.cmux-pack-entry.ts"), &roots),
        "the packer's wrapper"
    );
    assert!(!dev::relevant(
        &on(EventKind::Create(CreateKind::File), "node_modules/x/index.js"),
        &roots
    ));
    assert!(!dev::relevant(&on(write(), "src/main.ts~"), &roots));
    assert!(!dev::relevant(&Ok(Event::new(write()).add_path("/elsewhere/x.js".into())), &roots));
    assert!(dev::relevant(&Err(notify::Error::generic("lost events")), &roots));
}

/// A fake daemon on a Unix socket: `apps-list` names `local_dir`; a file
/// landing in it sends `apps-changed` (`local-reload`) for `app`, as the
/// daemon's folder watch does; `apps-mount` answers with a scene, or with an
/// init failure when the copied script holds `THROW_AT_INIT`.
struct FakeDaemon {
    socket: PathBuf,
    requests: Arc<Mutex<Vec<Value>>>,
    _watcher: notify::RecommendedWatcher,
    _dir: cmux_unix_socket::TestDir,
}

impl FakeDaemon {
    fn start(local_dir: &Path, app: &str, installed: bool) -> Self {
        use notify::Watcher as _;
        let dir = cmux_unix_socket::short_test_dir("cmux-ext");
        let socket = dir.path().join("daemon.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let clients: Arc<Mutex<Vec<UnixStream>>> = Arc::default();
        let requests: Arc<Mutex<Vec<Value>>> = Arc::default();
        std::fs::create_dir_all(local_dir).unwrap();
        let (watch_clients, watch_app) = (clients.clone(), app.to_string());
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            let line = json!({"event": "apps-changed", "transaction": "local-reload", "app": watch_app});
            for client in watch_clients.lock().unwrap().iter_mut() {
                let _ = writeln!(client, "{line}");
            }
        })
        .unwrap();
        watcher.watch(local_dir, notify::RecursiveMode::Recursive).unwrap();
        let (local, app, seen) = (local_dir.to_path_buf(), app.to_string(), requests.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                clients.lock().unwrap().push(stream.try_clone().unwrap());
                let (local, app, seen) = (local.clone(), app.clone(), seen.clone());
                std::thread::spawn(move || serve(stream, &local, &app, installed, &seen));
            }
        });
        Self { socket, requests, _watcher: watcher, _dir: dir }
    }

    fn cmds(&self) -> Vec<String> {
        let requests = self.requests.lock().unwrap();
        requests.iter().filter_map(|r| r["cmd"].as_str().map(str::to_string)).collect()
    }
}

fn serve(stream: UnixStream, local: &Path, app: &str, installed: bool, seen: &Mutex<Vec<Value>>) {
    let mut writer = stream.try_clone().unwrap();
    let name = app.trim_start_matches("local/");
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        let request: Value = serde_json::from_str(&line).unwrap();
        seen.lock().unwrap().push(request.clone());
        let id = request["id"].clone();
        let reply = |data: Value| json!({"id": id, "ok": true, "data": data});
        let mut out = Vec::new();
        match request["cmd"].as_str().unwrap_or("") {
            "apps-list" => {
                let apps = if local.join(name).is_dir() {
                    vec![
                        json!({"id": app, "version": "0.1.0", "installed": installed, "enabled": true,
                        "hidden": false, "available": true, "bundle_dir": local.join(name)}),
                    ]
                } else {
                    vec![]
                };
                out.push(reply(json!({"revision": 1, "apps": apps, "local_dir": local})));
            }
            "apps-mount" => {
                out.push(reply(json!({})));
                let mount_id = request["mount_id"].clone();
                let script = std::fs::read_to_string(local.join(name).join("dist/main.js"))
                    .unwrap_or_default();
                if script.contains("THROW_AT_INIT") {
                    out.push(json!({"event": "apps-mount-failed", "mount_id": mount_id,
                        "reason": "init: dist/main.js:2:12 SyntaxError: unexpected token"}));
                } else {
                    out.push(json!({"event": "apps-log", "app": app, "level": "info", "message": "rendered"}));
                    out.push(json!({"event": "apps-scene", "mount_id": mount_id, "ops": []}));
                }
            }
            _ => out.push(reply(json!({}))),
        }
        for value in out {
            if writeln!(writer, "{value}").is_err() {
                return;
            }
        }
    }
}

#[test]
fn once_loads_a_new_extension_then_reports_a_load_error_with_its_position() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "hello");
    let local = root.path().join("state/apps/local");
    let fake = FakeDaemon::start(&local, "local/hello", false);
    let options = dev_options(&dir);

    let outcome = dev::once(&global(&fake.socket), &options, false);
    assert_eq!(outcome.phase, Phase::Done, "{:?}", outcome.errors);
    assert_eq!(outcome.exit_code(), exit::OK);
    assert!(outcome.changed);
    assert!(outcome.reload_ms.is_some());
    assert_eq!(outcome.installed, Some(false));
    assert!(outcome.next.as_deref().unwrap_or("").contains("cmux apps install local/hello"));
    assert_eq!(outcome.probe.as_deref(), Some("cmux.section/1"));
    assert_eq!(outcome.placed[0]["where"], "sidebar, bottom region");
    assert!(outcome.logs.iter().any(|l| l["message"] == "rendered"), "{:?}", outcome.logs);
    let copy = local.join("hello");
    assert_eq!(outcome.folder.as_deref(), Some(copy.as_path()));
    assert!(copy.join("cmux-app.json").is_file() && copy.join("dist/main.js").is_file());
    assert!(
        !copy.join("src").exists() && !copy.join("cmux-app.d.ts").exists(),
        "sources stay home"
    );
    assert!(copy.join(dev::MARKER).is_file());
    let json = outcome.to_json(&dir);
    assert_eq!((json["ok"].clone(), json["phase"].clone()), (json!(true), json!("done")));
    assert_eq!(json["app"], "local/hello");
    assert!(json["reloadMs"].is_u64());
    // Not installed: a preview mount, which needs no install.
    let mounts: Vec<Value> = fake
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["cmd"] == "apps-mount")
        .cloned()
        .collect();
    assert_eq!(mounts[0]["context"]["preview"], true);
    assert!(fake.cmds().contains(&"apps-unmount".to_string()), "the probe unmounts");

    // Nothing changed: no copy, the load is still checked.
    let again = dev::once(&global(&fake.socket), &options, false);
    assert_eq!(again.phase, Phase::Done, "{:?}", again.errors);
    assert!(!again.changed);
    assert!(again.reload_ms.is_some());

    // A script that does not load: exit 1 with its file and line.
    std::fs::write(dir.join("dist/main.js"), "// THROW_AT_INIT\nconst a b = 2\n").unwrap();
    let broken = dev::once(&global(&fake.socket), &options, false);
    assert_eq!(broken.phase, Phase::Load);
    assert_eq!(broken.exit_code(), exit::LOAD_FAILED);
    let error = &broken.errors[0];
    assert_eq!(
        (error.file.as_deref(), error.line, error.column),
        (Some("dist/main.js"), Some(2), Some(12))
    );
    assert!(broken.line().contains("the last good version stays live"), "{}", broken.line());

    // `ext remove` drops the copy it made, and only that.
    assert_eq!(dev::remove_made_folder(&copy), Ok(true));
    assert!(!copy.exists());
}

#[test]
fn a_local_folder_ext_dev_did_not_make_is_left_alone() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "taken");
    let local = root.path().join("state/apps/local");
    std::fs::create_dir_all(local.join("taken")).unwrap();
    std::fs::write(local.join("taken/cmux-app.json"), "{}").unwrap();
    let fake = FakeDaemon::start(&local, "local/taken", true);
    let outcome = dev::once(&global(&fake.socket), &dev_options(&dir), false);
    assert_eq!(outcome.phase, Phase::Reload, "{:?}", outcome.errors);
    assert!(outcome.errors[0].message.contains("did not make it"), "{:?}", outcome.errors);
    assert_eq!(std::fs::read_to_string(local.join("taken/cmux-app.json")).unwrap(), "{}");
    assert!(dev::remove_made_folder(&local.join("taken")).is_err());
}

#[test]
fn the_fingerprint_follows_contents_and_skips_dot_files() {
    let root = tempfile::tempdir().unwrap();
    let dir = new_extension(root.path(), "prints");
    let before = dev::fingerprint(&dir);
    std::fs::write(dir.join("src/.main.ts.swp"), "typing").unwrap();
    assert_eq!(dev::fingerprint(&dir), before, "an editor's swap file is no change");
    std::fs::write(dir.join("src/main.ts"), "export function renderSection() {}\n").unwrap();
    assert_ne!(dev::fingerprint(&dir), before);
}
