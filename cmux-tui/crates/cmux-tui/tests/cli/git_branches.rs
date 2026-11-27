//! `cmux git branches` through a real daemon: the session host lists a real
//! repository's local and remote-tracking branches, marks the branch HEAD is
//! on, reports each local branch's upstream and how far it is ahead, and
//! suggests the bases a branch diff may compare with.
#![cfg(unix)]

use super::*;

fn git(dir: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_cli(server: &HeadlessServer, cwd: &std::path::Path, args: &[&str]) -> Output {
    Command::new(bin())
        .current_dir(cwd)
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .arg("git")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

fn branch<'a>(listing: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    listing["branches"]
        .as_array()
        .unwrap()
        .iter()
        .find(|branch| branch["name"] == name)
        .unwrap_or_else(|| panic!("no branch {name} in {listing}"))
}

#[test]
fn git_branches_lists_the_repository_branches_through_a_real_daemon() {
    let server = HeadlessServer::start("git-branches");
    let root = std::env::temp_dir().join(format!(
        "cmux-git-branches-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let repo = root.join("repo");
    let remote = root.join("remote.git");
    fs::create_dir_all(&repo).unwrap();
    git(&root, &["init", "-q", "--bare", remote.to_str().unwrap()]);
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    git(&repo, &["remote", "add", "origin", remote.to_str().unwrap()]);
    git(&repo, &["push", "-q", "--set-upstream", "origin", "main"]);
    // `feature` tracks origin/feature and is one commit ahead of it.
    git(&repo, &["checkout", "-q", "-b", "feature"]);
    git(&repo, &["push", "-q", "--set-upstream", "origin", "feature"]);
    fs::write(repo.join("a.txt"), "two\n").unwrap();
    git(&repo, &["commit", "-q", "-am", "second"]);
    let feature_head = git(&repo, &["rev-parse", "HEAD"]);
    let main_head = git(&repo, &["rev-parse", "main"]);

    let listed = git_cli(&server, &repo, &["branches"]);
    assert_success(&listed);
    let listing = json_output(&listed);
    assert_eq!(
        fs::canonicalize(listing["root"].as_str().unwrap()).unwrap(),
        fs::canonicalize(&repo).unwrap(),
        "{listing}"
    );
    assert_eq!(listing["current"], "feature", "{listing}");
    assert_eq!(listing["detached"], false, "{listing}");
    assert_eq!(listing["truncated"], false, "{listing}");

    // Local branches come first, then remote-tracking ones.
    let names: Vec<&str> = listing["branches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|branch| branch["name"].as_str().unwrap())
        .collect();
    assert_eq!(names.len(), 4, "{listing}");
    let mut locals = names[..2].to_vec();
    locals.sort_unstable();
    assert_eq!(locals, ["feature", "main"], "{listing}");
    let mut remotes = names[2..].to_vec();
    remotes.sort_unstable();
    assert_eq!(remotes, ["origin/feature", "origin/main"], "{listing}");

    // HEAD's branch, with its upstream and how far it is ahead.
    let feature = branch(&listing, "feature");
    assert_eq!(feature["current"], true, "{listing}");
    assert_eq!(feature["kind"], "local", "{listing}");
    assert_eq!(feature["ref"], "refs/heads/feature", "{listing}");
    assert_eq!(feature["commit"], feature_head.as_str(), "{listing}");
    assert_eq!(feature["upstream"], "origin/feature", "{listing}");
    assert_eq!(feature["ahead"], 1, "{listing}");
    assert_eq!(feature["behind"], 0, "{listing}");

    let main = branch(&listing, "main");
    assert_eq!(main["current"], false, "{listing}");
    assert_eq!(main["commit"], main_head.as_str(), "{listing}");
    assert_eq!(main["upstream"], "origin/main", "{listing}");
    assert_eq!(main["ahead"], 0, "{listing}");

    let origin_main = branch(&listing, "origin/main");
    assert_eq!(origin_main["kind"], "remote", "{listing}");
    assert_eq!(origin_main["ref"], "refs/remotes/origin/main", "{listing}");
    assert_eq!(origin_main["current"], false, "{listing}");
    assert!(origin_main.get("upstream").is_none(), "{listing}");

    // The branch scope's base comes first, then HEAD's upstream.
    let bases = listing["suggested_bases"].as_array().unwrap();
    assert_eq!(bases.len(), 2, "{listing}");
    assert_eq!(bases[0]["name"], "origin/main", "{listing}");
    assert_eq!(bases[0]["reason"], "default_branch", "{listing}");
    assert_eq!(bases[1]["name"], "origin/feature", "{listing}");
    assert_eq!(bases[1]["reason"], "upstream", "{listing}");

    // --limit cuts the listing and marks it truncated.
    let limited = git_cli(&server, &repo, &["branches", "--limit", "1"]);
    assert_success(&limited);
    let limited = json_output(&limited);
    assert_eq!(limited["branches"].as_array().unwrap().len(), 1, "{limited}");
    assert_eq!(limited["truncated"], true, "{limited}");

    // An upstream whose ref is gone is marked, and nothing is counted.
    git(&repo, &["push", "-q", "origin", "--delete", "feature"]);
    let gone = git_cli(&server, &repo, &["branches"]);
    assert_success(&gone);
    let gone = json_output(&gone);
    let feature = branch(&gone, "feature");
    assert_eq!(feature["upstream"], "origin/feature", "{gone}");
    assert_eq!(feature["upstream_gone"], true, "{gone}");
    assert!(feature.get("ahead").is_none(), "{gone}");
    assert_eq!(branch(&gone, "main")["ahead"], 0, "{gone}");

    // A detached HEAD has no current branch.
    git(&repo, &["checkout", "-q", "--detach", "main"]);
    let detached = git_cli(&server, &repo, &["branches"]);
    assert_success(&detached);
    let detached = json_output(&detached);
    assert_eq!(detached["detached"], true, "{detached}");
    assert!(detached.get("current").is_none(), "{detached}");
    assert_eq!(branch(&detached, "feature")["current"], false, "{detached}");
    let _ = fs::remove_dir_all(root);
}
