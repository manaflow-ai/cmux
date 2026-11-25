use super::*;
use crate::ledger::{Ledger, Stage};

fn sample() -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::Laptop,
        label: "this Mac".into(),
        id: "laptop:abc".into(),
    });
    let mut machine = MachineConfig::default();
    machine.setup.push("bun install".into());
    machine.secret_names.insert("DATABASE_URL".into());
    machine.env.insert("NODE_ENV".into(), "development".into());
    plan.projects.push(Project {
        key: "/Users/me/web".into(),
        name: machine_name("My Web App!"),
        repo: Some(Repo {
            url: Some(strip_login("https://me:ghp_x@github.com/me/web.git")),
            path: Some("/Users/me/web".into()),
            dirty_files: 2,
            ..Repo::default()
        }),
        machine,
        checked: true,
        ..Project::default()
    });
    plan.projects.push(Project {
        key: "/Users/me/skip".into(),
        name: "skip".into(),
        checked: false,
        ..Project::default()
    });
    plan.carry.push(Carry {
        kind: CarryKind::Shell,
        path: "~/.zshrc".into(),
        bytes: 10,
        agent: None,
        checked: true,
    });
    plan.carry.push(Carry {
        kind: CarryKind::AgentLogin,
        path: "~/.codex/auth.json".into(),
        bytes: 10,
        agent: Some(Agent::Codex),
        checked: true,
    });
    plan
}

#[test]
fn names_and_urls_are_safe() {
    assert_eq!(machine_name("My Web App!"), "my-web-app");
    assert_eq!(machine_name("--"), "project");
    assert_eq!(machine_name(&"a".repeat(60)).len(), 40);
    assert_eq!(strip_login("https://me:tok@github.com/a/b.git"), "https://github.com/a/b.git");
    assert_eq!(strip_login("git@github.com:a/b.git"), "git@github.com:a/b.git");
}

#[test]
fn steps_cover_checked_projects_and_split_secret_carry() {
    let steps = sample().steps();
    let kinds: Vec<String> = steps
        .iter()
        .map(|s| serde_json::to_value(s).unwrap()["step"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        kinds,
        [
            "create-machine",
            "carry-worktree",
            "deliver-secrets",
            "carry-files",
            "carry-secret-files"
        ]
    );
    let Step::CreateMachine { repo, machine_toml, .. } = &steps[0] else { panic!() };
    assert_eq!(repo.as_deref(), Some("https://github.com/me/web.git"));
    let parsed: toml::Table = machine_toml.parse().unwrap();
    assert_eq!(parsed["version"].as_integer(), Some(1));
    assert!(parsed["setup"]["run"][0].as_str().unwrap().ends_with("; bun install"));
    assert_eq!(parsed["secrets"]["names"][0].as_str(), Some("DATABASE_URL"));
    assert_eq!(parsed["env"]["NODE_ENV"].as_str(), Some("development"));
}

#[test]
fn plan_round_trips_as_json() {
    let plan = sample();
    let json = serde_json::to_string(&plan).unwrap();
    assert_eq!(serde_json::from_str::<Plan>(&json).unwrap(), plan);
}

#[test]
fn ledger_resumes_undoes_and_counts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.json");
    let mut ledger = Ledger::new();
    let entry = ledger.entry_mut("laptop:abc", "/Users/me/web");
    entry.machine_id = Some("m-1".into());
    entry.done.push("create-machine".into());
    entry.started_ms = Some(1_000);
    entry.first_chat_ms = Some(61_000);
    entry.stage = Stage::Done;
    ledger.entry_mut("laptop:abc", "/Users/me/other").stage = Stage::Failed;
    ledger.save(&path).unwrap();
    let crate::ledger::Load::Ledger(loaded) = Ledger::load(&path) else { panic!() };
    assert!(loaded.is_done("laptop:abc", "/Users/me/web", "create-machine"));
    assert!(!loaded.is_done("laptop:abc", "/Users/me/web", "deliver-secrets"));
    let undo = loaded.undo_steps("laptop:abc");
    assert_eq!(undo.len(), 1);
    assert_eq!(undo[0].machine_id, "m-1");
    let stats = loaded.stats();
    assert_eq!((stats.attempted, stats.done, stats.median_first_chat_ms), (2, 1, Some(60_000)));
}
