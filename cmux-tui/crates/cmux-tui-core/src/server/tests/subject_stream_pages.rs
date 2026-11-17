//! A journal stream with an exact-subject filter reads the store in subject
//! pages. Each page reads a bounded count of sequences, so a page can have no
//! record and end below the head: the stream goes on from that page's cursor.

use std::sync::atomic::AtomicUsize;

use super::*;
use crate::workspace_registry::session_journal::{SubjectPageProbe, set_subject_page_probe};

/// One child-completed record of the agent hooks, with an agent tree of its
/// own. With `append` false it is only built. Returns the record's
/// `agent_tree` subject and, when appended, its sequence.
fn child_completed(mux: &Arc<Mux>, marker: &str, append: bool) -> (JournalSubject, Option<u64>) {
    let ingress = crate::agent_hook_journal_ingress(
        "codex",
        "SubagentStop",
        None,
        json!({
            "session_id":format!("{marker}-root"),
            "root_session_id":format!("{marker}-root"),
            "parent_session_id":format!("{marker}-root"),
            "child_agent_id":marker,
            "message":"complete",
        }),
    )
    .unwrap();
    let subject =
        ingress.subjects.iter().find(|subject| subject.kind == "agent_tree").cloned().unwrap();
    let sequence = append.then(|| {
        let key = format!("key_{}", marker.replace('-', "_"));
        mux.append_journal_ingress(&ingress, "client_subject_pages", &key).unwrap().sequence
    });
    (subject, sequence)
}

fn subscribe(id: &str, stream: u128, subject: &JournalSubject, follow: bool) -> String {
    resource_request(
        id,
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":format!("stream_{stream:032x}"),
            "start":"beginning",
            "follow":follow,
            "filter":journal_subscription_filter(
                JournalSensitivity::Sensitive,
                json!({"kinds":["agent.child.completed"], "subjects":[subject]}),
            ),
        }),
        None,
    )
}

#[test]
fn an_exact_subject_stream_goes_on_over_subject_pages_with_no_record() {
    const SCAN: u64 = 2;
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-subject-pages-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("journal-subject-pages", SurfaceOptions::default(), &root).unwrap();
    assert!(mux.shared_journal_enabled(), "a persistent session fans out from the shared ring");
    let database = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    // Records that the subject of the test does not name.
    for index in 0..6 {
        child_completed(&mux, &format!("subject-pages-other-{index}"), true);
    }
    let head = mux.session_journal_after(0, 1).unwrap().head_sequence;
    assert!(head >= 6, "the store has too few records for 3 pages: {head}");
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    // Each stream below has a probe that counts its pages.
    let probe =
        |pages: &Arc<AtomicUsize>, empty: &Arc<AtomicUsize>, writer: Option<MessageWriter>| {
            let (pages, empty) = (pages.clone(), empty.clone());
            SubjectPageProbe {
                scan: SCAN,
                after_page: Box::new(move |no_record| {
                    pages.fetch_add(1, Ordering::SeqCst);
                    empty.fetch_add(usize::from(no_record), Ordering::SeqCst);
                    if let Some(writer) = &writer {
                        writer.close();
                    }
                }),
            }
        };

    // 1. No match in the store. The stream reads pages with no record to
    // the head, moves to the shared ring and waits there: it reads no more
    // page, and a record that comes then arrives.
    let (subject, _) = child_completed(&mux, "subject-pages-late", false);
    let (pages, empty) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    set_subject_page_probe(&database, Some(probe(&pages, &empty, None)));
    let at_switch = Arc::new(AtomicUsize::new(0));
    *mux.journal_stream_before_ring_switch.lock().unwrap() = Some(Arc::new({
        let (pages, at_switch) = (pages.clone(), at_switch.clone());
        move || at_switch.store(pages.load(Ordering::SeqCst), Ordering::SeqCst)
    }));
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let open = subscribe("subject-pages-follow", 0x6001, &subject, true);
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    let deadline = Instant::now() + Duration::from_secs(5);
    while at_switch.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline, "the stream never came to the head of the store");
        std::thread::sleep(Duration::from_millis(2));
    }
    let walked = at_switch.load(Ordering::SeqCst);
    assert!(walked >= 3, "the stream read {walked} pages for {head} records");
    assert_eq!(empty.load(Ordering::SeqCst), walked, "a page had a record");
    assert!(outbound.try_pop().is_none(), "the stream sent a message on its way to the head");
    let (_, late) = child_completed(&mux, "subject-pages-late", true);
    let late = late.unwrap();
    let item = pop_json(&outbound);
    assert_eq!(item["type"], "stream_item", "the stream at the head missed a record: {item}");
    assert_eq!(item["item"]["sequence"], late.to_string());
    assert_eq!(pages.load(Ordering::SeqCst), walked, "the stream at the head read pages");
    *mux.journal_stream_before_ring_switch.lock().unwrap() = None;
    assert!(disconnect_client(&mux, client, false));

    // 2. The match is the last record of the store: it arrives after the
    // pages with no record.
    let (pages, empty) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    set_subject_page_probe(&database, Some(probe(&pages, &empty, None)));
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let open = subscribe("subject-pages-replay", 0x6002, &subject, false);
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);
    let item = pop_json(&outbound);
    assert_eq!(item["type"], "stream_item", "no record after pages with no record: {item}");
    assert_eq!(item["item"]["sequence"], late.to_string());
    assert_eq!(pop_json(&outbound)["reason"], "completed");
    assert!(empty.load(Ordering::SeqCst) >= 3, "the record came with no empty page before it");
    assert!(disconnect_client(&mux, client, false));

    // 3. A stream that stops goes to no next page: the probe closes the
    // connection in the first page, and the stream ends after that page.
    let (absent, _) = child_completed(&mux, "subject-pages-never", false);
    let (pages, empty) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    let (writer, _outbound) = captured_writer();
    set_subject_page_probe(&database, Some(probe(&pages, &empty, Some(writer.clone()))));
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let open = subscribe("subject-pages-stop", 0x6003, &absent, true);
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert!(
        mux.control_clients
            .resource_stream_admission
            .wait_until_idle(Instant::now() + Duration::from_secs(5)),
        "the stopped stream did not end"
    );
    assert_eq!(pages.load(Ordering::SeqCst), 1, "the stopped stream read a next page");
    assert_eq!(empty.load(Ordering::SeqCst), 1);
    disconnect_client(&mux, client, false);

    set_subject_page_probe(&database, None);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
