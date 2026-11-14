use super::*;
use std::process::{Command, Stdio};

#[test]
fn a_build_or_test_command_may_run_elsewhere() {
    for ok in [
        "cargo test -p acpmux",
        "make -j8 && ./scripts/test.sh",
        "RUST_LOG=debug cargo build --release",
        "bun run test 2>&1 | tail -50",
        "rm -rf target && cargo build",
        "cd crates/core && cargo test",
        "pytest tests/unit",
        "env CI=1 time npm test",
    ] {
        assert_eq!(command_refusal(ok), None, "{ok}");
    }
}

#[test]
fn a_command_that_needs_this_machine_stays_here() {
    for (cmd, why) in [
        ("", "empty"),
        ("sudo make install", "sudo"),
        ("make && /usr/bin/vim notes", "vim"),
        ("cargo test | less", "less"),
        ("ssh box make", "ssh"),
        ("FOO=1 open build/app.html", "open"),
        ("curl http://localhost:3000/health", "this machine"),
        ("cat ~/.aws/credentials", "home folder"),
        ("cp $HOME/x .", "home folder"),
        ("cargo run -- /home/me/other/data.json", "path on this machine"),
        ("pytest /Users/me/src/app/tests", "path on this machine"),
        ("echo $(osascript -e 'x')", "osascript"),
    ] {
        let refusal = command_refusal(cmd).unwrap_or_default();
        assert!(refusal.contains(why), "{cmd:?}: {refusal:?}");
    }
    assert!(command_refusal(&"x".repeat(5000)).is_some());
}

#[test]
fn secret_looking_names_are_flagged_and_examples_are_not() {
    for path in [
        ".env",
        "app/.env.local",
        ".envrc",
        "deploy/.env-prod",
        "certs/server.pem",
        "deploy/id_ed25519",
        "config/credentials.json",
        ".npmrc",
        "secrets.yaml",
    ] {
        assert!(secret_name(path), "{path}");
    }
    for path in [".env.example", "src/env.rs", "docs/keys.md", "secrets.example.yaml", "Cargo.toml"]
    {
        assert!(!secret_name(path), "{path}");
    }
}

#[test]
fn a_private_key_in_added_lines_flags_its_file() {
    let patch = b"diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -0,0 +1 @@\n+fn a() {}\n\
        diff --git a/notes.txt b/notes.txt\n--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1 @@\n+-----BEGIN OPENSSH PRIVATE KEY-----\n\
        diff --git a/cfg.toml b/cfg.toml\n--- a/cfg.toml\n+++ b/cfg.toml\n@@ -1 +1 @@\n-old AKIAABCDEFGHIJKLMNOP\n+new = 1\n";
    assert_eq!(secret_content(patch), vec!["notes.txt".to_owned()]);
}

#[tokio::test]
async fn a_secret_in_a_file_git_quotes_the_name_of_is_still_flagged() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    // git quotes a name with a quote, a backslash or a tab in its diff header, and ends one with a
    // space in it with a tab.
    for name in [
        "config\"local.txt",
        "back\\slash.txt",
        "tab\there.txt",
        "caf\u{e9}.txt",
        "config local.txt",
    ] {
        write(&work.join(name), b"-----BEGIN RSA PRIVATE KEY-----\nabc\n");
        git_in(&work, &["add", "--", name]);
    }
    let plan = plan(&work).await.unwrap();
    for name in [
        "config\"local.txt",
        "back\\slash.txt",
        "tab\there.txt",
        "caf\u{e9}.txt",
        "config local.txt",
    ] {
        let file =
            plan.files.iter().find(|f| f.path == name).unwrap_or_else(|| panic!("{name} listed"));
        assert!(file.secret, "{name} is flagged");
    }
}

#[test]
fn the_task_command_quotes_every_part() {
    let c = task_command("ssh", "me@box", Path::new("/tmp/a b/run.sh"));
    assert_eq!(
        c,
        "'ssh' -T -o BatchMode=yes -o ConnectTimeout=20 -- 'me@box' 'bash -s' < '/tmp/a b/run.sh'; rc=$?; rm -f '/tmp/a b/run.sh'; exit $rc"
    );
    assert_eq!(shell_quote("it's"), r"'it'\''s'");
}

#[test]
fn a_login_in_the_origin_url_never_leaves_this_machine() {
    assert_eq!(
        without_login("https://me:ghp_secret@github.com/acme/app.git"),
        "https://github.com/acme/app.git"
    );
    assert_eq!(without_login("https://token@host:8443/a@b/c"), "https://host:8443/a@b/c");
    assert_eq!(without_login("https://github.com/acme/app"), "https://github.com/acme/app");
    assert_eq!(without_login("git@github.com:acme/app.git"), "git@github.com:acme/app.git");
    assert_eq!(without_login("ssh://git@host/acme/app"), "ssh://git@host/acme/app");
    assert_eq!(without_login("ssh://git:pw@host/acme/app"), "ssh://git@host/acme/app");
}

#[test]
fn two_origins_never_share_a_cache_folder() {
    let a = cache_slug("git@github.com:manaflow-ai/cmux.git");
    let b = cache_slug("https://github.com/manaflow-ai/cmux");
    assert!(a.starts_with("manaflow-ai-cmux-"), "{a}");
    assert!(b.starts_with("manaflow-ai-cmux-"), "{b}");
    assert_ne!(a, b);
}

// --- the diff sync and the stream: a real repository, a real upstream, the script run by bash ---

fn git_in(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "protocol.file.allow=always", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .expect("git runs");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn write(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// An upstream with two commits, and a clone with an unpushed commit, edits, a staged new file,
/// a deletion, a binary change, a new secret file and an untracked file.
fn dirty_clone(tmp: &Path) -> PathBuf {
    let upstream = tmp.join("upstream.git");
    std::fs::create_dir_all(&upstream).unwrap();
    git_in(&upstream, &["init", "-q", "--bare", "-b", "main"]);
    let seed = tmp.join("seed");
    git_in(tmp, &["clone", "-q", upstream.to_str().unwrap(), "seed"]);
    write(&seed.join("src/lib.rs"), b"pub fn a() -> u8 { 1 }\n");
    write(&seed.join("src/gone.rs"), b"// deleted later\n");
    write(&seed.join("assets/logo.bin"), &[0, 1, 2, 3, 255, 0, 7]);
    write(&seed.join("crates/core/Makefile"), b"all:\n\ttrue\n");
    git_in(&seed, &["add", "-A"]);
    git_in(&seed, &["commit", "-qm", "one"]);
    git_in(&seed, &["push", "-q", "origin", "main"]);
    let work = tmp.join("work");
    git_in(tmp, &["clone", "-q", upstream.to_str().unwrap(), "work"]);
    write(&work.join("src/lib.rs"), b"pub fn a() -> u8 { 2 }\n");
    git_in(&work, &["commit", "-qam", "unpushed"]);
    write(&work.join("src/lib.rs"), b"pub fn a() -> u8 { 3 } // edited, not committed\n");
    write(&work.join("src/new.rs"), b"pub fn n() {}\n");
    git_in(&work, &["add", "src/new.rs"]);
    git_in(&work, &["rm", "-q", "src/gone.rs"]);
    write(&work.join("assets/logo.bin"), &[9, 0, 8, 0, 7, 255]);
    write(&work.join(".env"), b"TOKEN=hunter2\n");
    git_in(&work, &["add", ".env"]);
    write(&work.join("scratch.txt"), b"untracked, stays here\n");
    work
}

fn run_script(script: &str, home: &Path) -> std::process::Output {
    let mut child = Command::new("bash")
        .arg("-s")
        .env("HOME", home)
        .env("XDG_CACHE_HOME", home.join("cache"))
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("bash runs");
    use std::io::Write as _;
    child.stdin.take().unwrap().write_all(script.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

/// Every file `ls-files` names that is in the working tree, with its bytes. A deletion the
/// other side applied without `--index` is still in its index but not on disk, so only the files
/// on disk are compared.
fn tracked_tree(dir: &Path) -> Vec<(String, Vec<u8>)> {
    let names = git_in(dir, &["ls-files", "-co", "--exclude-standard"]);
    let mut v: Vec<_> = names
        .lines()
        .filter_map(|n| Some((n.to_owned(), std::fs::read(dir.join(n)).ok()?)))
        .collect();
    v.sort();
    v
}

#[tokio::test]
async fn a_dirty_tree_arrives_the_same_without_its_untracked_or_secret_files() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("gitconfig"), "[protocol \"file\"]\n\tallow = always\n").unwrap();

    let plan = plan(&work.join("crates/core")).await.expect("plan");
    assert_eq!(plan.prefix, "crates/core/");
    let pushed = git_in(&work, &["rev-parse", "origin/main"]);
    assert_eq!(plan.base, pushed.trim(), "the base is the newest commit the upstream has");
    let mut files: Vec<_> =
        plan.files.iter().map(|f| (f.path.as_str(), f.status.as_str(), f.secret)).collect();
    files.sort();
    assert_eq!(
        files,
        vec![
            (".env", "A", true),
            ("assets/logo.bin", "M", false),
            ("src/gone.rs", "D", false),
            ("src/lib.rs", "M", false),
            ("src/new.rs", "A", false),
        ]
    );
    assert_eq!(plan.untracked, vec!["scratch.txt".to_owned()]);
    let digest = plan.digest();
    let again = super::plan(&work.join("crates/core")).await.unwrap();
    assert_eq!(again.digest(), digest, "the same tree, the same digest");
    assert_ne!(
        super::plan(&work).await.unwrap().digest(),
        digest,
        "another folder, another digest"
    );

    let left_out = plan.left_out(&[]);
    assert_eq!(left_out, vec![".env".to_owned()]);
    let patch = patch_without(&plan.patch, &left_out);
    let script =
        remote_script(&plan, &patch, &left_out, "pwd; cat ../../src/lib.rs", "run-1").unwrap();
    let out = run_script(&script, &home);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let remote = PathBuf::from(stdout.lines().next().unwrap()).join("../..");
    assert!(stdout.contains("{ 3 } // edited, not committed"), "{stdout}");
    assert!(stderr.contains("[cmux] running on"), "{stderr}");

    let mut here = tracked_tree(&work);
    here.retain(|(p, _)| p != ".env" && p != "scratch.txt");
    let there = tracked_tree(&remote.canonicalize().unwrap());
    assert_eq!(there, here, "every tracked file arrives with the same bytes");
    assert!(!remote.join("src/gone.rs").exists(), "a deletion arrives");
    assert!(!remote.join(".env").exists(), "the secret stays here");
    assert!(!remote.join("scratch.txt").exists(), "untracked files stay here");

    // A second run reuses the worktree and resets what the first left in it.
    write(&remote.join("src/leftover.rs"), b"from the last run\n");
    let out = run_script(
        &remote_script(&plan, &patch, &left_out, "ls ../../src", "run-2").unwrap(),
        &home,
    );
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(!String::from_utf8_lossy(&out.stdout).contains("leftover"));

    // A change after the plan changes the digest, so a stale start is refused.
    write(&work.join("src/lib.rs"), b"pub fn a() -> u8 { 4 }\n");
    assert_ne!(super::plan(&work.join("crates/core")).await.unwrap().digest(), digest);
}

#[tokio::test]
async fn a_secret_one_run_sent_is_gone_from_the_next_run_that_leaves_it_out() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    // The other machine ignores .env, as most repositories do, so `git clean` alone keeps it.
    write(&home.join("ignore"), b".env\n");
    let config = format!(
        "[protocol \"file\"]\n\tallow = always\n[core]\n\texcludesFile = {}\n",
        home.join("ignore").display()
    );
    std::fs::write(home.join("gitconfig"), config).unwrap();
    let plan = plan(&work).await.unwrap();

    // The person ticks .env: it goes with the run.
    let out =
        run_script(&remote_script(&plan, &plan.patch, &[], "cat .env", "run-5").unwrap(), &home);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stdout).contains("hunter2"));

    // The next run leaves it out, in the same worktree: it is not there to read.
    let left_out = plan.left_out(&[]);
    let patch = patch_without(&plan.patch, &left_out);
    let script =
        remote_script(&plan, &patch, &left_out, "cat .env 2>/dev/null || echo absent", "run-6")
            .unwrap();
    let out = run_script(&script, &home);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(stdout.trim(), "absent", "{stdout}");
}

#[tokio::test]
async fn clearing_the_last_run_never_follows_a_link_out_of_the_worktree() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    write(&home.join("ignore"), b"data\n");
    let config = format!(
        "[protocol \"file\"]\n\tallow = always\n[core]\n\texcludesFile = {}\n",
        home.join("ignore").display()
    );
    std::fs::write(home.join("gitconfig"), config).unwrap();
    // A file outside the worktree that a link could reach.
    let outside = tmp.path().join("outside");
    write(&outside.join("keep.txt"), b"not the run's\n");
    write(&work.join("data/keep.txt"), b"sent\n");
    git_in(&work, &["add", "-f", "data/keep.txt"]);
    let plan = plan(&work).await.unwrap();
    // The first run gets data/keep.txt and turns data/ into a link out of the worktree.
    let turn = format!("rm -rf data && ln -s {} data", shell_quote(outside.to_str().unwrap()));
    let out = run_script(&remote_script(&plan, &plan.patch, &[], &turn, "run-7").unwrap(), &home);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    // The next run (with no changes: git would refuse a patch through the link) clears what the
    // first one brought, without following the link.
    let out = run_script(&remote_script(&plan, b"", &[], "true", "run-8").unwrap(), &home);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(outside.join("keep.txt").exists(), "the file the link reached is still there");
}

#[test]
fn a_diff_splits_into_its_files_and_a_left_out_one_is_cut_whole() {
    let patch = b"diff --git a/my file.txt b/my file.txt\nnew file mode 100644\n--- /dev/null\n+++ b/my file.txt\t\n@@ -0,0 +1 @@\n+hi\n\
        diff --git \"a/q\\\"x\" \"b/q\\\"x\"\ndeleted file mode 100644\n--- \"a/q\\\"x\"\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n\
        diff --git a/src/a.rs b/src/a.rs\n--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1 +1 @@\n-a\n+b\n";
    let found: Vec<_> = sections(patch).into_iter().map(|s| (s.path, s.status)).collect();
    assert_eq!(
        found,
        vec![
            ("my file.txt".to_owned(), "A"),
            ("q\"x".to_owned(), "D"),
            ("src/a.rs".to_owned(), "M")
        ]
    );
    let cut = patch_without(patch, &["my file.txt".to_owned()]);
    let rest: Vec<_> = sections(&cut).into_iter().map(|s| s.path).collect();
    assert_eq!(rest, vec!["q\"x".to_owned(), "src/a.rs".to_owned()]);
    assert!(!String::from_utf8_lossy(&cut).contains("+hi"));
}

#[tokio::test]
async fn a_file_one_run_added_stays_once_the_base_has_it() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("gitconfig"), "[protocol \"file\"]\n\tallow = always\n").unwrap();
    let plan1 = plan(&work).await.unwrap();
    let left_out = plan1.left_out(&[]);
    let patch = patch_without(&plan1.patch, &left_out);
    let out =
        run_script(&remote_script(&plan1, &patch, &left_out, "true", "run-9").unwrap(), &home);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    // The added src/new.rs is committed and pushed: the next run's base has it.
    git_in(&work, &["rm", "-q", "--cached", ".env"]);
    git_in(&work, &["commit", "-qam", "push new.rs"]);
    git_in(&work, &["push", "-q", "origin", "HEAD:main"]);
    let plan2 = plan(&work).await.unwrap();
    assert_ne!(plan2.base, plan1.base);
    let out = run_script(
        &remote_script(&plan2, &plan2.patch, &[], "cat src/new.rs", "run-10").unwrap(),
        &home,
    );
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "pub fn n() {}\n");
}

// A bash stand-in for ssh, made executable with a Unix mode.
#[cfg(unix)]
#[tokio::test]
async fn the_task_streams_the_remote_output_in_order_and_keeps_its_exit_code() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("gitconfig"), "[protocol \"file\"]\n\tallow = always\n").unwrap();
    // A stand-in for ssh: it checks its arguments and runs the remote shell here.
    let fake = tmp.path().join("fake-ssh");
    write(
        &fake,
        b"#!/bin/bash\n[ \"$1 $2 $3 $4 $5 $6 $7\" = '-T -o BatchMode=yes -o ConnectTimeout=20 -- me@box' ] || exit 99\nexec bash -s\n",
    );
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();

    let plan = plan(&work).await.unwrap();
    let left_out = plan.left_out(&[]);
    let patch = patch_without(&plan.patch, &left_out);
    let command = "for i in 1 2 3; do echo line $i; sleep 0.05; done; echo oops >&2; exit 7";
    let script_path = tmp.path().join("run.sh");
    std::fs::write(
        &script_path,
        remote_script(&plan, &patch, &left_out, command, "run-3").unwrap(),
    )
    .unwrap();
    let task = task_command(fake.to_str().unwrap(), "me@box", &script_path);
    let out = Command::new("bash")
        .arg("-c")
        .arg(&task)
        .env("HOME", &home)
        .env("XDG_CACHE_HOME", home.join("cache"))
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(7), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "line 1\nline 2\nline 3\n");
    assert!(String::from_utf8_lossy(&out.stderr).ends_with("oops\n"));
    assert!(!script_path.exists(), "the script is removed after the run");
}

// A bash stand-in for ssh, made executable with a Unix mode.
#[cfg(unix)]
#[tokio::test]
async fn a_dropped_connection_ends_the_command_on_the_other_machine() {
    let tmp = tempfile::tempdir().unwrap();
    let work = dirty_clone(tmp.path());
    let home = tmp.path().join("peer-home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("gitconfig"), "[protocol \"file\"]\n\tallow = always\n").unwrap();
    // A stand-in for ssh that keeps the remote shell as its child, as sshd does: killing it drops
    // the connection, and the remote shell is left without its parent.
    let fake = tmp.path().join("fake-ssh");
    write(&fake, b"#!/bin/bash\nbash -s\n");
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let marks = tmp.path().join("marks");
    std::fs::create_dir_all(&marks).unwrap();
    let started = marks.join("started");
    let late = marks.join("late");
    let command = format!(
        "touch {}; sleep 6; touch {}",
        shell_quote(started.to_str().unwrap()),
        shell_quote(late.to_str().unwrap())
    );
    let plan = plan(&work).await.unwrap();
    let left_out = plan.left_out(&[]);
    let patch = patch_without(&plan.patch, &left_out);
    let script = remote_script(&plan, &patch, &left_out, &command, "run-4").unwrap();
    let mut ssh = Command::new(&fake)
        .env("HOME", &home)
        .env("XDG_CACHE_HOME", home.join("cache"))
        .env("GIT_CONFIG_GLOBAL", home.join("gitconfig"))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    {
        use std::io::Write as _;
        let mut stdin = ssh.stdin.take().unwrap();
        stdin.write_all(script.as_bytes()).unwrap();
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !started.exists() {
        assert!(std::time::Instant::now() < deadline, "the command never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ssh.kill().unwrap();
    ssh.wait().unwrap();
    // The watcher looks every 2 s; the command would finish 6 s after it started.
    tokio::time::sleep(Duration::from_secs(9)).await;
    assert!(!late.exists(), "the command ran on after the connection dropped");
}
