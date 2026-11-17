//! `cmux ext remix` and `cmux ext share`: the source reference, the manifest
//! and README edits, a remix fetched with `git` from a local stand-in for the
//! host (by commit, from a subfolder, and through the full-fetch fallback),
//! and publishing through a fake `gh` that records what it was asked.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use super::remix::{self, RemixOptions, SourceRef};
use super::share::{self, ShareOptions, Shared};
use super::tests::words;
use super::{Request, parse};

const MAIN_JS: &str = "function renderSection() { return Text('hi'); }\nglobalThis.__cmuxAppExports = { renderSection };\n";

fn manifest(id: &str, repository: Option<&str>) -> String {
    let repository =
        repository.map(|url| format!("  \"repository\": \"{url}\",\n")).unwrap_or_default();
    format!(
        r#"{{
  "$schema": "https://cmux.dev/schemas/cmux-app/2.json",
  "manifestVersion": 2,
  "id": "{id}",
{repository}  "name": "Todo",
  "version": "1.0.0",
  "description": "A to-do list in the sidebar.",
  "engines": {{ "cmux": "^2.0" }},
  "runtime": {{ "main": "main.js" }},
  "implements": {{
    "cmux.section/1": {{
      "export": "renderSection",
      "title": "Todo",
      "symbol": "sparkles",
      "options": {{ "defaultRegion": "bottom" }}
    }}
  }}
}}
"#
    )
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(args)
        .output()
        .expect("git runs");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn write(dir: &Path, files: &[(&str, &str)]) {
    for (path, text) in files {
        let path = dir.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
}

/// A source repository at `base/github.com/acme/REPO` with one commit of `files`; its commit.
fn source_repo(base: &Path, repo: &str, files: &[(&str, &str)]) -> String {
    let dir = base.join("github.com/acme").join(repo);
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    write(&dir, files);
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "-q", "-m", "one"]);
    git(&dir, &["rev-parse", "HEAD"])
}

fn badge_readme(slug: &str) -> String {
    format!(
        "# Todo\n\n[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/{slug})\n\nA list.\n"
    )
}

#[test]
fn reads_source_references() {
    let parsed =
        SourceRef::parse("github.com/Acme/cmux-todo@0123456789abcdef0123456789abcdef01234567")
            .unwrap();
    assert_eq!(
        parsed,
        SourceRef {
            host: "github.com".into(),
            owner: "Acme".into(),
            repo: "cmux-todo".into(),
            path: String::new(),
            rev: Some("0123456789abcdef0123456789abcdef01234567".into()),
        }
    );
    let parsed = SourceRef::parse("https://codeberg.org/acme/pack.git/widgets/clock@main").unwrap();
    assert_eq!(
        (parsed.host.as_str(), parsed.repo.as_str(), parsed.path.as_str()),
        ("codeberg.org", "pack", "widgets/clock")
    );
    assert_eq!(parsed.display(Some("abc")), "codeberg.org/acme/pack/widgets/clock@abc");
    assert_eq!(
        parsed.page_url(),
        "https://cmux.com/extensions/codeberg.org/acme/pack/widgets/clock"
    );
    assert_eq!(
        SourceRef::parse("github.com/acme/todo").unwrap().page_url(),
        "https://cmux.com/extensions/acme/todo"
    );
    assert_eq!(SourceRef::parse("github.com/acme/todo/").unwrap().rev, None);
    for bad in [
        "acme/todo",
        "github.com/acme",
        "github.com/acme/../x",
        "github.com/acme/todo@-x",
        "github.com/acme/todo@a..b",
        "github.com/acme/todo; rm -rf ~",
        "file:///etc/passwd",
        "github.com/acme/to do",
        "",
    ] {
        assert!(SourceRef::parse(bad).is_none(), "{bad}");
    }
}

#[test]
fn parses_remix_and_share() {
    assert_eq!(
        parse(&words("remix github.com/acme/todo@abc --name mine --dir /tmp/x")),
        Ok(Request::Remix(RemixOptions {
            source: "github.com/acme/todo@abc".into(),
            dir: Some("/tmp/x".into()),
            name: Some("mine".into()),
        }))
    );
    assert!(parse(&words("remix")).is_err());
    assert!(parse(&words("remix acme/todo")).is_err());
    assert!(parse(&words("remix github.com/a/b github.com/c/d")).is_err());
    assert_eq!(
        parse(&words("share")),
        Ok(Request::Share { dir: PathBuf::from("."), name: None, private: false })
    );
    assert_eq!(
        parse(&words("share ext/todo --private --name my-todo")),
        Ok(Request::Share {
            dir: PathBuf::from("ext/todo"),
            name: Some("my-todo".into()),
            private: true
        })
    );
    assert!(parse(&words("share --force")).is_err());
}

#[test]
fn repository_field_is_set_replaced_and_removed_in_place() {
    let with = manifest("acme/todo", Some("https://github.com/acme/todo"));
    let without = manifest("acme/todo", None);
    assert_eq!(remix::with_repository(&with, None).unwrap(), without);
    assert_eq!(
        remix::with_repository(&without, Some("https://github.com/acme/todo")).unwrap(),
        with
    );
    let replaced = remix::with_repository(&with, Some("https://github.com/me/todo")).unwrap();
    assert_eq!(replaced, with.replace("github.com/acme/todo\"", "github.com/me/todo\""));
    // The last field: the comma before it goes too.
    let last = "{\n  \"id\": \"a/b\",\n  \"repository\": \"https://github.com/a/b\"\n}\n";
    assert_eq!(remix::with_repository(last, None).unwrap(), "{\n  \"id\": \"a/b\"\n}\n");
    // One line: written whole.
    let one: Value = serde_json::from_str(
        &remix::with_repository(
            r#"{"id":"a/b","repository":"x"}"#,
            Some("https://github.com/me/b"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(one["repository"], "https://github.com/me/b");
    assert!(remix::with_repository("[1]", None).is_none());
}

#[test]
fn badge_goes_under_the_heading_once() {
    let exact = "[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/me/todo)";
    assert_eq!(share::badge("me", "todo"), exact);
    let out = share::with_badge(&badge_readme("acme/todo"), "me", "todo", "Todo");
    assert_eq!(out, format!("# Todo\n\n{exact}\n\nA list.\n"));
    assert_eq!(share::with_badge(&out, "me", "todo", "Todo"), out);
    assert_eq!(share::with_badge("", "me", "todo", "Todo"), format!("# Todo\n\n{exact}\n"));
}

#[test]
fn remix_fetches_the_commit_into_a_new_local_folder() {
    let base = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let first = source_repo(
        base.path(),
        "todo",
        &[
            ("cmux-app.json", &manifest("acme/todo", Some("https://github.com/acme/todo"))),
            ("main.js", MAIN_JS),
            ("README.md", &badge_readme("acme/todo")),
        ],
    );
    // A later commit on the branch: the remix takes the commit it was asked for.
    let source = base.path().join("github.com/acme/todo");
    write(&source, &[("main.js", "// later\n")]);
    git(&source, &["commit", "-q", "-am", "two"]);
    std::fs::create_dir_all(home.path().join("Projects/todo")).unwrap();

    let options =
        RemixOptions { source: format!("github.com/acme/todo@{first}"), dir: None, name: None };
    let made = remix::remix(&options, home.path(), Some(base.path())).unwrap();
    assert_eq!(made.commit, first);
    // ~/Projects/todo was taken.
    assert_eq!(made.dir, home.path().join("Projects/todo-2"));
    assert_eq!(made.app, "local/todo");
    assert!(made.issues.is_empty(), "{:?}", made.issues);
    let text = std::fs::read_to_string(made.dir.join("cmux-app.json")).unwrap();
    assert_eq!(text, manifest("local/todo", None));
    assert_eq!(std::fs::read_to_string(made.dir.join("main.js")).unwrap(), MAIN_JS);
    let readme = std::fs::read_to_string(made.dir.join("README.md")).unwrap();
    assert!(!readme.contains("badge.svg"), "{readme}");
    assert!(
        readme.contains(&format!(
            "Remixed from [github.com/acme/todo](https://github.com/acme/todo/tree/{first}) at `{}`.",
            &first[..12]
        )),
        "{readme}"
    );
    assert!(made.dir.join(".git").is_dir());
    let json = made.to_json();
    assert_eq!(json["source"]["ref"], format!("github.com/acme/todo@{first}"));
    let brief = made.brief();
    assert!(brief.contains("Ask the person what to change"), "{brief}");
    assert!(brief.contains(&format!("cmux ext share {} --json", made.dir.display())), "{brief}");
    assert!(brief.contains("on by default"), "{brief}");
}

#[test]
fn remix_takes_a_subfolder_and_the_default_branch() {
    let base = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let head = source_repo(
        base.path(),
        "pack",
        &[
            ("README.md", "# A pack\n"),
            ("widgets/clock/cmux-app.v2.json", &manifest("acme/clock", None)),
            ("widgets/clock/main.js", MAIN_JS),
        ],
    );
    let target = home.path().join("mine");
    let options = RemixOptions {
        source: "github.com/acme/pack/widgets/clock".into(),
        dir: Some(target.clone()),
        name: Some("my-clock".into()),
    };
    let made = remix::remix(&options, home.path(), Some(base.path())).unwrap();
    assert_eq!(
        (made.commit.as_str(), made.dir.as_path(), made.app.as_str()),
        (head.as_str(), target.as_path(), "local/my-clock")
    );
    assert_eq!(made.manifest, "cmux-app.v2.json");
    assert!(!target.join("widgets").exists());
    assert!(std::fs::read_to_string(target.join("README.md")).unwrap().contains("/tree/"));

    // Not an extension, an unknown commit, a missing folder: refused, nothing made.
    let not = RemixOptions {
        source: "github.com/acme/pack".into(),
        dir: Some(home.path().join("a")),
        name: None,
    };
    assert!(
        remix::remix(&not, home.path(), Some(base.path()))
            .unwrap_err()
            .contains("not a cmux extension")
    );
    let gone = RemixOptions {
        source: format!("github.com/acme/pack/widgets/clock@{}", "f".repeat(40)),
        dir: Some(home.path().join("b")),
        name: None,
    };
    assert!(remix::remix(&gone, home.path(), Some(base.path())).is_err());
    let missing = RemixOptions {
        source: "github.com/acme/pack/nope".into(),
        dir: Some(home.path().join("c")),
        name: None,
    };
    assert!(
        remix::remix(&missing, home.path(), Some(base.path()))
            .unwrap_err()
            .contains("no folder nope")
    );
    for dir in ["a", "b", "c"] {
        assert!(!home.path().join(dir).exists(), "{dir}");
    }
}

/// A fake `gh` that logs each call to `log` and answers `api user` with `login` (fails with none).
fn fake_gh(dir: &Path, login: Option<&str>, taken: &[&str]) -> (PathBuf, PathBuf) {
    let log = dir.join("gh.log");
    let gh = dir.join("gh");
    let user = match login {
        Some(login) => format!("echo {login}"),
        None => "echo 'You are not logged into any GitHub hosts.' >&2; exit 1".into(),
    };
    let taken: String =
        taken.iter().map(|slug| format!("[ \"$3\" = {slug} ] && exit 0\n")).collect();
    let script = format!(
        "#!/bin/sh\necho \"$*\" >> '{}'\ncase \"$1 $2\" in\n  'api user') {user} ;;\n  'repo view') {taken}exit 1 ;;\nesac\nexit 0\n",
        log.display()
    );
    std::fs::write(&gh, script).unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    (gh, log)
}

fn extension_folder(root: &Path) -> PathBuf {
    let dir = root.join("todo");
    write(
        &dir,
        &[
            ("cmux-app.json", &manifest("local/todo", None)),
            ("main.js", MAIN_JS),
            ("README.md", "# Todo\n\nA list.\n"),
        ],
    );
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["config", "user.name", "Test"]);
    git(&dir, &["config", "user.email", "test@example.com"]);
    dir
}

#[test]
fn share_publishes_to_a_new_repository_of_the_login() {
    let root = tempfile::tempdir().unwrap();
    let dir = extension_folder(root.path());
    let (gh, log) = fake_gh(root.path(), Some("Octo-Cat"), &["Octo-Cat/todo"]);
    let shared =
        share::share(&ShareOptions { dir: dir.clone(), name: None, private: false, gh }).unwrap();
    // Octo-Cat/todo was taken: the next free name.
    assert_eq!(
        shared,
        Shared::Published {
            owner: "Octo-Cat".into(),
            repo: "todo-2".into(),
            private: false,
            updated: false
        }
    );
    let text = std::fs::read_to_string(dir.join("cmux-app.json")).unwrap();
    let parsed: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["id"], "octo-cat/todo");
    assert_eq!(parsed["repository"], "https://github.com/Octo-Cat/todo-2");
    let readme = std::fs::read_to_string(dir.join("README.md")).unwrap();
    assert!(readme.contains(&share::badge("Octo-Cat", "todo-2")), "{readme}");
    let calls = std::fs::read_to_string(&log).unwrap();
    assert!(
        calls.contains(&format!(
            "repo create Octo-Cat/todo-2 --public --source {} --remote origin --push --description A to-do list in the sidebar.",
            dir.display()
        )),
        "{calls}"
    );
    assert!(calls.contains("repo edit Octo-Cat/todo-2 --add-topic cmux-extension"), "{calls}");
    // Everything was committed before the push.
    assert_eq!(git(&dir, &["status", "--porcelain"]), "");
    let json = shared.to_json(&dir);
    assert_eq!(json["page"], "https://cmux.com/extensions/Octo-Cat/todo-2");
    assert_eq!(json["topic"], "cmux-extension");
    assert!(shared.text(&dir).contains("page: https://cmux.com/extensions/Octo-Cat/todo-2"));
}

#[test]
fn share_without_github_keeps_the_folder_and_names_the_step() {
    let root = tempfile::tempdir().unwrap();
    let dir = extension_folder(root.path());
    let before = std::fs::read_to_string(dir.join("cmux-app.json")).unwrap();
    let (gh, log) = fake_gh(root.path(), None, &[]);
    let shared =
        share::share(&ShareOptions { dir: dir.clone(), name: None, private: false, gh }).unwrap();
    let Shared::NotConnected { step, .. } = &shared else { panic!("{shared:?}") };
    assert_eq!(step, "run gh auth login");
    assert_eq!(std::fs::read_to_string(dir.join("cmux-app.json")).unwrap(), before);
    assert!(!std::fs::read_to_string(&log).unwrap().contains("repo create"));
    assert_eq!(shared.to_json(&dir)["kept"], true);

    let missing = share::share(&ShareOptions {
        dir,
        name: None,
        private: false,
        gh: root.path().join("no-such-gh"),
    })
    .unwrap();
    let Shared::NotConnected { step, .. } = missing else { panic!("installed?") };
    assert!(step.contains("brew install gh"), "{step}");
}

#[test]
fn remix_refuses_a_source_with_a_symbolic_link() {
    // A link named README.md would point the README edit at a file of the person's.
    let base = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let victim = home.path().join("victim.txt");
    std::fs::write(&victim, "mine\n").unwrap();
    let dir = base.path().join("github.com/acme/evil");
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    write(&dir, &[("cmux-app.json", &manifest("acme/evil", None)), ("main.js", MAIN_JS)]);
    std::os::unix::fs::symlink(&victim, dir.join("README.md")).unwrap();
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "-q", "-m", "one"]);
    let target = home.path().join("evil");
    let options = RemixOptions {
        source: "github.com/acme/evil@main".into(),
        dir: Some(target.clone()),
        name: None,
    };
    let error = remix::remix(&options, home.path(), Some(base.path())).unwrap_err();
    assert!(error.contains("README.md is a symbolic link"), "{error}");
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "mine\n");
    assert!(!target.exists());
}

#[test]
fn share_that_does_not_validate_leaves_the_folder_as_it_was() {
    let root = tempfile::tempdir().unwrap();
    let dir = extension_folder(root.path());
    // A manifest the validator refuses (no runtime main file).
    std::fs::remove_file(dir.join("main.js")).unwrap();
    let manifest_before = std::fs::read_to_string(dir.join("cmux-app.json")).unwrap();
    let readme_before = std::fs::read_to_string(dir.join("README.md")).unwrap();
    let (gh, log) = fake_gh(root.path(), Some("octo"), &[]);
    let error = share::share(&ShareOptions { dir: dir.clone(), name: None, private: false, gh })
        .unwrap_err();
    assert!(error.contains("nothing was published or changed"), "{error}");
    assert_eq!(std::fs::read_to_string(dir.join("cmux-app.json")).unwrap(), manifest_before);
    assert_eq!(std::fs::read_to_string(dir.join("README.md")).unwrap(), readme_before);
    assert!(!std::fs::read_to_string(&log).unwrap().contains("repo create"));
}
