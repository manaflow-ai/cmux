//! A setup repo's font pack, under the community-theme rule: `fonts/` beside
//! `themes/`, `"fontLicense"` in `cmux-setup.json`, the license text
//! included, at most 8 files of at most 2 MiB. Install copies the fonts to
//! `<config dir>/fonts/setup-OWNER-NAME/` and points the setup's theme files
//! there; remove deletes them; a failed update keeps the old ones.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::community::fonts;
use cmux_customize::setup::{self, Receipt, Reference, SETUP_FILE};
use cmux_customize::{Customize, Roots};

const WOFF2: &[u8] = b"wOF2\0\x01\0\0rest";
const WOFF2_V2: &[u8] = b"wOF2\0\x01\0\0second";
const OFL: &[u8] = b"SIL OPEN FONT LICENSE Version 1.1\n";

const SETUP: &str = r#"{
  "cmuxSetup": 1,
  "id": "alice/type-look",
  "name": "Type",
  "description": "A type pack as a setup.",
  "version": "1.0.0",
  "fontLicense": "OFL-1.1",
  "cmuxProfile": 1,
  "settings": { "appearance.themeFile": "type", "agentPane.display.font.size": 15 }
}"#;
const THEME: &str = r#"{
  // Type only.
  "name": "Type",
  "agentPane.display.font.uiFamily": "Pack Sans",
  "agentPane.display.font.faces": {
    "Pack Sans": "file:../fonts/pack-sans.woff2",
    "Pack Sans:italic": "file:../fonts/pack-sans-italic.woff2"
  }
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

/// A setup repo under `root`, with `extra` written over (or added to) it.
fn repo(root: &Path, setup: &str, extra: &[(&str, &[u8])]) -> PathBuf {
    let repo = root.join("repo");
    let mut files: Vec<(&str, &[u8])> = vec![
        (SETUP_FILE, setup.as_bytes()),
        ("themes/type.json", THEME.as_bytes()),
        ("fonts/pack-sans.woff2", WOFF2),
        ("fonts/pack-sans-italic.woff2", WOFF2),
        ("fonts/OFL.txt", OFL),
        ("fonts/README.md", b"not installed"),
    ];
    files.extend_from_slice(extra);
    for (path, bytes) in files {
        let file = repo.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, bytes).unwrap();
    }
    repo
}

fn receipt(read: &setup::Setup, installed: &setup::Installed) -> Receipt {
    let reference = Reference::parse("github.com/alice/type-look").unwrap();
    Receipt {
        id: read.manifest.id.clone(),
        name: read.manifest.name.clone(),
        repository: reference.repository(),
        reference,
        commit: "a".repeat(40),
        sha256: read.sha256.clone(),
        version: read.manifest.version.clone(),
        generation: installed.applied.as_ref().map(|applied| applied.generation.n),
        before: installed.before,
        library: installed.applied.as_ref().and_then(|applied| applied.library.clone()),
        library_created: installed.library_created,
        actions: read.actions().clone(),
        prior_actions: installed.prior_actions.clone(),
        extensions: Vec::new(),
        installed_ms: 10,
    }
}

fn refusal(dir: &Path) -> String {
    match setup::read_dir(dir) {
        Ok(_) => panic!("expected a refusal"),
        Err(error) => error.to_string(),
    }
}

#[test]
fn a_setup_installs_its_fonts_and_remove_takes_them_out() {
    let home = Home::new();
    let repo = repo(home.dir.path(), SETUP, &[]);
    let read = setup::read_dir(&repo).unwrap();
    assert_eq!(read.fonts.files, ["fonts/pack-sans-italic.woff2", "fonts/pack-sans.woff2"]);
    assert_eq!(read.fonts.licenses, ["fonts/OFL.txt"]);
    assert_eq!(read.fonts.license.as_deref(), Some("OFL-1.1"));
    let theme = &read.profile.files["themes/type.json"];
    assert!(theme.contains("\"file:../fonts/setup-alice-type-look/pack-sans.woff2\""), "{theme}");
    assert!(theme.contains("// Type only."), "the rest of the file stays: {theme}");

    let customize = home.customize();
    let plan = customize.plan_setup(&read, "alice", "0.0.0").unwrap();
    assert_eq!(plan.fonts, read.fonts.files);
    assert_eq!(plan.font_license.as_deref(), Some("OFL-1.1"));

    let installed = customize.install_setup(&read, "setup alice/type-look", "cli", 10).unwrap();
    let folder = home.config("fonts/setup-alice-type-look");
    assert_eq!(folder, fonts::folder(&home.config(""), &setup::fonts_entry("alice/type-look")));
    assert_eq!(fs::read(folder.join("pack-sans.woff2")).unwrap(), WOFF2);
    assert_eq!(fs::read(folder.join("pack-sans-italic.woff2")).unwrap(), WOFF2);
    assert_eq!(fs::read(folder.join("OFL.txt")).unwrap(), OFL, "the license text is copied");
    assert!(!folder.join("README.md").exists(), "only fonts and license texts are copied");
    let live = fs::read_to_string(home.config("themes/type.json")).unwrap();
    assert!(
        live.contains("\"file:../fonts/setup-alice-type-look/pack-sans-italic.woff2\""),
        "{live}"
    );

    customize.record_setup(receipt(&read, &installed)).unwrap();
    let found = customize.setup("alice/type-look").unwrap().unwrap();
    customize.remove_setup(&found, "cli", 20).unwrap();
    assert!(!folder.exists(), "remove deletes the copied fonts");
    assert!(!home.config("themes/type.json").exists());
}

#[test]
fn the_fonts_are_part_of_what_the_setup_hash_covers() {
    let home = Home::new();
    let first = setup::read_dir(&repo(home.dir.path(), SETUP, &[])).unwrap();
    let again = setup::read_dir(&repo(home.dir.path(), SETUP, &[])).unwrap();
    assert_eq!(first.sha256, again.sha256);
    let changed =
        setup::read_dir(&repo(home.dir.path(), SETUP, &[("fonts/pack-sans.woff2", WOFF2_V2)]))
            .unwrap();
    assert_ne!(first.sha256, changed.sha256, "a new font file is a new setup");
}

#[test]
fn an_update_replaces_the_fonts_and_a_failed_one_keeps_the_old() {
    let home = Home::new();
    let root = home.dir.path();
    let read = setup::read_dir(&repo(root, SETUP, &[])).unwrap();
    let customize = home.customize();
    let installed = customize.install_setup(&read, "setup", "cli", 10).unwrap();
    customize.record_setup(receipt(&read, &installed)).unwrap();
    let folder = home.config("fonts/setup-alice-type-look");

    // A new commit whose theme cannot be written (a folder is in its place):
    // the update fails after the old setup came off, and the old fonts stay.
    let old = customize.setups().unwrap().remove(0);
    let mut next =
        setup::read_dir(&repo(root, SETUP, &[("fonts/pack-sans.woff2", WOFF2_V2)])).unwrap();
    next.profile.files.insert("themes/later.json".to_owned(), "{ \"name\": \"Later\" }\n".into());
    fs::create_dir_all(home.config("themes/later.json/inside")).unwrap();
    assert!(customize.replace_setup(&old, &next, "setup v2", "cli", 20).is_err());
    assert_eq!(fs::read(folder.join("pack-sans.woff2")).unwrap(), WOFF2, "the old fonts are back");
    fs::remove_dir_all(home.config("themes/later.json")).unwrap();

    // The update goes through: the new fonts are in place.
    let old = customize.setups().unwrap().remove(0);
    let installed = customize.replace_setup(&old, &next, "setup v2", "cli", 30).unwrap();
    customize.record_setup(receipt(&next, &installed)).unwrap();
    assert_eq!(fs::read(folder.join("pack-sans.woff2")).unwrap(), WOFF2_V2);

    // An update that no longer carries fonts takes the old copy out.
    let bare = home.dir.path().join("bare");
    fs::create_dir_all(bare.join("themes")).unwrap();
    fs::write(bare.join(SETUP_FILE), SETUP).unwrap();
    fs::write(bare.join("themes/type.json"), "{ \"name\": \"Type\" }\n").unwrap();
    let plain = setup::read_dir(&bare).unwrap();
    assert!(plain.fonts.files.is_empty());
    let old = customize.setups().unwrap().remove(0);
    let installed = customize.replace_setup(&old, &plain, "setup v3", "cli", 40).unwrap();
    customize.record_setup(receipt(&plain, &installed)).unwrap();
    assert!(!folder.exists(), "an update with no fonts removes them");
}

#[test]
fn a_setup_font_pack_follows_the_community_theme_rule() {
    let root = tempfile::tempdir().unwrap();
    let unlicensed = SETUP.replace("\n  \"fontLicense\": \"OFL-1.1\",", "");
    let why = refusal(&repo(root.path(), &unlicensed, &[]));
    assert!(why.contains("\"fontLicense\": \"OFL-1.1\" in cmux-setup.json"), "{why}");
    assert!(!why.contains("cmux-theme.json"), "{why}");

    let closed = SETUP.replace("OFL-1.1", "Proprietary");
    let why = refusal(&repo(tempfile::tempdir().unwrap().path(), &closed, &[]));
    assert!(why.contains("OFL-1.1, Apache-2.0, MIT"), "{why}");

    let root = tempfile::tempdir().unwrap();
    let no_text = repo(root.path(), SETUP, &[]);
    fs::remove_file(no_text.join("fonts/OFL.txt")).unwrap();
    let why = refusal(&no_text);
    assert!(why.contains("fonts/OFL.txt or fonts/LICENSE"), "{why}");

    let why = refusal(&repo(
        tempfile::tempdir().unwrap().path(),
        SETUP,
        &[("fonts/pack-sans.woff2", b"<svg>")],
    ));
    assert!(why.contains("not a font file"), "{why}");

    let mut big = WOFF2.to_vec();
    big.resize(usize::try_from(cmux_config::font_faces::MAX_FACE_BYTES).unwrap() + 1, 0);
    let why = refusal(&repo(
        tempfile::tempdir().unwrap().path(),
        SETUP,
        &[("fonts/pack-sans.woff2", &big)],
    ));
    assert!(why.contains("larger than 2 MiB"), "{why}");

    let names: Vec<String> =
        (0..cmux_config::font_faces::MAX_FACES).map(|n| format!("fonts/extra{n}.woff2")).collect();
    let extra: Vec<(&str, &[u8])> = names.iter().map(|n| (n.as_str(), WOFF2)).collect();
    let why = refusal(&repo(tempfile::tempdir().unwrap().path(), SETUP, &extra));
    assert!(why.contains("at most 8 font files"), "{why}");

    let missing = THEME.replace("pack-sans.woff2", "gone.woff2");
    let why = refusal(&repo(
        tempfile::tempdir().unwrap().path(),
        SETUP,
        &[("themes/type.json", missing.as_bytes())],
    ));
    assert!(why.contains("fonts/gone.woff2, which is not in the repository's fonts/"), "{why}");
}

#[test]
fn a_setup_without_fonts_reads_as_before() {
    let root = tempfile::tempdir().unwrap();
    let repo = root.path().join("plain");
    fs::create_dir_all(repo.join("themes")).unwrap();
    fs::write(repo.join(SETUP_FILE), SETUP.replace("\n  \"fontLicense\": \"OFL-1.1\",", ""))
        .unwrap();
    // A face that names a font of your own is left as it is when the setup
    // carries no fonts.
    let theme = THEME.replace("../fonts/pack-sans.woff2", "/Library/Fonts/Mine.ttf");
    fs::write(repo.join("themes/type.json"), &theme).unwrap();
    let read = setup::read_dir(&repo).unwrap();
    assert!(read.fonts.files.is_empty());
    assert_eq!(read.profile.files["themes/type.json"], theme);
}
