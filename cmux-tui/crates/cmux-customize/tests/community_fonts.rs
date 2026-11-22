//! A community typography theme's font pack: install copies `fonts/` (the
//! faces and their license text) into the config folder and points the
//! theme file's `agentPane.display.font.faces` at them; remove deletes them;
//! a pack with no open license, no license text, too many or too large
//! files, a file that is not what its name says, or a face the theme does
//! not carry is refused.

use std::fs;
use std::path::PathBuf;

use cmux_customize::community::{self, Receipt, Tier, fonts};
use cmux_customize::{Customize, Roots};

const WOFF2: &[u8] = b"wOF2\0\x01\0\0rest";
const TTF: &[u8] = &[0, 1, 0, 0, 0, 0x10, 0, 0];
const OFL: &[u8] = b"SIL OPEN FONT LICENSE Version 1.1\n";

const MARKER: &str = r#"{
  "cmuxTheme": 1, "id": "alice/type", "name": "Type", "version": "1.0.0",
  "fontLicense": "OFL-1.1"
}"#;
const DOTTED: &str = r#"{
  "name": "Type",
  "agentPane.display.font.uiFamily": "Pack Sans, system-ui",
  "agentPane.display.font.proseFamily": "Pack Serif",
  "agentPane.display.font.faces": {
    "Pack Sans": "file:../fonts/PackSans.woff2",
    "Pack Serif:italic": "file:../fonts/PackSerif-Italic.ttf"
  }
}"#;
const NESTED: &str = r#"{
  "name": "Type nested",
  "agentPane": { "display": { "font": { "faces": { "Pack Sans": "file:../fonts/PackSans.woff2" } } } }
}"#;

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Home {
        let home = Home { dir: tempfile::tempdir().unwrap() };
        let file = home.config("cmux-next.json");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "{}\n").unwrap();
        home
    }

    fn customize(&self) -> Customize {
        Customize::open(Roots::under(self.dir.path()))
    }

    fn config(&self, path: &str) -> PathBuf {
        self.dir.path().join("config").join(path)
    }
}

/// A theme repository with `extra` written over (or added to) the pack.
fn pack(marker: &str, extra: &[(&str, &[u8])]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let mut files: Vec<(&str, &[u8])> = vec![
        ("cmux-theme.json", marker.as_bytes()),
        ("themes/type.json", DOTTED.as_bytes()),
        ("themes/type-nested.json", NESTED.as_bytes()),
        ("fonts/PackSans.woff2", WOFF2),
        ("fonts/PackSerif-Italic.ttf", TTF),
        ("fonts/OFL.txt", OFL),
        ("fonts/README.md", b"not installed"),
    ];
    files.extend_from_slice(extra);
    for (path, bytes) in files {
        let file = dir.path().join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, bytes).unwrap();
    }
    dir
}

fn receipt(package: &community::Package) -> Receipt {
    Receipt {
        tier: package.tier,
        id: package.id.clone(),
        name: package.name.clone(),
        entry: package.profile.name.clone(),
        reference: "github.com/alice/type".to_owned(),
        repository: "https://github.com/alice/type".to_owned(),
        git_ref: None,
        commit: "c".repeat(40),
        tag: Some("1.0.0".to_owned()),
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
fn font_paths_are_one_level_under_fonts() {
    assert!(fonts::is_font_path("fonts/PackSans.woff2"));
    assert!(fonts::is_font_path("fonts/X.OTF"));
    assert!(!fonts::is_font_path("fonts/sub/X.woff2"));
    assert!(!fonts::is_font_path("fonts/../X.woff2"));
    assert!(!fonts::is_font_path("fonts/.hidden.ttf"));
    assert!(!fonts::is_font_path("fonts/X.svg"));
    assert!(!fonts::is_font_path("wallpapers/X.woff2"));
    assert!(fonts::is_license_path("fonts/OFL.txt"));
    assert!(fonts::is_license_path("fonts/LICENSE"));
    assert!(fonts::is_license_path("fonts/LICENSE-Pack.md"));
    assert!(!fonts::is_license_path("fonts/README.md"));
    assert!(!fonts::is_license_path("LICENSE"));
}

#[test]
fn a_font_pack_installs_into_the_config_folder_and_remove_takes_it_out() {
    let home = Home::new();
    let customize = home.customize();
    let repo = pack(MARKER, &[]);
    let package = community::read_package(repo.path()).unwrap();
    assert_eq!(package.fonts.files, ["fonts/PackSans.woff2", "fonts/PackSerif-Italic.ttf"]);
    assert_eq!(package.fonts.licenses, ["fonts/OFL.txt"]);
    assert_eq!(package.fonts.license.as_deref(), Some("OFL-1.1"));
    let card = community::card("Install", &package, &receipt(&package), false);
    assert!(card.contains("2 fonts (OFL-1.1)"), "{card}");

    customize.community_put(&package, receipt(&package), true, "cli", 10).unwrap();
    let folder = home.config("fonts/theme-alice-type");
    assert_eq!(folder, fonts::folder(&home.config(""), "theme-alice-type"));
    assert_eq!(fs::read(folder.join("PackSans.woff2")).unwrap(), WOFF2);
    assert_eq!(fs::read(folder.join("PackSerif-Italic.ttf")).unwrap(), TTF);
    assert_eq!(fs::read(folder.join("OFL.txt")).unwrap(), OFL, "the license text is copied");
    assert!(!folder.join("README.md").exists(), "only fonts and license texts are copied");
    let dotted = fs::read_to_string(home.config("themes/type.json")).unwrap();
    assert!(dotted.contains("\"file:../fonts/theme-alice-type/PackSans.woff2\""), "{dotted}");
    assert!(dotted.contains("\"file:../fonts/theme-alice-type/PackSerif-Italic.ttf\""), "{dotted}");
    assert!(dotted.contains("\"Pack Sans, system-ui\""), "the rest stays: {dotted}");
    let nested = fs::read_to_string(home.config("themes/type-nested.json")).unwrap();
    assert!(nested.contains("\"file:../fonts/theme-alice-type/PackSans.woff2\""), "{nested}");

    // An update that no longer carries fonts takes the old copy out.
    let plain = tempfile::tempdir().unwrap();
    fs::write(plain.path().join("cmux-theme.json"), MARKER).unwrap();
    fs::create_dir_all(plain.path().join("themes")).unwrap();
    fs::write(plain.path().join("themes/type.json"), r#"{ "name": "Type" }"#).unwrap();
    let package = community::read_package(plain.path()).unwrap();
    assert!(package.fonts.files.is_empty());
    customize.community_put(&package, receipt(&package), true, "cli", 20).unwrap();
    assert!(!folder.exists(), "an update with no fonts removes them");

    let package = community::read_package(repo.path()).unwrap();
    customize.community_put(&package, receipt(&package), true, "cli", 30).unwrap();
    assert!(folder.join("PackSans.woff2").is_file());
    customize.community_remove(Tier::Theme, "alice/type", "cli", 40).unwrap();
    assert!(!folder.exists(), "remove deletes the copied fonts");
    assert!(!home.config("themes/type.json").exists());
}

#[test]
fn a_font_pack_without_an_open_license_is_refused() {
    let unlicensed = MARKER.replace(",\n  \"fontLicense\": \"OFL-1.1\"", "");
    let why = refusal(pack(&unlicensed, &[]).path());
    assert!(why.contains("\"fontLicense\": \"OFL-1.1\""), "{why}");

    let closed = MARKER.replace("OFL-1.1", "Proprietary");
    let why = refusal(pack(&closed, &[]).path());
    assert!(why.contains("OFL-1.1, Apache-2.0, MIT"), "{why}");

    for open in ["Apache-2.0", "MIT"] {
        let marker = MARKER.replace("OFL-1.1", open);
        let package = community::read_package(pack(&marker, &[]).path()).unwrap();
        assert_eq!(package.fonts.license.as_deref(), Some(open));
    }

    // No license text: OFL.txt gone, nothing named LICENSE*.
    let repo = pack(MARKER, &[]);
    fs::remove_file(repo.path().join("fonts/OFL.txt")).unwrap();
    let why = refusal(repo.path());
    assert!(why.contains("fonts/OFL.txt or fonts/LICENSE"), "{why}");
    fs::write(repo.path().join("fonts/LICENSE"), OFL).unwrap();
    let package = community::read_package(repo.path()).unwrap();
    assert_eq!(package.fonts.licenses, ["fonts/LICENSE"]);
}

#[test]
fn font_files_that_are_not_what_they_say_are_refused() {
    // A TrueType file named .woff2.
    let why = refusal(pack(MARKER, &[("fonts/PackSans.woff2", TTF)]).path());
    assert!(why.contains("a ttf file, not .woff2"), "{why}");

    // Not a font at all.
    let why = refusal(pack(MARKER, &[("fonts/PackSans.woff2", b"<svg>")]).path());
    assert!(why.contains("not a font file"), "{why}");

    // Too large.
    let mut big = WOFF2.to_vec();
    big.resize(usize::try_from(cmux_config::font_faces::MAX_FACE_BYTES).unwrap() + 1, 0);
    let why = refusal(pack(MARKER, &[("fonts/PackSans.woff2", &big)]).path());
    assert!(why.contains("larger than 2 MiB"), "{why}");

    // Too many.
    let names: Vec<String> =
        (0..cmux_config::font_faces::MAX_FACES).map(|n| format!("fonts/Extra{n}.woff2")).collect();
    let extra: Vec<(&str, &[u8])> = names.iter().map(|n| (n.as_str(), WOFF2)).collect();
    let why = refusal(pack(MARKER, &extra).path());
    assert!(why.contains("at most 8 font files"), "{why}");
}

#[test]
fn a_face_the_theme_does_not_carry_is_refused() {
    let missing = DOTTED.replace("PackSans.woff2", "Gone.woff2");
    let why = refusal(pack(MARKER, &[("themes/type.json", missing.as_bytes())]).path());
    assert!(why.contains("fonts/Gone.woff2, which is not in the repository's fonts/"), "{why}");

    let elsewhere = DOTTED.replace("../fonts/PackSans.woff2", "/Library/Fonts/X.ttf");
    let why = refusal(pack(MARKER, &[("themes/type.json", elsewhere.as_bytes())]).path());
    assert!(why.contains("one of its own font files"), "{why}");

    let stack = DOTTED.replace("\"Pack Sans\": \"file:", "\"Pack Sans, Other\": \"file:");
    let why = refusal(pack(MARKER, &[("themes/type.json", stack.as_bytes())]).path());
    assert!(why.contains("Pack Sans, Other"), "{why}");

    let bold = DOTTED.replace("Pack Serif:italic", "Pack Serif:bold");
    let why = refusal(pack(MARKER, &[("themes/type.json", bold.as_bytes())]).path());
    assert!(why.contains(":italic"), "{why}");
}

#[test]
fn a_refused_font_install_writes_nothing() {
    let home = Home::new();
    let repo = pack(MARKER, &[]);
    let package = community::read_package(repo.path()).unwrap();
    // The source font vanishes between check and copy.
    fs::remove_file(repo.path().join("fonts/PackSans.woff2")).unwrap();
    assert!(home.customize().community_put(&package, receipt(&package), true, "cli", 10).is_err());
    assert!(!home.config("fonts/theme-alice-type").exists());
    assert!(!home.config("themes/type.json").exists());
}
