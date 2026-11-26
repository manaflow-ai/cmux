//! The session-move matrix: one chat carrying every payload a person expects to survive a
//! move (history with an image, model, effort, mode, allow rules, queue, draft, an unsent
//! composer, a hibernated agent) moves between two real daemons through `acpmux session move`,
//! and each payload is checked on the target. Every cell is checked before any assertion, so
//! one run names all the red cells (`MATRIX <harness> <payload> green|red: why`).
use super::session_move::prompt;
use super::*;

/// The person key both daemons get on `--person-key-fd`, as from the app's launcher.
const MATRIX_PERSON_KEY: &str = "6d617472697870657273306e6b65796d617472697870657273306e6b65793031";

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
    // Under the ask policy a client other than the app may pick a mode and rules that ask; a
    // mode that does not ask (`acceptEdits`) is the person's to pick, so each daemon holds the
    // person key as the app's launcher passes it, and the source's client proves it.
    let target = Daemon::with_person(
        &format!("{tag}-t"),
        None,
        harness_env.clone(),
        &[],
        "ask",
        MATRIX_PERSON_KEY,
    )
    .await;
    let idle: &[(&str, &str)] = if hibernate { &[("ACPMUX_IDLE_CHILD_SECS", "1")] } else { &[] };
    let mut harness_env = harness_env;
    let pids = std::env::temp_dir().join(format!("amx-{tag}-pids-{}", std::process::id()));
    let _ = std::fs::remove_file(&pids);
    harness_env["FAKE_CLASS_LOG"] = json!(pids);
    let source = Daemon::with_person(
        &format!("{tag}-s"),
        Some(&target),
        harness_env,
        idle,
        "ask",
        MATRIX_PERSON_KEY,
    )
    .await;
    let mut cells = Cells { harness, red: Vec::new() };
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect_person(&source.socket, MATRIX_PERSON_KEY).await;
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

    // Model, effort, mode and allow rules, as the person picked them. Each cell below checks
    // the picked value on both sides, so a pick the source refused is that cell's red, not a
    // start default that reads the same after the move.
    let rules = json!({"autoDeny": ["delete"], "ask": ["execute"], "default": "ask"});
    let picked = json!({"model": "opus", "effort": "low", "mode": mode, "rules": rules});
    let picks = [
        ("session/set_model", json!({"sessionId": id, "modelId": "opus"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "effort", "value": "low"}),
        ),
        ("session/set_mode", json!({"sessionId": id, "modeId": mode})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": rules})),
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
            before[key] == picked[key] && before[key] == after[key],
            format!("{} -> {} (picked {})", before[key], after[key], picked[key]),
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

// Rows 2 of RFD 0138 (cmuxterm-hq docs/rfd/0138-session-move.md, "Order of work"): the agent's
// own store (Codex's rollout, Claude's transcript with its subagents), and the move as the app
// drives it (`cmux link agent move` forwards `_acpmux/transfer_*`), not as `acpmux session move`.

/// The HOME of the daemon tagged `tag`: where its agent keeps `~/.codex` and `~/.claude`.
fn home_of(tag: &str) -> PathBuf {
    daemon_env::home(&Daemon::place(tag).0)
}

/// Every regular file under `root`, however deep.
fn files_under(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut todo = vec![root.to_owned()];
    while let Some(dir) = todo.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                todo.push(path);
            } else {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// `acpmux session move ID --machine target` as a person runs it.
async fn cli_move(source: &Daemon, id: &str, destination: &Path) -> Value {
    let mut command = daemon_env::tokio_command(&source.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target", "--interrupt", "--cwd"])
        .arg(destination)
        .env(
            "PATH",
            format!("{}:{}", source.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &source.home)
        .env("ACPMUX_SOCKET", &source.socket)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

/// The move as `cmux link agent move` (the app's Move to Cloud and Bring Back pump) makes it,
/// through each daemon's `agent-transfer-*` verbs, which forward these `_acpmux/transfer_*`
/// calls to acpmux as a local client (`cmux-tui-core/src/server/agent_transfer.rs`): begin on
/// the source (`interrupt`), a guarded receive on the target as Move to Cloud makes it
/// (`agent_transfer.rs` `guard_for`: `control: peer`, root `~/work`, the folder under it; the
/// `web` guard of Bring Back takes no Codex chat and no mode that does not ask), every bundle
/// file read page by page from the source
/// and written to the target, finish in the folder, commit on the source. `Err`: the step that
/// refused and why.
async fn gui_move(src: &mut Rpc, dst: &mut Rpc, id: &str, folder: &Path) -> Result<Value, String> {
    let step = |name: &'static str| move |e: Value| format!("{name}: {e}");
    let begun = src
        .try_call("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": true}))
        .await
        .map_err(step("begin"))?;
    let transfer_id = begun["transferId"].as_str().ok_or("begin named no transferId")?.to_owned();
    let epoch = begun.get("epoch").and_then(Value::as_u64).filter(|e| *e != 0);
    let with_epoch = |mut params: Value| {
        if let Some(epoch) = epoch {
            params["epoch"] = json!(epoch);
        }
        params
    };
    let moved = async {
        let guard = json!({"control": "peer", "roots": [folder.parent().ok_or("a folder with no parent")?]});
        let received = dst
            .try_call("_acpmux/transfer_receive", json!({"manifest": begun, "guard": guard}))
            .await
            .map_err(step("receive"))?;
        if received["guarded"] != true {
            return Err(format!("receive: not guarded: {received}"));
        }
        let receive_id = received["receiveId"].as_str().ok_or("receive named no receiveId")?;
        for file in begun["files"].as_array().into_iter().flatten() {
            let path = file["path"].as_str().ok_or("a file without a path")?;
            let mut offset = 0u64;
            loop {
                let read = with_epoch(
                    json!({"transferId": transfer_id, "path": path, "offset": offset, "limit": 1 << 20}),
                );
                let page = src.try_call("_acpmux/transfer_read", read).await.map_err(step("read"))?;
                let write = with_epoch(
                    json!({"receiveId": receive_id, "path": path, "offset": offset, "data": page["data"]}),
                );
                dst.try_call("_acpmux/transfer_write", write).await.map_err(step("write"))?;
                offset = page["next"].as_u64().ok_or("a page without next")?;
                if page["eof"] == true {
                    break;
                }
            }
        }
        let finish = with_epoch(json!({"receiveId": receive_id, "cwd": folder}));
        dst.try_call("_acpmux/transfer_finish", finish).await.map_err(step("finish"))
    }
    .await;
    match moved {
        Ok(landed) => {
            let commit = with_epoch(
                json!({"sessionId": id, "transferId": transfer_id, "to": {"machine": "target"}}),
            );
            src.try_call("_acpmux/transfer_commit", commit).await.map_err(step("commit"))?;
            Ok(landed)
        }
        Err(why) => {
            let abort = with_epoch(json!({"sessionId": id, "transferId": transfer_id}));
            let _ = src.try_call("_acpmux/transfer_abort", abort).await;
            Err(why)
        }
    }
}

/// How a Codex chat moves: through `acpmux session move` or as the app drives it.
#[derive(Clone, Copy)]
enum Way {
    Cli,
    Gui,
}

/// A Codex chat whose agent keeps Codex's own rollout store (`FAKE_CODEX_STORE`, one
/// `CODEX_HOME` per daemon) moves; its rollout must be on the target, and the agent there,
/// started from it, must hold the whole conversation (`history-probe` replies what the loaded
/// rollout holds).
async fn codex_store_moves(way: Way) {
    let tag = match way {
        Way::Cli => "mxcs",
        Way::Gui => "mxcg",
    };
    let env = |side: &str| {
        json!({"FAMILY": "codex", "FAKE_CODEX_STORE": "1",
               "CODEX_HOME": home_of(&format!("{tag}-{side}")).join(".codex")})
    };
    let target = Daemon::with_env(&format!("{tag}-t"), None, env("t"), &[], "ask").await;
    let source = Daemon::with_env(&format!("{tag}-s"), Some(&target), env("s"), &[], "ask").await;
    let mut cells = Cells { harness: "codex-store", red: Vec::new() };
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let id = id.as_str();
    for (prompt_id, text) in [("p-one", "one"), ("p-two", "two")] {
        src.call("session/prompt", prompt(id, prompt_id, text)).await;
    }
    let on_source = files_under(&home_of(&format!("{tag}-s")).join(".codex/sessions"));
    assert_eq!(on_source.len(), 1, "the agent keeps one rollout: {on_source:?}");
    // The turn's last records are written a moment after it answers.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let rollout = std::fs::read(&on_source[0]).unwrap();

    // Under the target's `~/work`, where Move to Cloud's guarded receive takes a folder.
    let destination = home_of(&format!("{tag}-t")).join("work/arrived");
    std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
    let mut dst = Rpc::connect(&target.socket).await;
    match way {
        Way::Cli => {
            let receipt = cli_move(&source, id, &destination).await;
            cells.check("moved", receipt["moves"][0]["moved"] == true, &receipt);
        }
        Way::Gui => {
            std::fs::create_dir_all(&destination).unwrap();
            let moved = gui_move(&mut src, &mut dst, id, &destination).await;
            cells.check("moved", moved.is_ok(), format!("{moved:?}"));
        }
    }

    let on_target = files_under(&home_of(&format!("{tag}-t")).join(".codex/sessions"));
    cells.check(
        "native-store",
        on_target.len() == 1 && std::fs::read(&on_target[0]).ok().as_deref() == Some(&rollout[..]),
        format!("{on_target:?}"),
    );
    // Moved as the app moves it (a `peer`-controlled receive), the target respawns the agent as
    // a remote launch, which takes a Codex chat only through the `codex app-server` bridge
    // (`web_modes::remote_start`). The fake agent speaks ACP, so it is refused there
    // (`remote.mode_not_asking`); the CLI row checks the resume from the moved store.
    if matches!(way, Way::Gui) {
        assert!(cells.red.is_empty(), "red cells for codex-store (gui): {:#?}", cells.red);
        return;
    }
    let answer = dst.try_call("session/prompt", prompt(id, "p-probe", "history-probe")).await;
    let probe = dst.texts(id, "agent_message_chunk").await.pop().unwrap_or_default();
    let probe: Value = serde_json::from_str(&probe).unwrap_or(Value::Null);
    cells.check(
        "agent-resumes-from-store",
        answer.is_ok() && probe["prompts"] == json!(["one", "two"]),
        format!("{answer:?} {probe}"),
    );
    assert!(cells.red.is_empty(), "red cells for codex-store: {:#?}", cells.red);
}

#[tokio::test]
async fn a_codex_native_store_travels_with_the_chat_and_its_agent_resumes_from_it() {
    codex_store_moves(Way::Cli).await;
}

#[tokio::test]
async fn a_codex_native_store_travels_with_a_move_driven_as_the_app_drives_it() {
    codex_store_moves(Way::Gui).await;
}

/// A Claude chat that ran subagents (`Task` children) moves with its native transcript
/// (`~/.claude/projects/<cwd>/<session>.jsonl`, the children's sidechain lines in it and their
/// own files under `<session>/subagents/`): the subagent rows the transcript folds show on the
/// target as they did, and the transcript is where Claude looks for it there.
async fn claude_subagent_folds_move(way: Way) {
    let tag = match way {
        Way::Cli => "mxsc",
        Way::Gui => "mxsg",
    };
    // A guarded receive (the app's move) takes only a plain agent session id of 8 or more
    // characters (`transfer_guard.rs`), which `fake-1` is not.
    let env = json!({"FAMILY": "claude", "FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude",
                     "FAKE_SESSION_PREFIX": "fake-sess-"});
    let target = Daemon::with_env(&format!("{tag}-t"), None, env.clone(), &[], "ask").await;
    let source = Daemon::with_env(&format!("{tag}-s"), Some(&target), env, &[], "ask").await;
    let mut cells = Cells { harness: "claude-subagents", red: Vec::new() };
    let cwd = source.home.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut src = Rpc::connect(&source.socket).await;
    let made = src.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let id = id.as_str();
    // The subagent the chat's log folds (`subagents.rs`): spawned, then completed.
    src.call("session/prompt", prompt(id, "p-seg", "reply-segments")).await;
    let folds = |events: &Value| -> Vec<Value> {
        events["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| e.pointer("/msg/params/_meta/acpmux/subagents").cloned())
            .collect()
    };
    let log =
        src.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    let folds_before = folds(&log);
    assert!(!folds_before.is_empty(), "the source logged no subagent: {log}");

    // Claude's own transcript of it, with its `Task` child, under the source's ~/.claude.
    let agent_id = "fake-sess-1";
    let project = |folder: &Path| {
        let dir: String = folder
            .to_string_lossy()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        PathBuf::from(".claude/projects").join(dir)
    };
    let line = |value: Value| format!("{value}\n");
    let transcript = [
        json!({"type": "user", "uuid": "u1", "sessionId": agent_id, "cwd": cwd,
               "message": {"role": "user", "content": "look around"}}),
        json!({"type": "assistant", "uuid": "a1", "parentUuid": "u1", "sessionId": agent_id,
               "message": {"role": "assistant", "content": [{"type": "tool_use",
                   "id": "toolu_task1", "name": "Task",
                   "input": {"description": "Look", "prompt": "look", "subagent_type": "general-purpose"}}]}}),
        json!({"type": "user", "uuid": "s1", "parentUuid": "a1", "isSidechain": true,
               "sessionId": agent_id, "message": {"role": "user", "content": "look"}}),
        json!({"type": "assistant", "uuid": "s2", "parentUuid": "s1", "isSidechain": true,
               "sessionId": agent_id, "message": {"role": "assistant",
                   "content": [{"type": "text", "text": "found it"}]}}),
        json!({"type": "user", "uuid": "u2", "parentUuid": "a1", "sessionId": agent_id,
               "message": {"role": "user", "content": [{"type": "tool_result",
                   "tool_use_id": "toolu_task1", "content": "found it"}]}}),
    ]
    .into_iter()
    .map(line)
    .collect::<String>();
    let child = line(json!({"type": "user", "uuid": "c1", "isSidechain": true,
                            "agentId": "a1", "message": {"role": "user", "content": "look"}}));
    let source_home = home_of(&format!("{tag}-s"));
    let folder = source_home.join(project(&cwd));
    std::fs::create_dir_all(folder.join(agent_id).join("subagents")).unwrap();
    std::fs::write(folder.join(format!("{agent_id}.jsonl")), &transcript).unwrap();
    std::fs::write(folder.join(agent_id).join("subagents/agent-a1.jsonl"), &child).unwrap();

    // Under the target's `~/work`, where Move to Cloud's guarded receive takes a folder.
    let destination = home_of(&format!("{tag}-t")).join("work/arrived");
    std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
    let mut dst = Rpc::connect(&target.socket).await;
    match way {
        Way::Cli => {
            let receipt = cli_move(&source, id, &destination).await;
            cells.check("moved", receipt["moves"][0]["moved"] == true, &receipt);
        }
        Way::Gui => {
            std::fs::create_dir_all(&destination).unwrap();
            let moved = gui_move(&mut src, &mut dst, id, &destination).await;
            cells.check("moved", moved.is_ok(), format!("{moved:?}"));
        }
    }

    let log =
        dst.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    cells.check(
        "subagent-folds-in-log",
        folds(&log).get(..folds_before.len()) == Some(&folds_before[..]),
        format!("{folds_before:?} -> {:?}", folds(&log)),
    );
    let there = home_of(&format!("{tag}-t")).join(project(&destination));
    let main = std::fs::read_to_string(there.join(format!("{agent_id}.jsonl"))).unwrap_or_default();
    cells.check(
        "native-transcript",
        main == transcript,
        format!("{} bytes of {} under {}", main.len(), transcript.len(), there.display()),
    );
    let children = std::fs::read_to_string(there.join(agent_id).join("subagents/agent-a1.jsonl"));
    cells.check(
        "native-subagent-transcripts",
        children.as_deref().ok() == Some(&child[..]),
        format!("{children:?}"),
    );
    assert!(cells.red.is_empty(), "red cells for claude-subagents: {:#?}", cells.red);
}

#[tokio::test]
async fn a_claude_chat_with_subagents_moves_its_transcript_and_folds() {
    claude_subagent_folds_move(Way::Cli).await;
}

#[tokio::test]
async fn a_claude_chat_with_subagents_moves_as_the_app_drives_it() {
    claude_subagent_folds_move(Way::Gui).await;
}
