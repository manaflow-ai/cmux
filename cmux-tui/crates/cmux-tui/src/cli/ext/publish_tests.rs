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
    assert_eq!((pkg.id.as_str(), pkg.published.as_deref()), ("local/hello", Some("acme/hello")));
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
    assert_eq!(failing(&report), vec!["picture"], "{}", report.text());
    assert!(!report.ready());

    add_icon(&dir);
    let report = publish_check(&dir, None, false);
    assert!(report.ready(), "{}", report.text());
    let text = report.text();
    assert!(text.contains("gh repo edit Acme/hello-ext --add-topic cmux-extension"), "{text}");
    assert!(text.contains("https://cmux.com/extensions"), "{text}");
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
    assert_eq!(failing(&report), vec!["repository", "id", "badge"], "{}", report.text());
    let text = report.text();
    assert!(text.contains("\"id\": \"acme/hello\""), "{text}");
    assert!(text.contains("\"repository\": \"https://github.com/Acme/hello-ext\""), "{text}");

    let report = publish_check(&dir, Some("Acme/hello-ext"), true);
    assert!(report.wrote_badge);
    assert_eq!(failing(&report), vec!["repository", "id"], "{}", report.text());
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
