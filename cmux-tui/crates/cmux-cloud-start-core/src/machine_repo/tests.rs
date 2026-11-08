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
    let keep = at(r#"if { [ "$cred" = cmux-github ] || [ "$cred" = cmux-gitlab ]; }"#);
    let cloned = at("status=cloned");
    let result = at(r#"sha=$(g -C "$dir" rev-parse"#);
    assert!(cloned < keep && keep < result);
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
