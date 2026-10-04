//! The `cmux link dial` contract: one JSON line on stderr for every outcome,
//! and a distinct exit code per failure.

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::*;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|value| (*value).to_string()).collect()
}

/// RED: each failure has its own exit code.
#[test]
fn every_failure_has_its_own_exit_code() {
    let cases = [
        (Failure::Refused(Some(DialError::UnknownHost)), 2, "unknown_host"),
        (Failure::Refused(Some(DialError::NotAuthorized)), 3, "not_authorized"),
        (Failure::Refused(Some(DialError::HostPaused)), 4, "host_paused"),
        (Failure::Refused(Some(DialError::Unreachable)), 5, "unreachable"),
        (Failure::Refused(None), 5, "unreachable"),
        (Failure::LinkUnavailable, 6, "link_unavailable"),
        (Failure::Refused(Some(DialError::BadRequest)), 64, "bad_request"),
        (Failure::BadUsage, 64, "bad_request"),
    ];
    for (failure, code, error_code) in cases {
        assert_eq!(failure.exit_code(), code, "{failure:?}");
        let line = failure.line();
        assert!(line.ends_with('\n') && line.matches('\n').count() == 1, "{line:?}");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error_code"], error_code, "{failure:?}");
        assert_eq!(value["path_state"], "unreachable");
        assert_eq!(value["relay_available"], false);
    }
}

#[test]
fn the_arguments_are_host_and_an_optional_service() {
    assert_eq!(parse(&args(&["--host", "host_a"])), Ok(("host_a".into(), Service::Daemon)));
    assert_eq!(
        parse(&args(&["--service", "ssh", "--host", "host_a"])),
        Ok(("host_a".into(), Service::Ssh))
    );
    for bad in [
        &["--host", "host_a", "--service", "shell"][..],
        &["--service", "ssh"],
        &["--host"],
        &["--host", "a", "--host", "b"],
        &["--host", "../x"],
        &["--host", "host_a", "--command", "sh"],
    ] {
        assert_eq!(parse(&args(bad)), Err(Failure::BadUsage), "{bad:?}");
    }
}

/// RED: with no link running, the dial is `link_unavailable` (exit 6), not a
/// bare error.
#[tokio::test]
async fn a_dial_with_no_running_link_is_link_unavailable() {
    let directory = cmux_unix_socket::short_test_dir("dialcli");
    let missing = directory.path().join("link.sock");
    let failure = connect(&missing, "host_a", Service::Daemon).await.unwrap_err();
    assert_eq!(failure, Failure::LinkUnavailable);
    assert_eq!(failure.exit_code(), 6);
}

#[tokio::test]
async fn a_refusal_from_the_link_keeps_its_code_and_a_success_names_the_path() {
    let directory = cmux_unix_socket::short_test_dir("dialcli");
    let path = directory.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let replies = [
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"host_paused\"}\n",
        "{\"relay_available\":false,\"ok\":true,\"path_state\":\"tunnel\"}\n",
    ];
    let server = tokio::spawn(async move {
        for reply in replies {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 256];
            let _ = stream.read(&mut request).await.unwrap();
            stream.write_all(reply.as_bytes()).await.unwrap();
        }
    });
    let refused = connect(&path, "host_a", Service::Ssh).await.unwrap_err();
    assert_eq!(refused.exit_code(), 4);
    let connected = connect(&path, "host_a", Service::Ssh).await.unwrap();
    let value: serde_json::Value = serde_json::from_str(&connected_line(&connected)).unwrap();
    assert_eq!(value["ok"], true);
    assert_eq!(value["path_state"], "tunnel");
    server.await.unwrap();
}
