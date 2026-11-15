//! Toggle Terminal and Chat (Leo, 2026-11-12: two live views of one session, instant both ways):
//! a terminal that waits for a chat's turn (`acpmux resume-here`) shows the permission that turn
//! asks for and takes the answer, over the CLI's own client on the daemon's unix socket
//! (`cli/resume_here_ask.rs`). The daemon still decides who may allow (`hub/person.rs`).

use super::*;
use acpmux::cli::resume_here_ask::follow;
use tokio::sync::watch;

/// The next printed text that contains `want`, within 20 s.
async fn printed(out: &mut mpsc::UnboundedReceiver<String>, want: &str) -> String {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let text = out.recv().await.expect("the prompt ended");
            if text.contains(want) {
                return text;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("never printed {want:?}"))
}

#[tokio::test]
async fn a_waiting_terminal_shows_the_turns_permission_and_answers_it_there() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "toggle-ask").await;
    let socket = std::path::PathBuf::from(format!("/tmp/acpmux-rha-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket);
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));

    // Already pending when the terminal opens: it shows at once.
    let first = c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm x", None)).await;
    c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == id).await;
    let terminal = acpmux::client::Client::connect_without_caller(&socket).await.unwrap();
    let (type_line, lines) = mpsc::channel(4);
    let (asking, mut asked) = watch::channel(false);
    let (out, mut shown) = mpsc::unbounded_channel();
    let sid = id.clone();
    let prompt_task = tokio::spawn(async move { follow(terminal, &sid, lines, asking, out).await });
    let question = printed(&mut shown, "permission needed:").await;
    assert!(question.contains("rm x"), "{question}");
    assert!(question.contains("  1. Allow\n  2. Reject\n"), "{question}");
    asked.wait_for(|a| *a).await.unwrap();

    // Only the cmux app allows: the terminal's allow is refused, says so, and still waits.
    type_line.send("1\n".into()).await.unwrap();
    printed(&mut shown, "switch this pane to Chat").await;
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["status"], "waiting");
    // A deny answers from the terminal: the turn goes on with it.
    type_line.send("2\n".into()).await.unwrap();
    printed(&mut shown, "answered: Reject").await;
    assert!(c.response(first).await.0.is_ok());
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["preview"], "chose no");
    asked.wait_for(|a| !*a).await.unwrap();

    // Asked while the terminal is up, then answered in the chat: the terminal stops asking.
    let second = c.send(method::SESSION_PROMPT, prompt(&id, "ask: ls", None)).await;
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == id).await;
    let question = printed(&mut shown, "permission needed:").await;
    assert!(question.contains("ls"), "{question}");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pending["permissionId"], "optionId": "yes"}),
    )
    .await
    .unwrap();
    printed(&mut shown, "answered in the chat").await;
    asked.wait_for(|a| !*a).await.unwrap();
    assert!(c.response(second).await.0.is_ok());
    prompt_task.abort();
    let _ = std::fs::remove_file(&socket);
}
