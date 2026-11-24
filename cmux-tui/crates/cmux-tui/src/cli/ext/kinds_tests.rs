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

/// Words each view kind's template shows in its first scene and has in `src/main.ts`: the test
/// sees them, saves the source with them changed, and sees the change (the command kind draws
/// nothing; its source is saved with its greeting changed).
fn marker(kind: &str) -> &'static str {
    match kind {
        "sidebar" => "Review pull requests",
        "session-info" => "Branch",
        "pane" => "Hi pane",
        "newtab" => "New agent chat",
        _ => "Hello",
    }
}

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
    let mark = marker(kind);
    if view && !shown(&first).contains(mark) {
        return Err(format!("the new view shows no {mark}: {}", shown(&first)));
    }
    let print = session.built_print.unwrap_or_else(|| dev::fingerprint(&dir));

    // Edit: one save to the source.
    let source = dir.join("src/main.ts");
    let text = std::fs::read_to_string(&source).map_err(|e| e.to_string())?;
    let saved = Instant::now();
    std::fs::write(&source, text.replace(mark, "Edited")).map_err(|e| e.to_string())?;

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
    // Not on the reserved list, but the first word of built-in `cmux density …`,
    // which always wins over an app's `cmux density hello`.
    let error = scaffold::scaffold(&root.path().join("density"), "density", "command").unwrap_err();
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

/// The scene each view kind's template draws, from its shipped `dist/main.js` in the real QuickJS
/// host, with the same context and answers as the gallery's `apps.ext-new-templates` entry. A
/// call to `workspace.list` gets three workspaces; every other call `null`.
fn template_scene(kind: &str) -> Result<Value, String> {
    use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits};
    let (export, context) = match kind {
        "sidebar" => ("renderSection", json!({})),
        "session-info" => (
            "renderSessionInfo",
            json!({"session_id": "session_1", "cwd": "/Users/you/src/atlas",
                   "branch": "fix/chat-drafts", "harness": "claude"}),
        ),
        "pane" => ("renderPane", json!({})),
        "newtab" => ("renderNewTab", json!({"cwd": "/Users/you/src/atlas"})),
        _ => return Err(format!("{kind} draws no view")),
    };
    let root = tempfile::tempdir().map_err(|e| e.to_string())?;
    let dir = root.path().join("my-view");
    scaffold::scaffold(&dir, "my-view", kind)?;
    let main = std::fs::read_to_string(dir.join("dist/main.js")).map_err(|e| e.to_string())?;
    let mut vm = AppVm::new(Limits::default())?;
    vm.init(InitParams {
        app: AppInfo { id: "local/my-view".into(), version: "0.1.0".into() },
        settings: json!({}),
        api_version: cmux_app_manifest::capabilities::Capabilities::get().api_version.clone(),
        ops: None,
        known_ops: None,
        locale: None,
        strings: Value::Null,
        main,
        main_name: Some("dist/main.js".into()),
    })
    .map_err(|e| format!("init: {e:?}"))?;
    if let Some(refused) = vm.mount("m", export, &context).map_err(|e| format!("{e:?}"))? {
        return Err(refused);
    }
    let workspaces = json!([
        {"id": "workspace_1", "session_id": "session_1", "name": "atlas", "index": 0, "focused": true},
        {"id": "workspace_2", "session_id": "session_1", "name": "docs site", "index": 1, "focused": false},
        {"id": "workspace_3", "session_id": "session_1", "name": "release 2.4", "index": 2, "focused": false},
    ]);
    let mut ops = Vec::new();
    for _ in 0..32 {
        let outbox = vm.take_outbox();
        if outbox.is_empty() {
            break;
        }
        for message in outbox {
            match message {
                FromHost::Scene { ops: batch, .. } => {
                    ops.extend(batch.as_array().cloned().unwrap_or_default());
                }
                FromHost::Call { cb, name, .. } => {
                    let value =
                        if name == "workspace.list" { workspaces.clone() } else { Value::Null };
                    vm.resolve(cb, true, &json!({ "value": value }))
                        .map_err(|e| format!("{e:?}"))?;
                }
                // The daemon's signals cache serves `workspaces()`; this host has none, so the
                // watch falls back to a plain `workspace.list` call, answered above.
                FromHost::Watch { watch, .. } => {
                    vm.watch_state(watch, &json!({ "fallback": true }))
                        .map_err(|e| format!("{e:?}"))?;
                }
                FromHost::Fatal { .. } => return Err(format!("{message:?}")),
                _ => {}
            }
        }
    }
    Ok(Value::Array(ops))
}

/// One node of a scene `scene_tree` builds: its type, props and child ids.
#[derive(Default)]
struct TreeNode {
    kind: String,
    props: serde_json::Map<String, Value>,
    children: Vec<String>,
}

/// The tree a list of scene ops leaves, from its root: `{type, props, children}`, ids dropped,
/// so two hosts that batch the same scene differently compare equal.
fn scene_tree(ops: &Value) -> Value {
    let mut nodes: std::collections::HashMap<String, TreeNode> = Default::default();
    let mut root = None;
    for op in ops.as_array().into_iter().flatten() {
        let id = op["id"].as_str().unwrap_or_default().to_string();
        match op["op"].as_str() {
            Some("create") => {
                let node = TreeNode {
                    kind: op["type"].as_str().unwrap_or_default().into(),
                    props: op["props"].as_object().cloned().unwrap_or_default(),
                    children: vec![],
                };
                nodes.insert(id, node);
            }
            Some("update") => {
                if let Some(node) = nodes.get_mut(&id) {
                    for (key, value) in op["props"].as_object().into_iter().flatten() {
                        if value.is_null() {
                            node.props.remove(key);
                        } else {
                            node.props.insert(key.clone(), value.clone());
                        }
                    }
                }
            }
            Some("children") => {
                if let Some(node) = nodes.get_mut(&id) {
                    node.children = op["children"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|c| c.as_str().map(String::from))
                        .collect();
                }
            }
            Some("remove") => {
                nodes.remove(&id);
            }
            Some("root") => root = Some(id),
            _ => {}
        }
    }
    fn walk(id: &str, nodes: &std::collections::HashMap<String, TreeNode>) -> Value {
        let Some(node) = nodes.get(id) else { return Value::Null };
        let children: Vec<Value> = node.children.iter().map(|c| walk(c, nodes)).collect();
        json!({"type": node.kind, "props": node.props, "children": children})
    }
    root.map(|id| walk(&id, &nodes)).unwrap_or(Value::Null)
}

/// The view kinds the gallery's `apps.ext-new-templates` entry draws. A widget is not one of them:
/// it draws the clock (`ctx.now()`), so no fixed scene can match it.
const GALLERY_KINDS: [&str; 4] = ["sidebar", "session-info", "pane", "newtab"];

/// The gallery's `apps.ext-new-templates` entry draws each of `GALLERY_KINDS`' templates from
/// `webviews/src/apps/scene/extTemplateScenes.json` (`KIND-shipped`): this keeps that fixture the
/// scene the template really draws. On a difference it prints the template's ops to put there.
#[test]
fn every_view_kind_draws_the_scene_its_gallery_entry_shows() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../webviews/src/apps/scene/extTemplateScenes.json");
    let Ok(text) = std::fs::read_to_string(&fixture) else {
        // A sparse checkout (`wt new --files`) may have no webviews/; CI always has it.
        assert!(std::env::var_os("CI").is_none(), "no {} on CI", fixture.display());
        eprintln!("SKIPPED: no {} in this checkout", fixture.display());
        return;
    };
    let gallery: Value = serde_json::from_str(&text).expect("the gallery fixture is JSON");
    let mut stale = Vec::new();
    for kind in GALLERY_KINDS {
        let ops = template_scene(kind).unwrap_or_else(|problem| panic!("{kind}: {problem}"));
        let key = format!("{kind}-shipped");
        if scene_tree(&ops) != scene_tree(&gallery[&key]) {
            eprintln!("=== BEGIN {key} ===\n{ops}\n=== END {key} ===");
            stale.push(key);
        }
    }
    assert!(stale.is_empty(), "the gallery shows other scenes than the templates draw: {stale:?}");
}
