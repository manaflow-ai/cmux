use super::*;
use serde_json::Value;

/// Every case of the shared vectors resolves as libghostty does.
#[test]
fn the_daemon_reads_every_vector_as_libghostty() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../../../schemas/ghostty-shell-features/vectors.json"
    ))
    .unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 20);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "cmux-ghostty-shell-features-{}-{}",
            std::process::id(),
            name.replace(|c: char| !c.is_ascii_alphanumeric(), "-")
        ));
        let _ = fs::remove_dir_all(&dir);
        for (file, text) in case["files"].as_object().unwrap() {
            let path = dir.join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, text.as_str().unwrap()).unwrap();
        }
        let settings = read_files(&[dir.join("config")], None);
        let mut expected = Features::all(false);
        for feature in case["features"].as_array().unwrap() {
            *expected.field(feature.as_str().unwrap()).unwrap() = true;
        }
        assert_eq!(settings.features, expected, "{name}");
        assert_eq!(settings.cursor_blink, case["cursor_blink"].as_bool(), "{name}");
        assert_eq!(settings.mode.name(), case["shell_integration"].as_str().unwrap(), "{name}");
        fs::remove_dir_all(&dir).unwrap();
    }
}
