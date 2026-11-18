//! `browser_import.read` (read, `browser-import-v1`): one reader of another browser's files for
//! the app's browser import, run by the `cmux-browser-import` crate. `reader` names it
//! (`cmux_browser_import::ops::OPS`: `chromium.bookmarks`, `firefox.history`,
//! `search_engine.setting`, ...); the other fields are its request, and the result is its reply,
//! `{ok}` or `{error: {kind, message}}` when the source file does not read.
//!
//! Only the verified app connection sends it (`request_origin::USER_ONLY_OPERATIONS`): it opens a
//! file by path. A path under a folder macOS protects in the daemon's home (Safari's, an app
//! container's: `cmux_browser_import::ops::PROTECTED`) is refused, so the daemon never opens one;
//! the app reads what a reader needs there and sends the bytes into an upload held in the
//! daemon's memory only (`upload.append`, `upload.drop`: `cmux_browser_import::upload`), which a
//! read names. Nothing else is kept between calls; every database on disk is read from a private
//! copy, and one in an upload is opened in memory.

use std::path::PathBuf;
use std::sync::Arc;

use cmux_browser_import::ops::{self, OpError};
use serde_json::Value;

use super::{ParsedResourceRequest, ensure_session_route};
use crate::Mux;
use crate::resource::ResourceError;

/// Advertised in identify: the daemon answers `browser_import.read`.
pub(crate) const CAPABILITY: &str = "browser-import-v1";
/// Only the verified app sends it (`request_origin::USER_ONLY_OPERATIONS`).
pub(crate) const OPERATION: &str = "browser_import.read";

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    read(request.fields, home().as_deref())
}

/// The daemon's own home, whose protected folders are refused.
fn home() -> Option<PathBuf> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).filter(|value| !value.is_empty()).map(PathBuf::from)
}

/// The reply to one request's fields, with `home`'s protected folders refused.
pub(crate) fn read(
    mut fields: serde_json::Map<String, Value>,
    home: Option<&std::path::Path>,
) -> Result<Value, ResourceError> {
    let reader = match fields.remove("reader") {
        Some(Value::String(reader)) => reader,
        _ => return Err(ResourceError::validation_invalid(Some("reader"), "reader is required")),
    };
    ops::call(&reader, &Value::Object(fields), home).map_err(|error| match error {
        OpError::Unknown => ResourceError::validation_invalid(
            Some("reader"),
            format!("{reader} is not a browser import reader"),
        ),
        OpError::Invalid => ResourceError::validation_invalid(
            None,
            format!("{reader}: a field it needs is missing or of the wrong type"),
        ),
        OpError::Refused => ResourceError::validation_invalid(
            None,
            format!(
                "{reader}: the path is not absolute, climbs with .., or is under a folder macOS \
                 protects (the app sends what it reads there into an upload)"
            ),
        ),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::{Map, json};

    use super::*;

    fn fields(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap_or_default()
    }

    /// An empty folder of this test's own, removed when dropped.
    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir()
                .join(format!("cmux-browser-import-{name}-{}", std::process::id()));
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
        let append = json!({"reader": "upload.append", "upload": upload, "name": "Bookmarks", "base64": "e30="});
        assert_eq!(read(fields(append), None).expect("append"), json!({"ok": null}));
        let request =
            json!({"reader": "chromium.bookmarks", "upload": upload, "path": "Bookmarks"});
        let reply = read(fields(request.clone()), None).expect("read");
        assert_eq!(reply["error"]["kind"], "notBookmarks", "the upload's bytes were read: {reply}");
        let drop = json!({"reader": "upload.drop", "upload": upload});
        assert_eq!(read(fields(drop), None).expect("drop"), json!({"ok": null}));
        let gone = read(fields(request), None).expect("read");
        assert_eq!(gone["error"]["kind"], "read", "{gone}");
        let climbs =
            json!({"reader": "chromium.bookmarks", "upload": upload, "path": "../Bookmarks"});
        assert!(read(fields(climbs), None).is_err());
    }
}
