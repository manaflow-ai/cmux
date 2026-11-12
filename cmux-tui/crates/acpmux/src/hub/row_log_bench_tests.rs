//! The row log's before and after numbers, in one harness (cmuxterm-hq
//! `docs/design/acpmux-session-list-row-log.md`): a follow at 525 chats and at 11,000, and the first
//! list frame while 30 peer links reconnect. It replaces `watch_delta_bench.rs`, which measured the
//! peer delta this follow replaced.

use super::*;

fn p95(mut samples: Vec<Duration>) -> Duration {
    samples.sort_unstable();
    samples[(samples.len() * 95 / 100).min(samples.len() - 1)]
}

/// The lane's bar, in one harness: a follow after one change costs the same at 525 chats and at
/// 11,000 (god), and the app's first list frame after its socket is up stays under 500 ms while
/// 30 peer links reconnect at once. "whole" is what every link did before (`_acpmux/watch` with no
/// cursor: its own list); "follow" is what a link does now. "first page" is the app's watch with
/// `limit: 200`, "whole read" `_acpmux/sessions` with none.
/// `cargo test -p acpmux --release --lib list_follow_bench -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: prints the before and after numbers"]
async fn list_follow_bench() {
    let (mut follow, mut pages) = (Vec::new(), Vec::new());
    for chats in [525, 11_000] {
        let hub = hub_with(chats, 0, 0).await;
        let mut link = Client::new(&hub, Origin::Peer).await;
        let first = link.call(method::MUX_WATCH, json!({"enabled": true})).await;
        let (mut cursor, epoch) = (first["listSeq"].as_u64().unwrap(), first["listEpoch"].clone());
        let (mut samples, mut whole) = (Vec::new(), Vec::new());
        for n in 0..200 {
            record(&hub, &format!("chat-{}", n % chats), "renamed");
            let started = Instant::now();
            let reply = link
                .call(
                    method::MUX_WATCH,
                    json!({"enabled": true, "afterSeq": cursor, "listEpoch": epoch}),
                )
                .await;
            samples.push(started.elapsed());
            cursor = reply["listSeq"].as_u64().unwrap();
        }
        for n in 0..10 {
            record(&hub, &format!("chat-{}", n % chats), "renamed");
            let mut fresh = Client::new(&hub, Origin::Peer).await;
            let started = Instant::now();
            fresh.call(method::MUX_WATCH, json!({"enabled": true})).await;
            whole.push(started.elapsed());
        }
        // The most bytes one follow holds at once (the test allocator's count on this thread), as
        // `watch_delta_bench.rs` measured the delta it replaced.
        #[cfg(target_os = "linux")]
        {
            let before = hub.list_cursor().0;
            record(&hub, "chat-0", "renamed");
            let (built, peak) = crate::hub::peer_snapshot::thread_peak_bytes(|| {
                hub.list_follow(before, true, false, 1 << 20)
            });
            assert!(built.is_some(), "the log follows its own head");
            eprintln!("PERF follow peak bytes chats={chats}: {peak}");
        }
        // The app's first page (`limit: 200`) and a whole read's first reply (`_acpmux/sessions`
        // with no `limit`), each on a new connection after a change, as an app opens.
        let (mut page, mut read) = (Vec::new(), Vec::new());
        for n in 0..20 {
            record(&hub, &format!("chat-{}", n % chats), "renamed");
            let mut app = Client::new(&hub, Origin::Local).await;
            let started = Instant::now();
            app.call(method::MUX_WATCH, json!({"enabled": true, "limit": 200})).await;
            page.push(started.elapsed());
            record(&hub, &format!("chat-{}", (n + 1) % chats), "renamed");
            let started = Instant::now();
            app.call(method::MUX_SESSIONS, json!({})).await;
            read.push(started.elapsed());
        }
        let (f, w) = (p95(samples), p95(whole));
        eprintln!("PERF reconnect chats={chats}: follow p95 {f:?}, whole list p95 {w:?}");
        let (p, r) = (p95(page), p95(read));
        eprintln!(
            "PERF open chats={chats}: first page p95 {p:?}, whole read first reply p95 {r:?}"
        );
        follow.push(f);
        pages.push(p);
    }
    eprintln!(
        "PERF follow god/small p95 ratio {:.2}",
        follow[1].as_secs_f64() / follow[0].as_secs_f64()
    );
    eprintln!(
        "PERF first page god/small p95 ratio {:.2}",
        pages[1].as_secs_f64() / pages[0].as_secs_f64()
    );

    // The first frame with 525 chats and 30 peers of 20 rows, while 30 links reconnect.
    for storm in ["whole", "follow"] {
        let hub = hub_with(525, 30, 20).await;
        let (head, epoch) = {
            let (h, e) = hub.list_cursor();
            (h, e.to_owned())
        };
        let mut links = Vec::new();
        for _ in 0..30 {
            let hub = hub.clone();
            let epoch = epoch.clone();
            links.push(tokio::spawn(async move {
                for _ in 0..10 {
                    let mut link = Client::new(&hub, Origin::Peer).await;
                    let params = if storm == "follow" {
                        json!({"enabled": true, "afterSeq": head, "listEpoch": epoch})
                    } else {
                        json!({"enabled": true})
                    };
                    let (id, input) = (link.next, link.input.clone());
                    input
                        .send(Message::request(id, method::MUX_WATCH, params).to_line())
                        .await
                        .unwrap();
                    // A refusal (`list.paced`) or a reply: either ends this reconnect.
                    while let Ok(Some(line)) =
                        tokio::time::timeout(Duration::from_secs(60), link.output.recv()).await
                    {
                        let message: Value = serde_json::from_str(&line).unwrap();
                        if message["id"] == id {
                            break;
                        }
                    }
                    record(&hub, "chat-1", "renamed");
                }
            }));
        }
        let (mut frames, mut refused) = (Vec::new(), 0);
        for _ in 0..20 {
            let started = Instant::now();
            let mut app = Client::new(&hub, Origin::Local).await;
            let id = app.next;
            app.input
                .send(
                    Message::request(id, method::MUX_WATCH, json!({"enabled": true, "limit": 200}))
                        .to_line(),
                )
                .await
                .unwrap();
            loop {
                let message: Value =
                    serde_json::from_str(&app.output.recv().await.unwrap()).unwrap();
                if message["id"] == id {
                    refused += usize::from(message.get("error").is_some());
                    break;
                }
            }
            frames.push(started.elapsed());
        }
        for link in links {
            link.await.unwrap();
        }
        eprintln!(
            "PERF first frame, 525 chats + 30 peers, 30 links reconnecting ({storm}): p95 {:?}, max {:?}, refused {refused}/20",
            p95(frames.clone()),
            frames.iter().max().unwrap()
        );
    }
}
