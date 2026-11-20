//! Run: CARGO_TARGET_DIR=/tmp/looks-check nice -n 10 timeout 1800 cargo run -q --manifest-path examples/customize-demo/looks/check/Cargo.toml -- examples/customize-demo/looks/*.json
//! Previews each profile file given on the command line on a fresh home, the
//! way cmux-customize's showcase test does, and fails on any problem.
use cmux_customize::{Customize, Roots};
use std::fs;

fn main() {
    let mut failed = false;
    for file in std::env::args().skip(1) {
        let home = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        let profile = match customize.load_profile(&file) {
            Ok(p) => p,
            Err(e) => {
                println!("FAIL {file}: load: {e}");
                failed = true;
                continue;
            }
        };
        if let Err(e) = customize.preview_profile(&profile, "cli", 1) {
            println!("FAIL {file}: preview: {e}");
            failed = true;
            continue;
        }
        let status = customize.status().unwrap();
        if !status.problems.is_empty() {
            println!("FAIL {file}: problems: {:?}", status.problems);
            failed = true;
            continue;
        }
        for (path, text) in &profile.files {
            let live = fs::read_to_string(home.path().join("config").join(path)).unwrap();
            if path == "keybindings.json" {
                // cmux merges a profile's keys into the person's own and writes the list back
                // without comments: check every binding landed, not the bytes.
                let uncommented: String = text
                    .lines()
                    .filter(|l| !l.trim_start().starts_with("//"))
                    .collect::<Vec<_>>()
                    .join("\n");
                let want: serde_json::Value = serde_json::from_str(&uncommented).unwrap();
                let got: serde_json::Value = serde_json::from_str(&live).unwrap();
                for binding in want.as_array().unwrap() {
                    assert!(
                        got.as_array().unwrap().contains(binding),
                        "{file}: {binding} is not in the live keybindings.json"
                    );
                }
                continue;
            }
            assert_eq!(&live, text, "{file}: {path}");
        }
        let schema = cmux_config::Schema::embedded();
        let mut bad_theme = false;
        for (path, text) in &profile.files {
            if let Some(name) = path
                .strip_prefix("themes/")
                .and_then(|n| n.strip_suffix(".json"))
            {
                let theme = cmux_config::ThemeFile::read(
                    name,
                    Some(Ok(text.as_str())),
                    &serde_json::json!({}),
                    None,
                    &schema,
                    &Default::default(),
                );
                for d in &theme.diagnostics {
                    println!("  theme {}: {}", path, d.display());
                    if !matches!(d.kind, cmux_config::ThemeDiagnosticKind::CorrectedValue) {
                        bad_theme = true;
                    }
                }
                println!("  theme {path}: {} values applied", theme.values.len());
            }
        }
        if bad_theme {
            println!("FAIL {file}: theme diagnostics");
            failed = true;
            continue;
        }
        println!(
            "ok   {file}: {} settings, files {:?}",
            profile.settings.len(),
            profile.files.keys().collect::<Vec<_>>()
        );
    }
    if failed {
        std::process::exit(1)
    }
}
