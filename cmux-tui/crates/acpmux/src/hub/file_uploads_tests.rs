use super::*;

#[test]
fn a_file_name_is_one_plain_file() {
    for good in ["state.sqlite", "a b.txt", "日本語.pdf", "x"] {
        assert!(is_file_name(good), "{good}");
    }
    let long = "a".repeat(256);
    for bad in
        ["", ".env", ".", "..", "a/b", "a\u{0}b", "a\nb", "a\u{7f}", "a\u{202e}txt", long.as_str()]
    {
        assert!(!is_file_name(bad), "{bad:?}");
    }
    // A drive prefix or a data stream on Windows, which a join would take out of the folder.
    if cfg!(windows) {
        for bad in ["C:evil.txt", "a.txt:stream", "a\\b"] {
            assert!(!is_file_name(bad), "{bad:?}");
        }
    }
}

#[test]
fn a_windows_device_name_is_no_file_name_on_windows() {
    // Windows opens these as devices in any folder (`dir\CON` is the console), and drops a
    // trailing dot or space, so the write would not land in the upload's own file.
    for bad in [
        "CON",
        "con.txt",
        "NUL",
        "nul.tar.gz",
        "AUX",
        "PRN",
        "COM1",
        "lpt9.log",
        "COM\u{b9}",
        "CONIN$",
        "a.",
        "a ",
    ] {
        assert!(!is_file_name_for(bad, true), "{bad:?}");
        assert!(is_file_name_for(bad, false), "{bad:?}");
    }
    for good in ["CONSOLE.txt", "COM10", "COM0", "nullable.rs", "aux_data.csv", "LPT", "report.pdf"]
    {
        assert!(is_file_name_for(good, true), "{good:?}");
    }
}

#[test]
fn legacy_requests_past_the_old_cap_are_validated_without_decoding_the_file() {
    use base64::Engine;
    for n in [0, 1, 2, 3, 4, LEGACY_MAX_BYTES, LEGACY_MAX_BYTES + 1, LEGACY_MAX_BYTES + 2] {
        let data = base64::engine::general_purpose::STANDARD.encode(vec![0u8; n]);
        assert_eq!(decoded_len(&data), n);
        assert!(check(&json!({"fileName": "big.bin", "data": data})).is_ok());
    }
}

#[test]
fn the_sweep_deletes_old_uploads_and_keeps_new_ones_and_what_it_did_not_name() {
    let root = std::env::temp_dir().join(format!("acpmux-sweep-{}", uuid::Uuid::now_v7()));
    let day = 24 * 60 * 60 * 1000;
    let now = crate::store::now_ms();
    let named = |ms: u64| {
        let at = uuid::Timestamp::from_unix(uuid::NoContext, ms / 1000, 0);
        uuid::Uuid::new_v7(at).to_string()
    };
    let old = root.join("chat-a").join(named(now - 31 * day));
    let new = root.join("chat-a").join(named(now - day));
    let only_old = root.join("chat-b").join(named(now - 40 * day));
    let other = root.join("chat-c").join("notes");
    let v4 = root.join("chat-c").join("0190a000-0000-4000-8000-000000000000");
    // An old upload that a prompt used just now stays.
    let used = root.join("chat-a").join(named(now - 35 * day));
    for dir in [&old, &new, &only_old, &other, &v4, &used] {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("f.txt"), b"x").unwrap();
    }
    touch(&used.join("f.txt")).unwrap();
    // An old upload still being written (its `.part` just now) stays.
    let writing = root.join("chat-a").join(named(now - 45 * day));
    std::fs::create_dir_all(&writing).unwrap();
    std::fs::write(writing.join(".part"), b"x").unwrap();
    // An old-named link, and a linked session folder: neither is followed.
    let outside = root.with_extension("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("keep.txt"), b"x").unwrap();
    let outside_old = outside.join(named(now - 90 * day));
    std::fs::create_dir_all(&outside_old).unwrap();
    #[cfg(unix)]
    {
        std::fs::create_dir_all(root.join("chat-d")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("chat-d").join(named(now - 90 * day)))
            .unwrap();
        std::os::unix::fs::symlink(&outside, root.join("chat-e")).unwrap();
    }
    assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 2);
    assert!(!old.exists() && new.exists() && used.exists() && writing.exists());
    assert!(!root.join("chat-b").exists(), "an emptied session folder stays");
    assert!(other.exists() && v4.exists());
    assert!(outside.join("keep.txt").exists() && outside_old.exists());
    // Nothing past the cap is left: a second sweep deletes nothing.
    assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 0);
    std::fs::remove_dir_all(&root).unwrap();
    std::fs::remove_dir_all(&outside).unwrap();
}

#[test]
#[cfg(unix)]
fn the_sweep_keeps_a_kept_chats_uploads_and_drops_bytes_once_nothing_names_them() {
    let root = std::env::temp_dir().join(format!("acpmux-sweep-{}", uuid::Uuid::now_v7()));
    let day = 24 * 60 * 60 * 1000;
    let now = crate::store::now_ms();
    let named = |ms: u64| {
        let at = uuid::Timestamp::from_unix(uuid::NoContext, ms / 1000, 0);
        uuid::Uuid::new_v7(at).to_string()
    };
    let put = |chat: &str, at: u64, bytes: &[u8]| {
        let file = root.join(chat).join(named(at)).join("image.png");
        crate::agent_tools::write_private(&file, bytes).unwrap();
        store::adopt(&root, &file, None, None, at).unwrap();
        file
    };
    // One screenshot, old in a pinned chat and in an unpinned one, new in a third; another
    // old one only in the unpinned chat.
    let pinned = put("chat-pinned", now - 40 * day, b"shot");
    let old = put("chat-old", now - 40 * day, b"shot");
    let fresh = put("chat-new", now - day, b"shot");
    let lone = put("chat-old", now - 40 * day, b"lone");
    store::set_kept(&root.join("chat-pinned"), true).unwrap();
    let shot = store::sha256_of(&pinned).unwrap();
    let lone_hash = store::sha256_of(&lone).unwrap();
    assert_eq!(store::references(&root, &shot), 3);
    assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 2);
    // The pinned chat keeps its file however old; the new one keeps its own.
    assert!(pinned.exists() && fresh.exists() && !old.exists() && !lone.exists());
    assert_eq!(store::references(&root, &shot), 2);
    // Bytes no chat names any more are gone; the shared ones stay.
    assert!(store::stored_path(&root, &shot).unwrap().exists());
    assert!(!store::stored_path(&root, &lone_hash).unwrap().exists());
    // The store's own folder is never read as a chat's.
    assert!(root.join(store::STORE).exists());
    // Unpinned, the chat's file ages out too, and the bytes go with the last name.
    store::set_kept(&root.join("chat-pinned"), false).unwrap();
    std::fs::remove_dir_all(root.join("chat-new")).unwrap();
    assert_eq!(sweep(&root, now, Duration::from_millis(30 * day)), 1);
    assert!(!store::stored_path(&root, &shot).unwrap().exists());
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
#[cfg(unix)]
fn a_full_disk_is_the_one_size_failure_and_names_the_host_and_path() {
    let e = std::io::Error::from_raw_os_error(libc::ENOSPC);
    let err = failed("cannot append upload", Path::new("/x/.part"), &e, Some(7));
    let data = err.data.unwrap();
    assert_eq!(data["reason"], "upload.diskFull");
    assert_eq!(data["path"], "/x/.part");
    assert_eq!(data["offset"], 7);
    assert_eq!(data["host"], crate::host_pressure::host_name());
    let other = failed("x", Path::new("/x"), &std::io::Error::other("no"), None);
    assert!(other.data.is_none());
}

#[test]
fn the_cap_leaves_the_frame_room_on_an_old_peers_link() {
    // tungstenite's default frame limit, which an older peer's listener keeps.
    let frame = 16 << 20;
    assert!(LEGACY_MAX_BYTES.div_ceil(3) * 4 + 4096 < frame);
}

/// Forced lost-home races for an upload's finish (#41372 review F3): the home is replaced by
/// a copy of itself (as restored from the old one) once the writer passed its home check.
/// The finished file and its stored bytes land in the held home; the new one is never changed.
#[cfg(unix)]
mod lost_home {
    use super::*;
    use crate::lost_home_race_tests::{copy_tree, forced, isolated};

    /// An upload begun and written whole in this daemon's home: its id.
    fn written(bytes: &[u8]) -> String {
        let began = begin("chat-a", &json!({"fileName": "f.bin", "size": bytes.len()})).unwrap();
        let id = began["uploadId"].as_str().unwrap().to_owned();
        append("chat-a", &id, 0, bytes).unwrap();
        id
    }

    fn seed(home: &Path) {
        copy_tree(&home.with_extension("old"), home);
    }

    /// The finish's rename of `.part` to the file's name and its removal of `.meta`.
    #[test]
    fn an_upload_finish_held_past_its_check() {
        isolated(
            module_path!(),
            "an_upload_finish_held_past_its_check",
            |home| {
                let id = written(b"hello");
                let target = finished_path("chat-a", &id, "f.bin").unwrap();
                let kept = format!("uploads/chat-a/{id}/f.bin");
                forced(home, target, seed, Some(&kept), move || {
                    let params = json!({"uploadId": id, "fileName": "f.bin", "size": 5});
                    let _ = finish("chat-a", &params);
                });
            },
            |_, _| {},
        );
    }

    /// The store's link of a finished upload's bytes (`store::adopt`): its mode narrowed and
    /// a hard link made in the store, held at the check of the store's shard folder.
    #[test]
    fn an_upload_store_link_held_past_its_check() {
        isolated(
            module_path!(),
            "an_upload_store_link_held_past_its_check",
            |home| {
                let id = written(b"hello");
                let hash = crate::sha256::sha256_hex(b"hello");
                let stored = store::stored_path(&root(), &hash).unwrap();
                let target = stored.parent().unwrap().to_path_buf();
                let kept = stored.strip_prefix(home).unwrap().to_string_lossy().into_owned();
                forced(home, target, seed, Some(&kept), move || {
                    let params = json!({"uploadId": id, "fileName": "f.bin", "size": 5});
                    let _ = finish("chat-a", &params);
                });
            },
            |_, _| {},
        );
    }
}
