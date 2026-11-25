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
        Ok(String::new())
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
    fn work_patch(&self, _checkout: &str) -> Result<WorkPatch, String> {
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
        patch: WorkPatch { commits: String::new(), work: "diff --git a/x b/x\n".into() },
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
    assert_eq!(entry.done, ["create-machine", "carry-worktree", "deliver-secrets", "move-chats"]);
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
