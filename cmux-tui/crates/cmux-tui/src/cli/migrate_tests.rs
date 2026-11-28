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
    assert!(joined.iter().any(|w| w.starts_with("cat ") && w.contains("> '/home/cmux/f'")));
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
