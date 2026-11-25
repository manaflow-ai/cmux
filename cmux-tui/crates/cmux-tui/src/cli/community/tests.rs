//! `cmux theme install` / `cmux snippet install` end to end against local
//! git repositories: the ref resolves to a release tag's commit, only that
//! commit is fetched, the card is refused without consent, an install
//! applies, an update follows a new tag, and remove takes it back out.

use cmux_process::Command;
use std::fs;
use std::path::Path;

use cmux_customize::community::Tier;
use cmux_customize::{Customize, Roots};

use super::super::{GlobalArgs, OutputMode};
use super::{Consent, Git, RepoRef, Request, Routed, listed, parse, resolve_in, routed, run};

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.com",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "tag.gpgsign=false",
        ])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A repository at `<base>/alice/dusk` with one commit holding `files`.
fn repo(base: &Path, files: &[(&str, &str)], tag: &str) -> std::path::PathBuf {
    let dir = base.join("alice").join("dusk");
    if !dir.exists() {
        fs::create_dir_all(&dir).unwrap();
        git(&dir, &["init", "-q", "-b", "main"]);
    }
    for (path, text) in files {
        let file = dir.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "-q", "-m", tag]);
    git(&dir, &["tag", "-a", tag, "-m", tag]);
    dir
}

const MARKER: &str =
    r#"{ "cmuxTheme": 1, "id": "alice/dusk", "name": "Dusk", "version": "1.0.0" }"#;

fn quiet() -> GlobalArgs {
    GlobalArgs { output: OutputMode::Quiet, ..GlobalArgs::default() }
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn the_verbs_parse() {
    assert_eq!(
        parse(&words("install github.com/alice/dusk@1.0.0 --yes")).unwrap(),
        Request::Install { reference: "github.com/alice/dusk@1.0.0".into(), yes: true }
    );
    assert_eq!(parse(&words("update")).unwrap(), Request::Update { which: None, yes: false });
    assert_eq!(
        parse(&words("remove alice/dusk")).unwrap(),
        Request::Remove { which: "alice/dusk".into() }
    );
    assert_eq!(parse(&words("installed")).unwrap(), Request::Installed);
    assert!(parse(&words("install")).is_err());
    assert!(parse(&words("install a b")).is_err());
    assert!(parse(&words("install x --force")).is_err());
}

#[test]
fn references_parse_as_for_extensions() {
    let r = RepoRef::parse("https://codeberg.org/Alice/dusk.git/themes/night@v1.2.0").unwrap();
    assert_eq!(
        (r.host.as_str(), r.owner.as_str(), r.repo.as_str()),
        ("codeberg.org", "Alice", "dusk")
    );
    assert_eq!(r.path, "themes/night");
    assert_eq!(r.git_ref.as_deref(), Some("v1.2.0"));
    assert_eq!(r.canonical(), "codeberg.org/Alice/dusk/themes/night");
    for bad in [
        "http://github.com/a/b",
        "git@github.com:a/b",
        "github.com/a",
        "127.0.0.1/a/b",
        "github.com/a/b@..x",
        "github.com/a/../b",
    ] {
        assert!(RepoRef::parse(bad).is_err(), "{bad}");
    }
}

#[test]
fn no_ref_follows_the_newest_version_tag_else_the_default_branch() {
    let a = "a".repeat(40);
    let b = "b".repeat(40);
    let c = "c".repeat(40);
    let d = "d".repeat(40);
    let listing = format!(
        "{a}\tHEAD\n{a}\trefs/heads/main\n{b}\trefs/tags/v1.9.0\n{c}\trefs/tags/1.10.0\n{d}\trefs/tags/1.10.0^{{}}\n{a}\trefs/tags/nightly\n"
    );
    let newest = resolve_in(&listing, None).unwrap();
    assert_eq!(
        (newest.commit.as_str(), newest.tag.as_deref()),
        (d.as_str(), Some("1.10.0")),
        "peeled, by version"
    );
    assert_eq!(resolve_in(&listing, Some("v1.9.0")).unwrap().commit, b);
    assert_eq!(
        resolve_in(&listing, Some("main")).unwrap(),
        super::Resolved { commit: a.clone(), tag: None }
    );
    assert!(resolve_in(&listing, Some("nope")).is_err());
    let untagged = format!("{a}\tHEAD\n{a}\trefs/heads/main\n");
    assert_eq!(resolve_in(&untagged, None).unwrap().commit, a);
}

#[test]
fn a_registry_list_names_a_repo_by_owner_repo_or_url_and_path() {
    let r = RepoRef::parse("github.com/Alice/dusk").unwrap();
    assert!(listed(r#"[{"id":"alice/dusk","repo":"alice/dusk"}]"#, &r));
    assert!(listed(r#"[{"repo":"https://github.com/alice/dusk.git"}]"#, &r));
    assert!(!listed(r#"[{"repo":"alice/dusk","path":"sub"}]"#, &r));
    assert!(!listed("not json", &r));
}

#[test]
fn install_asks_first_then_applies_updates_on_a_new_tag_and_removes() {
    let base = tempfile::tempdir().unwrap();
    let dusk = r#"{ "appearance": { "accent": "blue" } }"#;
    repo(
        base.path(),
        &[("cmux-theme.json", MARKER), ("themes/dusk.json", dusk), ("README.md", "# Dusk")],
        "1.0.0",
    );
    let home = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join("config")).unwrap();
    fs::write(home.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let git_local = Git::local(base.path());
    let theme_file = home.path().join("config/themes/dusk.json");

    // No consent: nothing written.
    let install = Request::Install { reference: "github.com/alice/dusk".into(), yes: false };
    assert_eq!(
        run(
            &quiet(),
            &customize,
            &git_local,
            Tier::Theme,
            install.clone(),
            &mut Consent::Answer(false)
        ),
        1
    );
    assert!(!theme_file.exists());

    // A snippet install of a theme repository says which verb it needs.
    assert_eq!(
        run(
            &quiet(),
            &customize,
            &git_local,
            Tier::Snippet,
            install.clone(),
            &mut Consent::Answer(true)
        ),
        1
    );
    assert!(!theme_file.exists());

    assert_eq!(
        run(&quiet(), &customize, &git_local, Tier::Theme, install, &mut Consent::Answer(true)),
        0
    );
    assert_eq!(fs::read_to_string(&theme_file).unwrap(), dusk);
    let receipts = customize.community(Some(Tier::Theme)).unwrap();
    assert_eq!(receipts[0].tag.as_deref(), Some("1.0.0"));
    assert_eq!(receipts[0].reference, "github.com/alice/dusk");
    assert_eq!(receipts[0].sha256.len(), 64);

    // Up to date: no change.
    let update = Request::Update { which: None, yes: true };
    assert_eq!(
        run(
            &quiet(),
            &customize,
            &git_local,
            Tier::Theme,
            update.clone(),
            &mut Consent::Answer(false)
        ),
        0
    );
    assert_eq!(customize.community(None).unwrap(), receipts);

    // A new release: the update follows it.
    let newer = r#"{ "appearance": { "accent": "red" } }"#;
    repo(base.path(), &[("themes/dusk.json", newer)], "1.1.0");
    assert_eq!(
        run(&quiet(), &customize, &git_local, Tier::Theme, update, &mut Consent::Answer(false)),
        0
    );
    assert_eq!(fs::read_to_string(&theme_file).unwrap(), newer);
    assert_eq!(customize.community(None).unwrap()[0].tag.as_deref(), Some("1.1.0"));

    let remove = Request::Remove { which: "alice/dusk".into() };
    assert_eq!(
        run(&quiet(), &customize, &git_local, Tier::Theme, remove, &mut Consent::Answer(false)),
        0
    );
    assert!(!theme_file.exists());
    assert!(customize.community(None).unwrap().is_empty());
}

#[test]
fn an_id_that_is_not_the_owners_is_refused() {
    let base = tempfile::tempdir().unwrap();
    let marker = MARKER.replace("alice/dusk", "mallory/dusk");
    repo(base.path(), &[("cmux-theme.json", &marker), ("themes/dusk.json", "{}")], "1.0.0");
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let install = Request::Install { reference: "github.com/alice/dusk".into(), yes: true };
    assert_eq!(
        run(
            &quiet(),
            &customize,
            &Git::local(base.path()),
            Tier::Theme,
            install,
            &mut Consent::Answer(true)
        ),
        1
    );
    assert!(customize.community(None).unwrap().is_empty());
}

#[test]
fn apps_install_and_theme_import_of_a_repository_are_routed() {
    let no_file = |_: &str| false;
    assert_eq!(
        routed(&words("apps install github.com/alice/dusk@1.0.0"), no_file),
        Some(Routed { scope: None, reference: "github.com/alice/dusk@1.0.0".into(), yes: false })
    );
    assert_eq!(
        routed(&words("theme import github.com/alice/dusk --yes"), no_file),
        Some(Routed {
            scope: Some(Tier::Theme),
            reference: "github.com/alice/dusk".into(),
            yes: true
        })
    );
    // A local app id, a file of that name, another flag or verb: left to their own command.
    assert_eq!(routed(&words("apps install local/hello"), no_file), None);
    assert_eq!(routed(&words("theme import github.com/alice/dusk"), |_| true), None);
    assert_eq!(routed(&words("theme import github.com/alice/dusk --use"), no_file), None);
    assert_eq!(
        routed(&words("apps install github.com/alice/dusk --grant-optional"), no_file),
        None
    );
    assert_eq!(routed(&words("apps remove github.com/alice/dusk"), no_file), None);
    assert_eq!(routed(&words("theme import dusk.json"), no_file), None);
}

#[test]
fn the_marker_says_whether_a_repository_is_a_theme_a_snippet_or_neither() {
    let base = tempfile::tempdir().unwrap();
    let git_local = Git::local(base.path());
    let dusk = RepoRef::parse("github.com/alice/dusk").unwrap();
    repo(base.path(), &[("cmux-app.v2.json", "{}"), ("main.js", "")], "1.0.0");
    assert_eq!(git_local.tier_of(&dusk).unwrap(), None, "an extension goes on to apps install");
    repo(base.path(), &[("cmux-theme.json", MARKER), ("themes/dusk.json", "{}")], "1.1.0");
    assert_eq!(git_local.tier_of(&dusk).unwrap(), Some(Tier::Theme));
    // At a path: the marker under it.
    repo(base.path(), &[("look/cmux-snippet.json", "{}")], "1.2.0");
    let look = RepoRef::parse("github.com/alice/dusk/look").unwrap();
    assert_eq!(git_local.tier_of(&look).unwrap(), Some(Tier::Snippet));
    assert!(git_local.tier_of(&RepoRef::parse("github.com/alice/none").unwrap()).is_err());
}

#[test]
fn apps_install_of_a_theme_repository_installs_and_applies_it() {
    let base = tempfile::tempdir().unwrap();
    let dusk = r#"{ "appearance": { "accent": "blue" } }"#;
    repo(base.path(), &[("cmux-theme.json", MARKER), ("themes/dusk.json", dusk)], "1.0.0");
    let home = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join("config")).unwrap();
    fs::write(home.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let git_local = Git::local(base.path());

    // What cmux.com's install page shows: `cmux apps install REF@COMMIT`.
    let commit = git(&base.path().join("alice/dusk"), &["rev-parse", "HEAD"]);
    let words = words(&format!("apps install github.com/alice/dusk@{commit} --yes"));
    let route = routed(&words, |_| false).unwrap();
    let tier = git_local.tier_of(&RepoRef::parse(&route.reference).unwrap()).unwrap().unwrap();
    let install = Request::Install { reference: route.reference, yes: route.yes };
    assert_eq!(
        run(&quiet(), &customize, &git_local, tier, install, &mut Consent::Answer(false)),
        0
    );
    assert_eq!(fs::read_to_string(home.path().join("config/themes/dusk.json")).unwrap(), dusk);
    // Applied: the settings now pick it, so the look changes with no other command.
    let settings = fs::read_to_string(home.path().join("config/cmux-next.json")).unwrap();
    assert!(
        settings.contains("\"themeFile\"") || settings.contains("appearance.themeFile"),
        "{settings}"
    );
    assert!(settings.contains("\"dusk\""), "{settings}");

    // And back: remove puts back what was there.
    let remove = Request::Remove { which: "alice/dusk".into() };
    assert_eq!(
        run(&quiet(), &customize, &git_local, Tier::Theme, remove, &mut Consent::Answer(false)),
        0
    );
    let settings = fs::read_to_string(home.path().join("config/cmux-next.json")).unwrap();
    assert!(!settings.contains("\"dusk\""), "{settings}");
}
