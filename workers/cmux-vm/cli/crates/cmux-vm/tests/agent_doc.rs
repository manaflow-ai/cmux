//! Runs every `cmux machine …` (or old `cmux vm …`) command in the agent guide
//! (skills/cmux-cloud-vm/references/headless.md) against a local mock of the
//! cmux VM API, so a command the guide shows is one the CLI accepts and
//! finishes. `cmux machine` passes its words to this CLI after renaming `new`,
//! `ls` and `rm` (cmux-tui/crates/cmux-tui/src/cli/vm.rs); the guide's `VM_ID`
//! is the id `new` answered.

use cmux_vm::exit;
use serde_json::json;
use wiremock::matchers::{body_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

const GUIDE: &str = include_str!("../../../../../../skills/cmux-cloud-vm/references/headless.md");
/// The `cmux machine` wrapper whose verb renames [`cmux_vm_args`] repeats.
const WRAPPER: &str = include_str!("../../../../../../cmux-tui/crates/cmux-tui/src/cli/vm.rs");
const VM_ID: &str = "vm_0123456789abcdefghjkmnpqrs";
const KEY: &str = "cmuxvm_sk_test";

/// The words of each `cmux machine` or `cmux vm` line in the guide's sh blocks, as typed.
fn guide_commands() -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    let mut in_sh = false;
    for line in GUIDE.lines() {
        let line = line.trim();
        if line.starts_with("```") {
            in_sh = line == "```sh";
            continue;
        }
        if in_sh && (line.starts_with("cmux machine ") || line.starts_with("cmux vm ")) {
            commands.push(shell_words(line));
        }
    }
    commands
}

/// `line` split as a shell would, for the single quotes the guide uses.
fn shell_words(line: &str) -> Vec<String> {
    line.split('\'')
        .enumerate()
        .flat_map(|(index, part)| {
            if index % 2 == 1 {
                vec![part.to_owned()]
            } else {
                part.split_whitespace().map(str::to_owned).collect()
            }
        })
        .collect()
}

/// The `cmux-vm` arguments `cmux machine` runs for `words` (`cmux machine …`
/// or `cmux vm …`).
fn cmux_vm_args(words: &[String]) -> Vec<String> {
    assert!(
        words[..2] == ["cmux", "machine"] || words[..2] == ["cmux", "vm"],
        "{words:?}"
    );
    words[2..]
        .iter()
        .enumerate()
        .map(|(index, word)| match (index, word.as_str()) {
            (0, "new") => "create".to_owned(),
            (0, "ls") => "list".to_owned(),
            (0, "rm") => "delete".to_owned(),
            (_, "VM_ID") => VM_ID.to_owned(),
            _ => word.clone(),
        })
        .collect()
}

fn vm(state: &str) -> serde_json::Value {
    json!({
        "id": VM_ID,
        "displayName": "scratch",
        "labels": {},
        "state": state,
        "resources": { "vcpus": 2, "memoryMib": 4096, "diskMib": 16384 },
        "idleTimeoutSeconds": 300,
        "maxRunSeconds": null,
        "autoDeleteSeconds": null,
        "createdAt": "2026-10-30T00:00:00.000Z",
        "updatedAt": "2026-10-30T00:00:00.000Z"
    })
}

async fn mount(server: &MockServer, verb: &str, route: String, response: ResponseTemplate) {
    Mock::given(method(verb))
        .and(path(route))
        .and(header("authorization", format!("Bearer {KEY}").as_str()))
        .respond_with(response)
        .mount(server)
        .await;
}

/// A mock that answers only the request with this body, once.
async fn mount_body(
    server: &MockServer,
    route: String,
    body: serde_json::Value,
    response: ResponseTemplate,
) {
    Mock::given(method("POST"))
        .and(path(route))
        .and(header("authorization", format!("Bearer {KEY}").as_str()))
        .and(body_json(body))
        .respond_with(response)
        .expect(1)
        .mount(server)
        .await;
}

#[test]
fn the_wrapper_still_renames_the_verbs_the_guide_uses() {
    for arm in [
        r#""new" | "create" => ("create""#,
        r#""ls" | "list" => ("list""#,
        r#""rm" | "delete" => ("delete""#,
    ] {
        assert!(
            WRAPPER.contains(arm),
            "cli/vm.rs no longer has `{arm}`: update cmux_vm_args"
        );
    }
}

#[tokio::test]
async fn every_guide_command_runs_against_the_api() {
    let server = MockServer::start().await;
    let ok = |body| ResponseTemplate::new(200).set_body_json(body);
    mount(
        &server,
        "GET",
        "/v1/vms".into(),
        ok(json!({ "items": [vm("running")], "nextCursor": null })),
    )
    .await;
    Mock::given(method("POST"))
        .and(path("/v1/vms"))
        .and(header("authorization", format!("Bearer {KEY}").as_str()))
        .and(header("idempotency-key", "scratch-1"))
        .and(body_json(json!({ "displayName": "scratch" })))
        .respond_with(ResponseTemplate::new(201).set_body_json(vm("starting")))
        .expect(1)
        .mount(&server)
        .await;
    let exec = json!({ "exitCode": 0, "stdout": "Linux\n", "stderr": "" });
    let route = format!("/v1/vms/{VM_ID}/exec");
    mount_body(
        &server,
        route.clone(),
        json!({ "command": "uname -a" }),
        ok(exec.clone()),
    )
    .await;
    let long = json!({ "command": "cd /root && ls -la", "timeoutMs": 600000 });
    mount_body(&server, route, long, ok(exec)).await;
    mount(
        &server,
        "POST",
        format!("/v1/vms/{VM_ID}/pause"),
        ok(vm("paused")),
    )
    .await;
    mount(
        &server,
        "POST",
        format!("/v1/vms/{VM_ID}/resume"),
        ok(vm("running")),
    )
    .await;
    mount(
        &server,
        "DELETE",
        format!("/v1/vms/{VM_ID}"),
        ResponseTemplate::new(204),
    )
    .await;

    let commands = guide_commands();
    let verbs = commands
        .iter()
        .map(|words| cmux_vm_args(words)[0].clone())
        .collect::<Vec<_>>();
    for verb in ["list", "create", "exec", "pause", "resume", "delete"] {
        assert!(
            verbs.iter().any(|seen| seen == verb),
            "the guide never runs `{verb}`: {verbs:?}"
        );
    }
    let uri = server.uri();
    let env = move |name: &str| match name {
        "CMUX_VM_API_KEY" => Some(KEY.to_owned()),
        "CMUX_VM_BASE_URL" => Some(uri.clone()),
        "HOME" => Some("/nonexistent-cmux-vm-guide-home".to_owned()),
        _ => None,
    };
    for words in &commands {
        let args = cmux_vm_args(words);
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let argv = std::iter::once("cmux-vm".to_owned()).chain(args.iter().cloned());
        let code = cmux_vm::run(argv, &env, &mut cmux_vm::NoPrompt, &mut stdout, &mut stderr).await;
        assert_eq!(
            code,
            exit::OK,
            "`{}` failed: {}",
            words.join(" "),
            String::from_utf8_lossy(&stderr)
        );
    }
    let created = commands
        .iter()
        .find(|words| words[2] == "new")
        .expect("a new command");
    assert!(
        created.iter().any(|word| word == "--idempotency-key"),
        "the guide's `new` retries safely only with --idempotency-key"
    );
}

#[tokio::test]
async fn guide_commands_without_a_key_stop_at_the_key() {
    let env = |name: &str| (name == "HOME").then(|| "/nonexistent-cmux-vm-guide-home".to_owned());
    let words = guide_commands()
        .into_iter()
        .find(|words| words[2] == "ls")
        .expect("an ls command");
    let argv = std::iter::once("cmux-vm".to_owned()).chain(cmux_vm_args(&words));
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let code = cmux_vm::run(argv, &env, &mut cmux_vm::NoPrompt, &mut stdout, &mut stderr).await;
    assert_eq!(
        code,
        exit::UNAUTHENTICATED,
        "{}",
        String::from_utf8_lossy(&stderr)
    );
    assert!(
        GUIDE.contains("exits 11"),
        "the guide names the no-key exit code"
    );
}
