//! `skills-*` gates, the request shapes (`skill_id`, not the envelope's `id`) and the answers.

use std::fs;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::{BoundedOutbound, ClientTransport, QueuedSink};

fn connection(
    mux: &Arc<Mux>,
    transport: ClientTransport,
) -> (u64, Arc<BoundedOutbound>, MessageWriter) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    (client, outbound, writer)
}

fn reply_to(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    out: &BoundedOutbound,
    request: Value,
) -> Value {
    assert_eq!(try_handle(mux, client, &request.to_string(), writer), Some(true));
    serde_json::from_str(&out.try_pop().expect("reply")).unwrap()
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn env(name: &str) -> (Scratch, SkillsEnv) {
    let dir = std::env::temp_dir().join(format!("cmux-skills-wire-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let root = dir.canonicalize().unwrap();
    let home = root.join("home");
    let env = SkillsEnv {
        claude_dir: home.join(".claude"),
        codex_dir: home.join(".codex"),
        codex_admin: root.join("etc"),
        home,
    };
    (Scratch(dir), env)
}

fn command(line: Value) -> Command {
    serde_json::from_value(line).expect("parses")
}

#[test]
fn remote_connections_are_refused() {
    let mux = Mux::new_for_test("skills-gates", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::WebSocket);
    let reply = reply_to(&mux, client, &writer, &out, json!({"id": 1, "cmd": "skills-list"}));
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error_code"], "skills.not_trusted");
    assert_eq!(reply["id"], 1);
}

#[test]
fn the_skill_is_named_by_skill_id_and_the_envelope_id_is_the_request() {
    let mux = Mux::new_for_test("skills-shapes", SurfaceOptions::default());
    let (client, out, writer) = connection(&mux, ClientTransport::Unix);
    // `skill_id` names the skill: an unlisted one is not found, answered under the request's id.
    let set = json!({"cmd": "skills-set-enabled", "id": 7, "skill_id": "claude:/nowhere/SKILL.md", "enabled": false});
    let reply = reply_to(&mux, client, &writer, &out, set);
    assert_eq!(
        (reply["id"].clone(), reply["error_code"].clone()),
        (json!(7), json!("skills.not_found"))
    );
    let locate = json!({"cmd": "skills-locate", "id": 8, "skill_id": "codex:/nowhere/SKILL.md"});
    let reply = reply_to(&mux, client, &writer, &out, locate);
    assert_eq!(
        (reply["id"].clone(), reply["error_code"].clone()),
        (json!(8), json!("skills.not_found"))
    );
    // Without `skill_id` (the envelope's `id` is never the skill): a bad request.
    for line in [
        json!({"cmd": "skills-locate", "id": 9}),
        json!({"cmd": "skills-set-enabled", "id": 10, "enabled": true}),
        json!({"cmd": "skills-create", "id": 11, "harness": "claude"}),
    ] {
        let reply = reply_to(&mux, client, &writer, &out, line);
        assert_eq!(reply["error_code"], "skills.bad_request", "{reply}");
    }
}

#[test]
fn other_commands_are_left_to_the_next_handler() {
    let mux = Mux::new_for_test("skills-others", SurfaceOptions::default());
    let (client, _out, writer) = connection(&mux, ClientTransport::Unix);
    assert_eq!(
        try_handle(&mux, client, &json!({"id": 1, "cmd": "identify"}).to_string(), &writer),
        None
    );
    assert_eq!(
        try_handle(&mux, client, r#"{"id":2,"cmd":"apps-list","x":"skills-"}"#, &writer),
        None
    );
}

#[test]
fn list_toggle_locate_and_create_answer_through_the_wire_shapes() {
    let mux = Mux::new_for_test("skills-answers", SurfaceOptions::default());
    let (_scratch, env) = env("answers");
    let project = env.home.join("code/app");
    fs::create_dir_all(project.join(".git")).unwrap();
    let dir = env.claude_dir.join("skills/deploy");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), "---\nname: deploy\ndescription: Ship it\n---\n").unwrap();

    let list =
        answer(&mux, &env, command(json!({"cmd": "skills-list", "projects": [project]}))).unwrap();
    assert_eq!(list["projects"], json!([{"root": project, "name": "app"}]));
    let skill = &list["skills"][0];
    assert_eq!(skill["name"], "deploy");
    assert_eq!(skill["harness"], "claude");
    assert_eq!(skill["scope"], "user");
    assert_eq!(skill["toggle"], "skill");
    assert_eq!(skill["enabled"], true);
    let skill_id = skill["id"].as_str().unwrap().to_owned();

    let off = answer(
        &mux,
        &env,
        command(
            json!({"cmd": "skills-set-enabled", "id": 3, "skill_id": skill_id, "enabled": false}),
        ),
    )
    .unwrap();
    assert_eq!(off["skill"]["enabled"], false);
    let located =
        answer(&mux, &env, command(json!({"cmd": "skills-locate", "id": 4, "skill_id": skill_id})))
            .unwrap();
    assert_eq!(located["file"], json!(dir.join("SKILL.md")));
    assert_eq!(located["dir"], json!(dir));

    // A project the page listed (not one of this daemon's terminals) takes a new skill.
    let made = answer(
        &mux,
        &env,
        command(json!({
            "cmd": "skills-create", "id": 5, "harness": "codex", "scope": "project",
            "project": project, "name": "check", "description": "Run the checks",
        })),
    )
    .unwrap();
    assert_eq!(made["skill"]["file"], json!(project.join(".agents/skills/check/SKILL.md")));
    assert_eq!(made["skill"]["project"], json!(project));
}
