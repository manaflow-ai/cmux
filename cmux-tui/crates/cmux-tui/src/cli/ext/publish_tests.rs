//! An extension as a git repository: `ext new --repo` (or the folder's
//! github.com origin) writes a folder whose id is the owner's, whose
//! manifest names the repository and whose README carries the "Get it on
//! cmux" badge and install line; `ext dev` still loads it (as `local/NAME`);
//! `ext publish` says what is left before it can be listed, and
//! `--write-badge` fills the badge in.

use cmux_process::Command;
use std::path::Path;

use serde_json::{Value, json};

use super::dev::{self, Phase};
use super::pack::{self, PackOptions};
use super::publish::{self, PublishOptions, Repo};
use super::tests::{FakeDaemon, dev_options, global, words};
use super::{Request, parse, scaffold};

const BADGE: &str = "[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/Acme/hello-ext)";

fn acme() -> Repo {
    Repo::parse("Acme/hello-ext").unwrap()
}

fn read_json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git").arg("-C").arg(dir).args(args).status().unwrap();
    assert!(status.success(), "git {args:?}");
}

/// Gives the manifest an image icon (listed in `files`) for the listing.
fn add_icon(dir: &Path) {
    std::fs::write(dir.join("icon.png"), b"\x89PNG\r\n\x1a\n").unwrap();
    let path = dir.join("cmux-app.json");
    let mut manifest = read_json(&path);
    manifest["icon"] = json!("icon.png");
    manifest["files"].as_array_mut().unwrap().push(json!("icon.png"));
    std::fs::write(&path, serde_json::to_string_pretty(&manifest).unwrap()).unwrap();
}

/// Records `ops` as the folder's scene (what `ext shot --record` writes) and ships `preview/`.
fn record_scene(dir: &Path, name: &str, ops: Value) {
    let file = super::shot::record_into(None, name, &ops);
    std::fs::create_dir_all(dir.join("preview")).unwrap();
    std::fs::write(dir.join("preview/scenes.json"), file.to_string()).unwrap();
    let path = dir.join("cmux-app.json");
    let mut manifest = read_json(&path);
    if let Some(files) = manifest["files"].as_array_mut() {
        if !files.contains(&json!("preview/")) {
            files.push(json!("preview/"));
        }
    }
    std::fs::write(&path, serde_json::to_string_pretty(&manifest).unwrap()).unwrap();
}

/// A section scene with no design warning.
fn clean_scene() -> Value {
    json!([
        {"op": "create", "id": "n1", "type": "VStack", "props": {"spacing": 8}},
        {"op": "create", "id": "n2", "type": "Text", "props": {"text": "Hello", "font": "headline"}},
        {"op": "children", "id": "n1", "children": ["n2"]},
        {"op": "root", "id": "n1"},
    ])
}

fn publish_check(dir: &Path, repo: Option<&str>, write_badge: bool) -> publish::Report {
    publish::check(&PublishOptions {
        dir: dir.to_path_buf(),
        repo: repo.map(str::to_string),
        write_badge,
    })
    .unwrap()
}

fn failing(report: &publish::Report) -> Vec<&'static str> {
    report.checks.iter().filter(|check| !check.ok).map(|check| check.name).collect()
}

#[test]
fn repositories_read_in_every_form_github_gives() {
    for text in [
        "Acme/hello-ext",
        "github.com/Acme/hello-ext",
        "https://github.com/Acme/hello-ext",
        "https://github.com/Acme/hello-ext.git",
        "https://github.com/Acme/hello-ext/",
        "git@github.com:Acme/hello-ext.git",
        "ssh://git@github.com/Acme/hello-ext.git",
    ] {
        assert_eq!(Repo::parse(text), Some(acme()), "{text}");
    }
    for bad in [
        "hello-ext",
        "https://gitlab.com/Acme/hello-ext",
        "git@gitlab.com:Acme/hello-ext.git",
        "Acme/hello/ext",
        "-acme/x",
        "Acme/..",
        "",
    ] {
        assert_eq!(Repo::parse(bad), None, "{bad}");
    }
    let repo = acme();
    assert_eq!(repo.publisher(), "acme");
    assert_eq!(repo.url(), "https://github.com/Acme/hello-ext");
    assert_eq!(repo.badge(), BADGE);
    assert_eq!(repo.install_command(), "cmux apps install github.com/Acme/hello-ext");
    assert!(Repo::parse("cmux/x").unwrap().publisher_problem().is_some());
    assert!(Repo::parse("manaflow-ai/x").unwrap().publisher_problem().is_none());
}

#[test]
fn new_and_publish_parse_their_repository_flags() {
    assert_eq!(
        parse(&words("new hello --repo github.com/Acme/hello-ext")),
        Ok(Request::New {
            name: "hello".into(),
            kind: "section".into(),
            dir: None,
            repo: Some(acme())
        })
    );
    assert!(parse(&words("new hello --repo nope")).is_err());
    assert!(parse(&words("new hello --repo")).is_err());
    let Ok(Request::Publish(options)) = parse(&words("publish ext/x --repo Acme/x --write-badge"))
    else {
        panic!("publish")
    };
    assert_eq!(options.dir, Path::new("ext/x"));
    assert_eq!(options.repo.as_deref(), Some("Acme/x"));
    assert!(options.write_badge);
    assert_eq!(
        parse(&words("pack x --out y")),
        Ok(Request::Pack(PackOptions { dir: "x".into(), out: Some("y".into()) }))
    );
    let Ok(Request::Publish(options)) = parse(&words("publish")) else { panic!("bare publish") };
    assert_eq!(
        (options.dir.as_path(), options.repo, options.write_badge),
        (Path::new("."), None, false)
    );
    for bad in ["publish --repo x", "publish a b", "publish --nope"] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

/// With a repository, the scaffold is a listable repo: the owner's id, the
/// repository field, the exact badge and install line, a .gitignore; and
/// `ext dev` loads it as `local/NAME`, its copy saying so.
#[test]
fn a_new_extension_with_a_repository_is_published_by_its_owner_and_still_loads() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold_for(&dir, "hello", "section", Some(&acme())).unwrap();
    let manifest = read_json(&dir.join("cmux-app.json"));
    assert_eq!(manifest["id"], "acme/hello");
    assert_eq!(manifest["repository"], "https://github.com/Acme/hello-ext");
    let report = cmux_app_manifest::validate_package_file(&dir, "cmux-app.json");
    assert!(report.is_valid(), "{:?}", report.issues);
    let readme = std::fs::read_to_string(dir.join("README.md")).unwrap();
    assert!(readme.lines().any(|line| line == BADGE), "{readme}");
    assert!(readme.contains("\ncmux apps install github.com/Acme/hello-ext\n"), "{readme}");
    assert!(readme.contains("(`acme/hello`)") && !readme.contains("OWNER/REPO"), "{readme}");
    assert!(std::fs::read_to_string(dir.join(".gitignore")).unwrap().contains("node_modules/"));

    let pkg = dev::load_package(&dir).unwrap_or_else(|errors| panic!("{errors:?}"));
    assert_eq!((pkg.id.as_str(), publish::published_id(&pkg)), ("local/hello", Some("acme/hello")));
    let local = root.path().join("state/apps/local");
    let fake = FakeDaemon::start(&local, "local/hello", false);
    let outcome = dev::once(&global(&fake.socket), &dev_options(&dir), false);
    assert_eq!(outcome.phase, Phase::Done, "{:?}", outcome.errors);
    assert_eq!(outcome.app.as_deref(), Some("local/hello"));
    let copy = read_json(&local.join("hello/cmux-app.json"));
    assert_eq!(copy["id"], "local/hello", "the daemon's local folder holds local/ apps only");
    let copied = cmux_app_manifest::validate_package_file(&local.join("hello"), "cmux-app.json");
    assert!(copied.is_valid(), "{:?}", copied.issues);
    // The folder itself keeps its published id.
    assert_eq!(read_json(&dir.join("cmux-app.json"))["id"], "acme/hello");
}

/// A command's catalog uses the owner's namespace; the copy `ext dev` loads
/// uses `local`'s, and both validate.
#[test]
fn a_published_command_validates_as_itself_and_as_its_development_copy() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("greet");
    scaffold::scaffold_for(&dir, "greet", "command", Some(&acme())).unwrap();
    let catalog = read_json(&dir.join("catalog.json"));
    assert_eq!(catalog["family"], "acme.greet");
    assert_eq!(catalog["operations"][0]["name"], "acme.greet.hello");
    assert_eq!(catalog["operations"][0]["owner"], "app:acme/greet");
    let report = cmux_app_manifest::validate_package_file(&dir, "cmux-app.json");
    assert!(report.is_valid(), "{:?}", report.issues);

    let pkg = dev::load_package(&dir).unwrap_or_else(|errors| panic!("{errors:?}"));
    let target = root.path().join("local/greet");
    dev::sync(&pkg, &target).unwrap_or_else(|problem| panic!("{problem:?}"));
    let copied = read_json(&target.join("catalog.json"));
    assert_eq!(copied["family"], "local.greet");
    assert_eq!(copied["operations"][0]["name"], "local.greet.hello");
    assert_eq!(copied["operations"][0]["owner"], "app:local/greet");
    let report = cmux_app_manifest::validate_package_file(&target, "cmux-app.json");
    assert!(report.is_valid(), "{:?}", report.issues);
}

/// With no repository the README says so: a marked placeholder badge and
/// install line; the id stays `local/`.
#[test]
fn a_new_extension_without_a_repository_marks_the_placeholder() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold(&dir, "hello", "section").unwrap();
    assert_eq!(read_json(&dir.join("cmux-app.json"))["id"], "local/hello");
    assert!(read_json(&dir.join("cmux-app.json")).get("repository").is_none());
    let readme = std::fs::read_to_string(dir.join("README.md")).unwrap();
    assert!(readme.contains(publish::PLACEHOLDER_NOTE), "{readme}");
    assert!(readme.contains("(https://cmux.com/extensions/OWNER/REPO)"), "{readme}");
    assert!(readme.contains("cmux apps install github.com/OWNER/REPO"), "{readme}");
}

/// A clone of the extension's empty GitHub repository: the folder holds only
/// `.git`, which counts as empty, and its origin names the repository.
#[test]
fn a_clone_of_an_empty_repository_takes_its_origin() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello-ext");
    std::fs::create_dir(&dir).unwrap();
    git(&dir, &["init", "-q"]);
    assert_eq!(publish::origin_repo(&dir), None, "no origin yet");
    git(&dir, &["remote", "add", "origin", "git@github.com:Acme/hello-ext.git"]);
    assert_eq!(publish::origin_repo(&dir), Some(acme()));
    // A folder inside that checkout is not the checkout's extension.
    let inner = dir.join("inner");
    std::fs::create_dir(&inner).unwrap();
    assert_eq!(publish::origin_repo(&inner), None);
    assert_eq!(publish::git_init(&inner), Some(false), "already in a repository");

    let repo = publish::origin_repo(&dir);
    std::fs::remove_dir(&inner).unwrap();
    scaffold::scaffold_for(&dir, "hello", "section", repo.as_ref()).unwrap();
    assert_eq!(read_json(&dir.join("cmux-app.json"))["id"], "acme/hello");

    let fresh = root.path().join("fresh");
    std::fs::create_dir(&fresh).unwrap();
    assert_eq!(publish::git_init(&fresh), Some(true));
    assert!(fresh.join(".git").exists());
}

/// `ext publish` on a fresh scaffold: everything but the picture is ready;
/// with an icon it is ready, and the steps name the topic and the page.
#[test]
fn publish_says_what_is_left_and_then_that_it_is_ready() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold_for(&dir, "hello", "section", Some(&acme())).unwrap();
    let report = publish_check(&dir, None, false);
    assert_eq!(failing(&report), vec!["picture", "design"], "{}", report.text());
    assert!(
        report.text().contains("no recorded scenes: run cmux ext shot --record"),
        "{}",
        report.text()
    );
    assert!(!report.ready());

    add_icon(&dir);
    record_scene(&dir, "cmux.section/1", clean_scene());
    let report = publish_check(&dir, None, false);
    assert!(report.ready(), "{}", report.text());
    let text = report.text();
    assert!(text.contains("gh repo edit Acme/hello-ext --add-topic cmux-extension"), "{text}");
    assert!(text.contains("https://cmux.com/extensions"), "{text}");
    assert!(
        text.contains("cmux ext pack && gh release create 0.1.0 release/cmux-app.v2.json release/cmux-extension.tar.gz --repo Acme/hello-ext"),
        "{text}"
    );
    assert!(text.contains("open a PR to manaflow-ai/cmux-extensions"), "{text}");
    let entry = publish::registry_entry(Some(&acme()), &read_json(&dir.join("cmux-app.json")));
    assert_eq!(
        entry,
        json!({
            "id": "acme/hello",
            "name": "Hello",
            "author": "Acme",
            "description": "A sidebar section made with cmux ext new.",
            "repo": "Acme/hello-ext",
        })
    );
    assert!(text.contains("cmux apps install github.com/Acme/hello-ext"), "{text}");
    let json = report.to_json();
    assert_eq!(json["ready"], true);
    assert_eq!(json["id"], "acme/hello");
    assert_eq!(json["badge"], BADGE);
    assert_eq!(json["page"], "https://cmux.com/extensions/Acme/hello-ext");

    // A --repo that is not the manifest's is named.
    let report = publish_check(&dir, Some("Other/hello-ext"), false);
    assert!(failing(&report).contains(&"repository"), "{}", report.text());
}

/// A `local/` extension published later: the id, the repository field and
/// the badge are named with the exact values; `--write-badge` fills in the
/// placeholder badge and install line, once.
#[test]
fn publish_names_the_id_and_repository_and_writes_the_badge() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold(&dir, "hello", "section").unwrap();
    add_icon(&dir);
    let report = publish_check(&dir, Some("Acme/hello-ext"), false);
    assert_eq!(failing(&report), vec!["repository", "id", "badge", "design"], "{}", report.text());
    let text = report.text();
    assert!(text.contains("\"id\": \"acme/hello\""), "{text}");
    assert!(text.contains("\"repository\": \"https://github.com/Acme/hello-ext\""), "{text}");

    let report = publish_check(&dir, Some("Acme/hello-ext"), true);
    assert!(report.wrote_badge);
    assert_eq!(failing(&report), vec!["repository", "id", "design"], "{}", report.text());
    let readme = std::fs::read_to_string(dir.join("README.md")).unwrap();
    assert!(readme.lines().any(|line| line == BADGE), "{readme}");
    assert!(readme.contains("cmux apps install github.com/Acme/hello-ext"), "{readme}");
    assert!(!readme.contains("OWNER/REPO"), "{readme}");
    assert!(!publish_check(&dir, Some("Acme/hello-ext"), true).wrote_badge, "already there");
}

#[test]
fn the_badge_goes_under_the_title_or_replaces_another() {
    let repo = acme();
    assert_eq!(
        publish::with_badge("# Hello\n\nText.\n", &repo).unwrap(),
        format!("# Hello\n\n{BADGE}\n\nText.\n")
    );
    assert_eq!(publish::with_badge("Text.\n", &repo).unwrap(), format!("{BADGE}\n\nText.\n"));
    let other = "# Hello\n\n[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/old/name)\n";
    assert_eq!(publish::with_badge(other, &repo).unwrap(), format!("# Hello\n\n{BADGE}\n"));
    assert_eq!(publish::with_badge(&format!("# Hello\n\n{BADGE}\n"), &repo), None);
}

#[test]
fn publish_refuses_a_bad_repository_and_a_missing_folder() {
    let root = tempfile::tempdir().unwrap();
    assert!(
        publish::check(&PublishOptions {
            dir: root.path().join("none"),
            repo: None,
            write_badge: false
        })
        .is_err()
    );
    assert!(
        publish::check(&PublishOptions {
            dir: root.path().to_path_buf(),
            repo: Some("nope".into()),
            write_badge: false
        })
        .is_err()
    );
    let report = publish_check(root.path(), None, false);
    assert!(failing(&report).contains(&"manifest"), "{}", report.text());
}

/// `ext pack`: the manifest and the files it names (no sources), the same
/// bytes for the same files, the manifest beside it as cmux-app.v2.json,
/// and nothing of an earlier pack's output inside the next one.
#[test]
fn pack_writes_the_release_assets_and_the_same_archive_twice() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold_for(&dir, "hello", "section", Some(&acme())).unwrap();
    add_icon(&dir);
    let options = PackOptions { dir: dir.clone(), out: None };
    let first = pack::pack(&options).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!((first.id.as_str(), first.version.as_str()), ("acme/hello", "0.1.0"));
    assert_eq!(first.archive, dir.join("release/cmux-extension.tar.gz"));
    assert_eq!(read_json(&first.manifest)["id"], "acme/hello");
    let mut names = Vec::new();
    let gz = flate2::read::GzDecoder::new(std::fs::File::open(&first.archive).unwrap());
    let mut archive = tar::Archive::new(gz);
    for entry in archive.entries().unwrap() {
        let entry = entry.unwrap();
        assert_eq!(entry.header().mtime().unwrap(), 0);
        names.push(entry.path().unwrap().to_string_lossy().into_owned());
    }
    assert_eq!(names, vec!["cmux-app.json", "dist/main.js", "icon.png"]);
    assert_eq!(first.sha256.len(), 64);
    let again = pack::pack(&options).unwrap();
    assert_eq!(again.sha256, first.sha256, "release/ stays out and the bytes are the same");
    assert!(std::fs::read_to_string(dir.join(".gitignore")).unwrap().contains("release/"));

    std::fs::write(dir.join("cmux-app.json"), "{").unwrap();
    assert!(pack::pack(&options).is_err(), "an invalid manifest is not packed");
}

/// Registry review refuses a listing whose recorded scenes have any design warning, with the
/// warnings and their fixes in the refusal; a scene that does not ship, or none at all, is
/// refused too; a command, which draws nothing, passes.
#[test]
fn publish_refuses_a_listing_whose_recorded_scenes_warn() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("hello");
    scaffold::scaffold_for(&dir, "hello", "section", Some(&acme())).unwrap();
    add_icon(&dir);
    let warned = json!([
        {"op": "create", "id": "n1", "type": "VStack", "props": {"spacing": 5}},
        {"op": "create", "id": "n2", "type": "Text", "props": {"text": "Hi", "font": 14, "color": "#ff0000"}},
        {"op": "children", "id": "n1", "children": ["n2"]},
        {"op": "root", "id": "n1"},
    ]);
    record_scene(&dir, "cmux.section/1", warned);
    let report = publish_check(&dir, None, false);
    assert_eq!(failing(&report), vec!["design"], "{}", report.text());
    let text = report.text();
    assert!(text.contains("registry review refuses a listing with any"), "{text}");
    assert!(text.contains("spacing: spacing 5 is not on the spacing scale"), "{text}");
    assert!(text.contains("fix: use 6"), "{text}");
    assert!(text.contains("color: color #ff0000 is a raw color"), "{text}");
    let json = report.to_json();
    assert_eq!(json["ready"], false);
    assert_eq!(json["design"]["ok"], false);
    let checks: Vec<&str> = json["design"]["scenes"][0]["design"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| finding["check"].as_str().unwrap())
        .collect();
    assert!(
        checks.contains(&"spacing") && checks.contains(&"type-size") && checks.contains(&"color"),
        "{checks:?}"
    );

    // The same check is `ext design --listing DIR`'s.
    let manifest = read_json(&dir.join("cmux-app.json"));
    assert_eq!(super::design::listing(&dir, &manifest), report.design.clone().unwrap());

    // Fixed and recorded again: ready.
    record_scene(&dir, "cmux.section/1", clean_scene());
    let report = publish_check(&dir, None, false);
    assert!(report.ready(), "{}", report.text());
    assert!(
        report.text().contains("1 recorded scene (preview/scenes.json), no design warning"),
        "{}",
        report.text()
    );

    // Recorded but not shipped: review reads the package, so it is refused.
    let path = dir.join("cmux-app.json");
    let mut manifest = read_json(&path);
    manifest["files"].as_array_mut().unwrap().retain(|entry| entry != "preview/");
    std::fs::write(&path, serde_json::to_string_pretty(&manifest).unwrap()).unwrap();
    let report = publish_check(&dir, None, false);
    assert_eq!(failing(&report), vec!["design"], "{}", report.text());
    assert!(
        report.text().contains("add \"preview/\" to the manifest's files"),
        "{}",
        report.text()
    );

    // A command draws no view: nothing to record, nothing refused.
    let command = root.path().join("cmd");
    scaffold::scaffold_for(&command, "cmd", "command", Some(&acme())).unwrap();
    let manifest = read_json(&command.join("cmux-app.json"));
    assert!(super::design::listing(&command, &manifest).ok());
}

/// A widget's recorded scene is checked as a widget (line limits too), by its name.
#[test]
fn a_recorded_widget_scene_is_checked_as_a_widget() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("tile");
    scaffold::scaffold_for(&dir, "tile", "widget", Some(&acme())).unwrap();
    let no_limit = json!([
        {"op": "create", "id": "n1", "type": "VStack", "props": {"spacing": 4, "padding": 16}},
        {"op": "create", "id": "n2", "type": "Text", "props": {"text": "72", "font": 34, "weight": "semibold"}},
        {"op": "children", "id": "n1", "children": ["n2"]},
        {"op": "root", "id": "n1"},
    ]);
    record_scene(&dir, "cmux.widget/1 small", no_limit);
    let manifest = read_json(&dir.join("cmux-app.json"));
    let review = super::design::listing(&dir, &manifest);
    assert!(!review.ok());
    assert_eq!(review.scenes[0].0, "preview/scenes.json:cmux.widget/1 small");
    let checks: Vec<&str> = review.scenes[0].1.iter().map(|f| f.check).collect();
    assert_eq!(checks, vec!["line-limit"], "{:?}", review.scenes[0].1);
}

/// The cold-model test (DESIGN.md section 12): widgets a small model wrote from
/// skills/cmux-customization/references/extension-design.md alone, recorded by
/// `cmux-app-host/tools/cold-model.ts`, pass registry review's design check with no warning.
#[test]
fn cold_model_widgets_pass_the_design_check() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/cli/ext/cold_model");
    let mut dirs: Vec<_> = std::fs::read_dir(&root)
        .expect("the cold-model runs")
        .map(|entry| entry.expect("an entry").path())
        .filter(|path| path.is_dir())
        .collect();
    dirs.sort();
    assert!(dirs.len() >= 5, "five cold-model widgets, found {}", dirs.len());
    for dir in dirs {
        let manifest: Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("cmux-app.json")).expect("a manifest"),
        )
        .expect("the manifest reads");
        let review = super::design::listing(&dir, &manifest);
        assert!(
            review.ok() && review.warnings() == 0,
            "{}: {}\n{}",
            dir.display(),
            review.summary(),
            review.details().join("\n")
        );
        // Both sizes the manifest offers were drawn and checked as a widget.
        let mut names: Vec<_> = review.scenes.iter().map(|(name, _)| name.as_str()).collect();
        names.sort();
        assert_eq!(
            names,
            ["preview/scenes.json:cmux.widget/1 medium", "preview/scenes.json:cmux.widget/1 small"],
            "{}",
            dir.display()
        );
    }
}
