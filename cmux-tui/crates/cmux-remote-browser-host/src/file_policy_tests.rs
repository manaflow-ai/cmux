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
