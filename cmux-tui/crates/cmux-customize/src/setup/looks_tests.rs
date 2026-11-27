use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;

fn receipt(id: &str, source: SetupSource, on: bool) -> Receipt {
    let repository = source.to_string();
    Receipt {
        id: id.to_owned(),
        name: id.split('/').next_back().unwrap_or_default().to_owned(),
        source,
        repository,
        commit: format!("{:0<40}", id.len()),
        sha256: String::new(),
        version: None,
        generation: None,
        before: None,
        library: None,
        library_created: false,
        actions: Default::default(),
        prior_actions: Default::default(),
        extensions: Vec::new(),
        installed_ms: 0,
        on,
        layer: None,
    }
}

fn repo(text: &str) -> SetupSource {
    SetupSource::Repo { reference: Reference::parse(text).unwrap() }
}

#[test]
fn the_compiled_catalog_reads_and_lists_the_looks() {
    let catalog = catalog().unwrap();
    let ids: Vec<&str> = catalog.looks.iter().map(|look| look.id.as_str()).collect();
    // Leo, 2026-11-27: "we need to have at least SOMETHING you root for" and
    // "and obv dont call it t3 code and whatnot". The gallery lists four looks
    // under names of our own; the other looks stay installable by name.
    let profiles = ["codex", "claude-code"];
    let mut want: Vec<String> =
        profiles.iter().map(|app| format!("manaflow-ai/{app}-profile")).collect();
    want.push("manaflow-ai/studio-look".to_owned());
    want.push("manaflow-ai/paper-look".to_owned());
    assert_eq!(ids, want);
    assert!(catalog.looks.iter().all(|look| !look.tagline.is_empty()));
    // Leo, 2026-11-27: "im not a fan of the descriptions on our themes and
    // whatnot". A tagline is one short plain phrase; the traits are the
    // tag line's two or three words.
    for look in &catalog.looks {
        assert!(super::plain_phrase(&look.tagline), "{}: {:?}", look.id, look.tagline);
        assert!((2..=3).contains(&look.traits.len()), "{}: traits {:?}", look.id, look.traits);
    }
    let names: Vec<&str> = catalog.looks.iter().map(|look| look.name.as_str()).collect();
    assert_eq!(names, ["Pebble", "Kiln", "Studio", "Paper"]);
    assert_eq!(catalog.looks[2].repo, "github.com/manaflow-ai/cmux-studio-look");
    assert_eq!(catalog.looks[3].repo, "github.com/manaflow-ai/cmux-paper-look");
    // The app looks are folders of cmux itself, on the branch that carries them.
    for (look, app) in catalog.looks.iter().zip(profiles) {
        let reference = look.reference().unwrap();
        assert_eq!(
            reference.key(),
            format!("github.com/manaflow-ai/cmux/examples/looks/{app}/profile")
        );
        assert_eq!(reference.git_ref.as_deref(), Some("feat-cmux-next"));
    }
}

/// Every look the catalog lists from this repo is a setup folder here whose
/// manifest names the same id and whose preview files exist.
#[test]
fn the_catalog_looks_from_this_repo_are_its_examples() {
    // affected-reads: examples/looks
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    for look in catalog().unwrap().looks {
        let reference = look.reference().unwrap();
        if reference.owner != "manaflow-ai" || reference.repo != "cmux" {
            continue;
        }
        let folder = root.join(&reference.path);
        let manifest = std::fs::read_to_string(folder.join("cmux-setup.json")).unwrap();
        assert!(manifest.contains(&format!("\"id\": \"{}\"", look.id)), "{}", look.id);
        for file in [&look.previews.light, &look.previews.dark].into_iter().flatten() {
            assert!(folder.join(file).is_file(), "{}: {file}", look.id);
        }
    }
}

#[test]
fn a_catalog_that_breaks_a_rule_is_refused() {
    let look = |id: &str, repo: &str| json!({"id": id, "name": "N", "repo": repo});
    let text = |looks: serde_json::Value| json!({"cmuxLooks": 1, "looks": looks}).to_string();
    assert!(parse_catalog(&text(json!([look("a/x", "github.com/a/cmux-x")]))).is_ok());
    // A branch: a look in a folder of a repo whose default branch lacks it.
    assert!(parse_catalog(&text(json!([look("a/x", "github.com/a/mono/looks/x@next")]))).is_ok());
    for bad in [
        json!({"cmuxLooks": 2, "looks": []}).to_string(),
        "not json".to_owned(),
        // The id is not one its repo's owner may publish.
        text(json!([look("b/x", "github.com/a/cmux-x")])),
        // A commit: the gallery pins the commit its card shows, from the branch.
        text(json!([look("a/x", &format!("github.com/a/cmux-x@{}", "a".repeat(40)))])),
        text(json!([look("a/x", "not a repo")])),
        // The same id, or the same repo, twice.
        text(json!([look("a/x", "github.com/a/one"), look("a/x", "github.com/a/two")])),
        text(json!([look("a/x", "github.com/a/one"), look("a/y", "github.com/a/one")])),
        text(json!([{"id": "a/x", "name": " ", "repo": "github.com/a/one"}])),
        // A preview that is not a file inside the repo.
        text(
            json!([{"id": "a/x", "name": "N", "repo": "github.com/a/one", "previews": {"dark": "../x.png"}}]),
        ),
        text(
            json!([{"id": "a/x", "name": "N", "repo": "github.com/a/one", "previews": {"light": "/x.png"}}]),
        ),
        text(
            json!([{"id": "a/x", "name": "N", "repo": "github.com/a/one", "previews": {"light": "a.png?raw=1"}}]),
        ),
    ] {
        assert!(parse_catalog(&bad).is_err(), "{bad}");
    }
}

#[test]
fn an_empty_machine_lists_every_look_not_installed_and_no_stack() {
    let catalog = catalog().unwrap();
    let gallery = gallery(&catalog, &[]);
    assert_eq!(gallery.looks.len(), catalog.looks.len());
    assert!(gallery.looks.iter().all(|look| look.installed.is_none()));
    assert!(gallery.stack.is_empty());
    let value = serde_json::to_value(&gallery).unwrap();
    assert_eq!(value["looks"][0]["installed"], json!(null));
    assert_eq!(value["looks"][0]["id"], "manaflow-ai/codex-profile");
    assert_eq!(value["looks"][0]["tags"][0], "chat");
    assert_eq!(value["stack"], json!([]));
}

#[test]
fn the_gallery_merges_the_receipts_in_order_with_off_and_other_setups() {
    let catalog = catalog().unwrap();
    // Top first: someone's own setup, Paper (off), Codex installed from its repo
    // under another id is still Codex.
    let receipts = [
        receipt("leo/night", repo("github.com/leo/cmux-night"), true),
        receipt("manaflow-ai/paper-look", repo("github.com/manaflow-ai/cmux-paper-look"), false),
        receipt(
            "leo/codex-dev",
            repo("github.com/manaflow-ai/cmux/examples/looks/codex/profile@main"),
            true,
        ),
        receipt(
            "manaflow-ai/claude-code-profile",
            SetupSource::Folder { path: PathBuf::from("/tmp/cards") },
            true,
        ),
    ];
    let gallery = gallery(&catalog, &receipts);
    let stack: Vec<(&str, usize, bool, bool)> = gallery
        .stack
        .iter()
        .map(|row| (row.id.as_str(), row.position, row.on, row.catalog))
        .collect();
    assert_eq!(
        stack,
        [
            ("leo/night", 1, true, false),
            ("manaflow-ai/paper-look", 2, false, true),
            ("leo/codex-dev", 3, true, true),
            ("manaflow-ai/claude-code-profile", 4, true, true),
        ]
    );
    assert_eq!(gallery.stack[1].source, "github.com/manaflow-ai/cmux-paper-look");
    assert_eq!(gallery.stack[3].source, "/tmp/cards");
    let installed =
        |id: &str| gallery.looks.iter().find(|look| look.look.id == id).unwrap().installed.clone();
    // A catalog look's row is the same object as its stack row.
    assert_eq!(installed("manaflow-ai/paper-look").as_ref(), Some(&gallery.stack[1]));
    assert_eq!(installed("manaflow-ai/codex-profile").as_ref(), Some(&gallery.stack[2]));
    assert_eq!(installed("manaflow-ai/claude-code-profile").as_ref(), Some(&gallery.stack[3]));
    assert_eq!(installed("manaflow-ai/studio-look"), None);
    let value = serde_json::to_value(&gallery).unwrap();
    assert_eq!(value["looks"][3]["installed"]["on"], json!(false));
    assert_eq!(value["looks"][3]["installed"]["position"], json!(2));
}

#[test]
fn a_preview_resolves_through_the_receipts_then_the_catalog_then_any_repo() {
    let catalog = catalog().unwrap();
    let receipts = [
        receipt("manaflow-ai/paper-look", repo("github.com/manaflow-ai/cmux-paper-look@v1"), true),
        receipt("leo/try", SetupSource::Folder { path: PathBuf::from("/tmp/try") }, true),
    ];
    // Installed: at the commit it is installed at, by id or by repo.
    for which in ["manaflow-ai/paper-look", "https://github.com/manaflow-ai/cmux-paper-look"] {
        let target = resolve_preview(&catalog, &receipts, which).unwrap();
        assert_eq!(target.id, "manaflow-ai/paper-look");
        let PreviewSource::Repo { reference, git_ref } = target.source else { panic!() };
        assert_eq!((reference.git_ref, git_ref), (None, Some(receipts[0].commit.clone())));
    }
    let folder = resolve_preview(&catalog, &receipts, "leo/try").unwrap();
    assert_eq!(folder.source, PreviewSource::Folder { path: PathBuf::from("/tmp/try") });
    // Listed only: its default branch.
    for which in ["manaflow-ai/paper-look", "github.com/manaflow-ai/cmux-paper-look"] {
        let target = resolve_preview(&catalog, &[], which).unwrap();
        assert_eq!(target.id, "manaflow-ai/paper-look");
        assert!(matches!(target.source, PreviewSource::Repo { git_ref: None, .. }));
    }
    // Listed at a branch: that branch, and the reference itself names none.
    for which in
        ["manaflow-ai/codex-profile", "github.com/manaflow-ai/cmux/examples/looks/codex/profile"]
    {
        let target = resolve_preview(&catalog, &receipts, which).unwrap();
        assert_eq!(target.id, "manaflow-ai/codex-profile");
        let PreviewSource::Repo { reference, git_ref } = target.source else { panic!() };
        assert_eq!((reference.git_ref, git_ref.as_deref()), (None, Some("feat-cmux-next")));
    }
    // Any other repo, at the ref it names.
    let other = resolve_preview(&catalog, &[], "github.com/a/b@v2").unwrap();
    assert_eq!(other.id, "github.com/a/b");
    assert!(matches!(other.source, PreviewSource::Repo { git_ref: Some(ref r), .. } if r == "v2"));
    assert!(resolve_preview(&catalog, &[], "nobody/nothing").is_err());
}

#[test]
fn preview_files_urls_and_cache_paths() {
    assert_eq!(
        preview_files(Scheme::Dark),
        ["preview/golden-dark.png", "preview/golden-light.png", "screenshots/chat.png"]
    );
    assert_eq!(preview_files(Scheme::Light)[0], "preview/golden-light.png");
    assert_eq!(Scheme::parse("light"), Some(Scheme::Light));
    assert_eq!(Scheme::parse("dim"), None);
    let reference = Reference::parse("github.com/manaflow-ai/cmux-paper-look").unwrap();
    assert_eq!(
        raw_url(&reference, None, "preview/golden-dark.png").as_deref(),
        Some(
            "https://raw.githubusercontent.com/manaflow-ai/cmux-paper-look/HEAD/preview/golden-dark.png"
        )
    );
    let nested = Reference::parse("github.com/a/b/looks/night").unwrap();
    assert_eq!(
        raw_url(&nested, Some("abc"), "screenshots/chat.png").as_deref(),
        Some("https://raw.githubusercontent.com/a/b/abc/looks/night/screenshots/chat.png")
    );
    assert_eq!(raw_url(&Reference::parse("codeberg.org/a/b").unwrap(), None, "x.png"), None);
    let state = Path::new("/state");
    assert_eq!(
        preview_cache_dir(state, "manaflow-ai/paper-look"),
        Path::new("/state/looks/previews/manaflow-ai-paper-look")
    );
    assert_eq!(
        preview_cache_dir(state, "github.com/a/b"),
        Path::new("/state/looks/previews/github.com-a-b")
    );
    assert_eq!(preview_cache_dir(state, "../.."), Path::new("/state/looks/previews/look"));
    assert!(is_png(b"\x89PNG\r\n\x1a\nrest"));
    assert!(!is_png(b"<html>"));
}

#[test]
fn a_look_s_own_pictures_are_tried_before_the_golden_sample() {
    let catalog = parse_catalog(
        &json!({"cmuxLooks": 1, "looks": [
            {"id": "manaflow-ai/newtab-cards-look", "name": "Cards", "repo": "github.com/manaflow-ai/cmux-newtab-cards-look",
             "previews": {"light": "screenshots/after-few-light.png", "dark": "screenshots/after-few-dark.png"}},
            {"id": "manaflow-ai/studio-look", "name": "Studio", "repo": "github.com/manaflow-ai/cmux-studio-look"},
        ]})
        .to_string(),
    )
    .unwrap();
    assert_eq!(
        look_preview_files(&catalog, "manaflow-ai/newtab-cards-look", Scheme::Light),
        [
            "screenshots/after-few-light.png",
            "screenshots/after-few-dark.png",
            "preview/golden-light.png",
            "preview/golden-dark.png",
            "screenshots/chat.png",
        ]
    );
    // A look with no pictures of its own, or one not in the catalog, tries the defaults.
    assert_eq!(
        look_preview_files(&catalog, "manaflow-ai/studio-look", Scheme::Dark),
        preview_files(Scheme::Dark)
    );
    assert_eq!(
        look_preview_files(&catalog, "someone/else", Scheme::Dark),
        preview_files(Scheme::Dark)
    );
    // The catalog's own pictures are not written into the gallery's answer.
    let value = serde_json::to_value(gallery(&super::catalog().unwrap(), &[])).unwrap();
    assert!(value["looks"][0].get("previews").is_none());
}
