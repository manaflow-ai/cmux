//! A look's composer shows exactly one attach control. The + menu always holds Add files (and
//! screenshots, windows), so a look whose `cmux.composer.toolbar/1` also adds a
//! `composer.attachFiles` button draws a paperclip beside the + that opens the same chooser: the
//! double attach lane-6's claude-code-app and t3-code captures graded as a mismatch with the real
//! apps, which have one.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

fn looks() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/looks")
}

fn manifests(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            manifests(&path, found);
        } else if path.file_name().is_some_and(|name| name == "cmux-app.json")
            // A composer-only part (`t3code/composer`, `"surface": "composer"`) is the one place an
            // attach button beside the draft is the whole ask; a whole look or profile is not.
            && !path.ends_with("composer/customize/cmux-app.json")
        {
            found.push(path);
        }
    }
}

#[test]
fn no_look_adds_a_second_attach_beside_the_plus() {
    let mut found = Vec::new();
    manifests(&looks(), &mut found);
    assert!(!found.is_empty(), "no cmux-app.json under examples/looks");
    for path in found {
        let manifest: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap())
            .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        let buttons = manifest["implements"]["cmux.composer.toolbar/1"]["options"]["buttons"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for button in buttons {
            assert_ne!(
                button["action"].as_str(),
                Some("composer.attachFiles"),
                "{}: a composer.attachFiles toolbar button repeats the + menu's Add files",
                path.display()
            );
        }
    }
}
