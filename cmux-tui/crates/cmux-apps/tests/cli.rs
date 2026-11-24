//! `cmux app publish|versions|rollback|ls`: argument parsing and the `--json` answers.
mod common;

use std::path::PathBuf;

use cmux_apps::cli::{Command, parse, run};
use cmux_apps::slug::slugify;
use common::{HEAD, World};
use serde_json::Value;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_publish_with_every_flag() {
    let parsed = parse(&words(
        "publish invoice-triage --port 3000 --cmd=npm --dir site --ref main --include-dirty --share team --json",
    ))
    .unwrap();
    assert!(parsed.json);
    assert_eq!(
        parsed.command,
        Command::Publish {
            name: Some("invoice-triage".into()),
            port: Some(3000),
            cmd: Some("npm".into()),
            dir: Some(PathBuf::from("site")),
            git_ref: Some("main".into()),
            include_dirty: true,
            share_team: true,
        }
    );
}

#[test]
fn parses_versions_rollback_and_ls() {
    assert_eq!(
        parse(&words("versions web")).unwrap().command,
        Command::Versions { name: "web".into() }
    );
    assert_eq!(
        parse(&words("rollback web --to v2")).unwrap().command,
        Command::Rollback { name: "web".into(), to: Some(2) }
    );
    assert_eq!(
        parse(&words("rollback web --to 3")).unwrap().command,
        Command::Rollback { name: "web".into(), to: Some(3) }
    );
    assert_eq!(
        parse(&words("rollback web")).unwrap().command,
        Command::Rollback { name: "web".into(), to: None }
    );
    let ls = parse(&words("ls --json")).unwrap();
    assert_eq!((ls.command, ls.json), (Command::Ls, true));
}

#[test]
fn refuses_bad_arguments() {
    for line in [
        "publish --port nope",
        "publish --port 0",
        "publish --share alice",
        "publish --to 2",
        "publish a b",
        "publish --bogus",
        "versions",
        "rollback web --to vx",
        "rollback web --include-dirty",
        "ls extra",
        "deploy web",
    ] {
        assert!(parse(&words(line)).is_err(), "{line} parsed");
    }
    assert!(parse(&words("publish --port")).unwrap_err().contains("--port needs a value"));
}

#[test]
fn slugs_are_lowercase_with_single_dashes() {
    assert_eq!(slugify("Invoice Triage!!").as_deref(), Some("invoice-triage"));
    assert_eq!(slugify("--a__b--").as_deref(), Some("a-b"));
    assert_eq!(slugify(&"x".repeat(50)).unwrap().len(), 40);
    assert_eq!(slugify(&format!("{}-tail", "y".repeat(39))).as_deref(), Some(&*"y".repeat(39)));
    assert_eq!(slugify("!!!"), None);
}

fn json_of(stdout: &str) -> Value {
    serde_json::from_str(stdout.trim()).unwrap()
}

#[test]
fn publish_versions_and_ls_answer_json() {
    let world = World::new();
    let cwd = PathBuf::from("/work/web");
    let out = world.with(|host| {
        run(host, &parse(&words("publish web --cmd serve --json")).unwrap(), cwd.clone())
    });
    assert_eq!(out.code, 0, "{out:?}");
    let body = json_of(&out.stdout);
    assert_eq!(body["app"]["slug"], "web");
    assert_eq!(body["app"]["live"], 1);
    assert_eq!(body["version"]["n"], 1);
    assert_eq!(body["version"]["commit"], HEAD);
    assert_eq!(body["version"]["state"], "live");
    assert_eq!(body["url"], "https://a-web--team_abc.preview.example");

    world.with(|host| run(host, &parse(&words("publish web --cmd serve")).unwrap(), cwd.clone()));
    let out =
        world.with(|host| run(host, &parse(&words("versions web --json")).unwrap(), cwd.clone()));
    let body = json_of(&out.stdout);
    let ns: Vec<u64> =
        body["versions"].as_array().unwrap().iter().map(|v| v["n"].as_u64().unwrap()).collect();
    assert_eq!(ns, [2, 1]);
    assert_eq!(body["versions"][1]["state"], "retired");

    let out = world.with(|host| run(host, &parse(&words("ls --json")).unwrap(), cwd.clone()));
    let body = json_of(&out.stdout);
    assert_eq!(body["items"][0]["slug"], "web");
    assert_eq!(body["items"][0]["live"], 2);

    let out =
        world.with(|host| run(host, &parse(&words("rollback web --json")).unwrap(), cwd.clone()));
    assert_eq!(out.code, 0, "{out:?}");
    assert_eq!(json_of(&out.stdout)["version"]["n"], 1);
}

#[test]
fn a_failure_answers_a_json_error_and_exits_1() {
    let world = World::new();
    world.git.dirty.set(true);
    let out = world.with(|host| {
        run(
            host,
            &parse(&words("publish web --cmd serve --json")).unwrap(),
            PathBuf::from("/work/web"),
        )
    });
    assert_eq!(out.code, 1);
    let body = json_of(&out.stdout);
    assert_eq!(body["error"]["code"], "app.dirty");
    assert!(body["version"].is_null());
}

#[test]
fn publish_without_port_or_cmd_is_a_usage_refusal() {
    let world = World::new();
    let out = world
        .with(|host| run(host, &parse(&words("publish web")).unwrap(), PathBuf::from("/work/web")));
    assert_eq!(out.code, 2);
    assert!(out.stderr.contains("--port") && out.stderr.contains("--cmd"), "{}", out.stderr);
}

#[test]
fn human_output_names_the_url() {
    let world = World::new();
    let out = world.with(|host| {
        run(host, &parse(&words("publish web --cmd serve")).unwrap(), PathBuf::from("/work/web"))
    });
    assert_eq!(out.stdout, "published web v1: https://a-web--team_abc.preview.example\n");
}
