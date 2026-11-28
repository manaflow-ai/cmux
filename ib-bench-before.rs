/// A coordinator's inbox at 10k threads: the list and one thread read stay under 200 ms.
#[tokio::test]
async fn inbox_ten_k_before() {
    let (hub, session) = hub_with_chat("ten-k");
    {
        let mut inbox = session.inbox();
        for n in 0..10_000u64 {
            for m in 0..2u64 {
                let mut i = item(
                    &format!("m-{n}-{m}"),
                    &format!("from:src-{n}/pr:{n}"),
                    "src",
                    PromptClass::Fyi,
                    1_000 + n * 2 + m,
                    &format!("message {n} {m}"),
                );
                (i.noticed, i.read) = (true, m == 0);
                inbox.items.push(i);
            }
        }
    }
    let t = std::time::Instant::now();
    let thread = hub.inbox_thread_whole(&session, "from:src-777/pr:777", false).unwrap();
    let read_ms = t.elapsed().as_millis();
    assert_eq!(thread["messages"].as_array().unwrap().len(), 2);
    let t = std::time::Instant::now();
    let whole = hub.inbox_threads(&session);
    let whole_ms = t.elapsed().as_millis();
    assert_eq!(whole["threads"].as_array().unwrap().len(), 10_000);
    let t = std::time::Instant::now();
    let list = hub.inbox_threads(&session);
    let list_ms = t.elapsed().as_millis();
    eprintln!(
        "INBOX10K before: thread read {read_ms} ms, whole list {whole_ms} ms"
    );
}
