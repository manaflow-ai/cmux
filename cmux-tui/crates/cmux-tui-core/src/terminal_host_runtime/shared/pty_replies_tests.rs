use super::*;
use std::sync::mpsc::channel;
use std::time::Duration;

#[test]
fn the_writer_thread_starts_with_the_first_answer() {
    let (written, received) = channel::<(Vec<u8>, Option<String>)>();
    let replies = PtyReplies::start(move |bytes| {
        let name = thread::current().name().map(str::to_owned);
        let _ = written.send((bytes.to_vec(), name));
    });
    assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Idle(_)));

    // An empty answer is nothing to write and starts nothing.
    assert!(replies.send(Vec::new(), |_| panic!("an empty answer was written inline")));
    assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Idle(_)));

    for answer in [b"one".to_vec(), b"two".to_vec()] {
        assert!(replies.send(answer, |_| panic!("the answer was written inline")));
    }
    assert!(matches!(*replies.writer.lock().recover_poison(), Writer::Running(_)));
    for expected in [b"one".to_vec(), b"two".to_vec()] {
        let (bytes, name) = received.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(bytes, expected);
        assert_eq!(name.as_deref(), Some("terminal-host-replies"));
    }
}
