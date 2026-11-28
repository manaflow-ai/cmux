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

/// The entry as `use` left it: the pointer's layer on an app with its ABI.
fn entry() -> CodeLayer {
    layer_of(&pointer_json(true, 3), &App { abi: Some(3), ..App::default() }).unwrap()
}

/// `refresh_step` on an app whose commit is not known.
fn step(code: &CodeLayer, layer: &CodeLayer, published: &Published, tip: Option<&str>) -> Step {
    refresh_step(code, layer, published, tip, None)
}

#[test]
fn refresh_asks_for_a_layer_on_this_app_when_the_newest_is_behind() {
    let code = entry();
    let app = "c".repeat(40);
    for published in
        [Published::Pr(7), Published::Ref { kind: CodeKind::Branch, name: "feat-x".into() }]
    {
        assert_eq!(
            refresh_step(&code, &code, &published, None, Some(&app)),
            Step::Behind(app.clone()),
            "{published:?}"
        );
        // Built on this app's commit: up to date.
        assert_eq!(refresh_step(&code, &code, &published, None, Some(&code.base)), Step::Same);
    }
    // Our CI never builds a fork: nothing to ask for.
    let fork = Published::Fork { repo: "someone/cmux".into(), reference: "theme".into() };
    assert_eq!(refresh_step(&code, &code, &fork, None, Some(&app)), Step::Same);
}

#[test]
fn refresh_follows_the_design_table() {
    let pr = Published::Pr(7);
    let code = entry();
    assert_eq!(step(&code, &code, &pr, None), Step::Same);
    // A newer head, or the same head on a newer base: taken in place.
    let newer = CodeLayer { head: "e".repeat(40), ..code.clone() };
    assert_eq!(step(&code, &newer, &pr, None), Step::Take);
    let rebased = CodeLayer { base: "f".repeat(40), ..code.clone() };
    assert_eq!(step(&code, &rebased, &pr, None), Step::Take);
    // A branch whose tip moved past the layer: CI is asked.
    let branch = Published::Ref { kind: CodeKind::Branch, name: "feat-x".into() };
    let tip = "9".repeat(40);
    assert_eq!(step(&code, &code, &branch, Some(&tip)), Step::Ask(tip.clone()));
    assert_eq!(step(&code, &code, &branch, Some(&code.head)), Step::Same);
    // A fork's newer layer waits for `use`.
    let fork = Published::Fork { repo: "someone/cmux".into(), reference: "theme".into() };
    assert!(matches!(step(&code, &newer, &fork, None), Step::Wait(_)));
}

#[test]
fn refresh_turns_off_a_layer_on_another_web_abi() {
    let code = entry();
    // The app moved to ABI 4; the layer, at the same head or a newer one, needs 3.
    let app = App { abi: Some(4), ..App::default() };
    let mut newer = pointer_json(true, 3);
    newer["head"] = json!("e".repeat(40));
    for pointer in [pointer_json(true, 3), newer] {
        let layer = layer_of(&pointer, &app).unwrap();
        for published in [
            Published::Pr(7),
            Published::Ref { kind: CodeKind::Sha, name: "a".repeat(40) },
            Published::Fork { repo: "someone/cmux".into(), reference: "theme".into() },
        ] {
            assert_eq!(
                step(&code, &layer, &published, None),
                Step::Off("no longer applies: its web part needs web ABI 3; this app has 4".into()),
                "{published:?}"
            );
        }
    }
}

#[test]
fn refresh_turns_off_a_head_with_no_web_change_left() {
    let code = entry();
    let mut pointer = pointer_json(false, 3);
    pointer["head"] = json!("e".repeat(40));
    let layer = layer_of(&pointer, &App { abi: Some(3), ..App::default() }).unwrap();
    assert_eq!(
        step(&code, &layer, &Published::Pr(7), None),
        Step::Off("no longer applies: eeeeeeeeeeee has no web change".into())
    );
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

/// A layer fetch is a bare GET of a public file: no credential, cookie or person header rides with it.
#[test]
fn seeded_layer_fetch_sends_no_credential() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let http = Http::with_timeout(std::time::Duration::from_secs(30)).unwrap();
    let url = "https://files.cmux.com/cmux-next-web/seeded-pr-probe/latest.json";
    assert_eq!(http.get_json(url).unwrap(), Some(serde_json::json!({})));
    let sent: Vec<_> = cmux_egress::capture::requests_to("files.cmux.com")
        .into_iter()
        .filter(|r| r.target == "/cmux-next-web/seeded-pr-probe/latest.json")
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    let allowed = ["host", "accept", "user-agent", "accept-encoding", "content-length"];
    for (name, _) in &sent[0].headers {
        assert!(allowed.contains(&name.to_ascii_lowercase().as_str()), "{name}: {sent:?}");
    }
    assert!(sent[0].body.is_empty());
}
