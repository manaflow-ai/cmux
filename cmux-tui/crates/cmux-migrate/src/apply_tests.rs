use std::collections::BTreeMap;

use super::*;
use crate::plan::{Agent, Carry, CarryKind, ChatRef, Project, Repo, Source, SourceKind};

#[derive(Default)]
struct FakeCloud {
    calls: Vec<String>,
    files: BTreeMap<String, String>,
    fail_create: bool,
    missing: Vec<String>,
    made: usize,
    /// An exec whose command contains this fails.
    fail_exec: Option<String>,
    headless: bool,
}

impl Cloud for FakeCloud {
    fn create_machine(
        &mut self,
        name: &str,
        repo: Option<&str>,
        toml: &str,
    ) -> Result<Created, String> {
        self.calls.push(format!("create {name} {} {}", repo.unwrap_or("-"), toml.lines().count()));
        if self.fail_create {
            return Err("no room".into());
        }
        self.made += 1;
        Ok(Created {
            machine_id: format!("m{}", self.made),
            checkout: None,
            first_chat_ms: Some(42_000),
        })
    }
    fn deliver_secrets(&mut self, machine: &str, names: &[String]) -> Result<Vec<String>, String> {
        self.calls.push(format!("secrets {machine} {}", names.join(",")));
        Ok(self.missing.clone())
    }
    fn write_file(&mut self, machine: &str, path: &str, text: &str) -> Result<(), String> {
        self.calls.push(format!("write {machine} {path}"));
        self.files.insert(format!("{machine}:{path}"), text.to_owned());
        Ok(())
    }
    fn exec(&mut self, machine: &str, command: &str) -> Result<String, String> {
        self.calls.push(format!("exec {machine} {command}"));
        if self.fail_exec.as_deref().is_some_and(|f| command.contains(f)) {
            return Err("exit 1: patch does not apply".into());
        }
        Ok(String::new())
    }
    fn carries_files(&self) -> bool {
        !self.headless
    }
    fn delete_machine(&mut self, machine: &str) -> Result<(), String> {
        self.calls.push(format!("delete {machine}"));
        Ok(())
    }
}

struct FakeLocal {
    files: BTreeMap<String, String>,
    patch: WorkPatch,
}

impl Local for FakeLocal {
    fn read_text(&self, path: &str, max: u64) -> Option<String> {
        self.files.get(path).filter(|t| t.len() as u64 <= max).cloned()
    }
    fn files(&self, path: &str) -> Vec<(String, u64)> {
        self.files
            .iter()
            .filter(|(p, _)| *p == path || p.starts_with(&format!("{path}/")))
            .map(|(p, t)| (p.clone(), t.len() as u64))
            .collect()
    }
    fn work_patch(&self, _: &Source, _: &str, _checkout: &str) -> Result<WorkPatch, String> {
        Ok(self.patch.clone())
    }
    fn now_ms(&self) -> i64 {
        1_000
    }
}

fn plan() -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::Laptop,
        label: "mac".into(),
        id: "laptop:mac".into(),
    });
    let mut machine = crate::plan::MachineConfig::default();
    machine.secret_names.insert("STRIPE_KEY".into());
    machine.setup.push("bun install".into());
    plan.projects.push(Project {
        key: "~/code/app".into(),
        name: "app".into(),
        repo: Some(Repo {
            url: Some("git@github.com:acme/app.git".into()),
            path: Some("~/code/app".into()),
            dirty_files: 2,
            ..Repo::default()
        }),
        machine,
        chats: vec![ChatRef {
            agent: Agent::Claude,
            path: "~/.claude/projects/-Users-me-code-app/abc.jsonl".into(),
        }],
        checked: true,
        ..Project::default()
    });
    plan.projects.push(Project {
        key: "~/code/off".into(),
        name: "off".into(),
        checked: false,
        ..Project::default()
    });
    for (kind, path) in [
        (CarryKind::Shell, "~/.zshrc"),
        (CarryKind::AgentSettings, "~/.claude"),
        (CarryKind::AgentLogin, "~/.claude/.credentials.json"),
    ] {
        plan.carry.push(Carry { kind, path: path.into(), bytes: 0, agent: None, checked: true });
    }
    plan
}

fn local() -> FakeLocal {
    let mut files = BTreeMap::new();
    files.insert("~/.zshrc".into(), "alias g=git\n".into());
    files.insert("~/.claude/settings.json".into(), "{}".into());
    files.insert("~/.claude/.credentials.json".into(), "TOKEN-VALUE".into());
    files.insert("~/.claude/projects/-Users-me-code-app/abc.jsonl".into(), "{\"m\":1}\n".into());
    FakeLocal {
        files,
        patch: WorkPatch { work: "diff --git a/x b/x\n".into(), ..WorkPatch::default() },
    }
}

#[test]
fn applies_every_checked_step_and_never_sends_a_login() {
    let (mut ledger, mut cloud, local) = (Ledger::new(), FakeCloud::default(), local());
    let mut events = Vec::new();
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |e| events.push(e.clone()));
    assert_eq!(out.failed, 0, "{events:?}");
    assert!(
        cloud.calls[0].starts_with("create app https://github.com/acme/app "),
        "{:?}",
        cloud.calls
    );
    assert!(!cloud.calls.iter().any(|c| c.contains("create off")));
    assert!(
        cloud.calls.iter().any(|c| c.contains("git apply") && c.contains("/home/cmux/work/app"))
    );
    assert!(cloud.calls.contains(&"secrets m1 STRIPE_KEY".to_owned()));
    assert!(
        cloud.files.contains_key("m1:/home/cmux/.claude/projects/-home-cmux-work-app/abc.jsonl")
    );
    assert!(cloud.files.contains_key("m1:/home/cmux/.zshrc"));
    assert!(cloud.files.contains_key("m1:/home/cmux/.claude/settings.json"));
    assert!(!cloud.files.values().any(|t| t.contains("TOKEN-VALUE")));
    let entry = ledger.entry("laptop:mac", "~/code/app").unwrap();
    assert_eq!(entry.machine_id.as_deref(), Some("m1"));
    assert_eq!(entry.first_chat_ms, Some(43_000));
    assert_eq!(
        entry.done,
        ["create-machine", "carry-worktree", "deliver-secrets", "move-chats", "carry-files"]
    );
    // Machine-wide carry is recorded on each machine's project, never as an entry that counts.
    assert!(ledger.entry("laptop:mac", MACHINE_WIDE).is_none());
    assert_eq!(ledger.stats().attempted, 1);
}

#[test]
fn a_rerun_makes_nothing_twice() {
    let (mut ledger, mut cloud, local) = (Ledger::new(), FakeCloud::default(), local());
    apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    let mut again = FakeCloud::default();
    let out = apply(&plan(), &[], &mut ledger, &mut again, &local, &mut |_| {});
    assert!(again.calls.is_empty(), "{:?}", again.calls);
    assert_eq!(out.done, 0);
}

#[test]
fn a_failed_create_skips_its_project_and_resumes_next_time() {
    let (mut ledger, local) = (Ledger::new(), local());
    let mut cloud = FakeCloud { fail_create: true, ..FakeCloud::default() };
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert_eq!(out.failed, 2, "create, and carry-files with no machine");
    assert_eq!(cloud.calls.len(), 1);
    assert_eq!(ledger.entry("laptop:mac", "~/code/app").unwrap().stage, Stage::Failed);
    let mut cloud = FakeCloud::default();
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert_eq!(out.failed, 0);
    assert_eq!(ledger.entry("laptop:mac", "~/code/app").unwrap().stage, Stage::Done);
}

#[test]
fn missing_secrets_are_named_not_failed() {
    let (mut ledger, local) = (Ledger::new(), local());
    let mut cloud = FakeCloud { missing: vec!["STRIPE_KEY".into()], ..FakeCloud::default() };
    let mut said = String::new();
    apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |e| {
        if let Event::Done { step, detail, .. } = e
            && step == "deliver-secrets"
        {
            said = detail.clone();
        }
    });
    assert!(said.contains("cmux cloud secret set NAME): STRIPE_KEY"), "{said}");
}

#[test]
fn undo_deletes_what_was_made() {
    let (mut ledger, mut cloud, local) = (Ledger::new(), FakeCloud::default(), local());
    apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    let out = undo("laptop:mac", &mut ledger, &mut cloud, &mut |_| {});
    assert_eq!(out.done, 1);
    assert!(cloud.calls.contains(&"delete m1".to_owned()));
    assert_eq!(ledger.entry("laptop:mac", "~/code/app").unwrap().stage, Stage::Undone);
}

#[test]
fn urls_paths_and_secret_files() {
    assert_eq!(https_clone_url("git@github.com:acme/app.git"), "https://github.com/acme/app");
    assert_eq!(https_clone_url("ssh://git@gitlab.com/a/b.git"), "https://gitlab.com/a/b");
    assert_eq!(https_clone_url("https://x:tok@github.com/a/b"), "https://github.com/a/b");
    assert_eq!(
        chat_destination("~/.codex/sessions/2026/a.jsonl", "/home/cmux/work/app"),
        "/home/cmux/.codex/sessions/2026/a.jsonl"
    );
    for secret in
        ["~/.ssh/id_ed25519", "~/.codex/auth.json", "~/.aws/credentials", "~/x/server.pem"]
    {
        assert!(is_secret_file(secret), "{secret}");
    }
    assert!(!is_secret_file("~/.ssh/config"));
}

#[test]
fn a_stale_machine_wide_entry_is_not_a_project() {
    let mut ledger = Ledger::new();
    ledger.entry_mut("laptop:mac", MACHINE_WIDE);
    ledger.entry_mut("laptop:mac", "~/code/app").stage = Stage::Done;
    let stats = ledger.stats();
    assert_eq!((stats.attempted, stats.done), (1, 1));
}

#[test]
fn files_reach_a_machine_a_later_run_makes() {
    let (mut ledger, local) = (Ledger::new(), local());
    let mut two = plan();
    two.projects[1].checked = true;
    two.projects[1].name = "off".into();
    let only_app = ["~/code/app".to_owned()];
    let mut cloud = FakeCloud::default();
    apply(&two, &only_app, &mut ledger, &mut cloud, &local, &mut |_| {});
    assert!(cloud.files.contains_key("m1:/home/cmux/.zshrc"));
    // The next run makes the second machine: the files go to it, and only to it.
    let mut cloud = FakeCloud { made: 1, ..FakeCloud::default() };
    apply(&two, &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert!(cloud.files.contains_key("m2:/home/cmux/.zshrc"), "{:?}", cloud.calls);
    assert!(!cloud.files.keys().any(|k| k.starts_with("m1:")), "{:?}", cloud.calls);
    // And a third run writes nothing.
    let mut cloud = FakeCloud { made: 2, ..FakeCloud::default() };
    apply(&two, &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert!(cloud.calls.is_empty(), "{:?}", cloud.calls);
}

#[test]
fn a_chat_folder_moves_as_its_transcripts() {
    let (mut ledger, mut cloud, mut local) = (Ledger::new(), FakeCloud::default(), local());
    local.files.clear();
    local
        .files
        .insert("~/.claude/projects/-Users-me-code-app/s1.jsonl".into(), "{\"m\":1}\n".into());
    local.files.insert(
        "~/.claude/projects/-Users-me-code-app/s1/subagents/a.jsonl".into(),
        "{\"m\":2}\n".into(),
    );
    local.files.insert("~/.claude/projects/-Users-me-code-app/notes.txt".into(), "x".into());
    let mut plan = plan();
    plan.carry.clear();
    plan.projects[0].chats = vec![ChatRef {
        agent: Agent::Claude,
        path: "~/.claude/projects/-Users-me-code-app".into(),
    }];
    let mut said = String::new();
    let out = apply(&plan, &[], &mut ledger, &mut cloud, &local, &mut |e| {
        if let Event::Done { step, detail, .. } = e
            && step == "move-chats"
        {
            said = detail.clone();
        }
    });
    assert_eq!(out.failed, 0);
    let to = "m1:/home/cmux/.claude/projects/-home-cmux-work-app";
    assert!(cloud.files.contains_key(&format!("{to}/s1.jsonl")), "{:?}", cloud.files.keys());
    assert!(cloud.files.contains_key(&format!("{to}/s1/subagents/a.jsonl")));
    assert!(!cloud.files.keys().any(|k| k.ends_with("notes.txt")));
    assert!(said.starts_with("2 chat histories"), "{said}");
}

#[test]
fn a_cursor_folder_without_transcripts_is_left_and_said() {
    let mut local = local();
    local.files.insert("~/Library/Cursor/ws1/state.vscdb".into(), "bin".into());
    assert_eq!(chat_files(&local, "~/Library/Cursor/ws1"), ["~/Library/Cursor/ws1"]);
    assert_eq!(chat_files(&local, "~/.zshrc"), ["~/.zshrc"]);
}

#[test]
fn local_work_lands_on_its_base_and_a_rerun_resumes_where_it_failed() {
    let (mut ledger, mut local) = (Ledger::new(), local());
    local.patch = WorkPatch {
        commits: "From abc\nSubject: [PATCH] one\n".into(),
        work: "diff --git a/x b/x\n".into(),
        base: Some("0123abcd".into()),
        branch: Some("feature/x".into()),
    };
    let mut cloud = FakeCloud { fail_exec: Some("git apply".into()), ..FakeCloud::default() };
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert_eq!(out.failed, 1, "{:?}", cloud.calls);
    let execs: Vec<&String> = cloud.calls.iter().filter(|c| c.starts_with("exec ")).collect();
    assert!(execs[0].contains("git checkout --quiet -B 'feature/x' '0123abcd'"), "{execs:?}");
    assert!(execs[0].contains("git fetch --quiet origin '0123abcd'"), "{execs:?}");
    assert!(execs[1].contains("git am --abort") && execs[1].contains(" am --3way"), "{execs:?}");
    let entry = ledger.entry("laptop:mac", "~/code/app").unwrap();
    assert!(entry.done.contains(&"carry-worktree:commits".to_owned()), "{:?}", entry.done);
    // The rerun neither checks out again nor re-applies the commits: only the work patch.
    let mut cloud = FakeCloud::default();
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {});
    assert_eq!(out.failed, 0, "{:?}", cloud.calls);
    let execs: Vec<&String> = cloud.calls.iter().filter(|c| c.starts_with("exec ")).collect();
    assert_eq!(execs.len(), 1, "{execs:?}");
    assert!(execs[0].contains("git apply"));
    let entry = ledger.entry("laptop:mac", "~/code/app").unwrap();
    assert!(entry.done.contains(&"carry-worktree".to_owned()));
    assert!(!entry.done.iter().any(|d| d.starts_with("carry-worktree:")), "{:?}", entry.done);
}

#[test]
fn the_headless_route_skips_carry_and_does_not_fail() {
    let (mut ledger, local) = (Ledger::new(), local());
    let mut cloud = FakeCloud { headless: true, ..FakeCloud::default() };
    let mut skipped = Vec::new();
    let out = apply(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |e| {
        if let Event::Skipped { step, .. } = e {
            skipped.push(step.clone());
        }
    });
    assert_eq!(out.failed, 0);
    for step in ["carry-worktree", "move-chats", "carry-files"] {
        assert!(skipped.iter().any(|s| s == step), "{step}: {skipped:?}");
    }
    assert!(!cloud.calls.iter().any(|c| c.starts_with("write ") || c.starts_with("exec ")));
    // Not recorded as done: a later run in the app carries it.
    assert!(!ledger.is_done("laptop:mac", "~/code/app", "carry-worktree"));
}

#[test]
fn remote_checkouts_are_read_on_the_source() {
    let ssh = Source { kind: SourceKind::SshHost, label: "box".into(), id: "ssh:me@box".into() };
    let PatchRoute::Remote { program, args } = patch_route(&ssh, "/srv/app") else {
        panic!("ssh reads remotely")
    };
    assert_eq!(program, "ssh");
    assert!(args.contains(&"me@box".to_owned()));
    let cs = Source { kind: SourceKind::Codespaces, label: "cs".into(), id: "codespaces".into() };
    let PatchRoute::Remote { args, .. } = patch_route(&cs, "fluffy-x") else { panic!() };
    assert_eq!(args[..4], ["codespace", "ssh", "-c", "fluffy-x"]);
    let coder = Source { kind: SourceKind::Coder, label: "Coder".into(), id: "coder".into() };
    assert!(matches!(patch_route(&coder, "a/b"), PatchRoute::Unsupported(_)));
    let mac = Source { kind: SourceKind::Laptop, label: "mac".into(), id: "laptop:mac".into() };
    assert_eq!(patch_route(&mac, "~/code/app"), PatchRoute::Local);
}

#[test]
fn an_unsupported_remote_skips_carry_worktree_with_a_note() {
    let (mut ledger, mut cloud, local) = (Ledger::new(), FakeCloud::default(), local());
    let mut plan = plan();
    plan.source =
        Source { kind: SourceKind::Daytona, label: "Daytona".into(), id: "daytona".into() };
    let mut why = String::new();
    let out = apply(&plan, &[], &mut ledger, &mut cloud, &local, &mut |e| {
        if let Event::Skipped { step, why: w, .. } = e
            && step == "carry-worktree"
        {
            why = w.clone();
        }
    });
    assert_eq!(out.failed, 0);
    assert!(why.contains("push it"), "{why}");
}

/// The script that reads a source's checkout, run here with sh against a real repo: branch,
/// base, unpushed commits and the working tree with an untracked file, the index untouched.
#[test]
fn the_work_patch_script_reads_a_checkout() {
    let run = |dir: &std::path::Path, args: &[&str]| {
        let out = std::process::Command::new("git")
            .current_dir(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let tmp = std::env::temp_dir().join(format!("cmux-migrate-wps-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let (origin, work) = (tmp.join("origin.git"), tmp.join("work"));
    std::fs::create_dir_all(&tmp).unwrap();
    run(&tmp, &["init", "--quiet", "--bare", origin.to_str().unwrap()]);
    run(&tmp, &["clone", "--quiet", origin.to_str().unwrap(), work.to_str().unwrap()]);
    std::fs::write(work.join("a.txt"), "one\n").unwrap();
    run(&work, &["add", "a.txt"]);
    run(&work, &["commit", "--quiet", "-m", "first"]);
    run(&work, &["push", "--quiet", "-u", "origin", "HEAD:main"]);
    let base = run(&work, &["rev-parse", "HEAD"]);
    std::fs::write(work.join("a.txt"), "two\n").unwrap();
    run(&work, &["commit", "--quiet", "-am", "second"]);
    std::fs::write(work.join("a.txt"), "three\n").unwrap();
    std::fs::write(work.join("new.txt"), "fresh\n").unwrap();
    let index_before = std::fs::read(work.join(".git/index")).unwrap();
    let mut child = std::process::Command::new("sh")
        .arg("-s")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write as _;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(remote_patch_script(work.to_str().unwrap()).as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let patch = parse_remote_patch(&String::from_utf8_lossy(&out.stdout)).unwrap();
    assert_eq!(patch.base.as_deref(), Some(base.as_str()));
    assert!(patch.branch.is_some());
    assert!(patch.commits.contains("Subject: [PATCH] second"), "{}", patch.commits);
    assert!(patch.work.contains("+three"), "{}", patch.work);
    assert!(patch.work.contains("b/new.txt") && patch.work.contains("+fresh"), "{}", patch.work);
    assert_eq!(std::fs::read(work.join(".git/index")).unwrap(), index_before);
    let _ = std::fs::remove_dir_all(&tmp);
    assert!(parse_remote_patch("cd: no such dir\n").is_err());
}

#[test]
fn the_ledger_is_handed_out_after_every_step_with_the_machine_id_first() {
    let (mut ledger, mut cloud, local) = (Ledger::new(), FakeCloud::default(), local());
    let mut seen: Vec<Ledger> = Vec::new();
    let out = apply_saving(&plan(), &[], &mut ledger, &mut cloud, &local, &mut |_| {}, &mut |l| {
        seen.push(l.clone());
    });
    let steps = out.done.saturating_add(out.skipped).saturating_add(out.failed);
    assert_eq!(seen.len(), steps);
    // The first checkpoint follows create-machine: a crash after it still knows the machine.
    let first = seen.first().and_then(|l| l.entry("laptop:mac", "~/code/app")).unwrap();
    assert_eq!(first.machine_id.as_deref(), Some("m1"));
    assert_eq!(first.done, ["create-machine"]);
    assert_eq!(seen.last(), Some(&ledger));
}
