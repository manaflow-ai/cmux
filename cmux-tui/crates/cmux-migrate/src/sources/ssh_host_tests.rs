use std::path::Path;
use std::process::{Command, Stdio};

use super::*;
use crate::plan::{CarryKind, Step};

const FIXTURE: &str = r#"{"t":"os","os":"Linux","arch":"x86_64","distro":"Ubuntu 22.04.4 LTS"}
{"t":"cpu","cpus":"8","mem_bytes":"16777216000"}
{"t":"disk","total_bytes":"107374182400","used_bytes":"53687091200","home_bytes":"42949672960"}
{"t":"tool","name":"node","version":"v20.11.0"}
{"t":"tool","name":"go","version":"go version go1.22.1 linux/amd64"}
{"t":"repo","path":"~/src/api","url":"https://x-access-token:ghp_abc@github.com/acme/api.git","branch":"main","commit":"0123456789abcdef0123456789abcdef01234567","dirty":"3","unpushed":"2","bytes":"20000000000","files":"go.mod,go.sum,docker-compose.yml"}
{"t":"repo","path":"~/web","url":"git@github.com:acme/web.git","branch":"feature/x","commit":"89abcdef0123456789abcdef0123456789abcdef","dirty":"0","unpushed":"0","bytes":"100000","files":"pnpm-lock.yaml,.devcontainer/devcontainer.json"}
{"t":"repo","path":"~/scratch","url":"","branch":"HEAD","commit":"HEAD","dirty":"1","unpushed":"","bytes":"4096","files":""}
{"t":"dotfile","path":"~/.zshrc","kind":"file","bytes":"4096"}
{"t":"dotfile","path":"~/.claude","kind":"dir","bytes":"81920"}
{"t":"dotfile","path":"~/.claude/.credentials.json","kind":"file","bytes":"4096"}
{"t":"unit","name":"syncthing.service"}
{"t":"container","name":"api-db-1","image":"postgres:16","ports":"0.0.0.0:5432->5432/tcp, :::5432->5432/tcp","dir":"~/src/api"}
{"t":"container","name":"portainer","image":"portainer/portainer-ce","ports":"0.0.0.0:9000->9000/tcp","dir":""}
{"t":"listen","port":"22"}
{"t":"listen","port":"5432"}
{"t":"listen","port":"8080"}
{"t":"cron","lines":"4"}
not json
{"t":"done"}
"#;

#[test]
fn reads_a_probe_into_projects_carry_and_warnings() {
    let plan = plan("devbox", FIXTURE);
    assert_eq!(plan.source.kind, SourceKind::SshHost);
    assert_eq!(plan.source.id, "ssh:devbox");
    assert_eq!(plan.projects.len(), 3);

    let api = &plan.projects[0];
    assert_eq!(api.key, "~/src/api");
    assert_eq!(api.name, "api");
    let repo = api.repo.as_ref().unwrap();
    assert_eq!(repo.url.as_deref(), Some("https://github.com/acme/api.git"));
    assert_eq!((repo.dirty_files, repo.unpushed_commits), (3, 2));
    assert_eq!(api.machine.setup, ["go mod download"]);
    assert_eq!(api.services, ["api-db-1 (postgres:16)"]);
    assert_eq!(api.ports, [5432]);

    let web = &plan.projects[1];
    assert_eq!(web.repo.as_ref().unwrap().branch.as_deref(), Some("feature/x"));
    assert_eq!(web.machine.setup, ["pnpm install --frozen-lockfile"]);
    assert!(web.notes.iter().any(|n| n.contains("devcontainer")));

    let scratch = plan.projects[2].repo.as_ref().unwrap();
    assert!(scratch.url.is_none() && scratch.branch.is_none() && scratch.commit.is_none());

    let w = plan.warnings.join("\n");
    assert!(w.contains("1 probe line"), "{w}");
    assert!(w.contains("~/scratch on devbox has no remote"), "{w}");
    assert!(w.contains("3 uncommitted file(s) and 2 unpushed"), "{w}");
    assert!(w.contains("more than a new machine's 16 GiB disk"), "{w}");
    assert!(w.contains("portainer (portainer/portainer-ce)"), "{w}");
    assert!(w.contains("syncthing.service"), "{w}");
    assert!(w.contains("port(s) 8080 "), "{w}");
    assert!(!w.contains("did not finish"), "{w}");
    assert_eq!(plan.unsupported.len(), 1);
    assert_eq!(plan.unsupported[0].what, "cron jobs");

    let kinds: Vec<CarryKind> = plan.carry.iter().map(|c| c.kind).collect();
    assert_eq!(kinds, [CarryKind::Shell, CarryKind::AgentSettings, CarryKind::AgentLogin]);

    let steps = plan.steps();
    assert!(
        steps.iter().any(|s| matches!(s, Step::CarryWorktree { path, .. } if path == "~/src/api"))
    );
    assert!(steps.iter().any(|s| matches!(s, Step::CarrySecretFiles { paths } if paths == &["~/.claude/.credentials.json"])));
}

#[test]
fn a_cut_off_probe_says_so() {
    let plan = plan("h", r#"{"t":"os","os":"Darwin","arch":"arm64"}"#);
    let w = plan.warnings.join("\n");
    assert!(w.contains("did not finish") && w.contains("is a Mac"), "{w}");
}

#[test]
fn docker_host_ports() {
    assert_eq!(host_ports("0.0.0.0:80->80/tcp, :::80->80/tcp, 0.0.0.0:443->8443/tcp"), [80, 443]);
    assert!(host_ports("6379/tcp").is_empty());
}

#[test]
fn ssh_config_hosts_skip_wildcards() {
    let text = "\
# work
Host devbox devbox-2
  HostName 10.0.0.2
Host *
  ForwardAgent no
Host=gpu.example.com # the big one
host !bastion jump?? prod
Match host foo
  User me
Host devbox
";
    assert_eq!(ssh_config_hosts(text), ["devbox", "devbox-2", "gpu.example.com", "prod"]);
}

fn git(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    assert!(ok, "git {args:?}");
}

fn has(cmd: &str) -> bool {
    Command::new(cmd).arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok()
}

#[test]
fn probe_parses_as_sh() {
    if !Path::new("/bin/sh").exists() {
        return;
    }
    let mut child = Command::new("/bin/sh").arg("-n").stdin(Stdio::piped()).spawn().unwrap();
    std::io::Write::write_all(child.stdin.as_mut().unwrap(), PROBE.as_bytes()).unwrap();
    assert!(child.wait().unwrap().success());
}

/// The probe, run for real against a made-up home: it finds the checkout, strips the remote's
/// token, sizes the login without printing it, and its output reads into a plan.
#[test]
fn probe_runs_against_a_temp_home() {
    if !Path::new("/bin/sh").exists() || !has("git") {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let repo = home.path().join("code/app");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("package-lock.json"), "{}").unwrap();
    std::fs::write(repo.join("Cargo.lock"), "").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "one"]);
    git(&repo, &["remote", "add", "origin", "https://me:SECRET-in-url@example.com/me/app.git"]);
    std::fs::write(repo.join("wip \"quoted\"\\name"), "x").unwrap();
    std::fs::create_dir_all(home.path().join(".claude")).unwrap();
    std::fs::write(home.path().join(".claude/.credentials.json"), "SECRET-login-token").unwrap();
    std::fs::write(home.path().join(".zshrc"), "export SECRET_RC=1\n").unwrap();

    let mut child = Command::new("/bin/sh")
        .arg("-s")
        .env_clear()
        .env("HOME", home.path())
        // A plain PATH: no agent shims in front of find.
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    std::io::Write::write_all(child.stdin.as_mut().unwrap(), PROBE.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(!text.contains("SECRET"), "{text}");
    for line in text.lines() {
        serde_json::from_str::<Value>(line).unwrap_or_else(|e| panic!("{e}: {line}"));
    }

    let plan = plan("tmp", &text);
    assert!(
        !plan.warnings.iter().any(|w| w.contains("not readable") || w.contains("did not finish")),
        "{:?}",
        plan.warnings
    );
    let app = plan.projects.iter().find(|p| p.key == "~/code/app").expect("the checkout");
    let r = app.repo.as_ref().unwrap();
    assert_eq!(r.url.as_deref(), Some("https://example.com/me/app.git"));
    assert_eq!(r.dirty_files, 1);
    assert_eq!(r.commit.as_ref().map(String::len), Some(40));
    assert_eq!(app.machine.setup, ["npm ci", "cargo fetch"]);
    assert!(plan.carry.iter().any(|c| c.kind == CarryKind::AgentLogin && c.bytes > 0));
    assert!(plan.carry.iter().any(|c| c.kind == CarryKind::Shell));
}
