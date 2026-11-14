use super::*;
use std::os::unix::fs::MetadataExt;

struct Rig {
    root: PathBuf,
}

impl Rig {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("acpmux-store-{}", uuid::Uuid::now_v7()));
        crate::config::private_state_dir(&root).unwrap();
        Self { root }
    }

    /// A finished upload of `bytes` named `name` in chat `chat`, put into the store.
    fn upload(&self, chat: &str, name: &str, bytes: &[u8]) -> (PathBuf, Record) {
        let file = self.root.join(chat).join(uuid::Uuid::now_v7().to_string()).join(name);
        crate::agent_tools::write_private(&file, bytes).unwrap();
        let record = adopt(&self.root, &file, None, Some("Safari"), 42).unwrap();
        (file, record)
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn the_same_bytes_are_stored_once_however_often_they_are_uploaded() {
    let rig = Rig::new();
    let (a, ra) = rig.upload("chat-a", "image.png", b"same pixels");
    let (b, rb) = rig.upload("chat-a", "image.png", b"same pixels");
    let (c, rc) = rig.upload("chat-b", "Screenshot 3.png", b"same pixels");
    let (d, rd) = rig.upload("chat-b", "image.png", b"other pixels");
    assert_eq!(ra.sha256, rb.sha256);
    assert_eq!(ra.sha256, rc.sha256);
    assert_ne!(ra.sha256, rd.sha256);
    let ino = |p: &Path| std::fs::metadata(p).unwrap().ino();
    assert_eq!(ino(&a), ino(&b));
    assert_eq!(ino(&a), ino(&c));
    assert_ne!(ino(&a), ino(&d));
    let stored = stored_path(&rig.root, &ra.sha256).unwrap();
    assert_eq!(ino(&stored), ino(&a));
    assert_eq!(std::fs::read(&stored).unwrap(), b"same pixels");
    // Two stored files: one per distinct content.
    let shards = std::fs::read_dir(rig.root.join(STORE)).unwrap().flatten();
    let held: usize = shards.map(|s| std::fs::read_dir(s.path()).unwrap().count()).sum();
    assert_eq!(held, 2);
    // Stored bytes are read-only, so no upload's agent changes another's file.
    assert_eq!(std::fs::metadata(&stored).unwrap().mode() & 0o777, 0o400);
}

#[test]
fn each_upload_keeps_its_own_record() {
    let rig = Rig::new();
    let (a, ra) = rig.upload("chat-a", "image.png", b"x");
    let (c, rc) = rig.upload("chat-b", "Screenshot 3.png", b"x");
    assert_eq!(record(a.parent().unwrap()).unwrap(), ra);
    assert_eq!(record(c.parent().unwrap()).unwrap(), rc);
    assert_eq!(rc.name, "Screenshot 3.png");
    assert_eq!(rc.source.as_deref(), Some("Safari"));
    assert_eq!(rc.at, 42);
    assert_eq!(rc.size, 1);
    assert_eq!(rc.sha256, sha256_of(&c).unwrap());
}

#[test]
fn references_count_the_uploads_that_link_the_bytes() {
    let rig = Rig::new();
    let (a, r) = rig.upload("chat-a", "image.png", b"pixels");
    assert_eq!(references(&rig.root, &r.sha256), 1);
    let (b, _) = rig.upload("chat-b", "image.png", b"pixels");
    let (c, _) = rig.upload("chat-c", "image.png", b"pixels");
    assert_eq!(references(&rig.root, &r.sha256), 3);
    // Putting the same upload in again adds nothing.
    adopt(&rig.root, &a, Some(&r.sha256), None, 43).unwrap();
    assert_eq!(references(&rig.root, &r.sha256), 3);
    std::fs::remove_dir_all(b.parent().unwrap()).unwrap();
    assert_eq!(references(&rig.root, &r.sha256), 2);
    std::fs::remove_dir_all(c.parent().unwrap()).unwrap();
    assert_eq!(references(&rig.root, &r.sha256), 1);
}

#[test]
fn stored_bytes_go_only_once_no_chat_links_them() {
    let rig = Rig::new();
    let (a, r) = rig.upload("chat-a", "image.png", b"pixels");
    let (b, _) = rig.upload("chat-b", "image.png", b"pixels");
    let stored = stored_path(&rig.root, &r.sha256).unwrap();
    // Chat A is deleted: chat B still links the bytes, so they stay, and B's path still
    // opens them.
    let hashes = hashes_under(&rig.root.join("chat-a"));
    assert_eq!(hashes, vec![r.sha256.clone()]);
    std::fs::remove_dir_all(rig.root.join("chat-a")).unwrap();
    assert_eq!(release(&rig.root, &hashes), 0);
    assert!(stored.exists() && !a.exists());
    assert_eq!(std::fs::read(&b).unwrap(), b"pixels");
    // Chat B goes too: nothing links them, and they go.
    let hashes = hashes_under(&rig.root.join("chat-b"));
    std::fs::remove_dir_all(rig.root.join("chat-b")).unwrap();
    assert_eq!(release(&rig.root, &hashes), 1);
    assert!(!stored.exists());
    assert!(!stored.parent().unwrap().exists(), "an emptied shard folder goes");
}

#[test]
fn collect_deletes_only_what_nothing_links() {
    let rig = Rig::new();
    let (_, kept) = rig.upload("chat-a", "a.png", b"kept");
    let (gone, orphan) = rig.upload("chat-b", "b.png", b"orphan");
    // A crash between an upload's removal and its release left stored bytes behind.
    std::fs::remove_dir_all(gone.parent().unwrap()).unwrap();
    // Something the store did not name is never deleted.
    let stray = rig.root.join(STORE).join("zz").join("notes.txt");
    crate::agent_tools::write_private(&stray, b"x").unwrap();
    assert_eq!(collect(&rig.root), 1);
    assert!(stored_path(&rig.root, &kept.sha256).unwrap().exists());
    assert!(!stored_path(&rig.root, &orphan.sha256).unwrap().exists());
    assert!(stray.exists());
    assert_eq!(collect(&rig.root), 0);
}

#[test]
fn an_uploads_path_stays_the_one_the_agent_was_given() {
    let rig = Rig::new();
    let (first, _) = rig.upload("chat-a", "image.png", b"pixels");
    let given = first.clone();
    // The same bytes again in another chat: the first path is untouched and still opens.
    let (second, _) = rig.upload("chat-b", "image.png", b"pixels");
    assert_eq!(std::fs::read(&given).unwrap(), b"pixels");
    assert_eq!(std::fs::read(&second).unwrap(), b"pixels");
    // Its folder holds the file and its record, and no swap file was left beside it.
    let mut names: Vec<String> = std::fs::read_dir(second.parent().unwrap())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, vec![RECORD.to_owned(), "image.png".to_owned()]);
    // The first chat goes; the second's path still opens the bytes.
    let hashes = hashes_under(&rig.root.join("chat-a"));
    std::fs::remove_dir_all(rig.root.join("chat-a")).unwrap();
    release(&rig.root, &hashes);
    assert_eq!(std::fs::read(&second).unwrap(), b"pixels");
}

#[test]
fn a_stored_link_is_told_from_a_link_to_another_file() {
    let rig = Rig::new();
    let (a, _) = rig.upload("chat-a", "image.png", b"pixels");
    let _ = rig.upload("chat-b", "image.png", b"pixels");
    let open = |p: &Path| crate::config::private_state_file(p).unwrap();
    assert!(is_stored_link(&rig.root, &a, &open(&a)));
    // A file linked in from outside the uploads, under a forged record, is not the stored
    // bytes the record names.
    let elsewhere = rig.root.with_extension("outside");
    let outside = elsewhere.join("secret.txt");
    crate::agent_tools::write_private(&outside, b"secret").unwrap();
    let planted = rig.root.join("chat-c").join(uuid::Uuid::now_v7().to_string());
    crate::config::private_state_dir(&planted).unwrap();
    std::fs::hard_link(&outside, planted.join("x.txt")).unwrap();
    std::fs::copy(a.parent().unwrap().join(RECORD), planted.join(RECORD)).unwrap();
    assert!(!is_stored_link(&rig.root, &planted.join("x.txt"), &open(&outside)));
    std::fs::remove_dir_all(&elsewhere).unwrap();
}

#[test]
fn a_kept_chat_is_marked_and_unmarked() {
    let rig = Rig::new();
    let chat = rig.root.join("chat-a");
    assert!(!is_kept(&chat));
    set_kept(&chat, true).unwrap();
    assert!(is_kept(&chat));
    set_kept(&chat, false).unwrap();
    assert!(!is_kept(&chat));
    set_kept(&chat, false).unwrap();
}
