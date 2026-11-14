use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

#[test]
fn executable_is_the_peers_while_its_key_is_current() {
    let (ours, _theirs) = UnixStream::pair().expect("socketpair");
    let key = super::key(ours.as_raw_fd()).expect("peer key");
    let own =
        std::fs::canonicalize(std::env::current_exe().expect("current exe")).expect("canonical");
    let found = super::executable(&key).expect("peer executable");
    assert_eq!(std::fs::canonicalize(found).expect("canonical"), own);
}

#[test]
fn executable_refuses_a_stale_or_malformed_key() {
    let (ours, _theirs) = UnixStream::pair().expect("socketpair");
    let key = super::key(ours.as_raw_fd()).expect("peer key");
    let (pid, version) =
        key.strip_prefix("token:").and_then(|rest| rest.split_once('.')).expect("key shape");
    let stale = format!("token:{pid}.{}", version.parse::<u64>().expect("version") + 1);
    assert_eq!(super::executable(&stale), None);
    for bad in ["", "token:", "pid:1.2", "token:x.1", "token:../self.1", "token:0.1", "token:-1.1"]
    {
        assert_eq!(super::executable(bad), None, "{bad}");
        assert!(super::executable_file(bad).is_none(), "{bad}");
    }
    assert!(super::executable_file(&stale).is_none());
}

#[test]
fn executable_file_is_the_peers_binary_open() {
    use std::os::unix::fs::MetadataExt as _;
    let (ours, _theirs) = UnixStream::pair().expect("socketpair");
    let key = super::key(ours.as_raw_fd()).expect("peer key");
    let own = std::env::current_exe().expect("current exe");
    let (path, file) = super::executable_file(&key).expect("peer executable");
    assert_eq!(
        std::fs::canonicalize(path).expect("canonical"),
        std::fs::canonicalize(&own).expect("canonical")
    );
    let (opened, expected) =
        (file.metadata().expect("opened"), std::fs::metadata(&own).expect("own"));
    assert_eq!((opened.dev(), opened.ino()), (expected.dev(), expected.ino()));
}
