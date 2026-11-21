use super::*;

#[test]
fn sources_that_name_a_pr() {
    for source in [
        "pr:43496",
        "#43496",
        "https://github.com/manaflow-ai/cmux/pull/43496",
        "https://github.com/manaflow-ai/cmux/pull/43496/files",
    ] {
        assert_eq!(pr_number(source), Some(43496), "{source}");
    }
    for source in
        ["night", "night.json", "pr-43496", "pr:", "#0", "https://github.com/other/repo/pull/1"]
    {
        assert_eq!(pr_number(source), None, "{source}");
    }
}

fn pointer_json(web: bool, abi: u64) -> Value {
    let mut files = json!({"no-app": ["docs/x.md"]});
    if web {
        files["web-live"] = json!(["webviews/src/a.ts"]);
    }
    files["rebuild"] = json!(["Packages/macOS/CmuxNext/Sources/X/Resources/icon.png"]);
    json!({
        "schema": 1, "repo": REPO, "pr": 7, "title": "cat",
        "head": "a".repeat(40), "base": "b".repeat(40), "merge": "c".repeat(40),
        "key": "d".repeat(64), "abi": abi,
        "classify": {"verdict": "rebuild", "files": files,
                     "reasons": {"resource or manifest": ["Packages/macOS/CmuxNext/Sources/X/Resources/icon.png"]}}
    })
}

#[test]
fn a_pointer_becomes_a_layer_with_what_needs_a_build() {
    let app = App { path: None, commit: None, abi: Some(3) };
    let layer = layer_of(&pointer_json(true, 3), &app).unwrap();
    assert_eq!(layer.web, "d".repeat(64));
    assert_eq!(
        layer.needs_build,
        vec![
            "resource or manifest (Packages/macOS/CmuxNext/Sources/X/Resources/icon.png)"
                .to_owned()
        ]
    );
    let none = layer_of(&pointer_json(false, 3), &app).unwrap();
    assert!(!none.has_web());
}

#[test]
fn refresh_takes_a_new_fork_layer_only_through_use() {
    let app = App { path: None, commit: None, abi: Some(3) };
    let fork = Published::Fork { repo: "someone/cmux".into(), reference: "theme".into() };
    let layer = layer_from(&pointer_json(true, 3), &app, Some(&fork)).unwrap();
    let note = fork_update_waits(&fork, &layer).unwrap();
    assert!(note.contains("cmux customize use someone/cmux@theme"), "{note}");
    assert!(note.contains(short(&layer.head)), "{note}");
    for ours in [
        Published::Pr(7),
        Published::Ref { kind: CodeKind::Branch, name: "feat-x".into() },
        Published::Ref { kind: CodeKind::Sha, name: "a".repeat(40) },
    ] {
        assert_eq!(fork_update_waits(&ours, &layer), None, "{ours:?}");
    }
}

#[test]
fn another_web_abi_keeps_the_web_part_out() {
    let app = App { path: None, commit: None, abi: Some(4) };
    let layer = layer_of(&pointer_json(true, 3), &app).unwrap();
    assert!(!layer.has_web());
    assert!(layer.needs_build[0].contains("web ABI 3; this app has 4"));
}

fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut builder =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
    for (path, body) in entries {
        let mut header = tar::Header::new_gnu();
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_entry_type(tar::EntryType::Regular);
        builder.append_data(&mut header, path, *body).unwrap();
    }
    builder.into_inner().unwrap().finish().unwrap()
}

#[test]
fn unpack_places_the_surfaces_and_writes_the_manifest_last() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("layers").join("k");
    let layer = layer_of(&pointer_json(true, 3), &App::default()).unwrap();
    let bytes = archive(&[
        (
            "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/index.html",
            b"<p>pr</p>",
        ),
        (
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
            b"pane",
        ),
        ("Resources/markdown-viewer/webviews-app/index.html", b"app"),
        ("other/ignored.txt", b"x"),
    ]);
    unpack(&bytes, &dir, &layer).unwrap();
    assert_eq!(std::fs::read(dir.join("pages/settings/index.html")).unwrap(), b"<p>pr</p>");
    assert!(dir.join("agent-pane/index.html").is_file());
    assert!(dir.join("webviews-app/index.html").is_file());
    assert!(!dir.join("other").exists());
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["abi"], json!(3));
    assert_eq!(manifest["commit"], json!("a".repeat(40)));
}

#[test]
fn unpack_refuses_a_path_that_climbs_out() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("layers").join("k");
    let layer = layer_of(&pointer_json(true, 3), &App::default()).unwrap();
    // tar::Builder refuses `..` itself, so write the name by hand.
    let mut header = tar::Header::new_gnu();
    header.set_size(1);
    header.set_mode(0o644);
    header.set_entry_type(tar::EntryType::Regular);
    let name = b"Resources/markdown-viewer/webviews-app/../../../x";
    header.as_old_mut().name[..name.len()].copy_from_slice(name);
    header.set_cksum();
    let mut builder =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
    builder.append(&header, &b"x"[..]).unwrap();
    let bytes = builder.into_inner().unwrap().finish().unwrap();
    assert!(unpack(&bytes, &dir, &layer).is_err());
    assert!(!dir.exists());
}
