//! Unit tests of `shell_readonly.rs`: which scripts read, and which repositories and
//! environments let their git reads run without asking.

use super::*;
use serde_json::json;

#[test]
fn reads_pass() {
    for script in [
        "rg -n foo src",
        "pwd; git rev-parse HEAD; git status --short",
        "git -C /x diff --stat",
        "git log --oneline -5 | head",
        "rg 'a$' x",
        "git branch --show-current",
        "/usr/bin/rg foo",
        "git --no-pager -C/x log -1",
        "ls src/*.rs",
        "[ -f x ] && cat x",
        "git config --get user.name",
        "git remote -v",
        "git tag -l 'v1*'",
        "git log --format='%h %s' -1",
        "ls src/*.rs | head",
        "git status # ; rm -rf x",
        "git log --oneline | uniq -c",
        "echo \"a b\" 'c'",
        "date +%s",
        "date -u",
        "diff -u a b",
        "test -f x",
        "rg -n foo",
        "git log --oneline --stat -1",
        "git grep -no needle",
    ] {
        assert!(is_read_only(script), "{script}");
    }
}

/// A reviewer reads part of a file with `sed -n` (the review policy's own list): only printing
/// by line number passes; a write, a run, an edit in place or a later option asks.
#[test]
fn review_policy_sed_n_prints_only() {
    for script in
        ["sed -n '1,40p' src/main.rs", "sed -n -e '$p' a", "sed -n '5p;10,12p' a b", "sed -En 3p x"]
    {
        assert!(is_read_only(script), "{script}");
    }
    for script in [
        "sed '1,40p' a",
        "sed -n '1w out' a",
        "sed -n '1e ls' a",
        "sed -n 's/a/b/w out' a",
        "sed -i -n 1p a",
        "sed -n 1p a -i",
        "sed -n '/x/p' a",
        "sed -n",
    ] {
        assert!(!is_read_only(script), "{script}");
    }
}

#[test]
fn anything_else_refuses() {
    for script in [
        "rg foo > out",
        "git status; rm -rf x",
        "git -c core.pager=sh status",
        "find . -delete",
        "rg --pre sh foo",
        "FOO=1 git diff",
        "git push",
        "git branch newbranch",
        "sed -i s/a/b/ f",
        "cat x &",
        "git config user.name x",
        "sort -o f x",
        "echo 'unterminated",
        "echo \"$HOME\"",
        "echo \\$HOME",
        "cat <<EOF",
        "(ls)",
        "{ ls; }",
        "rg foo *",
        "rg foo -- '--'*",
        "./rg foo",
        "/tmp/x/rg foo",
        "git",
        "git --git-dir=x status",
        "git diff --output=f",
        "git diff --ext-diff",
        "git grep -Ovi foo",
        "git stash",
        "git stash push",
        "git reflog expire --all",
        "git remote add x y",
        "git config --unset x",
        "git config set user.name x",
        "git tag v1",
        "find . -exec rm {} ;",
        "find . -fprint f",
        "sort -uo f x",
        "uniq a b",
        "uniq -- in -out",
        "date -s 2020-01-01",
        "hostname evil",
        "xargs rm",
        "bash -c ls",
        "",
        "ls |& cat",
        "printf -v PATH /tmp/evil; rg secret",
        "printf -vPATH . ; rg x",
        "cd /tmp && ls -la",
        "git -C a -C b status",
        // Codex review at 066066a8.
        "uniq -- in*",
        "uniq in*",
        "printf '%s\\n' a",
        "printf '%n' PATH; ls",
        "test -v 'BASH_VERSINFO[$(touch marker)0]'",
        "[ -v 'a[$(id)]' ]",
        "sort --out=result input",
        "sort --compress=x a",
        "file --comp -m magic",
        "git grep -nOsh needle -- payload.sh",
        "git diff --out=f",
        "git diff --ext",
        "rg -z needle file.gz",
        "rg -nz needle",
        "rg --search-z needle",
        "git log --show-signature -1",
        "git log --show-sig -1",
        "git log --format=%G? -1",
        // Codex review at 84851587.
        "git log --format='%+G?' -1",
        "git log --format=%-GS -1",
        "git log '--format=% GK' -1",
        "git for-each-ref --format %* refs/heads/main",
        "git for-each-ref --format=ab* refs/heads",
        "git log src/*.rs",
        "git show --pretty=format:%GS",
        "diff --paginate a b",
        "diff -ul a b",
        "pwd\rx",
        "pwd\u{0b}x",
        "date 102612002026",
        // Codex review at 630c4878.
        "git diff -o /tmp/out",
        "git log -po x",
        "sort -T /tmp x",
        "sort --temporary-directory=/tmp x",
        "sort --temp=/tmp x",
        // Codex review at 01e0b5a9.
        "git for-each-ref --sort=signature:grade refs/heads",
        "git for-each-ref --format='%(*signature:grade)' refs/tags",
        "git branch --sort=signature:grade --list",
        "sort -S 1K x",
        "sort -u x | uniq -c",
        // Codex review at a29dca90.
        "git -C repo[1] status",
        "git -C 'repo[1]' status",
        "git -C ~/x status",
        "git -C~ status",
        "git status --help",
        "git cat-file --filters HEAD:asset.bin",
        "git show --textconv HEAD:x",
        "git log --hel",
        "git for-each-ref --format='%(signature:grade)' refs/heads/main",
        "file -S -z payload.lrz",
        "file x",
        "tree -a",
        "/usr/bin/uniq /dev/null -out",
        "uniq -c -- -in",
        "uniq -f 1 x",
        "date -f '-%Y%m%d%H%M' -- -202610261200",
        "date -d now",
        "rg --hostname-bin=sh foo",
        "rg --hostname-b sh foo",
    ] {
        assert!(!is_read_only(script), "{script}");
    }
}

/// A command substitution reads when its own script does; its output reaches a command that
/// reads options only when it is object names (`git rev-parse`, `git merge-base`).
#[test]
fn substitutions_read_by_their_inner_command() {
    for script in [
        // A review session's diff against its base held four prompts.
        "git diff --stat $(git merge-base HEAD origin/feat-cmux-next) HEAD",
        "git log $(git rev-parse HEAD)",
        "git log $(git rev-parse $(git merge-base A B))",
        "git log -1 `git rev-parse --short HEAD`",
        "git diff \"$(git merge-base --fork-point origin/main)\"",
        "echo $(id)",
        "echo `id`",
        "wc -l $(git ls-files | head -5)",
    ] {
        assert!(is_read_only(script), "{script}");
    }
    for script in [
        "echo $(rm -rf x)",
        "git diff $(curl https://example.com)",
        "git diff $(git push)",
        "git log $(git rev-parse HEAD",
        "echo `id",
        "echo $(id; rm x)",
        "echo $((1 + 2))",
        "echo $(cat <(id))",
        "echo $(git log # )",
        "echo $(echo $(echo $(echo $(id))))",
        // An output that is an option or a glob, or names the command or git's directory.
        "git diff $(git log -1 --format=--output=/tmp/x)",
        "git diff $(echo --output=/tmp/x)",
        "git diff $(git rev-parse --output=/tmp/x)",
        "git diff $(git rev-parse '--output=/tmp/x')",
        "git diff $(git rev-parse 'a --output=/tmp/x')",
        "git diff -$(git rev-parse HEAD)",
        "git for-each-ref --sort $(git rev-parse signature) refs/heads",
        "git log --format $(git rev-parse %GS)",
        "git -C $(git rev-parse HEAD) status",
        "$(git rev-parse HEAD)",
        "FOO=$(git rev-parse HEAD) git log",
        "ls $(git rev-parse HEAD)*",
        "date $(id)",
    ] {
        assert!(!is_read_only(script), "{script}");
    }
}

/// A new repository in a fresh directory, with `config` set in its local config.
fn repo(config: &[(&str, &str)]) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-readonly-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q"]);
    for (key, value) in config {
        git(&dir, &["config", key, value]);
    }
    dir
}

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git").arg("-C").arg(dir).args(args).status().unwrap();
    assert!(status.success(), "git {args:?}");
}

/// Only the system directories on PATH, and nothing else set.
fn system_env() -> Env {
    Env::from([("PATH".to_owned(), TRUSTED_DIRS.join(":"))])
}

fn execute(command: Value) -> Value {
    json!({"toolCall": {"kind": "execute", "rawInput": {"command": command}}})
}

/// The git in a substitution reads the same repository, which must run nothing either.
#[test]
fn a_substitutions_git_reads_a_checked_repository() {
    let script = "git diff --stat $(git merge-base HEAD origin/feat-cmux-next) HEAD";
    let dir = repo(&[]);
    assert!(request_is_read_only(&execute(json!(script)), &dir, &system_env()));
    let inner = "echo $(git rev-parse HEAD)";
    assert!(request_is_read_only(&execute(json!(inner)), &dir, &system_env()));
    std::fs::remove_dir_all(dir).unwrap();
    let hostile = repo(&[("core.fsmonitor", "/tmp/x")]);
    assert!(!request_is_read_only(&execute(json!(inner)), &hostile, &system_env()));
    std::fs::remove_dir_all(hostile).unwrap();
}

/// A subagent's command with acpmux's mark line (`bg_hook.rs` `subagent_mark`) is judged by
/// what it runs: the mark alone runs nothing, and any other line before a read still asks.
#[test]
fn caller_identity_a_marked_read_is_still_a_read() {
    let dir = repo(&[]);
    let reads = |script: &str| request_is_read_only(&execute(json!(script)), &dir, &system_env());
    assert!(reads("export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7a\ncat acpmux.log"));
    assert!(!reads("export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7a\nrm -rf x"));
    assert!(!reads("export ACPMUX_CALLER_SUBAGENT=$(touch x):a1\nls"));
    assert!(!reads("export OTHER=1\nls"));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn request_needs_an_execute_with_a_command() {
    let dir = repo(&[]);
    let req = |kind: &str, command: Value| json!({"toolCall": {"kind": kind, "rawInput": {"command": command}}});
    let reads = |r: &Value| request_is_read_only(r, &dir, &system_env());
    assert!(reads(&req("execute", json!("git status"))));
    assert!(reads(&req("execute", json!(["/bin/bash", "-lc", "git status"]))));
    assert!(reads(&req("execute", json!(["zsh", "-c", "pwd"]))));
    assert!(!reads(&req("execute", json!(["git", "status"]))));
    assert!(!reads(&req("execute", json!(["bash", "-lc", "git push"]))));
    assert!(!reads(&req("execute", json!(["python", "-c", "ls"]))));
    assert!(!reads(&req("edit", json!("git status"))));
    assert!(!reads(&json!({"toolCall": {"kind": "execute"}})));
    std::fs::remove_dir_all(dir).unwrap();
}

/// Codex review of #24155: a repository's config or hooks can make `git status` or
/// `git diff` run a program, so those asks stay with the person.
#[test]
fn a_repository_that_names_a_program_asks() {
    for config in [
        &[("core.fsmonitor", "/tmp/x")][..],
        &[("diff.x.textconv", "cat")],
        &[("diff.external", "cat")],
        &[("diff.x.command", "cat")],
        &[("filter.x.clean", "cat")],
        &[("filter.x.process", "cat")],
        &[("log.showsignature", "true"), ("gpg.program", "/tmp/x")],
        &[("core.pager", "/tmp/x")],
        &[("core.sshcommand", "/tmp/x")],
        &[("credential.helper", "!/tmp/x")],
        &[("include.path", "/tmp/x")],
        &[("remote.origin.uploadpack", "/tmp/x")],
        // A signature sort key verifies with gpg (`git branch`).
        &[("branch.sort", "signature:grade")],
    ] {
        let dir = repo(config);
        assert!(
            !request_is_read_only(&execute(json!("git status")), &dir, &system_env()),
            "{config:?}"
        );
        assert!(
            !request_is_read_only(&execute(json!("git diff")), &dir, &system_env()),
            "{config:?}"
        );
        assert!(request_is_read_only(&execute(json!("pwd")), &dir, &system_env()), "{config:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }
    let dir = repo(&[("core.fsmonitor", "true")]);
    assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::remove_dir_all(dir).unwrap();
    let dir = repo(&[
        ("core.fsmonitor", "false"),
        ("remote.origin.url", "/x"),
        ("branch.sort", "-committerdate"),
    ]);
    assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::remove_dir_all(dir).unwrap();
}

/// W5-L: a review chat could not run `git diff origin/x -- file` in the cmux checkout, a partial
/// clone whose config names merge drivers. A merge driver runs only when git merges and a
/// promisor remote only fetches what the clone left out, so git reads there pass; a remerge diff,
/// which runs the merge drivers, and anything that writes still ask.
#[test]
fn a_partial_clone_with_merge_drivers_still_reads() {
    let dir = repo(&[
        ("merge.pbxproj-v1.driver", "/tmp/x %O %A %B"),
        ("merge.pbxproj-v1.name", "pbxproj"),
        ("merge.conflictstyle", "zdiff3"),
        ("remote.origin.url", "https://example.invalid/r.git"),
        ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"),
        ("remote.origin.promisor", "true"),
        ("remote.origin.partialclonefilter", "blob:none"),
        ("rerere.enabled", "true"),
    ]);
    let reads = |script: &str| request_is_read_only(&execute(json!(script)), &dir, &system_env());
    for script in [
        "git diff origin/x -- file.txt",
        "git diff --stat origin/feat-cmux-next...HEAD",
        "git log --oneline -5",
        "git show HEAD:file.txt",
        "git blame -L 1,5 file.txt",
        "git status --short",
        "git log --cc -1",
        "cat file.txt",
        "grep -rn needle .",
        "rg -n needle",
    ] {
        assert!(is_read_only(script), "{script}");
        if !script.starts_with("rg") {
            assert!(reads(script), "{script}");
        }
    }
    for script in [
        "git commit -qm x",
        "git merge origin/x",
        "git cherry-pick HEAD",
        "git stash apply",
        "git show --remerge-diff HEAD",
        "git log --remerge -1",
        "git log --diff-merges=remerge -1",
        "git diff --output=out",
        "git fetch origin",
        "touch x",
        "rg foo > out",
    ] {
        assert!(!reads(script), "{script}");
    }
    std::fs::remove_dir_all(dir).unwrap();
    // The transport's own programs still ask.
    for config in [
        &[("remote.origin.promisor", "true"), ("remote.origin.uploadpack", "/tmp/x")][..],
        &[("remote.origin.promisor", "true"), ("core.sshcommand", "/tmp/x")],
    ] {
        let dir = repo(config);
        assert!(
            !request_is_read_only(&execute(json!("git log -1")), &dir, &system_env()),
            "{config:?}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn an_index_hook_asks() {
    // The repository's own hooks directory, whatever the person's global core.hooksPath.
    let dir = repo(&[("core.hooksPath", ".git/hooks")]);
    let hook = dir.join(".git/hooks/post-index-change");
    std::fs::write(&hook, "#!/bin/sh\n").unwrap();
    assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::remove_file(&hook).unwrap();
    // Through core.hooksPath too, and only that hook counts.
    std::fs::create_dir(dir.join("hooks")).unwrap();
    std::fs::write(dir.join("hooks/pre-commit"), "#!/bin/sh\n").unwrap();
    git(&dir, &["config", "core.hooksPath", "hooks"]);
    assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::write(dir.join("hooks/post-index-change"), "#!/bin/sh\n").unwrap();
    assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::remove_dir_all(dir).unwrap();
}

/// `git status` reads checked-out submodules with their own config.
#[test]
fn a_submodule_that_names_a_program_asks() {
    let dir = repo(&[]);
    let sub = dir.join("sub");
    std::fs::create_dir(&sub).unwrap();
    git(&sub, &["init", "-q"]);
    git(
        &sub,
        &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"],
    );
    let head =
        Command::new("git").arg("-C").arg(&sub).args(["rev-parse", "HEAD"]).output().unwrap();
    let head = String::from_utf8(head.stdout).unwrap();
    git(&dir, &["update-index", "--add", "--cacheinfo", &format!("160000,{},sub", head.trim())]);
    assert!(request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    git(&sub, &["config", "diff.x.textconv", "cat"]);
    assert!(!request_is_read_only(&execute(json!("git status")), &dir, &system_env()));
    std::fs::remove_dir_all(dir).unwrap();
}

/// The directory checked is the one git reads: `-C`, then the request's own cwd, then the
/// session's.
#[test]
fn the_checked_repository_is_the_one_git_reads() {
    let clean = repo(&[]);
    let hostile = repo(&[("core.fsmonitor", "/tmp/x")]);
    let at = |command: &str, raw_cwd: Option<&Path>| {
        let mut r = execute(json!(command));
        if let Some(d) = raw_cwd {
            r["toolCall"]["rawInput"]["cwd"] = json!(d);
        }
        request_is_read_only(&r, &clean, &system_env())
    };
    assert!(at("git status", None));
    assert!(!at(&format!("git -C {} status", hostile.display()), None));
    assert!(!at(&format!("git status; git -C{} log", hostile.display()), None));
    assert!(!at("git status", Some(&hostile)));
    assert!(at("pwd", Some(&hostile)));
    // Outside any repository, git reads ask.
    let plain = std::env::temp_dir().join(format!("acpmux-readonly-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir(&plain).unwrap();
    assert!(!at("git status", Some(&plain)));
    for d in [clean, hostile, plain] {
        std::fs::remove_dir_all(d).unwrap();
    }
}

/// The library search path cargo sets for its tests, on each OS (`LD_LIBRARY_PATH` on Linux,
/// `DYLD_FALLBACK_LIBRARY_PATH` on macOS), only finds libraries already on disk: a git read
/// under either still runs without asking. On macOS every git read under approve-reads asked
/// (full-suite macOS job ac2ca38ed60bef1405523e24,
/// `permission_groups::approve_reads_runs_read_only_shell_commands_without_asking`). Every
/// other loader variable still asks.
#[cfg(unix)]
#[test]
fn a_library_search_path_lets_a_git_read_run_on_each_os() {
    let dir = repo(&[]);
    let reads =
        |command: &str, env: &Env| request_is_read_only(&execute(json!(command)), &dir, env);
    for key in ["LD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"] {
        let mut env = system_env();
        env.insert(key.to_owned(), "/tmp/x".to_owned());
        assert!(reads("git status", &env), "{key}");
    }
    for key in ["DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH"] {
        let mut env = system_env();
        env.insert(key.to_owned(), "/tmp/x".to_owned());
        assert!(!reads("git status", &env), "{key}");
    }
    std::fs::remove_dir_all(dir).unwrap();
}

/// Codex review of #24155 at 7e312f83: the command runs with the harness's PATH and env, so
/// a bare `ls` found first in another directory, or an env that points git at a program,
/// asks.
#[cfg(unix)]
#[test]
fn the_harness_environment_decides() {
    let dir = repo(&[]);
    let tools = std::env::temp_dir().join(format!("acpmux-tools-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir(&tools).unwrap();
    let with_path = |first: &Path| {
        Env::from([("PATH".to_owned(), format!("{}:{}", first.display(), TRUSTED_DIRS.join(":")))])
    };
    let reads =
        |command: &str, env: &Env| request_is_read_only(&execute(json!(command)), &dir, env);
    assert!(reads("ls", &with_path(&tools)));
    assert!(reads("pwd", &Env::new()), "a builtin needs no PATH");
    assert!(!reads("ls", &Env::new()), "no PATH finds no ls");
    // A relative PATH entry is searched from the command's directory, not the daemon's.
    for path in [".:/usr/bin:/bin", ":/usr/bin:/bin", "/usr/bin:bin:/bin"] {
        let env = Env::from([("PATH".to_owned(), path.to_owned())]);
        assert!(!reads("ls", &env), "{path}");
        assert!(!reads("pwd", &env), "{path}");
    }
    // The shell itself: an agent bash found first on PATH, or a $SHELL outside the system
    // directories, asks even for a builtin.
    {
        use std::os::unix::fs::PermissionsExt;
        let fake = tools.join("bash");
        std::fs::write(&fake, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(!reads("pwd", &with_path(&tools)));
        std::fs::remove_file(&fake).unwrap();
    }
    let mut shell = system_env();
    shell.insert("SHELL".to_owned(), tools.join("zsh").display().to_string());
    assert!(!reads("pwd", &shell));
    shell.insert("SHELL".to_owned(), "/bin/sh".to_owned());
    assert!(reads("pwd", &shell));
    {
        use std::os::unix::fs::PermissionsExt;
        let fake = tools.join("ls");
        std::fs::write(&fake, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    assert!(!reads("ls", &with_path(&tools)));
    assert!(!reads("git status; ls", &with_path(&tools)));
    assert!(reads("/bin/ls", &with_path(&tools)) || !Path::new("/bin/ls").exists());
    for key in [
        "GIT_EXTERNAL_DIFF",
        "GIT_CONFIG_COUNT",
        "GIT_DIR",
        "LD_PRELOAD",
        "BASH_ENV",
        "PAGER",
        "RIPGREP_CONFIG_PATH",
        "BASH_FUNC_pwd%%",
        "BASH_FUNC_git()",
        "ZDOTDIR",
        "LD_DEBUG_OUTPUT",
        "LD_PROFILE",
        "DYLD_PRINT_TO_FILE",
        "MALLOC_TRACE",
        "MANPAGER",
    ] {
        let mut env = system_env();
        env.insert(key.to_owned(), "/tmp/x".to_owned());
        assert!(!reads("git diff", &env), "{key}");
        assert!(!reads("pwd", &env), "{key}");
    }
    let mut env = system_env();
    env.insert("GIT_TERMINAL_PROMPT".to_owned(), "0".to_owned());
    assert!(reads("git diff", &env));
    for d in [dir, tools] {
        std::fs::remove_dir_all(d).unwrap();
    }
}

/// The person's global config is read too: a key there that makes a read run a program asks.
#[test]
fn a_global_config_that_names_a_program_asks() {
    let dir = repo(&[]);
    let home = std::env::temp_dir().join(format!("acpmux-home-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir(&home).unwrap();
    let mut env = system_env();
    env.insert("HOME".to_owned(), home.display().to_string());
    env.insert("XDG_CONFIG_HOME".to_owned(), home.join(".config").display().to_string());
    let reads = |command: &str| request_is_read_only(&execute(json!(command)), &dir, &env);
    for config in [
        "[diff]\n\texternal = /tmp/hook\n",
        "[diff \"x\"]\n\ttextconv = /tmp/hook\n",
        "[filter \"x\"]\n\tclean = /tmp/hook\n",
        "[core]\n\tfsmonitor = /tmp/hook\n",
        "[log]\n\tshowSignature = true\n",
        "[help]\n\tformat = man\n[man]\n\tviewer = probe\n[man \"probe\"]\n\tcmd = touch /tmp/marker\n",
        "[core]\n\tpager = touch /tmp/marker\n",
        "[pager]\n\tlog = touch /tmp/marker\n",
        "[pretty]\n\tverify = format:%G?\n",
        "[pretty]\n\tverify = format:%+G?\n",
        "[format]\n\tpretty = format:%G?\n",
        "[lfs]\n\tstandalonetransferagent = probe\n",
        "[interactive]\n\tdiffFilter = /tmp/hook\n",
        "[tag]\n\tsort = signature:grade\n",
    ] {
        std::fs::write(home.join(".gitconfig"), config).unwrap();
        assert!(!reads("git diff"), "{config}");
        assert!(reads("pwd"), "{config}");
    }
    // The person's own settings that no read runs still pass: aliases, an editor, credential
    // and signing helpers (no read talks to a remote or checks a signature), includes (their
    // keys are listed and checked too).
    let identity = home.join("identity.gitconfig");
    std::fs::write(&identity, "[user]\n\tname = t\n").unwrap();
    std::fs::write(
        home.join(".gitconfig"),
        format!(
            "[alias]\n\tst = status\n[core]\n\teditor = vim\n[credential]\n\thelper = osxkeychain\n\
             [gpg]\n\tformat = ssh\n[commit]\n\tgpgsign = true\n[safe]\n\tdirectory = *\n\
             [include]\n\tpath = {}\n",
            identity.display()
        ),
    )
    .unwrap();
    assert!(reads("git diff"));
    // An included file is checked like the file that includes it.
    std::fs::write(&identity, "[diff]\n\texternal = /tmp/hook\n").unwrap();
    assert!(!reads("git diff"));
    // git-lfs's own filter lines pass when git-lfs is a system program; its settings ask.
    let lfs = "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n\tprocess = git-lfs filter-process\n\trequired = true\n";
    std::fs::write(home.join(".gitconfig"), lfs).unwrap();
    assert_eq!(reads("git diff"), resolve("git-lfs", &env).is_some());
    std::fs::write(
        home.join(".gitconfig"),
        format!("{lfs}[lfs]\n\tstandalonetransferagent = probe\n"),
    )
    .unwrap();
    assert!(!reads("git diff"));
    std::fs::write(home.join(".gitconfig"), "[filter \"lfs\"]\n\tclean = /tmp/hook %f\n").unwrap();
    assert!(!reads("git diff"));
    for d in [dir, home] {
        std::fs::remove_dir_all(d).unwrap();
    }
}
