//! `--repo` specs and the repo step (moved from the app's `CloudMachineRepoTests`).

use super::*;

fn repo(owner: &str, name: &str, r#ref: Option<&str>, host: &str) -> Repo {
    Repo {
        owner: owner.into(),
        name: name.into(),
        r#ref: r#ref.map(str::to_owned),
        host: host.into(),
    }
}

#[test]
fn the_accepted_forms_all_name_the_same_repository() {
    for spec in [
        "manaflow-ai/cmux",
        "manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux.git",
        "https://www.github.com/manaflow-ai/cmux/",
        "http://github.com/manaflow-ai/cmux",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
        "  manaflow-ai/cmux\n",
    ] {
        let parsed = parse(spec).unwrap_or_else(|e| panic!("{spec}: {e:?}"));
        assert_eq!(parsed, Repo::new("manaflow-ai", "cmux"), "{spec}");
        assert_eq!(parsed.url(), "https://github.com/manaflow-ai/cmux.git");
        assert_eq!(parsed.directory(), "work/cmux");
    }
}

#[test]
fn a_ref_comes_from_at_or_from_tree() {
    let r = |spec: &str| parse(spec).unwrap().r#ref;
    assert_eq!(r("manaflow-ai/cmux@feat-cmux-next").as_deref(), Some("feat-cmux-next"));
    assert_eq!(r("git@github.com:manaflow-ai/cmux.git@v1.2.3").as_deref(), Some("v1.2.3"));
    assert_eq!(
        r("https://github.com/manaflow-ai/cmux/tree/lane/pm-x").as_deref(),
        Some("lane/pm-x")
    );
    assert_eq!(
        r("https://github.com/manaflow-ai/cmux/tree/lane/pm-x@main").as_deref(),
        Some("main")
    );
    let sha = "a".repeat(40);
    assert_eq!(parse(&format!("o/r@{sha}")).unwrap().spec(), format!("o/r@{sha}"));
}

#[test]
fn credentials_in_the_url_are_refused() {
    for spec in [
        "https://ghp_secret@github.com/o/r",
        "https://x:ghp_secret@github.com/o/r",
        "ssh://ghp_secret@github.com/o/r.git",
        "ssh://git:pw@github.com/o/r.git",
        "ghp_secret@github.com:o/r.git",
    ] {
        assert_eq!(parse(spec), Err(Invalid::CredentialsInUrl), "{spec}");
    }
}

#[test]
fn anything_but_a_plain_github_repository_or_https_git_url_is_refused() {
    for spec in [
        "",
        "cmux",
        "o/r/x",
        "https://github.com/o",
        "https://github.com:8443/o/r",
        "https://github.com/o/r?x=1",
        "file:///tmp/r",
        "evilgithub.com:o/r",
        "o/-r",
        "o/.r",
        "o/r;rm -rf ~",
        "o/r b",
        // Off GitHub: https only, a plain host, no port, query or odd path.
        "http://gitlab.com/o/r",
        "ssh://git@gitlab.com/o/r.git",
        "git@gitlab.com:o/r.git",
        "https://gitlab.com/r",
        "https://gitlab.com:8443/o/r",
        "https://localhost/o/r",
        "https://10.0.0.1/o/r",
        "https://-x.com/o/r",
        "https://gitlab.com/o/r?x=1",
        "https://gitlab.com/o/.r",
        "https://gitlab.com/-/r",
        "https://gitlab.com/o/r/-/blob/x",
    ] {
        assert_eq!(parse(spec), Err(Invalid::Unrecognized), "{spec}");
    }
}

/// Leo, 2026-11-05: "there's presumably other services, like there's GitLab or whatever".
#[test]
fn another_hosts_https_url_clones_with_its_group_path_and_ref() {
    let gitlab = parse("https://gitlab.com/gitlab-org/gitlab-test.git").unwrap();
    assert_eq!(gitlab, repo("gitlab-org", "gitlab-test", None, "gitlab.com"));
    assert!(!gitlab.is_github());
    assert_eq!(gitlab.url(), "https://gitlab.com/gitlab-org/gitlab-test.git");
    assert_eq!(gitlab.directory(), "work/gitlab-test");
    assert_eq!(gitlab.spec(), "https://gitlab.com/gitlab-org/gitlab-test");
    let nested = parse("https://GitLab.com/group/sub/project/-/tree/release/1.x").unwrap();
    assert_eq!(nested, repo("group/sub", "project", Some("release/1.x"), "gitlab.com"));
    assert_eq!(parse("https://codeberg.org/o/r@v2").unwrap().r#ref.as_deref(), Some("v2"));
    assert_eq!(parse("https://oauth2:glpat-x@gitlab.com/o/r"), Err(Invalid::CredentialsInUrl));
    assert_eq!(parse("https://gitlab.com/o/r/-/tree/a..b"), Err(Invalid::InvalidRef));
    let record: serde_json::Value = serde_json::from_str(&gitlab.record()).unwrap();
    assert_eq!(record["host"], "gitlab.com");
}

#[test]
fn another_host_is_never_offered_the_machines_github_credentials() {
    let step = parse("https://gitlab.com/o/r").unwrap().step();
    assert!(step.contains("github=0"));
    assert!(
        step.contains(r#"if [ "$github" = 1 ] && [ -x "$HOME/.local/bin/lane-gh-credential" ]"#)
    );
    assert!(step.contains(r#"if [ "$github" = 1 ] && [ -S /run/cmux-vm-agent/agent.sock ]"#));
    assert!(parse("o/r").unwrap().step().contains("github=1"));
}

#[test]
fn another_host_uses_only_its_own_sealed_token() {
    let step = parse("https://gitlab.com/o/r").unwrap().step();
    assert!(step.contains(r#"host='gitlab.com'; key="credential.https://$host""#));
    assert!(
        step.contains(r#"if [ "$github" = 0 ] && [ -f "$HOME/.config/cmux/git-hosts/$host" ]"#)
    );
    assert!(step.contains(r#"cmux-gitlab) helper="!'$cm' gitlab credential" ;;"#));
}

#[test]
fn a_checkout_cloned_through_cmux_keeps_its_helper_for_push() {
    let step = Repo::new("o", "r").step();
    let at = |needle: &str| step.find(needle).unwrap_or_else(|| panic!("{needle}"));
    let defined = at("keep_helper() {");
    let kept = at(r#"if { [ "$cred" = cmux-github ] || [ "$cred" = cmux-gitlab ]; }"#);
    assert!(defined < kept, "the helper is kept by keep_helper");
    // A start keeps it after its clone or update, before its record; a warm update behind the
    // chat keeps it after its fetch (review F2, cmux#38997 aafeae5053e).
    let keep = at("\nkeep_helper\n");
    let cloned = at("status=cloned");
    // The step's own record, the last read of its commit (an inline warm update reads it too).
    let result = step.rfind(r#"sha=$(g -C "$dir" rev-parse"#).unwrap();
    assert!(cloned < keep && keep < result);
    let fetched = at(r#"if g -C "$dir" fetch --quiet --tags origin; then"#);
    assert!(
        step[fetched..].trim_start_matches(|c| c != '\n').trim_start().starts_with("keep_helper")
    );
    assert!(
        step.contains(r#"git -C "$dir" config --local --add "$key.helper" """#),
        "a global helper is dropped first"
    );
    assert!(
        step.contains(r#"git -C "$dir" config --local --add "$key.helper" "$helper""#),
        "the helper, never a token"
    );
}

#[test]
fn another_host_that_does_not_clone_fails_instead_of_waiting_for_github() {
    let step = parse("https://gitlab.com/o/r").unwrap().step();
    let failed = step.find(r#"[ "$github" = 1 ] || die "#).unwrap();
    let needs = step.find("status=needs_github; result").unwrap();
    assert!(failed < needs, "off GitHub the step exits failed before it would say needs_github");
}

#[test]
fn a_ref_that_needs_quoting_is_refused() {
    for r in [
        "HEAD",
        "HEAD/x",
        "topic/.hidden",
        "a.lock/b",
        "-x",
        "a..b",
        "a b",
        "a'b",
        "a\"b",
        "a;b",
        "x.lock",
        "a/",
        "$(id)",
        "a@{1}",
    ] {
        assert_eq!(parse(&format!("o/r@{r}")), Err(Invalid::InvalidRef), "{r}");
    }
    assert!(is_ref("feat/x-1.2") && !is_ref(""));
}

#[test]
fn the_step_resets_every_other_helper_and_writes_no_token() {
    let step = repo("o", "r", Some("main"), GITHUB).step();
    let reset = step.find("git -c credential.helper= -c core.askPass= ").unwrap();
    let chosen = step.find(r#"-c "$key.helper=$helper""#).unwrap();
    // `set --` puts the chosen helper into "$@", which git reads after the reset.
    assert!(chosen < reset, "g's set -- line comes before its git line");
    assert!(
        step.contains(
            "export GIT_TERMINAL_PROMPT=0 GIT_TRACE_REDACT=1 GIT_TRACE=0 GIT_TRACE_CURL=0"
        )
    );
    assert!(step.contains("GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0"));
    assert!(step.contains("--includes --get-all credential.https://github.com.helper"));
    assert!(step.contains("export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1"));
    assert!(step.contains(r#"host='github.com'; key="credential.https://$host""#));
    assert!(step.contains(r#"-c credential.username= -c "$key.username=""#));
    assert!(step.contains("unset GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT"));
    assert!(step.contains(r#"lane="!$HOME/.local/bin/lane-gh-credential""#));
    assert!(step.contains(r#"grep -qxF -- "$lane""#));
    assert!(step.contains("[ -S /run/cmux-vm-agent/agent.sock ]"));
    assert!(step.contains("github credential"));
    for fetches in ["checkout", "merge", "status", "fetch", "clone"] {
        assert!(
            !step.contains(&format!("git -C \"$dir\" {fetches}"))
                && !step.contains(&format!("git {fetches} ")),
            "{fetches} goes through g (a blobless clone fetches on demand)"
        );
    }
    assert!(step.contains(r#"checkout --quiet --detach "$commit" --"#));
    // Only the code: the comments may say what it guards against.
    let code: Vec<&str> = step.lines().filter(|l| !l.trim_start().starts_with('#')).collect();
    let code = code.join("\n");
    for leak in ["token", "GH_TOKEN", "password", "credential.helper=store", "hosts.yml", "gh auth"]
    {
        assert!(!code.contains(leak), "{leak}");
    }
    assert!(step.contains("url='https://github.com/o/r.git'; ref='main'; dir=\"$HOME/work/r\""));
    assert!(step.contains(&format!("exit {NEEDS_GITHUB_EXIT}")));
    for placeholder in
        ["@URL@", "@REF@", "@DIRECTORY@", "@GITHUB@", "@HOST@", "@NEEDS_GITHUB_EXIT@"]
    {
        assert!(!step.contains(placeholder), "{placeholder} is filled");
    }
    assert!(
        step.starts_with("#!/bin/sh\n") && step.ends_with("result"),
        "the text ends as it always did"
    );
}

#[test]
fn the_record_names_the_repository_and_no_secret() {
    let record = repo("o", "r", Some("v1"), GITHUB).record();
    assert_eq!(
        record,
        r#"{"dir":"~\/work\/r","name":"r","owner":"o","ref":"v1","url":"https:\/\/github.com\/o\/r.git"}"#,
        "sorted keys and escaped slashes, as the app always wrote it"
    );
    let value: serde_json::Value = serde_json::from_str(&record).unwrap();
    assert_eq!(value["dir"], "~/work/r");
}

#[test]
fn the_description_carries_everything_the_app_shows() {
    let described = serde_json::to_value(describe(&parse("o/r@main").unwrap())).unwrap();
    assert_eq!(described["owner"], "o");
    assert_eq!(described["ref"], "main");
    assert_eq!(described["host"], "github.com");
    assert_eq!(described["isGitHub"], true);
    assert_eq!(described["spec"], "o/r@main");
    assert_eq!(described["directory"], "work/r");
    let read: Repo =
        serde_json::from_value(serde_json::json!({"owner": "o", "name": "r"})).unwrap();
    assert_eq!(read, Repo::new("o", "r"), "a repo without a host is on GitHub");
    assert_eq!(serde_json::to_value(Invalid::CredentialsInUrl).unwrap(), "credentialsInURL");
}

/// The step parses as shell, for GitHub and another host (where the host has a shell).
#[test]
fn the_step_parses() {
    for r in [Repo::new("o", "r"), parse("https://gitlab.com/g/s/p@v1").unwrap()] {
        let Ok(out) = std::process::Command::new("sh").arg("-n").arg("-c").arg(r.step()).output()
        else {
            return;
        };
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    }
}

#[test]
fn git_reads_the_reset_before_the_chosen_helper() {
    let step = repo("o", "r", Some("main"), GITHUB).step();
    let Some(start) = step.find("g() {") else { panic!("g is defined") };
    let Some(len) = step.get(start..).and_then(|rest| rest.find("\n}\n")) else { panic!("g ends") };
    let Some(g) = step.get(start..start + len + 2) else { panic!("g's text") };
    let script = format!(
        "git() {{ printf '%s\\n' \"$@\"; }}\nkey='credential.https://h'; helper='!x'\n{g}\ng clone u"
    );
    let Ok(out) = std::process::Command::new("sh").arg("-c").arg(script).output() else {
        panic!("sh runs")
    };
    let argv = String::from_utf8_lossy(&out.stdout);
    let argv: Vec<&str> = argv.lines().collect();
    let at = |arg: &str| argv.iter().position(|a| *a == arg);
    let (Some(reset), Some(chosen), Some(clone)) =
        (at("credential.helper="), at("credential.https://h.helper=!x"), at("clone"))
    else {
        panic!("{argv:?}")
    };
    assert!(reset < chosen && chosen < clone, "{argv:?}");
}

#[cfg(unix)]
/// A scratch folder with a source repository of two commits, and shims for the machine's
/// `cmux` (`repo hold` runs its command in the foreground), `systemd-run`, `sudo` and `runuser`.
struct Machine(std::path::PathBuf);

#[cfg(unix)]
impl Machine {
    fn new(with_hold: bool) -> Option<Self> {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "cmux-repo-step-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let sh = |script: &str| {
            std::process::Command::new("sh").arg("-c").arg(script).current_dir(&root).status()
        };
        std::fs::create_dir_all(root.join("bin")).ok()?;
        let made = sh(r#"
            set -e
            g() { git -c user.email=t@t -c user.name=t "$@"; }
            git init -q src; mkdir -p src/lib src/.github home boot
            echo a > src/AGENTS.md; echo x > src/lib/x.rs; echo w > src/.github/w.yml
            g -C src add -A; g -C src commit -qm one
            echo y > src/lib/y.rs; g -C src add -A; g -C src commit -qm two
            g -C src checkout -qb feature; echo f > src/f.txt; g -C src add -A; g -C src commit -qm f
            g -C src checkout -q -
            git -C src config uploadpack.allowFilter true
            printf '#!/bin/sh\nwhile [ "${1#--}" != "$1" ]; do shift; done; exec "$@"\n' > bin/systemd-run
            printf '#!/bin/sh\nshift 3; exec "$@"\n' > bin/runuser
            printf '#!/bin/sh\n[ "$1" = -n ] && shift; exec "$@"\n' > bin/sudo
            chmod +x bin/*
        "#)
        .ok()?;
        if !made.success() {
            return None;
        }
        if with_hold {
            let cmux = "#!/bin/sh\n[ \"$1 $2\" = \"repo hold\" ] || exit 2\n\
                        [ \"$3\" = --help ] && exit 0\n\
                        echo \"$3\" > \"$HOME/held\"; shift 4; \"$@\"\n";
            let machine = Self(root);
            machine.cmux(cmux);
            return Some(machine);
        }
        Some(Self(root))
    }

    /// The machine's `cmux` and `cmux-tui` (the step asks `cmux-tui` first): both run `script`,
    /// so a real one on the PATH of the host running the test is never reached.
    fn cmux(&self, script: &str) {
        use std::os::unix::fs::PermissionsExt as _;
        for name in ["bin/cmux", "bin/cmux-tui"] {
            let file = self.0.join(name);
            std::fs::write(&file, script).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    /// Runs the step for this machine's source repository; its exit code and repo-status.json.
    fn run(&self) -> (i32, serde_json::Value) {
        self.run_with(None, crate::machine_bootstrap::NO_SCRIPT)
    }

    /// [`Machine::run`] for `r#ref`, beside the bootstrap script `script` (the runner's `script`).
    fn run_with(&self, r#ref: Option<&str>, script: &str) -> (i32, serde_json::Value) {
        let url = format!("file://{}", self.0.join("src").display());
        let repo = Repo { r#ref: r#ref.map(str::to_owned), ..Repo::new("o", "r") };
        let step = repo.step().replace("https://github.com/o/r.git", &url);
        std::fs::write(self.0.join("boot/script"), script).unwrap();
        let file = self.0.join("boot/repo");
        std::fs::write(&file, step).unwrap();
        // As the bootstrap writes it (0o700): the fill runs the step again by its path.
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o700)).unwrap();
        let inherited = std::env::var("PATH").unwrap_or_default();
        let path = format!("{}:{inherited}", self.0.join("bin").display());
        let status = std::process::Command::new("sh")
            .arg(&file)
            .env("HOME", self.0.join("home"))
            .env("PATH", path)
            .status()
            .unwrap();
        let record =
            std::fs::read_to_string(self.0.join("boot/repo-status.json")).unwrap_or_default();
        (status.code().unwrap_or(-1), serde_json::from_str(&record).unwrap_or_default())
    }

    fn checkout(&self) -> std::path::PathBuf {
        self.0.join("home/work/r")
    }

    fn git(&self, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(self.checkout())
            .args(args)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }
}

#[cfg(unix)]
impl Drop for Machine {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
/// The default branch is cloned head first and filled under `cmux repo hold`: the step ends with
/// the whole tree there and the barrier's command run (cmuxterm-hq goals/cloud-no-network-wait.md).
#[test]
fn a_default_branch_is_cloned_head_first_and_filled_under_the_hold() {
    let Some(machine) = Machine::new(true) else { return };
    let (code, record) = machine.run();
    assert_eq!(code, 0, "{record}");
    assert_eq!(
        (record["status"].as_str(), record["fill"].as_str()),
        (Some("cloned"), Some("background"))
    );
    let dir = machine.checkout();
    let held = std::fs::read_to_string(machine.0.join("home/held")).unwrap();
    assert_eq!(held.trim(), dir.display().to_string());
    for file in ["AGENTS.md", ".github/w.yml", "lib/x.rs", "lib/y.rs"] {
        assert!(dir.join(file).is_file(), "{file} is checked out");
    }
    let sparse = std::process::Command::new("git")
        .args(["-C", &dir.display().to_string(), "config", "--bool", "core.sparseCheckout"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&sparse.stdout).trim(), "false");
}

#[cfg(unix)]
/// A machine whose cmux has no `repo hold` clones the whole repository, as before.
#[test]
fn without_a_hold_the_whole_repository_is_cloned() {
    let Some(machine) = Machine::new(false) else { return };
    // No `cmux` shim: the PATH's own may exist on this host, so hide it behind one that refuses.
    machine.cmux("#!/bin/sh\nexit 2\n");
    let (code, record) = machine.run();
    assert_eq!(code, 0, "{record}");
    assert_eq!(record["fill"].as_str(), Some("none"));
    let dir = machine.checkout();
    assert!(dir.join("lib/y.rs").is_file());
    let shallow = std::process::Command::new("git")
        .args(["-C", &dir.display().to_string(), "rev-parse", "--is-shallow-repository"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&shallow.stdout).trim(), "false");
}

#[cfg(unix)]
/// Review F2 (cmux#38099, e473b67ec61): a depth-1 clone tracks only the default branch, so once
/// the history came in, a later start on another branch found no such branch.
#[test]
fn a_head_first_clone_keeps_every_branch_for_a_later_start() {
    let Some(machine) = Machine::new(true) else { return };
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    let fetch = machine.git(&["config", "--get-all", "remote.origin.fetch"]);
    assert_eq!(fetch, "+refs/heads/*:refs/remotes/origin/*");
    // The history comes in the background (`unshallow`): let it end before the next start.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while machine.git(&["rev-parse", "--is-shallow-repository"]) != "false" {
        assert!(std::time::Instant::now() < deadline, "the history never came in");
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let (code, record) = machine.run_with(Some("feature"), crate::machine_bootstrap::NO_SCRIPT);
    assert_eq!(code, 0, "{record}");
    assert!(machine.checkout().join("f.txt").is_file());
}

#[cfg(unix)]
/// Review F1 (cmux#38099, e473b67ec61): the runner runs a start's bootstrap script right after the
/// step, with no barrier, so with a script of its own the whole tree is cloned first.
#[test]
fn a_start_with_a_bootstrap_script_clones_the_whole_repository() {
    let Some(machine) = Machine::new(true) else { return };
    let (code, record) = machine.run_with(None, "#!/bin/sh\ntest -f work/r/lib/y.rs\n");
    assert_eq!((code, record["fill"].as_str()), (0, Some("none")), "{record}");
    assert!(machine.checkout().join("lib/y.rs").is_file());
    assert_eq!(machine.git(&["rev-parse", "--is-shallow-repository"]), "false");
    assert!(!machine.0.join("home/held").exists(), "no hold");
}

#[cfg(unix)]
/// Review F3 (cmux#38099, 782cd5a47ad): a head-first checkout whose fill never ran, filled again
/// on a machine with no hold, gets its history too, as a whole clone has it.
#[test]
fn a_head_first_checkout_filled_without_a_hold_gets_its_history() {
    let Some(machine) = Machine::new(true) else { return };
    // A hold that takes the folder and never runs its fill.
    machine.cmux("#!/bin/sh\n[ \"$3\" = --help ] && exit 0\nexit 0\n");
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    assert_eq!(machine.git(&["rev-parse", "--is-shallow-repository"]), "true");
    machine.cmux("#!/bin/sh\nexit 2\n");
    let (code, record) = machine.run();
    assert_eq!(code, 0, "{record}");
    assert!(machine.checkout().join("lib/y.rs").is_file());
    assert_eq!(machine.git(&["rev-parse", "--is-shallow-repository"]), "false");
}

#[cfg(unix)]
/// Review F2 (cmux#38099, 344dd0d083c): a harness folder that the repository tracks as a symlink
/// is no sparse folder, so the head-first clone takes the whole tree at once instead of failing.
#[test]
fn a_symlinked_harness_folder_takes_the_whole_tree_at_once() {
    let Some(machine) = Machine::new(true) else { return };
    let linked = std::process::Command::new("sh")
        .arg("-c")
        .arg("cd src && ln -s .github .claude && git add -A && git -c user.email=t@t -c user.name=t commit -qm l")
        .current_dir(&machine.0)
        .status()
        .unwrap();
    assert!(linked.success());
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("done")), "{record}");
    assert!(machine.checkout().join("lib/y.rs").is_file());
    assert_eq!(machine.git(&["rev-parse", "--is-shallow-repository"]), "false");
    assert!(!machine.0.join("home/held").exists(), "no hold");
}

#[cfg(unix)]
/// A machine's `cmux` for the barrier: `repo wait DIR 0` exits with `$HOME/wait` (0 when absent),
/// a longer wait records `$HOME/waited`, blocks while `$HOME/busy` exists (the earlier fill runs),
/// then exits with `$HOME/wait-long` (0 when absent: that fill ended), `repo hold` runs its fill in
/// the foreground, and `repo hold-run` records its folder and runs it.
const BARRIER_CMUX: &str = "#!/bin/sh\ncase \"$1 $2\" in\n\
    \"repo wait\") [ \"$4\" = 0 ] && exit \"$(cat \"$HOME/wait\" 2>/dev/null || echo 0)\"\n\
    touch \"$HOME/waited\"; while [ -e \"$HOME/busy\" ]; do sleep 0.05; done\n\
    exit \"$(cat \"$HOME/wait-long\" 2>/dev/null || echo 0)\" ;;\n\
    \"repo hold\") [ \"$3\" = --help ] && exit 0; echo \"$3\" > \"$HOME/held\"; shift 4; exec \"$@\" ;;\n\
    \"repo hold-run\") echo \"$3\" > \"$HOME/held-run\"; shift 4; echo held; exec \"$@\" ;;\n\
    esac\nexit 2\n";

#[cfg(unix)]
impl Machine {
    /// The barrier on the checkout reads `code` (`repo wait`: 1 failed, 124 busy).
    fn barrier_reads(&self, code: i32) {
        std::fs::write(self.0.join("home/wait"), code.to_string()).unwrap();
    }

    /// Waits for the first start's background history fetch to end (it holds its lock while
    /// it runs), so the next start is not one that comes during it.
    fn settle(&self) {
        let lock = self.checkout().join(".git/cmux-history.lock");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            let free = std::process::Command::new("flock")
                .arg("-n")
                .arg(&lock)
                .arg("true")
                .status()
                .map_or(true, |s| s.success());
            if free && self.git(&["rev-parse", "--is-shallow-repository"]) == "false" {
                return;
            }
            assert!(std::time::Instant::now() < deadline, "the history fetch never ended");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    /// A process holding the checkout's history lock, as a running history fetch does (it sleeps
    /// 30 s; kill it). None on a host with no flock(1).
    fn hold_history(&self) -> Option<std::process::Child> {
        let lock = self.checkout().join(".git/cmux-history.lock");
        let (tx, rx) = std::sync::mpsc::channel();
        let mut holder = std::process::Command::new("sh")
            .arg("-c")
            .arg("exec 9>\"$1\" && flock 9 && echo locked && exec sleep 30")
            .arg("sh")
            .arg(&lock)
            .stdout(std::process::Stdio::piped())
            .spawn()
            .ok()?;
        let stdout = holder.stdout.take().unwrap();
        std::thread::spawn(move || {
            use std::io::BufRead as _;
            let mut line = String::new();
            let _ = std::io::BufReader::new(stdout).read_line(&mut line);
            let _ = tx.send(line);
        });
        let locked = rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap_or_default();
        if locked.trim() != "locked" {
            let _ = holder.kill();
            let _ = holder.wait();
            return None;
        }
        Some(holder)
    }

    /// The barrier reads busy until a second from now, when the earlier fill ends and opens it.
    /// Join the thread before reading what the start did.
    fn fill_busy_for_a_second(&self) -> std::thread::JoinHandle<()> {
        let home = self.0.join("home");
        std::fs::write(home.join("busy"), "").unwrap();
        let _ = std::fs::remove_file(home.join("waited"));
        self.barrier_reads(124);
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(1));
            std::fs::write(home.join("wait"), "0").unwrap();
            std::fs::remove_file(home.join("busy")).unwrap();
        })
    }

    fn commit_upstream(&self, file: &str) {
        let made = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!(
                "echo n > src/{file} && git -C src add -A && git -c user.email=t@t -c user.name=t -C src commit -qm n"
            ))
            .current_dir(&self.0)
            .status()
            .unwrap();
        assert!(made.success());
    }
}

#[cfg(unix)]
/// cmux#38364: a fill that died after the tree was whole leaves the barrier failed, and only the
/// next start can open it. With a hold the step fills again in the background; without one (a
/// start with a script of its own) it fills now under `repo hold-run`, which opens the barrier.
#[test]
fn a_failed_fill_is_filled_again_under_the_barrier() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, record) = machine.run();
    machine.settle();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    machine.barrier_reads(1);
    std::fs::remove_file(machine.0.join("home/held")).unwrap();
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    assert!(machine.0.join("home/held").exists(), "held again");
    machine.settle();
    let (code, record) = machine.run_with(None, "#!/bin/sh\ntrue\n");
    assert_eq!((code, record["fill"].as_str()), (0, Some("done")), "{record}");
    let held = std::fs::read_to_string(machine.0.join("home/held-run")).unwrap();
    assert_eq!(held.trim(), machine.checkout().display().to_string());
    assert!(machine.checkout().join("lib/y.rs").is_file());
}

#[cfg(unix)]
/// cmux#38364: a start while an earlier start's fill still holds the checkout fetches, switches
/// and fills nothing (its git locks would fail this one); the chat starts on the checkout as it is.
#[test]
fn a_start_during_a_fill_leaves_the_checkout_to_it() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    machine.settle();
    assert_eq!(code, 0);
    let before = machine.git(&["rev-parse", "HEAD"]);
    machine.commit_upstream("z.txt");
    machine.barrier_reads(124);
    let (code, record) = machine.run();
    assert_eq!(code, 0, "{record}");
    assert_eq!(
        (record["status"].as_str(), record["fill"].as_str()),
        (Some("kept"), Some("background"))
    );
    assert_eq!(machine.git(&["rev-parse", "HEAD"]), before, "not fetched or forwarded");
}

#[cfg(unix)]
/// cmux#38364: the history fetch holds its lock while it runs, and a later start leaves it alone.
#[test]
fn a_start_during_the_history_fetch_leaves_the_checkout_to_it() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    machine.settle();
    assert_eq!(code, 0);
    let Some(mut holder) = machine.hold_history() else { return };
    machine.commit_upstream("z.txt");
    let before = machine.git(&["rev-parse", "HEAD"]);
    let (code, record) = machine.run();
    let _ = holder.kill();
    let _ = holder.wait();
    assert_eq!((code, record["status"].as_str()), (0, Some("kept")), "{record}");
    assert_eq!(machine.git(&["rev-parse", "HEAD"]), before);
}

#[cfg(unix)]
/// Review F1 and F2 (cmux#38582, 0d1a4678b96): a start that needs more than the checkout as it is,
/// a branch to switch to or a script of its own that runs right after the step, waits for the
/// earlier start's fill instead of leaving the checkout to it.
#[test]
fn a_start_with_a_ref_or_a_script_waits_for_the_fill() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    let fill = machine.fill_busy_for_a_second();
    let started = std::time::Instant::now();
    let (code, record) = machine.run_with(Some("feature"), crate::machine_bootstrap::NO_SCRIPT);
    fill.join().unwrap();
    assert_eq!((code, record["status"].as_str()), (0, Some("updated")), "{record}");
    assert!(machine.0.join("home/waited").exists(), "waited for the fill");
    assert!(started.elapsed() >= std::time::Duration::from_secs(1), "until it ended");
    assert!(machine.checkout().join("f.txt").is_file(), "switched to feature");
    machine.settle();
    let fill = machine.fill_busy_for_a_second();
    let started = std::time::Instant::now();
    let (code, record) = machine.run_with(None, "#!/bin/sh\ntrue\n");
    fill.join().unwrap();
    assert_eq!((code, record["status"].as_str()), (0, Some("updated")), "{record}");
    assert!(machine.0.join("home/waited").exists(), "waited for the fill");
    assert!(started.elapsed() >= std::time::Duration::from_secs(1), "until it ended");
}

#[cfg(unix)]
/// Review F1 (cmux#38582, f2d6d161820): the history fetch took its lock only after the fill had
/// returned and the barrier opened, so a start in between found neither and fetched beside it.
/// The fill now holds the lock when it returns: this `repo hold` reads it right then, with the
/// history fetch slowed so it cannot have ended.
#[test]
fn the_history_lock_is_held_when_the_barrier_opens() {
    let Some(machine) = Machine::new(true) else { return };
    let Ok(real) = std::process::Command::new("sh").arg("-c").arg("command -v git").output() else {
        return;
    };
    let real = String::from_utf8_lossy(&real.stdout).trim().to_owned();
    let slow =
        format!("#!/bin/sh\ncase \"$*\" in *--unshallow*) sleep 2 ;; esac\nexec '{real}' \"$@\"\n");
    std::fs::write(machine.0.join("bin/git"), slow).unwrap();
    machine.cmux(
        "#!/bin/sh\n[ \"$1 $2\" = \"repo hold\" ] || exit 2\n[ \"$3\" = --help ] && exit 0\n\
         d=$3; shift 4; \"$@\" || exit\n\
         if flock -n \"$d/.git/cmux-history.lock\" true; then echo free; else echo held; fi > \"$HOME/at-open\"\n",
    );
    use std::os::unix::fs::PermissionsExt as _;
    let git = machine.0.join("bin/git");
    std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    let at_open = std::fs::read_to_string(machine.0.join("home/at-open")).unwrap_or_default();
    machine.settle();
    assert_eq!(at_open.trim(), "held");
}

#[cfg(unix)]
/// Review F2 (cmux#38582, f2d6d161820): a history fetch can outlive a fill that left the barrier
/// failed, and a start with no ref and no script of its own took the keep path, so nothing opened
/// the barrier again. It now waits for the fetch and fills again under the barrier.
#[test]
fn a_failed_barrier_is_filled_again_after_the_history_fetch() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    machine.barrier_reads(1);
    std::fs::remove_file(machine.0.join("home/held")).unwrap();
    let Some(mut holder) = machine.hold_history() else { return };
    let pid = holder.id();
    let release = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(1));
        let _ = std::process::Command::new("kill").arg(pid.to_string()).status();
    });
    let (code, record) = machine.run();
    let _ = release.join();
    let _ = holder.kill();
    let _ = holder.wait();
    assert_eq!(
        (code, record["status"].as_str(), record["fill"].as_str()),
        (0, Some("updated"), Some("background")),
        "{record}"
    );
    assert!(machine.0.join("home/held").exists(), "held again");
}

#[cfg(unix)]
/// Review F1 (cmux#38582, ce36521d223): the fill opened the history lock with `>`, so a symlink
/// planted at it truncated whatever file it named. The lock is now removed if a symlink and only
/// appended to.
#[test]
fn a_symlink_at_the_history_lock_is_not_followed() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    let victim = machine.0.join("home/victim");
    std::fs::write(&victim, "keep").unwrap();
    let lock = machine.checkout().join(".git/cmux-history.lock");
    let _ = std::fs::remove_file(&lock);
    std::os::unix::fs::symlink(&victim, &lock).unwrap();
    machine.barrier_reads(1);
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    machine.settle();
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
    assert!(!lock.is_symlink(), "the symlink is gone");
}

#[cfg(unix)]
/// cmuxterm-hq goals/cloud-no-network-wait.md step 5: a start on a whole checkout with nothing of
/// its own (no ref, no script) ran `git fetch` and a fast-forward before the chat, a network round
/// trip in front of every warm first reply. They now run behind it under `repo hold`: the hold is
/// taken on the checkout as it was, and the update ends under it.
#[test]
fn a_warm_start_fetches_behind_the_hold() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    let before = machine.git(&["rev-parse", "HEAD"]);
    machine.commit_upstream("z.txt");
    machine.cmux(
        "#!/bin/sh\ncase \"$1 $2\" in\n\
         \"repo wait\") exit 0 ;;\n\
         \"repo hold\") [ \"$3\" = --help ] && exit 0; git -C \"$3\" rev-parse HEAD > \"$HOME/head-at-hold\"\n\
         echo \"$5 $6\" > \"$HOME/hold-mode\"; shift 4; exec \"$@\" ;;\n\
         esac\nexit 2\n",
    );
    let (code, record) = machine.run();
    assert_eq!(
        (code, record["status"].as_str(), record["fill"].as_str()),
        (0, Some("updated"), Some("background")),
        "{record}"
    );
    let at_hold = std::fs::read_to_string(machine.0.join("home/head-at-hold")).unwrap();
    assert_eq!(at_hold.trim(), before, "nothing fetched or forwarded before the hold");
    let mode = std::fs::read_to_string(machine.0.join("home/hold-mode")).unwrap();
    assert!(mode.trim().ends_with("/repo refresh"), "the hold runs the update: {mode}");
    assert!(machine.checkout().join("z.txt").is_file(), "forwarded under the hold");
}

#[cfg(unix)]
/// The warm update keeps a checkout with local changes as it is, as the inline update did.
#[test]
fn a_warm_start_keeps_local_changes() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    let before = machine.git(&["rev-parse", "HEAD"]);
    std::fs::write(machine.checkout().join("AGENTS.md"), "mine").unwrap();
    machine.commit_upstream("z.txt");
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("background")), "{record}");
    assert_eq!(machine.git(&["rev-parse", "HEAD"]), before, "not forwarded");
    assert_eq!(std::fs::read_to_string(machine.checkout().join("AGENTS.md")).unwrap(), "mine");
}

#[cfg(unix)]
/// Review F1 (cmux#38997, aafeae5053e): a warm update whose fetch no path could make ended by
/// `net`'s exit, which left the barrier failed (the chat's tools waited for good) and rewrote
/// repo-status.json. It now keeps the checkout as it was, ends well, and leaves the record alone.
#[test]
fn a_warm_update_that_cannot_fetch_keeps_the_checkout() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    let before = machine.git(&["rev-parse", "HEAD"]);
    // The hold runs the update detached in production: record how it ended, answer held.
    machine.cmux(
        "#!/bin/sh\ncase \"$1 $2\" in\n\
         \"repo wait\") exit 0 ;;\n\
         \"repo hold\") [ \"$3\" = --help ] && exit 0; shift 4\n\
         mv \"$HOME/../src\" \"$HOME/../gone\"; \"$@\"; echo $? > \"$HOME/update-exit\"\n\
         mv \"$HOME/../gone\" \"$HOME/../src\"; exit 0 ;;\n\
         esac\nexit 2\n",
    );
    let (code, record) = machine.run();
    assert_eq!(
        (code, record["status"].as_str(), record["fill"].as_str()),
        (0, Some("updated"), Some("background")),
        "{record}"
    );
    let exit = std::fs::read_to_string(machine.0.join("home/update-exit")).unwrap();
    assert_eq!(exit.trim(), "0", "the update ends well, so the barrier opens");
    assert_eq!(machine.git(&["rev-parse", "HEAD"]), before);
}

#[cfg(unix)]
/// Review F1 (cmux#38997, d8bce39df2d): a warm start whose update could not run behind the chat
/// updated inline after the step had read its commit, so the record named the commit before the
/// update. It now reads it again after the update.
#[test]
fn a_warm_update_made_inline_records_the_updated_commit() {
    let Some(machine) = Machine::new(true) else { return };
    machine.cmux(BARRIER_CMUX);
    let (code, _) = machine.run();
    assert_eq!(code, 0);
    machine.settle();
    machine.commit_upstream("z.txt");
    // A hold that is there but cannot start: the update falls back to inline.
    std::fs::write(machine.0.join("bin/systemd-run"), "#!/bin/sh\nexit 1\n").unwrap();
    let (code, record) = machine.run();
    assert_eq!((code, record["fill"].as_str()), (0, Some("none")), "{record}");
    let head = machine.git(&["rev-parse", "HEAD"]);
    assert!(machine.checkout().join("z.txt").is_file(), "updated inline");
    assert_eq!(record["sha"].as_str(), Some(head.as_str()), "the record names the updated commit");
}
