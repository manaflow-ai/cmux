//! The app's pipe to the holder process, end to end: a run asks the app its questions and shows
//! the device code, the machine gets access, and the end of input leaves it there.

use super::*;
use crate::target::{ACCESS_PATH, ExecResult, MODE_PATH, VmError};
use crate::test_support::holder_script;

#[derive(Default)]
struct Files(Mutex<HashMap<String, Vec<u8>>>);

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
