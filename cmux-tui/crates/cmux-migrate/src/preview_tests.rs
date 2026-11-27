use super::*;
use crate::plan::{Carry, CarryKind, Project, Source, SourceKind, Unsupported};

fn plan(projects: usize) -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::Laptop,
        label: "this Mac".into(),
        id: "laptop:mac".into(),
    });
    for i in 0..projects {
        plan.projects.push(Project {
            key: format!("/code/p{i}"),
            name: format!("p{i}"),
            checked: true,
            ..Project::default()
        });
    }
    plan
}

#[test]
fn counts_checked_projects_not_yet_moved() {
    let mut plan = plan(3);
    plan.projects[2].checked = false;
    let mut ledger = Ledger::new();
    ledger.entry_mut("laptop:mac", "/code/p0").stage = Stage::Done;
    ledger.entry_mut("laptop:mac", "/code/p1").stage = Stage::Failed;
    let preview = Preview::of(&plan, &ledger);
    assert_eq!((preview.moving, preview.already), (1, 1));
    assert_eq!(preview.names, ["p1"]);
    assert!(!preview.more);
}

#[test]
fn lists_at_most_listed_rows_and_cuts_long_text() {
    let mut plan = plan(LISTED + 2);
    plan.warnings.push("w".repeat(300));
    plan.unsupported.push(Unsupported { what: "Docker volumes".into(), why: "not copied".into() });
    plan.carry.push(Carry {
        kind: CarryKind::Shell,
        path: "~/.zshrc".into(),
        bytes: 0,
        agent: None,
        checked: true,
    });
    plan.carry.push(Carry {
        kind: CarryKind::Shell,
        path: "~/.bashrc".into(),
        bytes: 0,
        agent: None,
        checked: false,
    });
    let preview = Preview::of(&plan, &Ledger::new());
    assert_eq!(preview.moving, LISTED + 2);
    assert_eq!(preview.names.len(), LISTED);
    assert!(preview.more);
    assert_eq!(preview.carry, 1);
    assert_eq!(preview.warnings[0].chars().count(), WARNING_CHARS);
    assert_eq!(
        (preview.left, preview.left_rows.as_slice()),
        (1, &["Docker volumes: not copied".to_owned()][..])
    );
}

#[test]
fn an_empty_plan_moves_nothing() {
    assert_eq!(Preview::of(&plan(0), &Ledger::new()), Preview::default());
}
