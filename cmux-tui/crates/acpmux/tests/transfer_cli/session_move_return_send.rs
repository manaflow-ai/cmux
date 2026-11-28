//! A chat moved to another machine and back answers the next `send --wait` with its reply.
//! Leo: "any chat moves Mac↔Cloud and back in one action, keeping its live state". The offload
//! probe's return leg sent its first prompt on the source after the move back and got exit 0
//! with nothing printed, in under a second, its chat left idle.
use super::session_move_live::{Side, move_to_the_other, pair};
use super::*;

/// `acpmux send --wait --quiet` on `side`, as the probe sends: its exit status and stdout.
async fn send_wait(side: &Side, id: &str, text: &str) -> (bool, String, String) {
    let out = daemon_env::tokio_command(&side.daemon.home, daemon_env::Agents::Deny)
        .args(["send", "--wait", "--quiet", "--no-steer", "--on-permission", "fail", id, text])
        .env("ACPMUX_HOME", &side.daemon.home)
        .env("ACPMUX_SOCKET", &side.daemon.socket)
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(60), out)
        .await
        .expect("send --wait returned")
        .expect("run send");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).trim().to_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[tokio::test]
async fn a_chat_moved_there_and_back_answers_the_next_waiting_send() {
    let logs = tempfile::tempdir().unwrap();
    let sides = pair("mrs", logs.path()).await;
    let mut here = Rpc::connect(&sides[0].daemon.socket).await;
    let made = here.call("session/new", json!({"cwd": sides[0].folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let (ok, said, err) = send_wait(&sides[0], &id, "seed").await;
    assert!(ok && said == "echo: seed", "seed: {said:?} {err}");

    move_to_the_other(&sides[0], &sides[1], &id, &[]).await;
    let (ok, said, err) = send_wait(&sides[1], &id, "there").await;
    assert!(ok && said == "echo: there", "there: {said:?} {err}");

    move_to_the_other(&sides[1], &sides[0], &id, &[]).await;
    let (ok, said, err) = send_wait(&sides[0], &id, "back").await;
    assert!(ok, "back: {err}");
    assert_eq!(said, "echo: back", "the reply after the move back: {err}");
}

/// As the probe's way there goes: its message to the moved chat crosses the team hub from the
/// machine it left, so the chat takes it from another agent (`fromAgent`, the inbox's route), not
/// as a prompt of its own machine's person. The next `send --wait` after the move back is the
/// person's again and runs a turn.
#[tokio::test]
async fn a_chat_messaged_by_an_agent_there_answers_the_next_waiting_send_back_home() {
    let logs = tempfile::tempdir().unwrap();
    let sides = pair("mra", logs.path()).await;
    let mut here = Rpc::connect(&sides[0].daemon.socket).await;
    let made = here.call("session/new", json!({"cwd": sides[0].folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let (ok, said, err) = send_wait(&sides[0], &id, "seed").await;
    assert!(ok && said == "echo: seed", "seed: {said:?} {err}");

    move_to_the_other(&sides[0], &sides[1], &id, &[]).await;
    let mut there = Rpc::connect(&sides[1].daemon.socket).await;
    let answer = tokio::time::timeout(
        Duration::from_secs(60),
        there.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "there"}],
                   "_meta": {"acpmux": {"promptId": "p-there", "fromAgent": "relay-host"}}}),
        ),
    )
    .await
    .expect("the agent's message was answered");
    eprintln!("there answered: {answer}");

    move_to_the_other(&sides[1], &sides[0], &id, &[]).await;
    let (ok, said, err) = send_wait(&sides[0], &id, "back").await;
    let info = here.call("_acpmux/info", json!({"sessionId": id})).await;
    assert!(ok, "back: {err} info={info}");
    assert_eq!(said, "echo: back", "the reply after the move back: {err} info={info}");
}
