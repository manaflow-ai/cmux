//! Which `file:` URLs a tab may load: navigations and subresources (frames,
//! images, fetch), checked by the shim before Chromium opens the file
//! (`on_file_load`, `OnBeforeBrowse` and `OnBeforeResourceLoad`).
//!
//! A host starts with no policy: every file loads, as the Mac app's own
//! remote tabs expect. The viewer that streams to a phone (cmux-mobile-host)
//! sends `rb.file_policy {roots, files}` right after its hello; from then on
//! a `file:` URL loads only when its resolved path (symlinks followed, at
//! load time) is one of `files` or inside one of `roots`. A policy can be
//! replaced but never removed, and a viewer's phone cannot send one (hostd
//! forwards only the rb messages a viewer sends; cmux-next-ios
//! PROTOCOL.md `browser`).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::Value;

/// The rb message that sets the policy.
pub const MESSAGE: &str = "rb.file_policy";

/// At most this many roots and files (a policy is a short list).
const MAX_ENTRIES: usize = 256;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FilePolicy {
    roots: Vec<PathBuf>,
    files: Vec<PathBuf>,
}

impl FilePolicy {
    /// The policy of an `rb.file_policy` body (absolute paths only; each is
    /// resolved now, and one that does not resolve is left out).
    pub fn parse(body: &Value) -> Option<Self> {
        if body.get("t").and_then(Value::as_str) != Some(MESSAGE) {
            return None;
        }
        let list = |key: &str| -> Vec<PathBuf> {
            body.get(key)
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .take(MAX_ENTRIES)
                        .filter_map(Value::as_str)
                        .map(Path::new)
                        .filter(|p| p.is_absolute())
                        .filter_map(|p| std::fs::canonicalize(p).ok())
                        .collect()
                })
                .unwrap_or_default()
        };
        Some(Self { roots: list("roots"), files: list("files") })
    }

    /// Whether `url` (a `file:` URL) may load now.
    pub fn allows(&self, url: &str) -> bool {
        let Some(path) = file_path(url) else { return false };
        let Ok(resolved) = std::fs::canonicalize(&path) else { return false };
        self.files.contains(&resolved) || self.roots.iter().any(|root| resolved.starts_with(root))
    }
}

/// The path of a `file:` URL (`file:///p`, `file://localhost/p`, `file:/p`),
/// percent-decoded, without query or fragment. None for another host, a
/// relative path, a NUL or a bad escape.
pub fn file_path(url: &str) -> Option<PathBuf> {
    let url = url.trim();
    if !url.get(..5).is_some_and(|s| s.eq_ignore_ascii_case("file:")) {
        return None;
    }
    let rest = url[5..].split(['?', '#']).next().unwrap_or_default();
    let path = match rest.strip_prefix("//") {
        Some(after) => {
            let (host, path) = after.find('/').map_or((after, ""), |i| (&after[..i], &after[i..]));
            if !(host.is_empty() || host.eq_ignore_ascii_case("localhost")) {
                return None;
            }
            path
        }
        None => rest,
    };
    if !path.starts_with('/') {
        return None;
    }
    let mut bytes = Vec::with_capacity(path.len());
    let raw = path.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' {
            let hex = path.get(i + 1..i + 3)?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            bytes.push(raw[i]);
            i += 1;
        }
    }
    if bytes.contains(&0) {
        return None;
    }
    use std::os::unix::ffi::OsStrExt;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)))
}

static POLICY: Mutex<Option<Arc<FilePolicy>>> = Mutex::new(None);

/// Sets (or replaces) the process's policy.
pub fn set(policy: FilePolicy) {
    *POLICY.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Arc::new(policy));
}

/// Whether `url` may load under the process's policy (any thread; the IO thread
/// for subresources). No policy: yes. The path is resolved after the lock is
/// released, so a slow volume never holds up another thread's check.
pub fn check(url: &str) -> bool {
    let policy = POLICY.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    policy.is_none_or(|policy| policy.allows(url))
}

/// The `rb.text_input` body for the shim's text input state: `ui::TextInputType`
/// as a name, the composition rects and the caret (x, y, w, h in CSS pixels).
pub fn text_input(input_type: i32, rects: &[[i32; 4]], caret: Option<[i32; 4]>) -> Value {
    let name = match input_type {
        0 => "none",
        1 => "text",
        2 => "password",
        3 => "search",
        4 => "email",
        5 => "number",
        6 => "telephone",
        7 => "url",
        8..=13 => "date_time",
        14 => "text_area",
        15 => "content_editable",
        _ => "text",
    };
    let rect =
        |r: &[i32; 4]| serde_json::json!({"x": r[0], "y": r[1], "width": r[2], "height": r[3]});
    serde_json::json!({
        "t": "rb.text_input",
        "input_type": name,
        "composition_rects": rects.iter().map(rect).collect::<Vec<_>>(),
        "caret": caret.as_ref().map(rect),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh folder under the temp folder, removed on drop (the crate has no
    /// tempfile dependency and builds `--locked`).
    struct Dir(PathBuf);
    impl Dir {
        fn new(name: &str) -> Self {
            let path =
                std::env::temp_dir().join(format!("rb-file-policy-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn url(path: &Path) -> String {
        format!("file://{}", path.display()).replace(' ', "%20")
    }

    #[test]
    fn files_load_only_inside_the_roots_or_the_named_files() {
        let shared = Dir::new("shared");
        let elsewhere = Dir::new("elsewhere");
        std::fs::create_dir(shared.path().join("sub")).unwrap();
        std::fs::write(shared.path().join("sub/page one.html"), "x").unwrap();
        std::fs::write(elsewhere.path().join("secret"), "x").unwrap();
        std::fs::write(elsewhere.path().join("shown.html"), "x").unwrap();
        std::os::unix::fs::symlink(elsewhere.path().join("secret"), shared.path().join("link"))
            .unwrap();
        let body = serde_json::json!({
            "t": MESSAGE,
            "roots": [shared.path()],
            "files": [elsewhere.path().join("shown.html"), "relative/x", "/no/such/file"],
        });
        let policy = FilePolicy::parse(&body).unwrap();
        assert!(policy.allows(&url(&shared.path().join("sub/page one.html"))));
        assert!(policy.allows(&url(shared.path())));
        assert!(policy.allows(&format!("{}?q#f", url(&shared.path().join("sub/page one.html")))));
        assert!(policy.allows(&url(&elsewhere.path().join("shown.html"))));
        // Not the shown page's neighbours, not a symlink out, not `..`, not a missing file.
        assert!(!policy.allows(&url(&elsewhere.path().join("secret"))));
        assert!(!policy.allows(&url(&shared.path().join("link"))));
        assert!(!policy.allows(&format!(
            "{}/sub/../../{}/secret",
            url(shared.path()),
            elsewhere.path().file_name().unwrap().to_str().unwrap()
        )));
        assert!(!policy.allows(&url(&shared.path().join("gone.html"))));
        assert!(!policy.allows("file://server/share/x"));
        assert!(!policy.allows("file:///tmp/%00x"));
        assert!(!policy.allows("https://example.com/"));
        // An empty policy refuses every file.
        let none = FilePolicy::parse(&serde_json::json!({"t": MESSAGE})).unwrap();
        assert!(!none.allows(&url(&shared.path().join("sub/page one.html"))));
        assert!(FilePolicy::parse(&serde_json::json!({"t": "rb.navigate"})).is_none());
    }

    #[test]
    fn text_input_names_the_field_and_its_caret() {
        let none = text_input(0, &[], None);
        assert_eq!(none["input_type"], "none");
        assert!(none["caret"].is_null());
        let field = text_input(3, &[[1, 2, 3, 4]], Some([10, 20, 1, 18]));
        assert_eq!(field["t"], "rb.text_input");
        assert_eq!(field["input_type"], "search");
        assert_eq!(field["caret"], serde_json::json!({"x": 10, "y": 20, "width": 1, "height": 18}));
        assert_eq!(field["composition_rects"][0]["width"], 3);
        let control: cmux_remote_browser::proto::Control = serde_json::from_value(field).unwrap();
        assert!(matches!(control, cmux_remote_browser::proto::Control::TextInput { .. }));
    }
}
