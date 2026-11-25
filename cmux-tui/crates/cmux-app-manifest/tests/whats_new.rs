//! The What's New generator on a fixture git repository: squash-merge
//! subjects ending `(#N)` become items, only those since the bump to the
//! previous version, and the version rows name each bump's commit and date.

use std::path::PathBuf;
use std::process::Command;

use cmux_app_manifest::whats_new::{self, WHATS_NEW_FILE, WhatsNew};
use serde_json::{Value, json};

struct Repo(PathBuf);

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl Repo {
    fn new(name: &str) -> Self {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-whats-new-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp repo");
        let repo = Self(dir);
        repo.git(&["init", "-q", "-b", "main"], 0);
        repo
    }

    /// Runs git with no global or system config (no hooks, no signing), the
    /// commit dated `seconds` after the epoch.
    fn git(&self, args: &[&str], seconds: i64) -> String {
        let date = format!("@{seconds} +0000");
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.0)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_DATE", &date)
            .output()
            .expect("git");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    /// Writes `files` (path, contents) and commits them as `subject`;
    /// answers the commit.
    fn commit(&self, subject: &str, seconds: i64, files: &[(&str, String)]) -> String {
        for (path, text) in files {
            let path = self.0.join(path);
            std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
            std::fs::write(path, text).expect("write");
        }
        self.git(&["add", "-A"], seconds);
        self.git(&["commit", "-q", "-m", subject], seconds);
        self.git(&["rev-parse", "HEAD"], seconds)
    }
}

fn manifest(version: &str) -> String {
    json!({ "manifestVersion": 2, "id": "cmux/demo", "version": version }).to_string()
}

fn titles(file: &WhatsNew) -> Vec<(String, u64)> {
    file.items.iter().map(|item| (item.title.clone(), item.pr)).collect()
}

const APP: &str = "first-party-apps/demo";

fn path(file: &str) -> String {
    format!("{APP}/{file}")
}

#[test]
fn items_are_the_prs_since_the_bump_to_the_previous_version() {
    let repo = Repo::new("bumps");
    let v1 = repo.commit(
        "Demo: the first version (#1)",
        100,
        &[(&path("cmux-app.v2.json"), manifest("1.0.0"))],
    );
    repo.commit("Demo: a fix in 1.0 (#2)", 200, &[(&path("src/a.js"), "a".into())]);
    // Another app's change is not this app's news.
    repo.commit("Other: its own change (#3)", 300, &[("first-party-apps/other/x.js", "x".into())]);
    let v2 = repo.commit(
        "Demo: version 1.1 (#4)",
        400,
        &[(&path("cmux-app.v2.json"), manifest("1.1.0"))],
    );
    repo.commit("App Store: a faster list (#5)", 500, &[(&path("src/a.js"), "b".into())]);
    repo.commit("chore: tidy (#6)", 600, &[(&path("src/a.js"), "c".into())]);
    repo.commit("Demo: no PR number", 700, &[(&path("src/a.js"), "d".into())]);

    // The previous version is 1.0.0: the PRs after its bump, newest first.
    let file = whats_new::generate(&repo.0, APP).expect("generate");
    assert_eq!(file.version, "1.1.0");
    assert_eq!(
        titles(&file),
        [
            ("A faster list".to_string(), 5),
            ("Version 1.1".to_string(), 4),
            ("A fix in 1.0".to_string(), 2),
        ],
        "{file:?}"
    );
    let versions: Vec<Value> = file.versions.iter().map(|row| row.to_json()).collect();
    assert_eq!(
        versions,
        [
            json!({ "version": "1.1.0", "commit": v2, "date_ms": 400_000 }),
            json!({ "version": "1.0.0", "commit": v1, "date_ms": 100_000 }),
        ]
    );

    // Written into the package; the commit that only rewrites the file is
    // not news, and a second run changes nothing.
    let (written, changed) = whats_new::write(&repo.0, APP).expect("write");
    assert!(changed);
    assert_eq!(written, repo.0.join(APP).join(WHATS_NEW_FILE));
    let text = std::fs::read_to_string(&written).expect("read");
    repo.commit("Demo: regenerate What's New (#7)", 800, &[]);
    let again = whats_new::generate(&repo.0, APP).expect("generate");
    assert_eq!(again, file);
    assert_eq!(whats_new::write(&repo.0, APP).expect("write"), (written, false));
    let parsed: Value = serde_json::from_str(&text).expect("json");
    assert_eq!(WhatsNew::from_json(&parsed), Some(file));
}

#[test]
fn one_version_lists_the_whole_history_and_an_unpushed_bump_comes_first() {
    let repo = Repo::new("single");
    repo.commit(
        "Demo: the first version (#10)",
        100,
        &[(&path("cmux-app.json"), manifest("0.1.0"))],
    );
    // The v2 manifest takes over the version; the older v1 history still counts.
    repo.commit("Demo: manifest v2 (#11)", 200, &[(&path("cmux-app.v2.json"), manifest("0.1.0"))]);
    let file = whats_new::generate(&repo.0, APP).expect("generate");
    assert_eq!(
        titles(&file),
        [("Manifest v2".to_string(), 11), ("The first version".to_string(), 10)]
    );
    assert_eq!(file.versions.len(), 1, "{file:?}");
    assert_eq!(
        file.versions[0].commit.as_deref(),
        Some(repo.git(&["rev-list", "--max-parents=0", "HEAD"], 0).as_str())
    );

    // A bump in the working tree: its row has no commit yet, and the items
    // are the PRs since the bump to 0.1.0.
    std::fs::write(repo.0.join(path("cmux-app.v2.json")), manifest("0.2.0")).expect("bump");
    let file = whats_new::generate(&repo.0, APP).expect("generate");
    assert_eq!(file.version, "0.2.0");
    assert_eq!(file.versions[0].to_json(), json!({ "version": "0.2.0" }));
    assert_eq!(titles(&file), [("Manifest v2".to_string(), 11)]);
}

#[test]
fn an_app_with_no_manifest_is_an_error() {
    let repo = Repo::new("none");
    repo.commit("Something (#1)", 100, &[("README.md", "r".into())]);
    let error = whats_new::generate(&repo.0, APP).expect_err("no manifest");
    assert!(error.contains("no manifest"), "{error}");
}
