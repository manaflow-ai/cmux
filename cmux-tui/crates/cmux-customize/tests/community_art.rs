//! A community theme's wallpapers, header image and flourishes: install
//! copies the listed images into the config folder and points the theme
//! file's backdrop settings at them; remove deletes them; an image that is
//! not what its name says, too large, too many, or missing is refused.

use std::fs;
use std::path::PathBuf;

use cmux_customize::community::{self, Receipt, Tier, art};
use cmux_customize::{Customize, Roots};

const PNG: &[u8] = b"\x89PNG\r\n\x1a\n0000";
const WEBP: &[u8] = b"RIFF\x04\0\0\0WEBPVP8 ";
const JPEG: &[u8] = &[0xff, 0xd8, 0xff, 0xe0, 0, 0];

const MARKER: &str = r##"{
  "cmuxTheme": 1, "id": "alice/twin", "name": "Twin", "description": "Teal.", "version": "1.1.1",
  "wallpapers": {
    "dark": ["wallpapers/dark/a.webp", "wallpapers/dark/b.png"],
    "light": ["wallpapers/light/a.jpg"],
    "pane": { "dark": ["wallpapers/pane/dark/p.webp"] }
  },
  "header": { "dark": "header/dark.webp" },
  "flourishes": {
    "accentGlow": { "dark": "#39c5bb", "radius": 24, "opacity": 0.35 },
    "cursor": { "style": "bar", "blink": true, "color": { "dark": "#39c5bb", "light": "#137a73" } },
    "tabClose": { "from": "#39c5bb", "to": { "dark": "#ff5f87" }, "interpolation": "oklab" }
  }
}"##;
const DARK: &str = r#"{ "name": "Twin", "appearance": { "background": "folder:../wallpapers/dark", "backgroundOpacity": 0.4 } }"#;
const LIGHT: &str =
    r#"{ "name": "Twin light", "appearance.background": "file:../wallpapers/light/a.jpg" }"#;

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        let file = home.config("cmux-next.json");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "{ \"appearance\": { \"density\": \"comfortable\" } }\n").unwrap();
        home
    }

    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }
}

fn tree(files: &[(&str, &[u8])]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (path, bytes) in files {
        let file = dir.path().join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, bytes).unwrap();
    }
    dir
}

fn twin(marker: &str, extra: &[(&str, &[u8])]) -> tempfile::TempDir {
    let mut files: Vec<(&str, &[u8])> = vec![
        ("cmux-theme.json", marker.as_bytes()),
        ("themes/twin.json", DARK.as_bytes()),
        ("themes/twin-light.json", LIGHT.as_bytes()),
        ("wallpapers/dark/a.webp", WEBP),
        ("wallpapers/dark/b.png", PNG),
        ("wallpapers/light/a.jpg", JPEG),
        ("wallpapers/pane/dark/p.webp", WEBP),
        ("header/dark.webp", WEBP),
    ];
    files.extend_from_slice(extra);
    tree(&files)
}

fn receipt(package: &community::Package) -> Receipt {
    Receipt {
        tier: package.tier,
        id: package.id.clone(),
        name: package.name.clone(),
        entry: package.profile.name.clone(),
        reference: "github.com/alice/twin".to_owned(),
        repository: "https://github.com/alice/twin".to_owned(),
        git_ref: None,
        commit: "b".repeat(40),
        tag: Some("1.1.1".to_owned()),
        version: package.version.clone(),
        sha256: "0".repeat(64),
        installed_ms: 1,
    }
}

fn refusal(dir: &std::path::Path) -> String {
    match community::read_package(dir) {
        Ok(_) => panic!("expected a refusal"),
        Err(error) => error.to_string(),
    }
}

#[test]
fn image_kinds_come_from_bytes() {
    assert_eq!(art::image_kind(PNG), Some("png"));
    assert_eq!(art::image_kind(WEBP), Some("webp"));
    assert_eq!(art::image_kind(JPEG), Some("jpeg"));
    assert_eq!(art::image_kind(b"<svg"), None);
    assert!(art::is_art_path("wallpapers/dark/a.webp"));
    assert!(art::is_art_path("header/dark.PNG"));
    assert!(!art::is_art_path("wallpapers/../x.png"));
    assert!(!art::is_art_path("wallpapers/a.svg"));
    assert!(!art::is_art_path("screenshots/a.png"));
}

#[test]
fn wallpapers_install_into_the_config_folder_and_remove_takes_them_out() {
    let home = Home::new();
    let customize = home.customize();
    let repo = twin(MARKER, &[]);
    let package = community::read_package(repo.path()).unwrap();
    assert_eq!(package.art.images.len(), 5);
    for item in ["wallpapers.pane", "header", "flourishes.accentGlow", "flourishes.cursor.style"] {
        assert!(package.art.pending.iter().any(|p| p == item), "{item} is pending");
    }
    assert!(community::card("Install", &package, &receipt(&package), false).contains("5 images"));

    customize.community_put(&package, receipt(&package), true, "cli", 10).unwrap();
    let art = home.config("wallpapers/theme-alice-twin");
    assert_eq!(fs::read(art.join("dark/a.webp")).unwrap(), WEBP);
    assert_eq!(fs::read(art.join("dark/b.png")).unwrap(), PNG);
    assert_eq!(fs::read(art.join("light/a.jpg")).unwrap(), JPEG);
    assert!(art.join("pane/dark/p.webp").is_file());
    assert!(art.join("header/dark.webp").is_file());
    let dark = fs::read_to_string(home.config("themes/twin.json")).unwrap();
    assert!(dark.contains("\"folder:../wallpapers/theme-alice-twin/dark\""), "{dark}");
    assert!(dark.contains("\"backgroundOpacity\": 0.4"), "the rest stays: {dark}");
    let light = fs::read_to_string(home.config("themes/twin-light.json")).unwrap();
    assert!(light.contains("\"file:../wallpapers/theme-alice-twin/light/a.jpg\""), "{light}");

    // An update with fewer images replaces the folder.
    let marker = MARKER.replace(", \"wallpapers/dark/b.png\"", "");
    let smaller = twin(&marker, &[]);
    let package = community::read_package(smaller.path()).unwrap();
    customize.community_put(&package, receipt(&package), true, "cli", 20).unwrap();
    assert!(art.join("dark/a.webp").is_file());
    assert!(!art.join("dark/b.png").exists(), "the old folder is replaced");

    customize.community_remove(Tier::Theme, "alice/twin", "cli", 30).unwrap();
    assert!(!art.exists(), "remove deletes the copied art");
    assert!(!home.config("themes/twin.json").exists());
}

#[test]
fn art_that_is_not_what_it_says_is_refused() {
    // A JPEG named .png.
    let repo = twin(MARKER, &[("wallpapers/dark/b.png", JPEG)]);
    assert!(refusal(repo.path()).contains("not a png image"), "{}", refusal(repo.path()));

    // A listed image that is not there.
    let marker = MARKER.replace("\"wallpapers/light/a.jpg\"", "\"wallpapers/light/gone.jpg\"");
    let repo = twin(&marker, &[]);
    assert!(refusal(repo.path()).contains("not in the repository"));

    // Outside wallpapers/ and header/.
    let marker = MARKER.replace("\"header/dark.webp\"", "\"screenshots/dark.webp\"");
    let repo = twin(&marker, &[("screenshots/dark.webp", WEBP)]);
    assert!(refusal(repo.path()).contains("under wallpapers/ or header/"));

    // A theme file pointing into wallpapers/ at something unlisted.
    let stray =
        r#"{ "name": "Twin", "appearance": { "background": "folder:../wallpapers/elsewhere" } }"#;
    let repo = twin(MARKER, &[("themes/twin.json", stray.as_bytes())]);
    assert!(refusal(repo.path()).contains("does not list"), "{}", refusal(repo.path()));

    // A bad flourish.
    let marker = MARKER.replace("\"style\": \"bar\"", "\"style\": \"wavy\"");
    let repo = twin(&marker, &[]);
    assert!(refusal(repo.path()).contains("flourishes.cursor.style"));

    // Too large.
    let mut big = WEBP.to_vec();
    big.resize(usize::try_from(art::MAX_IMAGE_BYTES).unwrap() + 1, 0);
    let repo = twin(MARKER, &[("wallpapers/dark/a.webp", &big)]);
    assert!(refusal(repo.path()).contains("larger than"));

    // Too many.
    let names: Vec<String> =
        (0..=art::MAX_IMAGES).map(|n| format!("wallpapers/dark/{n}.png")).collect();
    let list = names.iter().map(|n| format!("\"{n}\"")).collect::<Vec<_>>().join(", ");
    let marker = MARKER
        .replace("[\"wallpapers/dark/a.webp\", \"wallpapers/dark/b.png\"]", &format!("[{list}]"));
    let extra: Vec<(&str, &[u8])> = names.iter().map(|n| (n.as_str(), PNG)).collect();
    let repo = twin(&marker, &extra);
    assert!(refusal(repo.path()).contains("at most"), "{}", refusal(repo.path()));
}

#[test]
fn a_refused_art_install_writes_nothing() {
    let home = Home::new();
    let repo = twin(MARKER, &[]);
    let package = community::read_package(repo.path()).unwrap();
    // The source image vanishes between check and copy.
    fs::remove_file(repo.path().join("header/dark.webp")).unwrap();
    assert!(home.customize().community_put(&package, receipt(&package), true, "cli", 10).is_err());
    assert!(!home.config("wallpapers/theme-alice-twin").exists());
    assert!(!home.config("themes/twin.json").exists());
}
