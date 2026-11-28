use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_each_verb() {
    assert_eq!(
        parse(&words("plan ssh:box --out p.json")).unwrap(),
        Command::Plan { source: "ssh:box".into(), out: Some("p.json".into()), preview: false }
    );
    assert_eq!(
        parse(&words("plan gitpod ./app")).unwrap(),
        Command::Plan { source: "gitpod:./app".into(), out: None, preview: false }
    );
    assert_eq!(
        parse(&words("plan laptop --out p.json --preview")).unwrap(),
        Command::Plan { source: "laptop".into(), out: Some("p.json".into()), preview: true }
    );
    assert_eq!(
        parse(&words("apply plan.json --only a --only b --headless --backend dev")).unwrap(),
        Command::Apply {
            from: "plan.json".into(),
            only: vec!["a".into(), "b".into()],
            dry_run: false,
            headless: Some("dev".into())
        }
    );
    assert!(parse(&words("apply x --backend dev")).is_err());
    assert!(parse(&words("undo laptop:mac")).unwrap_err().contains("--yes"));
    assert_eq!(
        parse(&words("undo laptop:mac --yes")).unwrap(),
        Command::Undo { source_id: "laptop:mac".into() }
    );
    assert!(parse(&words("plan")).is_err());
    assert!(parse(&words("plan a b")).is_err());
}

#[test]
fn product_names_and_routes() {
    assert_eq!(product_named("exe.dev"), Some(Product::ExeDev));
    assert_eq!(product_named("Ona"), Some(Product::Gitpod));
    assert_eq!(product_named("devin"), Some(Product::Devin));
    assert_eq!(product_named("./app"), None);
    assert_eq!(route_json(Product::Devin)["route"], "unsupported");
    assert_eq!(route_json(Product::Coder)["route"], "ssh-host");
}

#[test]
fn a_kept_journey_gives_machine_checkout_and_time_to_first_reply() {
    let journey = json!({"steps": [
        {"step": "sign in", "status": "pass", "ms": 500, "detail": ""},
        {"step": "create machine", "status": "pass", "ms": 4000, "detail": "m-abc status running"},
        {"step": "clone repo", "status": "pass", "ms": 3000, "detail": "acme/app at 1a2b in /home/cmux/work/app"},
        {"step": "reply", "status": "pass", "ms": 2500, "detail": "Earth"},
        {"step": "delete", "status": "skip", "ms": 0, "detail": "kept"},
    ]});
    let created = headless_created(&journey).unwrap();
    assert_eq!(created.machine_id, "m-abc");
    assert_eq!(created.checkout.as_deref(), Some("/home/cmux/work/app"));
    assert_eq!(created.first_chat_ms, Some(10_000));
    let failed = json!({"steps": [{"step": "clone repo", "status": "fail", "ms": 1, "detail": "needs GitHub"}]});
    assert_eq!(headless_created(&failed).unwrap_err(), "clone repo: needs GitHub");
}

struct Fake {
    calls: Vec<Vec<String>>,
    answers: Vec<Value>,
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.calls.push(args.to_vec());
        let answer = if self.answers.is_empty() { json!({}) } else { self.answers.remove(0) };
        Ran {
            code: 0,
            stdout: json!({"ok": true, "result": answer}).to_string(),
            stderr: String::new(),
        }
    }
    fn pause(&mut self, _: Duration) {}
    fn now(&mut self) -> Instant {
        Instant::now()
    }
    fn fresh_name(&mut self) -> String {
        "fresh".into()
    }
}

#[test]
fn the_app_route_runs_the_cloud_verbs() {
    let mut cloud = AppCloud {
        runner: Fake {
            calls: vec![],
            answers: vec![
                json!({"pending": true}),
                json!({"machines": [{"title": "app", "machine_id": "m9"}]}),
                json!({"missing": ["B"]}),
            ],
        },
    };
    let made =
        cloud.create_machine("app", Some("https://github.com/acme/app"), "version = 1\n").unwrap();
    assert_eq!(made.machine_id, "m9");
    let first = &cloud.runner.calls[0];
    assert_eq!(&first[..3], ["cloud", "new-machine", "--name"]);
    assert!(first.windows(2).any(|w| w[0] == "--repo" && w[1] == "https://github.com/acme/app"));
    assert_eq!(first.last().unwrap(), "--json");
    assert_eq!(cloud.deliver_secrets("m9", &["A".into(), "B".into()]).unwrap(), ["B"]);
    // A big file goes in chunks under the argument limit, joined on the machine.
    let big = "x".repeat(WRITE_CHUNK * 2 + 10);
    cloud.write_file("m9", "/home/cmux/f", &big).unwrap();
    let writes: Vec<_> = cloud.runner.calls.iter().filter(|c| c[1] == "file-write").collect();
    assert_eq!(writes.len(), 3);
    // The text never rides in argv (`ps` shows it): it goes through a file `--contents-file` reads.
    assert!(writes.iter().all(|c| c.iter().all(|w| w.len() < 4096 && w != "--contents")));
    assert!(writes.iter().all(|c| c.iter().any(|w| w == "--contents-file")));
    let joined = cloud.runner.calls.last().unwrap();
    // Quoted as `cloud_start_chat::shell_quote` quotes it (a plain path goes bare).
    let to = format!("> {}", shell_quote("/home/cmux/f"));
    assert!(joined.iter().any(|w| w.starts_with("cat ") && w.contains(&to)));
}

#[test]
fn the_headless_journey_keeps_only_when_asked() {
    let (out, config) = (Path::new("/tmp/o"), Path::new("/tmp/o/machine.toml"));
    let ci = headless_journey_args("staging", "https://github.com/a/b", out, config, false, None);
    assert!(!ci.iter().any(|w| w == "--keep"), "{ci:?}");
    let person =
        headless_journey_args("prod", "https://github.com/a/b", out, config, true, Some("s"));
    assert_eq!(person.iter().filter(|w| *w == "--keep").count(), 1, "{person:?}");
    assert!(person.windows(2).any(|w| w[0] == "--model-stub" && w[1] == "s"));
    assert!(person.windows(2).any(|w| w[0] == "--machine-config" && w[1] == "/tmp/o/machine.toml"));
}

/// The JSON the app's Move this Mac to AutoCloud card reads from this CLI: `plan --preview
/// --json`'s answer, an apply's `--json` event line and its answer. The app's Swift test
/// (`MoveToAutoCloudImportTests.theCLIsJSONDecodes`) decodes this same file, so a field renamed
/// here fails there. `CMUX_UPDATE_MIGRATE_GOLDEN=1` rewrites it.
#[test]
fn the_move_card_json_matches_its_golden() {
    use cmux_migrate::ledger::Stage;
    use cmux_migrate::plan::Unsupported;
    use cmux_migrate::{Carry, CarryKind, Project, Source, SourceKind};

    let mut plan = Plan::new(Source {
        kind: SourceKind::Laptop,
        label: "this Mac".into(),
        id: "laptop:mac".into(),
    });
    for name in ["old", "app", "web"] {
        plan.projects.push(Project {
            key: format!("~/code/{name}"),
            name: name.into(),
            checked: true,
            ..Project::default()
        });
    }
    plan.carry.push(Carry {
        kind: CarryKind::Shell,
        path: "~/.zshrc".into(),
        bytes: 0,
        agent: None,
        checked: true,
    });
    plan.warnings.push("web has uncommitted changes: they come along as a patch".into());
    plan.unsupported.push(Unsupported { what: "Docker volumes".into(), why: "not copied".into() });
    let mut before = Ledger::new();
    before.entry_mut("laptop:mac", "~/code/old").stage = Stage::Done;
    let mut after = before.clone();
    after.entry_mut("laptop:mac", "~/code/app").stage = Stage::Done;
    after.entry_mut("laptop:mac", "~/code/web").stage = Stage::Done;
    let event = event_json(
        &Event::Done {
            step: "create-machine".into(),
            project: "~/code/app".into(),
            detail: "machine m1 (/home/cmux/work/app)".into(),
        },
        Some(preview::progress(1, 4)),
    );
    let failed = event_json(
        &Event::Failed {
            step: "create-machine".into(),
            project: "~/code/app".into(),
            error: "not signed in".into(),
        },
        Some(preview::progress(1, 4)),
    );
    let golden = json!({
        "preview": preview_answer(&Preview::of(&plan, &before)),
        "apply_event": event,
        "apply_answer": finish_answer(&[event.clone()], 0, Some(9000), Some(Applied::of(&plan, &before, &after))),
        "apply_failed": finish_answer(&[failed], 1, None, Some(Applied::of(&plan, &before, &before))),
    });
    let text = format!("{}\n", serde_json::to_string_pretty(&golden).unwrap());
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/migrate_move_card.json");
    if std::env::var("CMUX_UPDATE_MIGRATE_GOLDEN").is_ok_and(|v| v == "1") {
        std::fs::write(&path, &text).unwrap();
    }
    let kept = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(kept, text, "{} is stale: rerun with CMUX_UPDATE_MIGRATE_GOLDEN=1", path.display());
}
