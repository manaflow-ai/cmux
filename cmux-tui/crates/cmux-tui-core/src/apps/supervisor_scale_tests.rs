//! Sidebar extensions at scale (`scale_bench`): what a person waits on as
//! their local extensions grow from 1 to 200. A save of one extension (the
//! `cmux ext dev` save loop) must cost the same whether 1 or 200 others are
//! installed or mounted; `apps-list` (the sidebar's and the palette's read)
//! must not walk the disk; a malformed, huge or misbehaving extension must be
//! refused or bounded without slowing the others.
//!
//! The timing sweep runs only when asked: `CMUX_APPS_SCALE_BENCH=1`, or a
//! plain `cargo test` whose filter names `scale_bench`. It prints one
//! `APPS-SCALE-BENCH` JSON line per scenario and size. The save sweeps are a
//! measurement here; the reload pass's own cost and its counted test belong
//! to `supervisor_local_reload_tests.rs` (cmux#44991). The constant-cost
//! tests below count work (package files read, refusals) rather than time,
//! and always run.

use super::super::catalog::work::{self, Work};
use super::under_load::{ListProbe, Samples};
use super::*;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_APPS_SCALE_BENCH").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("scale_bench")) && !args.iter().any(|a| a == "--exact")
}

fn report(scenario: &str, n: usize, fields: Value) {
    let mut line = json!({
        "scenario": scenario,
        "n": n,
        "cores": std::thread::available_parallelism().map_or(0, |n| n.get()),
        "os": std::env::consts::OS,
    });
    if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
        line.extend(fields.clone());
    }
    println!("APPS-SCALE-BENCH {line}");
}

fn work_json(work: Work) -> Value {
    json!({
        "validated": work.packages_validated,
        "file_reads": work.package_file_reads,
    })
}

const SIZES: [usize; 4] = [1, 10, 50, 200];
const SAVES: usize = 20;

/// The local folder.
fn local(f: &Fixture) -> PathBuf {
    f.state.join("apps/local")
}

/// `n - 1` local extensions beside the fixture's `local/spy`, each with an
/// asset of `asset` bytes (a bundled web build or image).
fn add_extensions(f: &Fixture, n: usize, asset: usize) -> Vec<String> {
    let mut ids = Vec::new();
    for i in 1..n {
        let id = format!("local/ext{i}");
        write_app(&local(f), &format!("ext{i}"), &id, json!({}));
        if asset > 0 {
            std::fs::write(local(f).join(format!("ext{i}/dist/asset.bin")), vec![b'a'; asset])
                .unwrap();
        }
        ids.push(id);
    }
    ids
}

/// Rewrites the manifest of the app in `dir` with `version` and the section
/// export `export` (the scripted host renders the export's name).
fn save(dir: &Path, version: &str, export: &str) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!(version);
    manifest["implements"]["cmux.section/1"]["export"] = json!(export);
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// Waits for `app`'s `apps-changed` and mount `mount`'s scene drawing
/// `export`; pushes each into its samples as it comes.
fn wait_reloaded(
    f: &Fixture,
    app: &str,
    mount: &str,
    export: &str,
    start: Instant,
    changed: &mut Samples,
    scene: &mut Samples,
) {
    let deadline = start + Duration::from_secs(60);
    let (mut saw_changed, mut saw_scene) = (false, false);
    while !(saw_changed && saw_scene) {
        let left = deadline.saturating_duration_since(Instant::now());
        let event = f.events.recv_timeout(left).unwrap_or_else(|_| {
            panic!("{app}'s save drawing {export} did not reach mount {mount}")
        });
        if !saw_changed && event["event"] == "apps-changed" && event["app"] == app {
            saw_changed = true;
            changed.push(start);
        }
        if !saw_scene
            && event["event"] == "apps-scene"
            && event["mount_id"] == mount
            && event["ops"][0]["op"] == "create"
            && event["ops"][0]["props"]["text"] == export
        {
            saw_scene = true;
            scene.push(start);
        }
    }
}

/// Saves `app` (in `dir`, mounted as `mount`) `SAVES` times through an
/// asked pass (`apps-reload-local`, as `cmux ext dev` asks): the pass's own
/// time, the time to `apps-changed` and to the new scene, `apps-list` probed
/// meanwhile, and the work of the last pass.
fn save_loop(f: &Fixture, app: &str, dir: &Path, mount: &str, tag: &str) -> (Value, Work) {
    while f.events.try_recv().is_ok() {}
    let probe = ListProbe::start(&f.supervisor);
    let (mut call, mut changed, mut scene) =
        (Samples::default(), Samples::default(), Samples::default());
    let mut last = Work::default();
    for n in 0..SAVES {
        let export = format!("{tag}{n}");
        save(dir, &format!("1.1.{n}"), &export);
        let start = Instant::now();
        let (_, done) = work::of(|| f.supervisor.reload_local_apps_now());
        call.push(start);
        last = done;
        wait_reloaded(f, app, mount, &export, start, &mut changed, &mut scene);
    }
    let list = probe.finish();
    let timings = json!({
        "pass_ms": call.summary(),
        "changed_ms": changed.summary(),
        "scene_ms": scene.summary(),
        "list_ms": list.summary(),
    });
    (timings, last)
}

/// Scenario 1: one extension saved with `n - 1` others installed, or with
/// all `n` mounted as sidebar sections (n live hosts); and with each other
/// extension carrying a 1 MiB asset.
fn save_scenarios() {
    for n in SIZES {
        let f = fixture();
        add_extensions(&f, n, 0);
        f.supervisor.reload_local_apps_now();
        f.install("local/spy");
        f.mount("m-spy", "local/spy", "cmux.section/1", json!({}));
        let (timings, work) = save_loop(&f, "local/spy", &local(&f).join("spy"), "m-spy", "render");
        report("save_installed", n, json!({ "timings": timings, "work": work_json(work) }));
    }
    for n in [1, 10, 50] {
        let f = fixture();
        let ids = add_extensions(&f, n, 0);
        f.supervisor.reload_local_apps_now();
        let start = Instant::now();
        for (i, id) in std::iter::once(&"local/spy".to_string()).chain(&ids).enumerate() {
            f.install(id);
            f.mount(&format!("m{i}"), id, "cmux.section/1", json!({}));
        }
        let mount_all = start.elapsed().as_secs_f64() * 1000.0;
        let (timings, work) = save_loop(&f, "local/spy", &local(&f).join("spy"), "m0", "render");
        report(
            "save_mounted",
            n,
            json!({ "timings": timings, "work": work_json(work), "mount_all_ms": mount_all }),
        );
    }
    for n in [1, 10, 50] {
        let f = fixture();
        add_extensions(&f, n, 1 << 20);
        f.supervisor.reload_local_apps_now();
        f.install("local/spy");
        f.mount("m-spy", "local/spy", "cmux.section/1", json!({}));
        let (timings, work) = save_loop(&f, "local/spy", &local(&f).join("spy"), "m-spy", "render");
        report("save_assets_1mib", n, json!({ "timings": timings, "work": work_json(work) }));
    }
}

/// `apps-list` with `n` local extensions installed: the sidebar's and the
/// palette's read, under the supervisor lock.
fn list_scenario() {
    for n in SIZES {
        let f = fixture();
        let ids = add_extensions(&f, n, 0);
        f.supervisor.reload_local_apps_now();
        f.install("local/spy");
        for id in &ids {
            f.install(id);
        }
        let mut list = Samples::default();
        let mut last = Work::default();
        for _ in 0..50 {
            let start = Instant::now();
            let (_, done) = work::of(|| f.supervisor.list());
            list.push(start);
            last = done;
        }
        report("apps_list", n, json!({ "list_ms": list.summary(), "work": work_json(last) }));
    }
}

/// Writes `dir`'s manifest as `save` does, through a temporary file renamed
/// over it (how most editors and `cp` to a new name save): no read sees a
/// half-written manifest.
fn save_atomic(dir: &Path, version: &str, export: &str) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!(version);
    manifest["implements"]["cmux.section/1"]["export"] = json!(export);
    let tmp = dir.join(".cmux-app.json.tmp");
    std::fs::write(&tmp, manifest.to_string()).unwrap();
    std::fs::rename(&tmp, &path).unwrap();
}

/// Scenario 2: 200 writes to one mounted extension as fast as possible,
/// through the real file watch, with `apps-list` probed every 2 ms: in place
/// (truncate, then write, as `fs::write` and some editors do) and through a
/// rename. Reports whether the final scene drew the last write within 20 s,
/// and what the open view saw meanwhile (a failed mount, a removal).
fn storm_scenario() {
    for (mode, n) in [("in_place", 1), ("in_place", 50), ("rename", 1), ("rename", 50)] {
        let f = fixture();
        add_extensions(&f, n, 0);
        f.supervisor.reload_local_apps_now();
        f.install("local/spy");
        f.mount("m-spy", "local/spy", "cmux.section/1", json!({}));
        f.supervisor.start_local_watch_for_test();
        // The watch reads once as it starts; let that settle.
        std::thread::sleep(Duration::from_millis(500));
        while f.events.try_recv().is_ok() {}
        let probe = ListProbe::start(&f.supervisor);
        let dir = local(&f).join("spy");
        let start = Instant::now();
        const WRITES: usize = 200;
        for w in 0..WRITES {
            let (version, export) = (format!("2.0.{w}"), format!("storm{w}"));
            if mode == "rename" {
                save_atomic(&dir, &version, &export);
            } else {
                save(&dir, &version, &export);
            }
        }
        let wrote = Instant::now();
        let last = format!("storm{}", WRITES - 1);
        let deadline = wrote + Duration::from_secs(20);
        let (mut changed, mut mount_failed, mut drawn) = (0, Vec::new(), None);
        while let Ok(event) =
            f.events.recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            if event["event"] == "apps-changed" && event["app"] == "local/spy" {
                changed += 1;
            }
            if event["event"] == "apps-mount-failed" && event["mount_id"] == "m-spy" {
                mount_failed.push(event["reason"].clone());
            }
            if event["event"] == "apps-scene"
                && event["mount_id"] == "m-spy"
                && event["ops"][0]["props"]["text"] == last.as_str()
            {
                drawn = Some(wrote.elapsed().as_secs_f64() * 1000.0);
                break;
            }
        }
        let list = probe.finish();
        let version = app_entry(&f.supervisor.list(), "local/spy")["version"].clone();
        report(
            "save_storm",
            n,
            json!({
                "case": mode,
                "writes": WRITES,
                "write_ms": (wrote - start).as_secs_f64() * 1000.0,
                "last_write_to_scene_ms": drawn,
                "listed_version": version,
                "reloads": changed,
                "mount_failed": mount_failed.len(),
                "first_mount_failure": mount_failed.first(),
                "list_ms": list.summary(),
            }),
        );
    }
}

/// A manifest of `bytes` bytes or more: a valid section app whose JSON is
/// padded with whitespace after its last field.
fn padded_manifest(id: &str, bytes: usize) -> String {
    let manifest = json!({
        "manifestVersion": 2, "id": id, "name": "Padded", "version": "1.0.0",
        "description": "d", "engines": { "cmux": "^2.0" },
        "runtime": { "main": "dist/main.js" }, "files": ["dist/"],
        "implements": { "cmux.section/1": { "export": "render", "title": "Padded" } }
    })
    .to_string();
    let pad = bytes.saturating_sub(manifest.len());
    format!("{}{}}}", &manifest[..manifest.len() - 1], " ".repeat(pad))
}

/// A bad package folder `name` in the local folder whose manifest is `text`.
fn write_bad(f: &Fixture, name: &str, text: &str) {
    let dir = local(f).join(name);
    std::fs::create_dir_all(dir.join("dist")).unwrap();
    std::fs::write(dir.join("dist/main.js"), "var __cmuxAppExports = {};").unwrap();
    std::fs::write(dir.join("cmux-app.json"), text).unwrap();
}

/// The manifests a person (or a broken generator) can write.
fn bad_manifests() -> Vec<(&'static str, String)> {
    let base = |id: &str| {
        json!({
            "manifestVersion": 2, "id": id, "name": "Bad", "version": "1.0.0",
            "description": "d", "engines": { "cmux": "^2.0" },
            "runtime": { "main": "dist/main.js" }, "files": ["dist/"],
            "implements": { "cmux.section/1": { "export": "render", "title": "Bad" } }
        })
    };
    let sections = |count: usize| {
        let mut m = base("local/many");
        m["contributes"] = json!({ "sidebarSections": (0..count)
            .map(|i| json!({ "id": format!("s{}", i % 7), "title": format!("Section {i}"), "render": "render" }))
            .collect::<Vec<_>>() });
        m.to_string()
    };
    let mut title = base("local/title");
    title["implements"]["cmux.section/1"]["title"] = json!("T".repeat(60 << 10));
    let mut huge_title = base("local/hugetitle");
    huge_title["implements"]["cmux.section/1"]["title"] = json!("T".repeat(4 << 20));
    let deep = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
    vec![
        ("sections_50", sections(50)),
        ("sections_200", sections(200)),
        ("manifest_64k", padded_manifest("local/edge", 64 << 10)),
        ("manifest_64k_plus_1", padded_manifest("local/edgeplus", (64 << 10) + 1)),
        ("manifest_16mib", padded_manifest("local/huge", 16 << 20)),
        ("title_60k", title.to_string()),
        ("title_4mib", huge_title.to_string()),
        ("deep_json", deep),
        ("malformed_json", r#"{"manifestVersion": 2, "id": "local/broken", "#.into()),
        // Sorts after `spy`, so `spy` stays the first folder with the id.
        ("zz_duplicate_id", base("local/spy").to_string()),
    ]
}

/// Scenario 3: each bad manifest beside 50 healthy extensions: what the
/// catalog says of it, and the healthy extension's save pass with it there.
fn bad_manifest_scenario() {
    let measure = |bad: Option<(&str, &str)>| {
        let f = fixture();
        add_extensions(&f, 50, 0);
        if let Some((name, text)) = bad {
            write_bad(&f, name, text);
        }
        let answer = f.supervisor.reload_local_apps_now();
        f.install("local/spy");
        f.mount("m-spy", "local/spy", "cmux.section/1", json!({}));
        let (timings, work) = save_loop(&f, "local/spy", &local(&f).join("spy"), "m-spy", "render");
        let dir = bad.map(|(name, _)| local(&f).join(name).display().to_string());
        let issue = answer["rejected"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| Some(r["dir"].as_str().unwrap_or_default()) == dir.as_deref())
            .map(|r| r["issue"].clone())
            .unwrap_or(Value::Null);
        (timings, work, issue)
    };
    let (timings, work, _) = measure(None);
    report(
        "bad_manifest",
        50,
        json!({ "case": "none", "timings": timings, "work": work_json(work) }),
    );
    for (case, text) in bad_manifests() {
        let (timings, work, issue) = measure(Some((case, &text)));
        let issue = issue.as_str().map(|s| s.chars().take(160).collect::<String>());
        report(
            "bad_manifest",
            50,
            json!({ "case": case, "bytes": text.len(), "issue": issue, "timings": timings, "work": work_json(work) }),
        );
    }
}

/// Scenario 4: a misbehaving extension mounted beside 10 healthy mounted
/// ones: a healthy one's save-to-scene must not move.
fn bad_neighbour_scenario() {
    for case in ["none", "renderFail", "interrupt", "renderHang", "renderHuge"] {
        let f = fixture();
        let ids = add_extensions(&f, 10, 0);
        write_app(&local(&f), "bad", "local/bad", json!({}));
        if case != "none" && case != "interrupt" {
            save(&local(&f).join("bad"), "1.0.0", case);
        }
        f.supervisor.reload_local_apps_now();
        for (i, id) in std::iter::once(&"local/spy".to_string()).chain(&ids).enumerate() {
            f.install(id);
            f.mount(&format!("m{i}"), id, "cmux.section/1", json!({}));
        }
        if case != "none" {
            f.install("local/bad");
            // `timeout`: the scripted host's render runs past its entry
            // deadline (a render that loops until the host interrupts it).
            let ctx = if case == "interrupt" { json!({ "timeout": true }) } else { json!({}) };
            f.supervisor.mount(CLIENT, "m-bad", "local/bad", "cmux.section/1", ctx).unwrap();
        }
        let (timings, _) = save_loop(&f, "local/spy", &local(&f).join("spy"), "m0", "render");
        report("bad_neighbour", 11, json!({ "case": case, "timings": timings }));
    }
}

#[test]
fn scale_bench() {
    if !bench_selected() {
        return;
    }
    let limit = crate::raise_open_file_limit(crate::OPEN_FILE_LIMIT_CEILING);
    println!("APPS-SCALE-BENCH-SETUP open-file limit {limit:?}");
    list_scenario();
    save_scenarios();
    storm_scenario();
    bad_manifest_scenario();
    bad_neighbour_scenario();
}

// MARK: constant cost, counted

/// `apps-list` reads no package file: its palette commands come from the
/// catalog fragment read when the package loaded (base red: every list
/// read and parsed every app's catalog fragment from disk, under the
/// supervisor lock, so with 50 apps each list made 50 file reads while
/// every other apps request waited).
#[test]
fn apps_list_reads_no_package_file() {
    let f = fixture();
    let ids = add_extensions(&f, 50, 0);
    f.supervisor.reload_local_apps_now();
    for id in &ids {
        f.install(id);
    }
    let (list, work) = work::of(|| f.supervisor.list());
    assert_eq!(work.package_file_reads, 0, "{work:?}");
    let ext = app_entry(&list, "local/ext1");
    assert_eq!(ext["commands"][0]["title"], "Go", "palette commands still listed: {ext}");
}

/// Two local folders with one id: the second is refused with why, so a
/// person whose saves to it changed nothing can see it (base red: it was
/// dropped without a word, its saves changed nothing and no pass said so).
#[test]
fn a_second_folder_with_the_same_id_is_refused_with_why() {
    let f = fixture();
    write_app(&local(&f), "zz-copy", "local/spy", json!({}));
    let answer = f.supervisor.reload_local_apps_now();
    let copy = local(&f).join("zz-copy").display().to_string();
    let issue = answer["rejected"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["dir"] == copy.as_str())
        .map(|r| r["issue"].as_str().unwrap_or_default().to_string());
    let issue = issue.unwrap_or_else(|| panic!("the copy is not named: {answer}"));
    assert!(issue.contains("local/spy"), "{issue}");
    let spy = app_entry(&f.supervisor.list(), "local/spy");
    assert!(spy["bundle_dir"].as_str().unwrap().ends_with("/spy"), "the first folder wins: {spy}");
}

/// A manifest past 64 KiB is refused, also when it is valid JSON, and the
/// other extensions keep loading.
#[test]
fn an_oversize_manifest_is_refused_and_the_others_load() {
    let f = fixture();
    write_bad(&f, "huge", &padded_manifest("local/huge", 1 << 20));
    let answer = f.supervisor.reload_local_apps_now();
    let dir = local(&f).join("huge").display().to_string();
    let rejected = answer["rejected"].as_array().unwrap();
    let issue = rejected.iter().find(|r| r["dir"] == dir.as_str()).map(|r| r["issue"].clone());
    assert!(
        issue.as_ref().and_then(Value::as_str).is_some_and(|i| i.contains("64 KiB")),
        "{answer}"
    );
    assert_eq!(app_entry(&f.supervisor.list(), "local/huge"), Value::Null);
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.0");
}
