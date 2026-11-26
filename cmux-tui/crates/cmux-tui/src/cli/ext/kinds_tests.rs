//! `cmux ext new NAME --kind K`, then `cmux ext dev`, for every kind: the new
//! folder loads as written, and a save to its `src/main.ts` is rebuilt and
//! reloaded, its view redrawn by the real QuickJS app host, within a second
//! of the save. The loop is `run_watch`'s: the folder watch, the debounce
//! (`dev::settle`), the fingerprint check and one `Session::reload`.

use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use super::daemon::{Daemon, Wake};
use super::dev::{self, Phase};
use serde_json::{Value, json};

use super::tests::{FakeDaemon, dev_options, global, words};
use super::{Request, exit, parse, scaffold};

/// The longest a save may take to be on screen.
const BUDGET: Duration = Duration::from_secs(1);

/// The kinds that make a folder; `view` when the kind draws one.
const KINDS: [(&str, bool); 6] = [
    ("sidebar", true),
    ("session-info", true),
    ("pane", true),
    ("newtab", true),
    ("widget", true),
    ("command", false),
];

/// One kind's run: save to reloaded, and that reload's build and copy-to-frame times.
struct Measured {
    save_to_reload: Duration,
    build_ms: Option<u128>,
    reload_ms: Option<u128>,
}

/// The words a view's first scene shows, from its outline.
fn shown(outcome: &dev::Outcome) -> String {
    outcome.scene.join("\n")
}

fn new_edit_reload(root: &Path, kind: &str, view: bool, bun: &Path) -> Result<Measured, String> {
    let name = format!("hi-{kind}");
    let dir = root.join(&name);
    let new = format!("new {name} --kind {kind} --dir {}", dir.display());
    let Request::New { name, kind: made, dir: Some(target), .. } = parse(&words(&new))? else {
        return Err(format!("ext {new} is not a new request"));
    };
    scaffold::scaffold(&target, &name, &made)?;

    let fake = FakeDaemon::start_hosting(&root.join("state/apps/local"), &format!("local/{name}"));
    let Ok(Request::Dev(mut options)) = parse(&words(&format!("dev {}", dir.display()))) else {
        return Err("ext dev does not parse".into());
    };
    options.bun = Some(bun.to_path_buf());
    let (sender, wakes) = channel();
    let _watcher = dev::watch(&dir, sender.clone()).map_err(|e| format!("watch: {e}"))?;
    let daemon = Daemon::connect(&global(&fake.socket), sender, wakes)?;
    let mut session = dev::Session::new(dir.clone(), &options, daemon);

    // New: it loads as written.
    let first = session.reload(true);
    if first.phase != Phase::Done {
        return Err(format!("the new folder does not load: {:?}", first.errors));
    }
    if view && !shown(&first).contains("Hello") {
        return Err(format!("the new view shows no Hello: {}", shown(&first)));
    }
    let print = session.built_print.unwrap_or_else(|| dev::fingerprint(&dir));

    // Edit: one save to the source.
    let source = dir.join("src/main.ts");
    let text = std::fs::read_to_string(&source).map_err(|e| e.to_string())?;
    let saved = Instant::now();
    std::fs::write(&source, text.replace("Hello", "Edited")).map_err(|e| e.to_string())?;

    // Reload: as `run_watch` does, a wake, the debounce, a changed fingerprint.
    let outcome = loop {
        let left = (saved + Duration::from_secs(10)).saturating_duration_since(Instant::now());
        match session.daemon.next_wake_within(left) {
            None => return Err("no reload within 10 s of the save".into()),
            Some(Wake::Files) => {
                if let Some((why, _)) = dev::settle(&mut session.daemon) {
                    return Err(why.into());
                }
                if dev::fingerprint(&dir) == print {
                    continue;
                }
                break session.reload(false);
            }
            Some(Wake::DaemonGone) => return Err("the daemon went away".into()),
            Some(_) => {}
        }
    };
    let save_to_reload = saved.elapsed();
    if outcome.phase != Phase::Done {
        return Err(format!("the edit does not reload: {:?}", outcome.errors));
    }
    if view && !shown(&outcome).contains("Edited") {
        return Err(format!("the reloaded view does not show the edit: {}", shown(&outcome)));
    }
    let loaded =
        std::fs::read_to_string(root.join("state/apps/local").join(&name).join("dist/main.js"))
            .map_err(|e| e.to_string())?;
    if !loaded.contains("Edited") {
        return Err("the copy cmux loads is not the edited build".into());
    }
    Ok(Measured { save_to_reload, build_ms: outcome.build_ms, reload_ms: outcome.reload_ms })
}

#[test]
fn every_kind_is_new_loads_then_shows_an_edit_within_a_second() {
    let Some(bun) = dev::find_bun() else {
        eprintln!("SKIPPED: bun is not on PATH; the edit is a source save, which bun builds");
        return;
    };
    let mut problems = Vec::new();
    for (kind, view) in KINDS {
        let root = tempfile::tempdir().unwrap();
        match new_edit_reload(root.path(), kind, view, &bun) {
            Ok(m) => {
                eprintln!(
                    "ext new --kind {kind}: save to reloaded {} ms (build {:?} ms, copy to frame {:?} ms)",
                    m.save_to_reload.as_millis(),
                    m.build_ms,
                    m.reload_ms
                );
                if m.save_to_reload >= BUDGET {
                    problems.push(format!(
                        "{kind}: {} ms from the save to the reload",
                        m.save_to_reload.as_millis()
                    ));
                }
            }
            Err(problem) => problems.push(format!("{kind}: {problem}")),
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

/// A kind whose cmux interface has not landed is refused with the interface
/// it needs and what works meanwhile, never scaffolded on an invented API.
/// When the interface lands this fails: give the kind its template.
#[test]
fn a_kind_whose_interface_has_not_landed_names_what_it_needs() {
    assert!(
        scaffold::PENDING
            .iter()
            .any(|(kind, needs, _)| *kind == "menu" && *needs == "cmux.context_menu/1")
    );
    for (kind, needs, _) in scaffold::PENDING {
        assert!(
            !cmux_app_manifest::KNOWN_INTERFACES.contains(needs),
            "{needs} landed: give --kind {kind} its template"
        );
        let error = parse(&words(&format!("new x --kind {kind}"))).unwrap_err();
        assert!(error.contains(needs) && error.contains("meanwhile"), "{kind}: {error}");
    }
}

/// Every kind `ext new` makes is a project on the public SDK as this cmux
/// ships it (no registry, the same `API_VERSION`), and `ext dev --once
/// --json` loads it as written, with no bun: exit 0.
#[test]
fn every_kind_is_made_on_the_shipped_sdk_and_passes_ext_dev_once() {
    let api_version = cmux_app_manifest::capabilities::Capabilities::get().api_version.clone();
    for (kind, _) in KINDS {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join(format!("hi-{kind}"));
        let new = format!("new hi-{kind} --kind {kind} --dir {}", dir.display());
        let Ok(Request::New { name, kind: parsed, dir: Some(target), .. }) = parse(&words(&new))
        else {
            panic!("ext {new} does not parse")
        };
        scaffold::scaffold(&target, &name, &parsed).unwrap_or_else(|e| panic!("{kind}: {e}"));

        // The code imports the SDK, and the SDK is the copy in the folder.
        let read = |file: &str| std::fs::read_to_string(dir.join(file)).unwrap();
        let source = read("src/main.ts");
        assert!(source.contains("from \"cmux-extension-sdk\""), "{kind}: {source}");
        let tsconfig: Value = serde_json::from_str(&read("tsconfig.json")).unwrap();
        let sdk = tsconfig["compilerOptions"]["paths"]["cmux-extension-sdk"][0].as_str().unwrap();
        let index = read(sdk);
        assert!(index.contains("export function section("), "{kind}: the SDK's own source");
        assert!(!index.contains("../../../cmux-app-host/"), "{kind}: no path into the repository");
        // Every export the manifest or catalog names is in the source and the first build.
        let dist = read("dist/main.js");
        let manifest: Value = serde_json::from_str(&read("cmux-app.json")).unwrap();
        let catalog: Value = std::fs::read_to_string(dir.join("catalog.json"))
            .map_or(Value::Null, |text| serde_json::from_str(&text).unwrap());
        let exports: Vec<String> = manifest["implements"]
            .as_object()
            .into_iter()
            .flat_map(|slots| slots.values())
            .chain(catalog["operations"].as_array().into_iter().flatten())
            .filter_map(|entry| entry["export"].as_str().map(str::to_owned))
            .collect();
        assert!(!exports.is_empty(), "{kind}: names no export");
        for export in exports {
            assert!(source.contains(&format!("export const {export} =")), "{kind}: {export}");
            assert!(dist.contains(&format!("{export}: () => {export}")), "{kind}: {export}");
        }
        let scopes: Value = serde_json::from_str(&read("sdk/tables/scopes.json")).unwrap();
        assert_eq!(scopes["apiVersion"], json!(api_version), "{kind}: SDK API_VERSION");
        let package: Value = serde_json::from_str(&read("package.json")).unwrap();
        assert_eq!(package["dependencies"]["cmux-extension-sdk"], "file:./sdk", "{kind}");

        // `ext dev --once --json` against a daemon, with no bun: exit 0, ok.
        let fake = FakeDaemon::start(
            &root.path().join("state/apps/local"),
            &format!("local/hi-{kind}"),
            false,
        );
        let outcome = dev::once(&global(&fake.socket), &dev_options(&dir), false);
        assert_eq!(outcome.exit_code(), exit::OK, "{kind}: {:?}", outcome.errors);
        assert_eq!(outcome.to_json(&dir)["ok"], true, "{kind}");
        let files = dev::package_files(&dev::load_package(&dir).unwrap()).unwrap();
        assert!(files.contains(&PathBuf::from("dist/main.js")), "{kind}: {files:?}");
        assert!(!files.iter().any(|f| f.starts_with("sdk")), "{kind}: the SDK copy stays home");
    }
}

#[test]
fn a_command_extension_needs_a_name_cmux_does_not_use() {
    let root = tempfile::tempdir().unwrap();
    let error = scaffold::scaffold(&root.path().join("apps"), "apps", "command").unwrap_err();
    assert!(error.contains("is a cmux command"), "{error}");
    assert!(scaffold::scaffold(&root.path().join("apps"), "apps", "sidebar").is_ok());
    for bad in ["ab-", "a--b"] {
        assert!(scaffold::scaffold(&root.path().join(bad), bad, "command").is_err(), "{bad}");
    }
}

/// Every kind's first `dist/main.js` is the packer's build of its
/// `src/main.ts`, what the first save writes. On a difference this prints
/// the build, placeholders back in, to put in `templates/KIND/dist/main.js`.
#[test]
fn every_kind_ships_the_packers_build_of_its_source() {
    let Some(bun) = dev::find_bun() else {
        eprintln!("SKIPPED: bun is not on PATH");
        return;
    };
    let name = "x-name-x";
    let unfill = |text: &str| {
        text.replace(&cmux_app_manifest::app_namespace(&format!("local/{name}")), "{{NS}}")
            .replace("X name x", "{{TITLE}}")
            .replace(name, "{{NAME}}")
    };
    let body = |text: &str| {
        text.lines().skip_while(|line| line.starts_with("//")).collect::<Vec<_>>().join("\n")
    };
    let mut stale = Vec::new();
    for (kind, _) in KINDS {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join(name);
        scaffold::scaffold(&dir, name, kind).unwrap();
        let shipped = std::fs::read_to_string(dir.join("dist/main.js")).unwrap();
        let pkg = dev::load_package(&dir).unwrap();
        dev::build(&pkg, &dev::BuildPlan::Pack(bun.clone()), dev::BUILD_TIMEOUT)
            .unwrap_or_else(|problems| panic!("{kind}: {problems:?}"));
        let built = std::fs::read_to_string(dir.join("dist/main.js")).unwrap();
        if body(&shipped) != body(&built) {
            let text = format!("{}{}", scaffold::FIRST_BUILD_HEADER, unfill(body(&built).trim()));
            eprintln!("=== BEGIN {kind} ===\n{text}\n=== END {kind} ===");
            stale.push(kind);
        }
    }
    assert!(stale.is_empty(), "stale first builds: {stale:?} (the builds are printed above)");
}
