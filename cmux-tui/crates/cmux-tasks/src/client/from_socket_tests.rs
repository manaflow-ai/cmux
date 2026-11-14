use super::Conn;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

#[test]
fn from_socket_sends_a_request_and_reads_its_reply_on_one_socket() {
    let (ours, owner) = UnixStream::pair().unwrap();
    let mut conn = Conn::from_socket(ours).unwrap();
    assert!(!conn.is_in_process());
    let fake_owner = std::thread::spawn(move || {
        let mut lines = BufReader::new(owner.try_clone().unwrap()).lines();
        let request: serde_json::Value =
            serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        assert_eq!(request["op"], "task.get");
        assert_eq!(request["id"], 1);
        let mut owner = owner;
        writeln!(owner, r#"{{"id":1,"ok":{{"hello":true}}}}"#).unwrap();
        writeln!(owner, r#"{{"settled":{{"id":1,"tx":"t","seq":7}}}}"#).unwrap();
    });
    let (reply, seq) = conn.call("task.get", serde_json::json!({}), None).unwrap();
    fake_owner.join().unwrap();
    assert_eq!(reply, serde_json::json!({"hello": true}));
    assert_eq!(seq, 7);
}
