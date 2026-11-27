//! Inference from fake /proc fixtures.
mod common;

use std::path::{Path, PathBuf};

use cmux_apps::infer::{InferError, infer, listening_inodes};
use common::{FakeFs, proc_entry, tcp_table};

#[test]
fn reads_the_listener_on_the_port_from_tcp() {
    let fs = FakeFs::default();
    fs.file("/proc/net/tcp", tcp_table(3000, 4242).as_bytes());
    proc_entry(&fs, 77, 1, 4242, "/work/web", &["node", "server.js", "--title", "my app"]);
    proc_entry(&fs, 78, 1, 5151, "/elsewhere", &["sleep", "100"]);

    let found = infer(&fs, Path::new("/proc"), 3000).unwrap();
    assert_eq!(found.pid, 77);
    assert_eq!(found.dir, PathBuf::from("/work/web"));
    assert_eq!(found.argv, ["node", "server.js", "--title", "my app"]);
    assert_eq!(found.command, "node server.js --title 'my app'");
}

#[test]
fn reads_tcp6_too() {
    let fs = FakeFs::default();
    fs.file("/proc/net/tcp", tcp_table(9999, 1).as_bytes());
    let six = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
               0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 8080 1 0000000000000000 100 0 0 10 0\n";
    fs.file("/proc/net/tcp6", six.as_bytes());
    proc_entry(&fs, 90, 1, 8080, "/work/api", &["python3", "-m", "http.server"]);

    let found = infer(&fs, Path::new("/proc"), 8080).unwrap();
    assert_eq!((found.pid, found.command.as_str()), (90, "python3 -m http.server"));
}

#[test]
fn a_connected_socket_on_the_port_is_not_a_listener() {
    // Row 1 of the fixture is an ESTABLISHED socket whose local port is 0x1F40 (8000).
    assert!(listening_inodes(&tcp_table(3000, 4242), 8000).is_empty());
    assert_eq!(listening_inodes(&tcp_table(3000, 4242), 3000), [4242]);
}

#[test]
fn forked_workers_resolve_to_the_parent_server() {
    let fs = FakeFs::default();
    fs.file("/proc/net/tcp", tcp_table(5000, 600).as_bytes());
    proc_entry(&fs, 40, 1, 600, "/work/web", &["gunicorn", "app:app"]);
    proc_entry(&fs, 41, 40, 600, "/work/web", &["gunicorn", "app:app"]);
    proc_entry(&fs, 42, 40, 600, "/work/web", &["gunicorn", "app:app"]);
    assert_eq!(infer(&fs, Path::new("/proc"), 5000).unwrap().pid, 40);
}

#[test]
fn nothing_listening_refuses_and_names_the_flags() {
    let fs = FakeFs::default();
    fs.file("/proc/net/tcp", tcp_table(3000, 4242).as_bytes());
    let error = infer(&fs, Path::new("/proc"), 4000).unwrap_err();
    assert_eq!(error, InferError::NoListener { port: 4000 });
    let text = error.to_string();
    assert!(text.contains("--cmd") && text.contains("--dir"), "{text}");
}

#[test]
fn a_listener_held_by_an_unreadable_process_refuses_and_names_the_flags() {
    let fs = FakeFs::default();
    fs.file("/proc/net/tcp", tcp_table(3000, 4242).as_bytes());
    // pid 1 exists but its fds can't be listed (another user's process).
    fs.file("/proc/1/stat", b"1 (init) S 0 1 1 0");
    let error = infer(&fs, Path::new("/proc"), 3000).unwrap_err();
    assert_eq!(error, InferError::Unseen { port: 3000 });
    assert!(error.to_string().contains("--cmd CMD and --dir DIR"));
}
