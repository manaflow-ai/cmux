//! The session-move matrix: one chat carrying every payload a person expects to survive a
//! move (history with an image, model, effort, mode, allow rules, queue, draft, an unsent
//! composer, a hibernated agent) moves between two real daemons through `acpmux session move`,
//! and each payload is checked on the target. Every cell is checked before any assertion, so
//! one run names all the red cells (`MATRIX <harness> <payload> green|red: why`).
use super::session_move::prompt;
use super::*;

/// The smallest PNG: a 1x1 transparent pixel.
const PNG_B64: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

impl Rpc {
    /// `call`, answering the error instead of failing the test.
    pub(super) async fn try_call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.expect("send");
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .expect("read")
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).expect("json line");
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    /// Each record's kind, in log order, without the move's own records.
    /// The rules the chat's log last recorded (`_acpmux/set_rules` logs `mux/rules`).
    async fn rules(&mut self, id: &str) -> Value {
        let page = self
            .call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
            .await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .rev()
            .find(|e| e["kind"] == "rules")
            .map(|e| e["msg"]["rules"].clone())
            .unwrap_or(Value::Null)
    }

    async fn kinds(&mut self, id: &str) -> Vec<String> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
            .await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                format!("{}/{}", e["dir"].as_str().unwrap_or(""), e["kind"].as_str().unwrap_or(""))
            })
            .collect()
    }
}

struct Cells {
    harness: &'static str,
    red: Vec<String>,
}

impl Cells {
    fn check(&mut self, payload: &str, green: bool, why: impl std::fmt::Display) {
        let verdict = if green { "green" } else { "red" };
        eprintln!("MATRIX {} {payload} {verdict}: {why}", self.harness);
        if !green {
            self.red.push(format!("{payload}: {why}"));
        }
    }
}

/// The values a person set: model, effort and mode as `_acpmux/info` reports them, and the
/// allow rules as the chat's log last recorded them.
fn chosen(info: &Value, rules: &Value) -> Value {
    let option = |id: &str| {
        info["configOptions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|o| o["id"] == id)
            .map(|o| o["currentValue"].clone())
            .unwrap_or(Value::Null)
    };
    json!({
        "model": info.pointer("/models/currentModelId").cloned().unwrap_or_else(|| option("model")),
        "effort": option("effort"),
        "mode": info.get("currentModeId").cloned().unwrap_or(Value::Null),
        "rules": rules.clone(),
    })
}

async fn move_matrix(harness: &'static str, harness_env: Value, mode: &str, hibernate: bool) {
    let tag = format!("mx-{harness}{}", if hibernate { "-h" } else { "" });
    // Under the ask policy a client other than the app may pick a mode and rules that ask.
    let target = Daemon::with_env(&format!("{tag}-t"), None, harness_env.clone(), &[], "ask").await;
    let idle: &[(&str, &str)] = if hibernate { &[("ACPMUX_IDLE_CHILD_SECS", "1")] } else { &[] };
    let mut harness_env = harness_env;
    let pids = std::env::temp_dir().join(format!("amx-{tag}-pids-{}", std::process::id()));
    let _ = std::fs::remove_file(&pids);
    harness_env["FAKE_CLASS_LOG"] = json!(pids);
    let source =
        Daemon::with_env(&format!("{tag}-s"), Some(&target), harness_env, idle, "ask").await;
    let mut cells = Cells { harness, red: Vec::new() };
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let id = id.as_str();

    // History: a reply, and a prompt with an image.
    src.call("session/prompt", prompt(id, "p-hi", "hi")).await;
    let image = json!({"sessionId": id, "prompt": [
        {"type": "text", "text": "look"},
        {"type": "image", "mimeType": "image/png", "data": PNG_B64}],
        "_meta": {"acpmux": {"promptId": "p-img"}}});
    src.call("session/prompt", image).await;
    let image_id = {
        use base64::Engine;
        use sha2::Digest;
        let bytes = base64::engine::general_purpose::STANDARD.decode(PNG_B64).unwrap();
        format!("{:x}", sha2::Sha256::digest(&bytes))
    };
    assert!(
        src.try_call("_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await.is_ok(),
        "the source keeps the image"
    );

    // Model, effort, mode and allow rules, as the person picked them.
    let picks = [
        ("session/set_model", json!({"sessionId": id, "modelId": "opus"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "effort", "value": "low"}),
        ),
        ("session/set_mode", json!({"sessionId": id, "modeId": mode})),
        (
            "_acpmux/set_rules",
            json!({"sessionId": id, "rules": {"autoDeny": ["delete"], "ask": ["execute"], "default": "ask"}}),
        ),
    ];
    for (method, params) in picks {
        if let Err(e) = src.try_call(method, params).await {
            eprintln!("MATRIX {harness} setup {method} refused: {e}");
        }
    }
    let before =
        chosen(&src.call("_acpmux/info", json!({"sessionId": id})).await, &src.rules(id).await);
    eprintln!("MATRIX {harness} chosen on source: {before}");

    // Unsent words: the draft and a composer.
    src.call("_acpmux/draft_set", json!({"sessionId": id, "text": "unsent words"})).await;
    let composer = src
        .try_call("_acpmux/composer_set", json!({"sessionId": id, "surface": {"id": "main", "name": "Main"}, "text": "half typed"}))
        .await;
    eprintln!("MATRIX {harness} composer_set on source: {composer:?}");
    let composers_before = src.try_call("_acpmux/composers", json!({"sessionId": id})).await;

    let history_before = src.kinds(id).await;
    let replies_before = src.texts(id, "agent_message_chunk").await;

    if hibernate {
        // The agent goes after a second idle: the move takes a hibernated chat.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            // Its agent's process is gone: the fake agent logs its pid when the chat starts.
            let log = std::fs::read_to_string(&pids).unwrap_or_default();
            let gone = !log.is_empty()
                && log.lines().all(|line| {
                    let pid = serde_json::from_str::<Value>(line).unwrap()["pid"].as_u64().unwrap();
                    !Path::new(&format!("/proc/{pid}")).exists()
                });
            if gone {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "never hibernated: {log}");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    } else {
        // A running turn and two queued prompts.
        src.send_prompt(id, "p-turn", "until-cancel").await;
        src.notification("session/update", |p| p["update"]["content"]["text"] == "running").await;
        for (prompt_id, text) in [("p-a", "a"), ("p-b", "b")] {
            src.send_prompt(id, prompt_id, text).await;
            src.notification("_acpmux/prompt_accepted", |p| {
                p["promptId"] == prompt_id && p["queued"] == true
            })
            .await;
        }
    }

    eprintln!("DIAG peers before: {}", src.call("_acpmux/peers", json!({})).await);
    let destination = target.home.join("arrived");
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target", "--interrupt", "--cwd"])
        .arg(&destination)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let started = std::time::Instant::now();
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    let took = started.elapsed();
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    cells.check("moved", receipt["moves"][0]["moved"] == true, format!("{took:?} {receipt}"));

    let mut dst = Rpc::connect(&target.socket).await;
    let ready = dst
        .call(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["ready"], "all": true, "timeoutMs": 20000}),
        )
        .await;
    cells.check("settled", ready["timedOut"] == false, &ready);

    let history_after = dst.kinds(id).await;
    let carried = history_after.len() >= history_before.len()
        && history_after[..history_before.len()] == history_before[..];
    cells.check(
        "history",
        carried,
        format!("{} records before, {} after", history_before.len(), history_after.len()),
    );
    let replies_after = dst.texts(id, "agent_message_chunk").await;
    cells.check(
        "replies",
        replies_after.len() >= replies_before.len()
            && replies_after[..replies_before.len()] == replies_before[..],
        format!("{replies_before:?} -> {replies_after:?}"),
    );
    let image = dst.try_call("_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await;
    cells.check("image-in-history", image.is_ok(), format!("{:?}", image.as_ref().err()));

    let after =
        chosen(&dst.call("_acpmux/info", json!({"sessionId": id})).await, &dst.rules(id).await);
    for key in ["model", "effort", "mode", "rules"] {
        cells.check(
            key,
            !before[key].is_null() && before[key] == after[key],
            format!("{} -> {}", before[key], after[key]),
        );
    }

    let draft = dst.call("_acpmux/draft_get", json!({"sessionId": id})).await;
    cells.check("draft", draft["draft"] == "unsent words", &draft);
    let composers_after = dst.try_call("_acpmux/composers", json!({"sessionId": id})).await;
    cells.check(
        "composer",
        composers_before
            .as_ref()
            .is_ok_and(|c| c["composers"].as_array().is_some_and(|a| !a.is_empty()))
            && composers_before.as_ref().ok().map(|c| &c["composers"])
                == composers_after.as_ref().ok().map(|c| &c["composers"]),
        format!("{composers_before:?} -> {composers_after:?}"),
    );

    if !hibernate {
        let prompts = dst.texts(id, "user_message").await;
        cells.check(
            "queue",
            prompts.len() >= 2 && prompts[prompts.len() - 2..] == ["a", "b"],
            format!("{prompts:?}"),
        );
    } else {
        // A hibernated chat answers on the target: its agent resumes from the carried store.
        let answer = dst.try_call("session/prompt", prompt(id, "p-wake", "after")).await;
        let replies = dst.texts(id, "agent_message_chunk").await;
        cells.check(
            "hibernated-resume",
            answer.is_ok() && replies.len() > replies_before.len(),
            format!("{answer:?}"),
        );
    }
    assert!(cells.red.is_empty(), "red cells for {harness}: {:#?}", cells.red);
}

#[tokio::test]
async fn a_claude_style_chat_moves_with_every_payload() {
    move_matrix(
        "claude",
        json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"}),
        "acceptEdits",
        false,
    )
    .await;
}

#[tokio::test]
async fn a_codex_style_chat_moves_with_every_payload() {
    move_matrix(
        "codex",
        json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "1", "FAKE_MODELS": "gpt-a,opus"}),
        "strict",
        false,
    )
    .await;
}

#[tokio::test]
async fn a_hibernated_claude_style_chat_moves_and_resumes() {
    move_matrix(
        "claude",
        json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"}),
        "acceptEdits",
        true,
    )
    .await;
}
