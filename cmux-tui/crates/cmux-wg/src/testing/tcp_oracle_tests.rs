use super::*;

#[test]
fn a_faithful_stream_passes() {
    let mut oracle = StreamOracle::new(false);
    oracle.wrote(End::Client, b"hello ").unwrap();
    oracle.wrote(End::Client, b"world").unwrap();
    oracle.shutdown(End::Client);
    oracle.read(End::Server, b"hel").unwrap();
    oracle.read(End::Server, b"lo world").unwrap();
    oracle.eof(End::Server).unwrap();
    oracle.finish([false, true]).unwrap();
}

#[test]
fn each_broken_promise_is_caught() {
    let mut oracle = StreamOracle::new(false);
    oracle.wrote(End::Client, b"abc").unwrap();
    assert!(oracle.clone().read(End::Server, b"abd").is_err(), "corruption");
    assert!(oracle.clone().read(End::Server, b"abcd").is_err(), "invented byte");
    assert!(oracle.clone().eof(End::Server).is_err(), "EOF before FIN");
    oracle.read(End::Server, b"ab").unwrap();
    assert!(oracle.clone().read(End::Server, b"b").is_err(), "duplicate");
    oracle.shutdown(End::Client);
    assert!(oracle.clone().wrote(End::Client, b"x").is_err(), "write after shutdown");
    assert!(oracle.clone().eof(End::Server).is_err(), "EOF before the last byte");
    assert!(oracle.finish([false, true]).is_err(), "no EOF at the end");
    assert!(oracle.error(End::Client, "reset").is_err(), "unexpected reset");
}
