use std::path::PathBuf;

use serde_json::json;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

/// A config folder of its own, removed when the test ends.
struct Home(PathBuf);

impl Home {
    fn new(tag: &str) -> Home {
        let dir = std::env::temp_dir().join(format!("cmux-theme-cli-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("themes")).expect("temp dir");
        Home(dir)
    }

    fn paths(&self) -> Paths {
        Paths { settings: self.0.join("cmux-next.json"), config_dir: self.0.clone() }
    }

    fn theme(&self, name: &str, text: &str) {
        std::fs::write(self.0.join("themes").join(format!("{name}.json")), text).expect("write");
    }

    fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.0.join("themes").join(format!("{name}.json"))).expect("read")
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn verbs_parse() {
    assert_eq!(parse(&words("list")), Ok(Request::List));
    assert_eq!(
        parse(&words("set appearance.accent blue --theme tokyo")),
        Ok(Request::Set {
            key: "appearance.accent".into(),
            value: json!("blue"),
            theme: Some("tokyo".into())
        })
    );
    assert_eq!(
        parse(&words("set appearance.backgroundOpacity 0.8")),
        Ok(Request::Set {
            key: "appearance.backgroundOpacity".into(),
            value: json!(0.8),
            theme: None
        })
    );
    assert_eq!(parse(&words("reset")), Ok(Request::Reset { key: None, theme: None }));
    assert_eq!(
        parse(&words("export --save mine --use")),
        Ok(Request::Export {
            save: Some("mine".into()),
            output: None,
            title: None,
            activate: true
        })
    );
    assert!(parse(&words("export --use")).is_err(), "--use needs --save");
    assert!(parse(&words("set appearance.accent blue --theme ../x")).is_err());
    assert!(parse(&words("use tokyo.json")).is_err());
}

#[test]
fn bare_export_and_theme_file_import_route_here_and_schemes_do_not() {
    let home = Home::new("route");
    home.theme("tokyo", r#"{ "appearance.accent": "blue", "colors": {} }"#);
    let look = home.0.join("themes/tokyo.json");
    assert!(is_theme_file(&look));
    let scheme = home.0.join("scheme.json");
    std::fs::write(
        &scheme,
        r##"{ "name": "x", "background": "#000000", "foreground": "#ffffff" }"##,
    )
    .expect("write");
    assert!(!is_theme_file(&scheme), "a Windows Terminal scheme is not a theme file");
}

#[test]
fn set_writes_one_checked_value_and_keeps_comments() {
    let home = Home::new("set");
    home.theme("tokyo", "// mine\n{\n  \"appearance\": { \"accent\": \"red\" }, // nested\n}\n");
    let global = GlobalArgs { output: OutputMode::Quiet, ..GlobalArgs::default() };
    let paths = home.paths();
    assert_eq!(set(&global, &paths, "tokyo", "appearance.accent", json!("blue")), 0);
    assert_eq!(set(&global, &paths, "tokyo", "appearance.borders", json!("none")), 0);
    let text = home.read("tokyo");
    assert!(text.starts_with("// mine"), "{text}");
    assert!(text.contains("// nested"), "{text}");
    let file = read(&paths, "tokyo", None);
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys(), ["appearance.accent", "appearance.borders"]);
    // A refused value or a non-look key leaves the file as it was.
    assert_eq!(set(&global, &paths, "tokyo", "appearance.accent", json!("purple")), 1);
    assert_eq!(set(&global, &paths, "tokyo", "terminal.term", json!("xterm")), 1);
    assert_eq!(home.read("tokyo"), text);
    // reset takes it out, nested or dotted.
    assert_eq!(reset(&global, &paths, "tokyo", "appearance.accent"), 0);
    assert_eq!(reset(&global, &paths, "tokyo", "appearance.borders"), 0);
    assert!(read(&paths, "tokyo", None).values.is_empty());
    assert_eq!(reset(&global, &paths, "tokyo", "appearance.borders"), 1);
}

#[test]
fn the_exported_current_look_is_the_same_look() {
    let home = Home::new("export");
    std::fs::write(
        home.0.join("cmux-next.json"),
        r#"{ "appearance": { "accent": "blue", "themeFile": "tokyo" }, "terminal": { "fontSize": 13 } }"#,
    )
    .expect("write");
    home.theme("tokyo", r#"{ "appearance.borders": "none" }"#);
    let paths = home.paths();
    let look = current_look(&paths);
    assert_eq!(value_at(&look, &key_path("appearance.borders")), Some(&json!("none")));
    assert_eq!(value_at(&look, &key_path("appearance.themeFile")), None);
    let text = render(
        &look,
        Schema::embedded(),
        &Domains::default(),
        &RenderOptions { name: "x", description: "" },
    );
    let file = read(&paths, "export", Some(&text));
    assert!(file.diagnostics.is_empty(), "{:?}", file.diagnostics);
    assert_eq!(file.keys(), ["appearance.accent", "appearance.borders", "terminal.fontSize"]);
}
