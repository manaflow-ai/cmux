use super::*;

/// Fake builders at the real paths: each writes one file into its `--out`
/// (or fails when asked), so the side-by-side build runs without bun.
fn fake_builders(dir: &Path, fail: Option<&str>) {
    for (builder, _) in BUILDERS {
        let path = dir.join(builder);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let body = if fail.is_some_and(|name| builder.contains(name)) {
            "#!/bin/sh\necho building >&2\necho broke here >&2\nexit 3\n".to_owned()
        } else {
            "#!/bin/sh\nwhile [ \"$1\" != --out ]; do shift; done\nmkdir -p \"$2\" && echo built > \"$2/index.js\"\n".to_owned()
        };
        std::fs::write(&path, body).unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&path, permissions).unwrap();
    }
}

#[test]
fn the_builders_fill_every_nested_surface_and_leave_no_log() {
    let tmp = tempfile::tempdir().unwrap();
    fake_builders(tmp.path(), None);
    let out = tmp.path().join("out");
    build_surfaces(tmp.path(), &out).unwrap();
    for (prefix, _) in SURFACES {
        assert!(out.join(prefix).join("index.js").is_file(), "{prefix}");
    }
    let found = files(&out).unwrap();
    assert_eq!(found.len(), SURFACES.len(), "{found:?}");
    let logs: Vec<_> = std::fs::read_dir(&out)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().ends_with(".log"))
        .collect();
    assert!(logs.is_empty(), "{logs:?}");
}

#[test]
fn a_dead_clis_scratch_build_is_cleared_and_a_live_ones_kept() {
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(cmux_customize::Roots::under(home.path()));
    let layers = customize.layer_dir("build").parent().unwrap().to_path_buf();
    let mine = layers.join(format!(".build-{}-1", std::process::id()));
    let dead = layers.join(".build-999999999-1");
    let layer = layers.join("a".repeat(64));
    for dir in [&mine, &dead, &layer] {
        std::fs::create_dir_all(dir).unwrap();
    }
    clear_stale_builds(&customize);
    assert!(mine.is_dir() && layer.is_dir());
    assert!(!dead.exists());
}

#[test]
fn a_failing_builder_names_itself_and_its_last_lines() {
    let tmp = tempfile::tempdir().unwrap();
    fake_builders(tmp.path(), Some("pages"));
    let error = build_surfaces(tmp.path(), &tmp.path().join("out")).unwrap_err();
    assert!(error.message.contains("build-pages-web.sh failed"), "{}", error.message);
    assert!(error.message.contains("broke here"), "{}", error.message);
}

fn tree(root: &Path, files: &[(&str, &str)]) {
    for (path, body) in files {
        let path = root.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }
}

#[test]
fn the_same_build_is_the_same_layer_and_a_change_is_another() {
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("out");
    tree(
        &out,
        &[
            ("Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/app.js", "a"),
            ("Resources/markdown-viewer/webviews-app/index.html", "b"),
            (
                "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity/x",
                "c",
            ),
            ("Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/other.txt", "d"),
        ],
    );
    let found = files(&out).unwrap();
    // Agent Activity is a surface; a file beside the surfaces is none.
    assert_eq!(found.len(), 3);
    let one = digest(&out, &found).unwrap();
    assert_eq!(one, digest(&out, &files(&out).unwrap()).unwrap());
    tree(&out, &[("Resources/markdown-viewer/webviews-app/index.html", "c")]);
    assert_ne!(one, digest(&out, &files(&out).unwrap()).unwrap());
}

#[test]
fn place_maps_the_surfaces_and_writes_the_manifest() {
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("out");
    tree(
        &out,
        &[
            ("Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/app.js", "a"),
            (
                "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
                "p",
            ),
        ],
    );
    let found = files(&out).unwrap();
    let key = digest(&out, &found).unwrap();
    let layer = layer_for(tmp.path(), &App::default(), key.clone());
    let dir = tmp.path().join("layers").join(&key);
    place(&out, &found, &dir, &layer).unwrap();
    assert_eq!(std::fs::read_to_string(dir.join("pages/settings/app.js")).unwrap(), "a");
    assert!(dir.join("agent-pane/index.html").is_file());
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["kind"], "dir");
}

#[test]
fn a_folder_with_another_web_abi_stays_out() {
    let tmp = tempfile::tempdir().unwrap();
    tree(tmp.path(), &[(ABI_SOURCE, r#"{"abi": 8}"#)]);
    let app = App { path: None, commit: None, abi: Some(7) };
    let layer = layer_for(tmp.path(), &app, "e".repeat(64));
    assert!(!layer.has_web());
    assert!(layer.needs_build[0].contains("web ABI 8; this app has 7"));
    let same = App { abi: Some(8), ..app };
    assert!(layer_for(tmp.path(), &same, "e".repeat(64)).has_web());
}

#[test]
fn a_folder_is_named_by_its_last_part() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("My Cmux");
    std::fs::create_dir_all(&path).unwrap();
    let layer = layer_for(&path, &App::default(), "e".repeat(64));
    assert_eq!(layer.name(), "dir-my-cmux");
    assert_eq!(layer.kind, CodeKind::Dir);
}

#[test]
fn a_file_opened_or_read_is_not_a_save() {
    use notify::EventKind;
    use notify::event::{
        AccessKind, AccessMode, CreateKind, DataChange, MetadataKind, ModifyKind, RemoveKind,
        RenameMode,
    };
    let event = |kind| Ok(notify::Event::new(kind).add_path(PathBuf::from("/w/a.ts")));
    for kind in [
        EventKind::Access(AccessKind::Open(AccessMode::Any)),
        EventKind::Access(AccessKind::Read),
        EventKind::Access(AccessKind::Close(AccessMode::Read)),
        EventKind::Modify(ModifyKind::Metadata(MetadataKind::AccessTime)),
        EventKind::Other,
    ] {
        assert!(saved_paths(event(kind)).is_empty(), "{kind:?}");
    }
    for kind in [
        EventKind::Create(CreateKind::File),
        EventKind::Modify(ModifyKind::Data(DataChange::Any)),
        EventKind::Modify(ModifyKind::Name(RenameMode::To)),
        EventKind::Access(AccessKind::Close(AccessMode::Write)),
        EventKind::Remove(RemoveKind::File),
        EventKind::Any,
    ] {
        assert_eq!(saved_paths(event(kind)), vec![PathBuf::from("/w/a.ts")], "{kind:?}");
    }
}

#[test]
fn output_and_installs_are_not_saves() {
    let tmp = tempfile::tempdir().unwrap();
    let kept = worth_a_build(
        tmp.path(),
        vec![
            tmp.path().join("webviews/node_modules/x/index.js"),
            tmp.path().join("webviews/dist/a.js"),
        ],
    );
    assert!(kept.is_empty());
}

#[test]
fn a_failed_build_names_its_error_line_when_warnings_fill_the_tail() {
    // hq run 45341531578 (2026-11-24): the row showed only the esbuild warning.
    let mut text = String::from("vite v7 building\nerror TS2304: Cannot find name 'expect'.\n");
    for _ in 0..30 {
        text.push_str(
            "▲ [WARNING] No matching export in \"src/agent-session/acpmux/layoutWatch.ts\"\n",
        );
    }
    let said = super::why_failed("build.sh", &text);
    assert!(said.starts_with("build.sh failed: error TS2304"), "{said}");
    assert!(said.ends_with("layoutWatch.ts\""), "{said}");
    assert!(!said.contains("vite v7"), "{said}");
}

#[test]
fn a_failed_build_with_its_error_in_the_tail_is_the_tail() {
    let said = super::why_failed("build.sh", "a\nb\nerror: boom\n");
    assert_eq!(said, "build.sh failed:\na\nb\nerror: boom");
}
