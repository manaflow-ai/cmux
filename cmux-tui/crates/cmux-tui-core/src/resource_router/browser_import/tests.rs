use serde_json::{Map, json};

use super::*;

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

/// An empty folder of this test's own, removed when dropped.
struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("cmux-browser-import-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("test folder");
        Self(path)
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn every_reader_is_named_and_unknown_ones_are_refused() {
    let empty = Folder::new("readers");
    let dir = empty.path().to_string_lossy().into_owned();
    for reader in ops::OPS {
        let request = json!({
            "reader": reader, "path": empty.path().join("none").to_string_lossy(),
            "profile": dir, "sessions": dir, "profileDirectory": "Default", "head": "[]",
            "engine": {"name": "K", "search": "https://kagi.com/?q={searchTerms}"},
            "builtIn": {},
        });
        let reply = read(fields(request), None).expect(reader);
        assert!(reply.get("ok").is_some() || reply["error"]["kind"].is_string(), "{reply}");
    }
    let unknown = read(fields(json!({"reader": "opera.passwords"})), None).unwrap_err();
    assert_eq!(unknown.code, "validation.invalid");
    assert!(read(fields(json!({})), None).is_err());
    assert!(read(fields(json!({"reader": "chromium.history"})), None).is_err());
}

#[test]
fn a_protected_folder_of_the_home_is_never_opened() {
    let home = Folder::new("protected");
    let safari = home.path().join("Library/Safari");
    std::fs::create_dir_all(&safari).expect("safari folder");
    let history = safari.join("History.db").to_string_lossy().into_owned();
    let refused =
        read(fields(json!({"reader": "safari.history", "path": history})), Some(home.path()))
            .unwrap_err();
    assert_eq!(refused.code, "validation.invalid");
    let profile = home.path().join("Library/Group Containers/com.alohabrowser.alohabrowser");
    let refused = read(
        fields(json!({"reader": "chromium.extensions", "profile": profile.to_string_lossy()})),
        Some(home.path()),
    );
    assert!(refused.is_err());
}

#[test]
fn a_protected_file_is_read_from_an_upload_in_memory() {
    let upload = format!("core-{}", std::process::id());
    let append =
        json!({"reader": "upload.append", "upload": upload, "name": "Bookmarks", "base64": "e30="});
    assert_eq!(read(fields(append), None).expect("append"), json!({"ok": null}));
    let request = json!({"reader": "chromium.bookmarks", "upload": upload, "path": "Bookmarks"});
    let reply = read(fields(request.clone()), None).expect("read");
    assert_eq!(reply["error"]["kind"], "notBookmarks", "the upload's bytes were read: {reply}");
    let drop = json!({"reader": "upload.drop", "upload": upload});
    assert_eq!(read(fields(drop), None).expect("drop"), json!({"ok": null}));
    let gone = read(fields(request), None).expect("read");
    assert_eq!(gone["error"]["kind"], "read", "{gone}");
    let climbs = json!({"reader": "chromium.bookmarks", "upload": upload, "path": "../Bookmarks"});
    assert!(read(fields(climbs), None).is_err());
}
