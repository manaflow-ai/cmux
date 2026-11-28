use super::*;
#[cfg(unix)]
#[tokio::test]
async fn a_pipe_inherited_by_a_helper_ends_with_its_leader() {
    let child = Command::new("sh")
        .args(["-c", "sleep 60 & printf 'last failure\\n'"])
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let out = collect(child, true, Duration::from_secs(2)).await.unwrap();
    assert!(out.contains("last failure"));
}

#[cfg(unix)]
#[tokio::test]
async fn a_command_that_never_exits_is_refused_at_its_bound() {
    let child = Command::new("sh")
        .args(["-c", "sleep 60"])
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(collect(child, true, Duration::from_millis(20)).await.is_err());
}

#[tokio::test]
async fn logs_keep_the_end_and_json_refuses_truncation() {
    let mut input = vec![b'a'; JSON_LIMIT + 1];
    input.extend_from_slice(b"\nlast failure\n");
    let tail = capture(input.as_slice(), true).await.unwrap();
    assert_eq!(tail.len(), TAIL_LIMIT);
    assert!(tail.ends_with(b"last failure\n"));
    assert!(capture(input.as_slice(), false).await.is_err());
}
