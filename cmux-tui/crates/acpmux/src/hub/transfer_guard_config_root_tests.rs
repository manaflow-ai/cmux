use super::*;

/// A host's webRoots held "/tmp" (a probe appended its cwd), and every hub move
/// to it failed `transfer.guard: root "/tmp" is not under the home folder`. A bad root is
/// left out; the good ones still take the move.
#[tokio::test]
async fn a_bad_web_root_is_left_out_not_fatal() {
    let Some(home) = dirs::home_dir() else { return };
    let work = home.join(format!("acpmux-guard-test-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&work).unwrap();
    let roots = vec!["/tmp".to_string(), work.to_string_lossy().into_owned(), "relative".into()];
    let guard = Guard::from_config_roots(&roots).await;
    let only_bad = Guard::from_config_roots(&["/tmp".to_string()]).await;
    let none = Guard::from_config_roots(&[]).await;
    std::fs::remove_dir(&work).unwrap();
    let guard = guard.unwrap();
    assert_eq!(guard.roots.len(), 1);
    assert!(guard.roots[0].ends_with(work.file_name().unwrap()));
    assert!(guard.control == Control::Peer && !guard.owner);
    let msg = only_bad.err().unwrap().message;
    assert!(msg.contains("\"/tmp\"") && msg.contains("not under the home folder"), "{msg}");
    assert!(none.err().unwrap().message.contains("no usable webRoots"));
}
