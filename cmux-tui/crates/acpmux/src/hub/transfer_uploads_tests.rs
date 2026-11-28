use super::*;
use std::path::PathBuf;

fn upload_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// A finished upload of chat `session`, the way `file_uploads` leaves one: the file, owner-only,
/// beside its folder's own files.
fn uploaded(session: &str, name: &str, bytes: &[u8]) -> (String, PathBuf) {
    let upload = upload_id();
    let dir = file_uploads::session_dir(session).unwrap().join(&upload);
    crate::home_fs::create_dirs(&dir).unwrap();
    let file = dir.join(name);
    crate::agent_tools::write_private(&file, bytes).unwrap();
    crate::agent_tools::write_private(&dir.join(".meta"), b"{}").unwrap();
    crate::agent_tools::write_private(&dir.join(".used"), b"").unwrap();
    (upload, file)
}

fn bundle_dir() -> PathBuf {
    let dir =
        crate::config::home().join("transfers").join(format!("test-{}", uuid::Uuid::now_v7()));
    crate::home_fs::create_dirs(&dir).unwrap();
    dir
}

fn chat() -> String {
    format!("chat-{}", uuid::Uuid::now_v7().simple())
}

#[test]
fn moving_uploads_is_off_unless_its_flag_says_on() {
    assert!(!flag_on(None));
    assert!(!flag_on(Some("")));
    assert!(!flag_on(Some("0")));
    assert!(!flag_on(Some("true")));
    assert!(flag_on(Some("1")));
    assert!(flag_on(Some(" 1\n")));
}

#[test]
fn only_a_uuidv7_folder_and_a_plain_name_are_a_bundled_upload() {
    let upload = upload_id();
    assert!(valid_parts(&upload, "report.pdf"));
    assert!(!valid_parts(&upload, ".meta"), "a folder's own file stays behind");
    assert!(!valid_parts(&upload, ".part"));
    assert!(!valid_parts(&upload, "a/b"));
    assert!(!valid_parts(&upload, ".."));
    assert!(!valid_parts("019a-upload", "report.pdf"), "not a UUIDv7");
    assert!(!valid_parts(&uuid::Uuid::new_v4().to_string(), "report.pdf"));
}

#[test]
fn a_moved_chat_takes_its_finished_uploads_and_the_target_keeps_them_under_the_same_ids() {
    let (source, target) = (chat(), chat());
    let (first, _) = uploaded(&source, "notes.txt", b"hello");
    let (second, _) = uploaded(&source, "shot.png", &[0u8, 1, 2, 3]);
    // An unfinished upload has only its `.part`: nothing of it goes.
    let unfinished = upload_id();
    let dir = file_uploads::session_dir(&source).unwrap().join(&unfinished);
    crate::home_fs::create_dirs(&dir).unwrap();
    crate::agent_tools::write_private(&dir.join(".part"), b"half").unwrap();

    let bundle = bundle_dir();
    assert_eq!(bundle_uploads(&source, &bundle).unwrap(), 2);
    let mut paths: Vec<String> = crate::hub::transfer_out::bundle_files(&bundle)
        .unwrap()
        .into_iter()
        .map(|(path, _)| path)
        .collect();
    paths.sort();
    let mut want = vec![format!("uploads/{first}/notes.txt"), format!("uploads/{second}/shot.png")];
    want.sort();
    assert_eq!(paths, want, "only finished files, none of a folder's own");

    assert_eq!(restore_uploads(&bundle, &target).unwrap(), 2);
    let kept = file_uploads::finished_path(&target, &first, "notes.txt").unwrap();
    assert_eq!(std::fs::read(&kept).unwrap(), b"hello");
    assert!(file_uploads::open_finished(&kept).is_ok(), "a prompt's reference resolves to it");
    assert!(unacked_uploads(&bundle, &target).is_empty());

    // A chat moved back finds its own uploads, kept as they are.
    assert_eq!(restore_uploads(&bundle, &target).unwrap(), 2);
}

#[test]
fn an_upload_the_target_did_not_keep_is_named_so_the_move_fails_while_the_source_holds_it() {
    let (source, target) = (chat(), chat());
    let (upload, _) = uploaded(&source, "big.bin", b"0123456789");
    let bundle = bundle_dir();
    bundle_uploads(&source, &bundle).unwrap();
    assert_eq!(unacked_uploads(&bundle, &target), vec![format!("uploads/{upload}/big.bin")]);
}

#[test]
fn a_chat_with_no_uploads_bundles_none() {
    let bundle = bundle_dir();
    assert_eq!(bundle_uploads(&chat(), &bundle).unwrap(), 0);
    assert!(!bundle.join(BUNDLE_DIR).exists());
    assert_eq!(bundle_uploads("../escape", &bundle).unwrap(), 0);
}

#[cfg(unix)]
#[test]
fn a_symlink_in_a_chats_uploads_is_never_bundled() {
    let source = chat();
    let (upload, _) = uploaded(&source, "real.txt", b"mine");
    let dir = file_uploads::session_dir(&source).unwrap().join(&upload);
    std::os::unix::fs::symlink("/etc/hosts", dir.join("hosts")).unwrap();
    let bundle = bundle_dir();
    assert_eq!(bundle_uploads(&source, &bundle).unwrap(), 1);
    assert!(!bundle.join(BUNDLE_DIR).join(&upload).join("hosts").exists());
}

#[test]
fn a_guarded_move_takes_uploads_and_an_older_target_is_left_them_out() {
    let upload = upload_id();
    let path = format!("uploads/{upload}/notes.txt");
    assert_eq!(crate::hub::transfer_guard::bundle_path_kind(&path), Some(false));
    let own = format!("uploads/{upload}/.meta");
    assert_eq!(crate::hub::transfer_guard::bundle_path_kind(&own), None);
    assert_eq!(crate::hub::transfer_guard::bundle_path_kind("uploads/x/notes.txt"), None);
    assert_eq!(
        crate::capabilities::optional_bundle_file(&path),
        Some(crate::capabilities::TRANSFER_UPLOADS)
    );
    let mut manifest = serde_json::json!({"files": [{"path": path}, {"path": "session.json"}]});
    let left = crate::capabilities::leave_out_untaken(&mut manifest, |c| {
        c != crate::capabilities::TRANSFER_UPLOADS
    });
    assert_eq!(left, vec![path]);
    assert!(crate::capabilities::left_out_line(&left).unwrap().contains("uploaded files"));
}
