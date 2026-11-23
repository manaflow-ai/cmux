//! Community themes and snippets: a theme repository's files install as
//! one library entry that picks its theme; a snippet's settings and
//! stylesheet the same; remove puts back what was there; a snippet that
//! carries code, a theme that does not load, and an id that is not the
//! owner's are refused before anything is written.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::community::{self, Receipt, Tier};
use cmux_customize::{Customize, Error, Roots};

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        home.write_config(
            "cmux-next.json",
            "{\n  // mine\n  \"appearance\": { \"density\": \"comfortable\" }\n}\n",
        );
        home
    }

    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }

    fn write_config(&self, path: &str, text: &str) {
        let file = self.config(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }

    fn settings(&self) -> serde_json::Value {
        cmux_config::jsonc::parse(&fs::read_to_string(self.config("cmux-next.json")).unwrap())
            .unwrap()
    }
}

fn tree(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (path, text) in files {
        let file = dir.path().join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
    dir
}

const THEME_MARKER: &str = r#"{ "cmuxTheme": 1, "id": "alice/dusk", "name": "Dusk", "description": "A warm dark look.", "version": "1.0.0", "use": "dusk" }"#;
const DUSK: &str = r#"{ "name": "Dusk", "appearance": { "accent": "blue" } }"#;

fn receipt(package: &community::Package, reference: &str) -> Receipt {
    Receipt {
        tier: package.tier,
        id: package.id.clone(),
        name: package.name.clone(),
        entry: package.profile.name.clone(),
        reference: reference.to_owned(),
        repository: format!("https://{reference}"),
        git_ref: None,
        commit: "a".repeat(40),
        tag: Some("1.0.0".to_owned()),
        version: package.version.clone(),
        sha256: "0".repeat(64),
        installed_ms: 1,
    }
}

fn read(dir: &Path) -> community::Package {
    community::read_package(dir).unwrap()
}

#[test]
fn a_theme_installs_as_one_entry_that_picks_it_and_remove_puts_back_what_was_there() {
    let home = Home::new();
    let customize = home.customize();
    let repo = tree(&[
        ("cmux-theme.json", THEME_MARKER),
        ("themes/dusk.json", DUSK),
        ("README.md", "# Dusk"),
    ]);
    let package = read(repo.path());
    assert_eq!(package.tier, Tier::Theme);
    assert_eq!(package.themes, vec!["dusk"]);
    assert_eq!(package.profile.name, "theme-alice-dusk");
    community::check_id(&package, "Alice").unwrap();

    let receipt = receipt(&package, "github.com/alice/dusk");
    let card = community::card("Install", &package, &receipt, false);
    assert_eq!(
        card,
        "Install theme \"Dusk\" by alice from github.com/alice/dusk @ 1.0.0 (aaaaaaa): no code runs. Not reviewed by cmux."
    );

    let change = customize.community_put(&package, receipt, true, "cli", 10).unwrap();
    assert!(change.generation.is_some(), "one applied generation");
    assert_eq!(fs::read_to_string(home.config("themes/dusk.json")).unwrap(), DUSK);
    assert_eq!(home.settings()["appearance"]["themeFile"], "dusk");
    assert_eq!(
        home.settings()["appearance"]["density"],
        "comfortable",
        "the person's own setting stays"
    );
    let listing = customize.library().unwrap();
    assert_eq!(listing.entries[0].name, "theme-alice-dusk");
    assert_eq!(listing.entries[0].source, "theme");
    assert_eq!(customize.community(Some(Tier::Theme)).unwrap().len(), 1);
    assert!(customize.community(Some(Tier::Snippet)).unwrap().is_empty());

    let (removed, change) =
        customize.community_remove(Tier::Theme, "github.com/alice/dusk@1.0.0", "cli", 20).unwrap();
    assert_eq!(removed.id, "alice/dusk");
    assert!(change.is_some());
    assert!(!home.config("themes/dusk.json").exists(), "the theme file it wrote is gone");
    assert!(
        home.settings()["appearance"].get("themeFile").is_none(),
        "no theme file is picked again"
    );
    assert!(customize.library().unwrap().entries.is_empty());
    assert!(customize.community(None).unwrap().is_empty());
}

#[test]
fn an_update_replaces_the_entry_in_place_and_keeps_it_off_when_it_was_off() {
    let home = Home::new();
    let customize = home.customize();
    let v1 = tree(&[("cmux-theme.json", THEME_MARKER), ("themes/dusk.json", DUSK)]);
    let package = read(v1.path());
    customize
        .community_put(&package, receipt(&package, "github.com/alice/dusk"), true, "cli", 10)
        .unwrap();
    customize.library_set_on("theme-alice-dusk", false, "cli", 11).unwrap();

    let newer = r#"{ "name": "Dusk", "appearance": { "accent": "red" } }"#;
    let v2 = tree(&[("cmux-theme.json", THEME_MARKER), ("themes/dusk.json", newer)]);
    let package = read(v2.path());
    customize
        .community_put(&package, receipt(&package, "github.com/alice/dusk"), false, "cli", 12)
        .unwrap();
    let listing = customize.library().unwrap();
    assert_eq!(listing.entries.len(), 1);
    assert!(!listing.entries[0].on, "an update keeps it off");
    customize.library_set_on("theme-alice-dusk", true, "cli", 13).unwrap();
    assert_eq!(fs::read_to_string(home.config("themes/dusk.json")).unwrap(), newer);
}

#[test]
fn a_snippet_sets_its_settings_and_stylesheet_and_comes_off_cleanly() {
    let home = Home::new();
    let customize = home.customize();
    let marker = r#"{ "cmuxSnippet": 1, "id": "bob/compact", "name": "Compact", "description": "Tighter rows.",
        "cmuxProfile": 1, "settings": { "appearance.density": "compact" } }"#;
    let css = ".message { line-height: 1.3; }\n";
    let repo = tree(&[("cmux-snippet.json", marker), ("agent-pane/theme.css", css)]);
    let package = read(repo.path());
    assert_eq!(package.tier, Tier::Snippet);
    assert_eq!(package.profile.files.keys().collect::<Vec<_>>(), vec!["agent-pane/theme.css"]);
    customize
        .community_put(&package, receipt(&package, "github.com/bob/compact"), true, "cli", 10)
        .unwrap();
    assert_eq!(home.settings()["appearance"]["density"], "compact");
    assert_eq!(fs::read_to_string(home.config("agent-pane/theme.css")).unwrap(), css);

    customize.community_remove(Tier::Snippet, "bob/compact", "cli", 11).unwrap();
    assert_eq!(home.settings()["appearance"]["density"], "comfortable");
    assert!(!home.config("agent-pane/theme.css").exists());
}

fn refused(files: &[(&str, &str)]) -> String {
    match community::read_package(tree(files).path()) {
        Err(Error::Community(why)) => why,
        other => panic!("{other:?}"),
    }
}

#[test]
fn what_is_not_a_no_code_theme_or_snippet_is_refused_with_its_reason() {
    assert!(refused(&[("README.md", "x")]).contains("not a cmux theme or snippet"));
    assert!(refused(&[("cmux-theme.json", THEME_MARKER)]).contains("no theme files"));
    let bad_theme = r#"{ "appearance": { "accent": 42 } }"#;
    let why = refused(&[("cmux-theme.json", THEME_MARKER), ("themes/dusk.json", bad_theme)]);
    assert!(why.contains("does not load as a cmux theme file"), "{why}");
    let code = r#"{ "cmuxSnippet": 1, "id": "bob/x", "name": "X", "cmuxProfile": 1,
        "files": { "customize/main.js": "run()" } }"#;
    assert!(refused(&[("cmux-snippet.json", code)]).contains("views and automations run code"));
    let theme_pick = r#"{ "cmuxSnippet": 1, "id": "bob/x", "name": "X", "cmuxProfile": 1,
        "settings": { "appearance.themeFile": "dusk" } }"#;
    assert!(refused(&[("cmux-snippet.json", theme_pick)]).contains("may not pick a theme file"));
    let empty = r#"{ "cmuxSnippet": 1, "id": "bob/x", "name": "X", "cmuxProfile": 1 }"#;
    assert!(refused(&[("cmux-snippet.json", empty)]).contains("sets nothing"));
    let bad_id = r#"{ "cmuxTheme": 1, "id": "Alice Dusk", "name": "Dusk" }"#;
    assert!(
        refused(&[("cmux-theme.json", bad_id), ("themes/dusk.json", DUSK)]).contains("OWNER/NAME")
    );
}

#[test]
fn a_value_the_setting_refuses_is_refused_at_install_and_nothing_is_written() {
    let home = Home::new();
    let customize = home.customize();
    let marker = r#"{ "cmuxSnippet": 1, "id": "bob/x", "name": "X", "cmuxProfile": 1,
        "settings": { "appearance.density": "not-a-density" } }"#;
    let package = read(tree(&[("cmux-snippet.json", marker)]).path());
    let before = fs::read_to_string(home.config("cmux-next.json")).unwrap();
    assert!(
        customize
            .community_put(&package, receipt(&package, "github.com/bob/x"), true, "cli", 1)
            .is_err()
    );
    assert_eq!(
        fs::read_to_string(home.config("cmux-next.json")).unwrap(),
        before,
        "nothing written"
    );
    assert!(customize.community(None).unwrap().is_empty());
}

#[test]
fn the_id_must_be_the_owners_and_engines_must_admit_this_cmux() {
    let package =
        read(tree(&[("cmux-theme.json", THEME_MARKER), ("themes/dusk.json", DUSK)]).path());
    assert!(community::check_id(&package, "mallory").is_err());
    let first_party = THEME_MARKER.replace("alice/dusk", "cmux/dusk");
    let package_cmux =
        read(tree(&[("cmux-theme.json", &first_party), ("themes/dusk.json", DUSK)]).path());
    assert!(community::check_id(&package_cmux, "alice").is_err());
    community::check_id(&package_cmux, "manaflow-ai").unwrap();

    let needs = THEME_MARKER.replace("\"use\"", "\"engines\": { \"cmux\": \">=0.80.0\" }, \"use\"");
    let package = read(tree(&[("cmux-theme.json", &needs), ("themes/dusk.json", DUSK)]).path());
    assert!(community::check_engines(&package, "0.79.3").is_err());
    community::check_engines(&package, "0.80.0").unwrap();
    community::check_engines(&package, "0.0.0").unwrap();
}

#[test]
fn a_snippet_sets_only_look_settings_and_its_stylesheet_loads_nothing() {
    let marker = |settings: &str| {
        format!(
            r#"{{ "cmuxSnippet": 1, "id": "bob/x", "name": "X", "cmuxProfile": 1, "settings": {settings} }}"#
        )
    };
    let why = refused(&[("cmux-snippet.json", &marker(r#"{ "chief.reactionsCanWake": true }"#))]);
    assert!(why.contains("not a look setting"), "{why}");
    let look = marker(r#"{ "appearance.density": "compact" }"#);
    for css in [
        "@import 'https://x.example/a.css';",
        ".a { background: url(https://x.example/p.png) }",
        ".a { background: URL( \"//x.example/p\" ) }",
        ".a { background: u\\rl(https://x.example) }",
        "@font-face { src: src(\"https://x.example/f\") }",
    ] {
        let why = refused(&[("cmux-snippet.json", &look), ("agent-pane/theme.css", css)]);
        assert!(why.contains("loads nothing from the network"), "{css}: {why}");
    }
    let inline =
        ".a { background: url(\"data:image/png;base64,AAAA\") } /* url(https://x) in a comment */";
    let package =
        read(tree(&[("cmux-snippet.json", &look), ("agent-pane/theme.css", inline)]).path());
    assert!(package.profile.files.contains_key("agent-pane/theme.css"));
    // A shortcuts file in the tree is not read: a binding can run any action.
    let package = read(tree(&[("cmux-snippet.json", &look), ("keybindings.json", "[]")]).path());
    assert!(package.profile.files.is_empty());
}

#[test]
fn an_install_never_writes_over_a_library_entry_of_the_same_name_it_did_not_make() {
    let home = Home::new();
    let customize = home.customize();
    // The person's own entry, by hand, under the name the theme would take.
    let mine = cmux_customize::profile::Profile {
        version: 1,
        name: "theme-alice-dusk".to_owned(),
        description: String::new(),
        created_ms: 0,
        settings: [("appearance.density".to_owned(), serde_json::json!("compact"))].into(),
        files: Default::default(),
    };
    customize.library_put(mine, "ask", vec!["mine".to_owned()], true, "cli", 1).unwrap();
    let package =
        read(tree(&[("cmux-theme.json", THEME_MARKER), ("themes/dusk.json", DUSK)]).path());
    match customize.community_put(
        &package,
        receipt(&package, "github.com/alice/dusk"),
        true,
        "cli",
        2,
    ) {
        Err(Error::Community(why)) => assert!(why.contains("already has an entry named"), "{why}"),
        other => panic!("{other:?}"),
    }
    assert_eq!(customize.library().unwrap().entries[0].source, "ask");
}
