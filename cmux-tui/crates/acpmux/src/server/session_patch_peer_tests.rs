//! A peer daemon's link gets row patches when it asks (`sessionChangedDelta: 2`), of the masked
//! row (`peer_text.rs`); one that does not ask, as every link before this change, gets whole
//! rows as before; and `_acpmux/session_resync` sends a row whole again with the next `rowSeq`.

use super::{Origin, serve_connection_with};
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const OWN: &str = "own-chat";

fn github_token() -> String {
    format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234")
}

fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": OWN, "name": OWN,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        // A rename names the title, so the secret sits where a rename leaves it too.
        "title": format!("fix {}", github_token()),
        "lastPrompt": format!("deploy with {}", github_token())
    }))
    .unwrap();
    store.save(&meta).unwrap();
    crate::hub::Hub::new(config, store)
}

/// A connection of `origin` whose `initialize` carries `delta` as `sessionChangedDelta` (none
/// when null), watching the list with tools.
async fn watching(
    hub: &Arc<crate::hub::Hub>,
    origin: Origin,
    delta: Value,
) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(256);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
    let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": crate::peer::CLIENT_NAME, "version": "0"}});
    if !delta.is_null() {
        hello["_meta"] = json!({"acpmux": {"sessionChangedDelta": delta}});
    }
    for (id, m, params) in [
        (1, method::INITIALIZE, hello),
        (2, method::MUX_WATCH, json!({"enabled": true, "withTools": true})),
    ] {
        input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let reply = next(&mut outgoing, |line| line["id"] == id).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
    }
    (input, outgoing)
}

async fn next(outgoing: &mut mpsc::Receiver<String>, stop: impl Fn(&Value) -> bool) -> Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if stop(&line) {
                return line;
            }
        }
    })
    .await
    .expect("the line comes")
}

/// The next row notice of [`OWN`]: a whole row or a patch.
async fn row_notice(outgoing: &mut mpsc::Receiver<String>) -> Value {
    next(outgoing, |line| {
        matches!(
            line["method"].as_str(),
            Some(method::MUX_SESSION_CHANGED | method::MUX_SESSION_PATCH)
        ) && line["params"]["sessionId"] == OWN
    })
    .await
}

async fn rename(cli: &mpsc::Sender<String>, id: i64, name: &str) {
    let params = json!({"sessionId": OWN, "newName": name});
    cli.send(Message::request(id, method::MUX_RENAME, params).to_line()).await.unwrap();
}

#[tokio::test]
async fn a_peer_link_that_asks_gets_patches_of_the_masked_row_and_a_resync() {
    let hub = hub();
    let (cli, mut cli_out) = watching(&hub, Origin::Local, Value::Null).await;
    let (link, mut link_out) = watching(&hub, Origin::Peer, json!(2)).await;

    rename(&cli, 10, "first").await;
    let first = row_notice(&mut link_out).await;
    assert_eq!(first["method"], method::MUX_SESSION_CHANGED, "{first}");
    assert_eq!(first["params"]["rowSeq"], 1);
    let token = github_token();
    assert!(!first.to_string().contains(&token), "a peer's whole row is masked: {first}");
    let mut held = first["params"]["session"].clone();

    rename(&cli, 11, "second").await;
    let second = row_notice(&mut link_out).await;
    assert_eq!(second["method"], method::MUX_SESSION_PATCH, "{second}");
    assert_eq!(
        (second["params"]["baseRowSeq"].as_u64(), second["params"]["rowSeq"].as_u64()),
        (Some(1), Some(2))
    );
    let text = second.to_string();
    assert!(!text.contains(&token), "a peer's patch carries no secret: {text}");
    assert!(text.len() < first.to_string().len(), "a patch is smaller than the row");
    assert!(crate::server::session_patch::apply(&mut held, &second["params"]["patch"]));

    // The link missed a row: it asks, and the row comes whole with the next number.
    let ask = json!({"sessionId": OWN});
    link.send(Message::request(20, method::MUX_SESSION_RESYNC, ask).to_line()).await.unwrap();
    // Rows sent before the ask (a rename can send more than one) come first, numbered on.
    let mut last = 2;
    let mut reply = None;
    let whole = loop {
        let line = next(&mut link_out, |line| {
            line["id"] == 20
                || (matches!(
                    line["method"].as_str(),
                    Some(method::MUX_SESSION_CHANGED | method::MUX_SESSION_PATCH)
                ) && line["params"]["sessionId"] == OWN)
        })
        .await;
        if line["id"] == 20 {
            reply = Some(line);
            continue;
        }
        if line["params"]["recordKind"] == "resync" {
            break line;
        }
        assert_eq!(line["method"], method::MUX_SESSION_PATCH, "{line}");
        assert_eq!(line["params"]["baseRowSeq"], last, "{line}");
        assert!(crate::server::session_patch::apply(&mut held, &line["params"]["patch"]));
        last += 1;
    };
    assert_eq!(whole["method"], method::MUX_SESSION_CHANGED, "{whole}");
    assert_eq!(whole["params"]["rowSeq"], last + 1, "the next number, not a restart");
    assert!(!whole.to_string().contains(&token), "the whole row is masked too");
    // The resync's row is the chat as it is now, which can be newer than the last row noticed
    // (the rename's later rows): the link holds it, and the patches after it go on from it.
    let mut held = whole["params"]["session"].clone();
    let mut last = whole["params"]["rowSeq"].as_u64().unwrap();
    let reply = match reply {
        Some(reply) => reply,
        None => next(&mut link_out, |line| line["id"] == 20).await,
    };
    assert_eq!(reply["result"]["sent"], true, "{reply}");
    rename(&cli, 12, "third").await;
    while held["name"] != "third" {
        let line = row_notice(&mut link_out).await;
        assert_eq!(line["method"], method::MUX_SESSION_PATCH, "{line}");
        assert_eq!(line["params"]["baseRowSeq"], last, "{line}");
        assert!(!line.to_string().contains(&token), "{line}");
        assert!(crate::server::session_patch::apply(&mut held, &line["params"]["patch"]));
        last += 1;
    }

    // The local watcher that did not ask heard whole rows, raw.
    let heard = next(&mut cli_out, |l| {
        l["method"] == method::MUX_SESSION_CHANGED && l["params"]["session"]["name"] == "second"
    })
    .await;
    assert!(heard["params"].get("rowSeq").is_none());
    assert!(heard.to_string().contains(&token), "a local client reads the raw title");
}

/// Compatibility, both ways: a link that does not ask (every link before version 2) gets whole
/// rows with no `rowSeq`; one that asks with version 1's `true` gets patches as a raw client
/// did. A daemon before version 2 took only `true`, so a new link's `2` reads there as not
/// asking (`session_patch::allowed`, its test), and the link passes whole rows on
/// (`peer_row_patch.rs` `an_old_peers_whole_rows_pass_and_hold_nothing`).
#[tokio::test]
async fn a_link_that_does_not_ask_gets_whole_rows_as_before() {
    let hub = hub();
    let (cli, _cli_out) = watching(&hub, Origin::Local, Value::Null).await;
    let (_old, mut old_out) = watching(&hub, Origin::Peer, Value::Null).await;
    for (i, name) in ["one", "two", "three"].into_iter().enumerate() {
        rename(&cli, 10 + i as i64, name).await;
        // A rename can send more than one row (the name, then the list's order): each whole.
        let line = next(&mut old_out, |l| {
            l["method"] == method::MUX_SESSION_PATCH
                || (l["method"] == method::MUX_SESSION_CHANGED
                    && l["params"]["session"]["name"] == name)
        })
        .await;
        assert_eq!(line["method"], method::MUX_SESSION_CHANGED, "{line}");
        assert!(line["params"].get("rowSeq").is_none(), "{line}");
    }
    // Resync to a connection that did not ask sends nothing.
    let (old, mut old_out) = watching(&hub, Origin::Peer, json!(false)).await;
    let ask = json!({"sessionId": OWN});
    old.send(Message::request(30, method::MUX_SESSION_RESYNC, ask).to_line()).await.unwrap();
    let reply = next(&mut old_out, |line| line["id"] == 30).await;
    assert_eq!(reply["result"]["sent"], false, "{reply}");
}
