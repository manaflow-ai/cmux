//! The app's pipe to the holder process, end to end: a run asks the app its questions and shows
//! the device code, the machine gets access, and the end of input leaves it there.

use super::*;
use crate::target::{ACCESS_PATH, ExecResult, MODE_PATH, VmError};
use crate::test_support::{Gate, holder_script};

/// A machine's files; a read waits at the gate when one is set.
#[derive(Default)]
struct Files(Mutex<HashMap<String, Vec<u8>>>, Mutex<Option<Arc<Gate>>>);

#[async_trait]
impl Machines for Files {
    async fn exec(
        &self,
        team: Option<&str>,
        _: &str,
        command: &str,
        _: u64,
    ) -> Result<ExecResult, VmError> {
        assert_eq!(team, Some("team-1"), "the scope's team is pinned");
        if command.starts_with("if [") {
            let mut files = lock(&self.0);
            let staged: Vec<(String, Vec<u8>)> =
                files.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            for (path, data) in staged {
                if path.contains("/.access-") {
                    files.insert(ACCESS_PATH.into(), data);
                } else if path.contains("/.codex-") {
                    files.insert(MODE_PATH.into(), data);
                }
            }
            return Ok(ExecResult { exit_code: 0, stdout: String::new() });
        }
        Ok(ExecResult {
            exit_code: 0,
            stdout: r#"{"capabilities":["codex-external-access-v1"]}"#.into(),
        })
    }
    async fn read(&self, _: Option<&str>, _: &str, path: &str) -> Result<Vec<u8>, VmError> {
        let gate = lock(&self.1).clone();
        if let Some(gate) = gate {
            gate.pause().await;
        }
        lock(&self.0).get(path).cloned().ok_or(VmError {
            status: 404,
            code: Some("vm_file_not_found".into()),
            message: String::new(),
        })
    }
    async fn write(
        &self,
        _: Option<&str>,
        _: &str,
        path: &str,
        data: &[u8],
        _: Option<u32>,
    ) -> Result<(), VmError> {
        lock(&self.0).insert(path.into(), data.to_vec());
        Ok(())
    }
    async fn mkdir(&self, _: Option<&str>, _: &str, _: &str) -> Result<(), VmError> {
        Ok(())
    }
    async fn remove(&self, _: Option<&str>, _: &str, path: &str) -> Result<(), VmError> {
        lock(&self.0).remove(path);
        Ok(())
    }
}

const HOLDER: &str = r#"holder="$3"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"login"'; then
    touch "$holder/signed-in"
    echo "{\"id\":$id,\"result\":{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"TEST-CODE\"}}"
  elif [ -f "$holder/signed-in" ]; then
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"holder-access\",\"chatgptAccountId\":\"account\",\"expiresAt\":2147483647}}"
  else
    echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"
  fi
done
"#;

#[tokio::test(flavor = "multi_thread")]
async fn a_run_over_the_pipe_asks_the_app_and_leaves_access_at_the_end_of_input() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    let codex = home.join(".local/bin/codex");
    std::fs::write(&codex, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let acpmux = holder_script(root.path(), HOLDER);
    let files = Arc::new(Files::default());

    let (mut app_in, holder_in) = tokio::io::duplex(64 * 1024);
    let (holder_out, app_out) = tokio::io::duplex(64 * 1024);
    let machines = files.clone();
    let served =
        tokio::spawn(async move { serve(holder_in, holder_out, move |_, _| machines).await });
    let mut replies = tokio::io::BufReader::new(app_out).lines();
    let scope = json!({"user": "user-1", "team": "team-1"});
    let send = |value: Value| format!("{value}\n");
    app_in
        .write_all(
            send(json!({"op": "config", "root": root.path().join("cloud"), "user_home": home}))
                .as_bytes(),
        )
        .await
        .unwrap();
    app_in
        .write_all(
            send(
                json!({"op": "run", "id": 1, "machine": "vm_1", "scope": scope, "confirmed": true,
                "ask_local": true, "current": scope, "acpmux": acpmux}),
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let mut asked = Vec::new();
    loop {
        let line: Value =
            serde_json::from_str(&replies.next_line().await.unwrap().unwrap()).unwrap();
        if line.get("reply").is_some() {
            assert_eq!(line["reply"], 1);
            assert_eq!(line["ok"], true, "{line}");
            break;
        }
        let kind = line["ask"].as_str().unwrap().to_owned();
        let value = match kind.as_str() {
            "owner" | "live" => json!(true),
            "consent" | "local_sign_in" => json!(false),
            "device_code" => {
                assert_eq!(line["code"], "TEST-CODE");
                assert_eq!(line["run"], 1);
                json!(true)
            }
            other => panic!("unexpected question {other}"),
        };
        asked.push(kind);
        app_in
            .write_all(send(json!({"op": "answer", "id": line["id"], "value": value})).as_bytes())
            .await
            .unwrap();
    }
    assert!(
        asked.contains(&"local_sign_in".to_owned()) && asked.contains(&"device_code".to_owned())
    );
    let delivered = lock(&files.0).get(ACCESS_PATH).cloned().unwrap();
    assert!(String::from_utf8(delivered).unwrap().contains("holder-access"));

    app_in
        .write_all(
            send(json!({"op": "delivers", "id": 2, "machine": "vm_1", "scope": scope})).as_bytes(),
        )
        .await
        .unwrap();
    let reply: Value = serde_json::from_str(&replies.next_line().await.unwrap().unwrap()).unwrap();
    assert_eq!(reply, json!({"reply": 2, "ok": true, "value": true}));
    app_in.write_all(send(json!({"op": "nope", "id": 3})).as_bytes()).await.unwrap();
    let reply: Value = serde_json::from_str(&replies.next_line().await.unwrap().unwrap()).unwrap();
    assert_eq!(reply["ok"], false);

    drop(app_in);
    served.await.unwrap().unwrap();
    assert!(lock(&files.0).contains_key(ACCESS_PATH), "the end of input detaches: access stays");
}

#[test]
fn finds_codex_on_path_or_in_the_usual_folders() {
    let root = tempfile::tempdir().unwrap();
    let bin = root.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("codex"), "").unwrap();
    assert_eq!(find_codex(Some(&bin.display().to_string()), root.path()), None, "not executable");
    std::fs::set_permissions(bin.join("codex"), std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(
        find_codex(Some(&format!("relative:{}", bin.display())), root.path()),
        Some(bin.join("codex"))
    );
}

/// A cancel that overtakes its run's line still ends that run; a late cancel of a run that
/// already finished leaves nothing behind.
#[test]
fn a_cancel_before_its_run_line_starts_the_run_cancelled() {
    let mut runs = Runs::default();
    runs.read(1, false);
    runs.cancel(2);
    runs.read(2, true);
    assert!(runs.live.get(&2).is_some_and(Cx::is_cancelled), "the run starts cancelled");

    runs.read(3, true);
    assert!(!runs.live.get(&3).is_some_and(Cx::is_cancelled));
    runs.cancel(3);
    assert!(runs.live.get(&3).is_some_and(Cx::is_cancelled));

    runs.live.remove(&2);
    runs.live.remove(&3);
    runs.cancel(3);
    assert!(runs.live.is_empty(), "a cancel after its run ended keeps nothing");
}

/// One holder process over a pipe, its app side answering every question as a person who owns
/// the machine and signed in to Codex.
struct Pipe {
    input: tokio::io::DuplexStream,
    replies: tokio::io::Lines<tokio::io::BufReader<tokio::io::DuplexStream>>,
    served: tokio::task::JoinHandle<Result<(), Error>>,
}

impl Pipe {
    fn start(files: &Arc<Files>) -> Self {
        let (input, holder_in) = tokio::io::duplex(64 * 1024);
        let (holder_out, output) = tokio::io::duplex(64 * 1024);
        let machines = files.clone();
        let served =
            tokio::spawn(async move { serve(holder_in, holder_out, move |_, _| machines).await });
        Self { input, replies: tokio::io::BufReader::new(output).lines(), served }
    }

    async fn send(&mut self, value: Value) {
        self.input.write_all(format!("{value}\n").as_bytes()).await.unwrap();
    }

    /// Answers questions until request `id`'s reply, which it returns.
    async fn reply(&mut self, id: u64) -> Value {
        loop {
            let line: Value =
                serde_json::from_str(&self.replies.next_line().await.unwrap().unwrap()).unwrap();
            if line.get("reply").is_some() {
                if line["reply"] == id {
                    return line;
                }
                continue;
            }
            let Some(kind) = line["ask"].as_str() else { continue };
            let value = json!(matches!(kind, "owner" | "live" | "device_code"));
            self.send(json!({"op": "answer", "id": line["id"], "value": value})).await;
        }
    }

    /// The app quits: input ends and the holder detaches.
    async fn quit(self) {
        drop(self.input);
        self.served.await.unwrap().unwrap();
    }
}

struct World {
    root: tempfile::TempDir,
    home: PathBuf,
    acpmux: PathBuf,
    files: Arc<Files>,
}

fn scope() -> Value {
    json!({"user": "user-1", "team": "team-1"})
}

impl World {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        std::fs::create_dir_all(home.join(".local/bin")).unwrap();
        let codex = home.join(".local/bin/codex");
        std::fs::write(&codex, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
        let acpmux = holder_script(root.path(), HOLDER);
        Self { root, home, acpmux, files: Arc::new(Files::default()) }
    }

    fn config(&self) -> Value {
        json!({"op": "config", "root": self.root.path().join("cloud"), "user_home": self.home})
    }

    fn delivered(&self) -> bool {
        lock(&self.files.0).contains_key(ACCESS_PATH)
    }

    /// A first holder delivers to `vm_1` and then ends, leaving the access there.
    async fn delivered_by_a_holder_that_ended(&self) {
        let mut pipe = Pipe::start(&self.files);
        pipe.send(self.config()).await;
        pipe.send(
            json!({"op": "run", "id": 1, "machine": "vm_1", "scope": scope(), "confirmed": true,
            "current": scope(), "acpmux": self.acpmux}),
        )
        .await;
        assert_eq!(pipe.reply(1).await["ok"], true);
        pipe.quit().await;
        assert!(self.delivered());
    }

    /// The next holder, given what the last one knew.
    async fn restarted(&self, replay: Option<Value>) -> Pipe {
        let mut pipe = Pipe::start(&self.files);
        pipe.send(self.config()).await;
        if let Some(live) = replay {
            pipe.send(json!({"op": "restore", "scopes": [scope()], "live": live,
                "current": scope(), "acpmux": self.acpmux}))
                .await;
        }
        pipe
    }
}

/// cmux#37306 review: a holder started again after the last one ended knew nothing of the
/// machines that one delivered to, so a sign-out left their access in place. Replayed, it erases.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_holder_given_the_replay_erases_on_sign_out() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = world.restarted(Some(json!(["vm_1"]))).await;
    pipe.send(json!({"op": "sign_out", "id": 2, "current": scope()})).await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(!world.delivered(), "the sign-out erased the last holder's access");
    pipe.quit().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_holder_given_the_replay_erases_on_a_team_switch() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = world.restarted(Some(json!(["vm_1"]))).await;
    pipe.send(
        json!({"op": "scope_changed", "id": 2, "current": {"user": "user-1", "team": "team-2"}}),
    )
    .await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(!world.delivered(), "the switch erased the old team's access");
    pipe.quit().await;
}

/// Without the replay the same sign-out reaches nothing: the restore is what fixes it.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_holder_without_the_replay_cannot_erase() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = world.restarted(None).await;
    pipe.send(json!({"op": "sign_out", "id": 2, "current": scope()})).await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(world.delivered());
    pipe.quit().await;
}

/// cmux#37306 review: a machine delivered after the last machine list is not in the replayed
/// list; the holder still finds it in the delivery record and erases it on sign-out.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_holder_erases_a_machine_delivered_after_the_last_list() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = world.restarted(Some(json!([]))).await;
    pipe.send(json!({"op": "sign_out", "id": 2, "current": scope()})).await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(!world.delivered(), "the record named it");
    pipe.quit().await;
}

/// cmux#37306 review: the off switch started a new holder with Cloud already off, so the restore
/// took nothing back and the off switch retired nothing; the access stayed and could renew once
/// Cloud was on again. Now a restore under the fence ends the scope, which erases it at once, and
/// nothing renews once Cloud is on again. An off line said again changes nothing.
#[tokio::test(flavor = "multi_thread")]
async fn a_holder_restarted_while_cloud_is_off_erases_and_never_renews() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = Pipe::start(&world.files);
    pipe.send(world.config()).await;
    pipe.send(
        json!({"op": "available", "enabled": false, "current": scope(), "acpmux": world.acpmux}),
    )
    .await;
    pipe.send(json!({"op": "restore", "scopes": [scope()], "live": ["vm_1"], "current": scope()}))
        .await;
    // A request after the restore answers only once the restore is done.
    pipe.send(json!({"op": "pending_cleanup", "id": 2})).await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(!world.delivered(), "the off switch erased it");

    pipe.send(json!({"op": "available", "enabled": false, "current": scope()})).await;
    // The app's switch carries an id and is answered once the fence is in place.
    pipe.send(json!({"op": "available", "id": 4, "enabled": true, "current": scope()})).await;
    assert_eq!(pipe.reply(4).await["ok"], true);
    pipe.send(json!({"op": "listed", "live": ["vm_1"], "current": scope()})).await;
    pipe.send(json!({"op": "pending_cleanup", "id": 3})).await;
    assert_eq!(pipe.reply(3).await["ok"], true);
    assert!(!world.delivered(), "nothing renews it");
    pipe.quit().await;
}

/// cmux#37306 review: a holder that ended before it read a team switch; the next one opens under
/// the new team. The old team's scope is among those replayed, so it ends now and its delivered
/// access is erased, not left until it expires.
#[tokio::test(flavor = "multi_thread")]
async fn a_switch_the_last_holder_never_read_still_erases_the_old_teams_access() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let mut pipe = Pipe::start(&world.files);
    pipe.send(world.config()).await;
    let new_team = json!({"user": "user-1", "team": "team-2"});
    pipe.send(json!({"op": "restore", "scopes": [scope(), new_team], "live": ["vm_1"],
        "current": new_team, "acpmux": world.acpmux}))
        .await;
    pipe.send(json!({"op": "pending_cleanup", "id": 2})).await;
    assert_eq!(pipe.reply(2).await["ok"], true);
    assert!(!world.delivered(), "the old team's access is erased");
    pipe.quit().await;
}

/// cmux#37306 review: an off switch read while a restore was blocked on a machine took effect
/// only once the restore ended, so a renewal could go on meanwhile. It fences when read, and
/// what the restore was taking back is still erased.
#[tokio::test(flavor = "multi_thread")]
async fn an_off_switch_fences_at_once_while_a_restore_is_blocked() {
    let world = World::new();
    world.delivered_by_a_holder_that_ended().await;
    let gate = Gate::new();
    *lock(&world.files.1) = Some(gate.clone());
    let (out, mut lines) = mpsc::unbounded_channel::<String>();
    let app = Arc::new(App {
        out,
        waiting: Mutex::default(),
        next: AtomicU64::new(0),
        closed: AtomicBool::new(false),
    });
    let machines: Arc<dyn Machines> = world.files.clone();
    let holder = Holder::new(Config::from_json(&world.config()).unwrap(), app.clone(), machines);
    // The app: answers every question, and passes on the holder's replies.
    let (replies, mut replied) = mpsc::unbounded_channel::<Value>();
    let answers = app.clone();
    tokio::spawn(async move {
        while let Some(line) = lines.recv().await {
            let line: Value = serde_json::from_str(&line).unwrap();
            if line.get("reply").is_some() {
                let _ = replies.send(line);
            } else if let (Some(kind), Some(id)) = (line["ask"].as_str(), line["id"].as_u64()) {
                answers.answer(id, json!(matches!(kind, "owner" | "live")));
            }
        }
    });

    holder.take(
        &json!({"op": "restore", "scopes": [scope()], "live": ["vm_1"], "current": scope(),
            "acpmux": world.acpmux})
        .to_string(),
    );
    gate.entered().await;
    holder.take(&json!({"op": "available", "enabled": false, "current": scope()}).to_string());
    assert!(!holder.adapter.available(), "fenced while the restore still waits on the machine");

    *lock(&world.files.1) = None;
    gate.open();
    holder.take(&json!({"op": "pending_cleanup", "id": 2, "current": scope()}).to_string());
    assert_eq!(replied.recv().await.unwrap()["ok"], true);
    assert!(!world.delivered(), "the off switch still erased it");
}
