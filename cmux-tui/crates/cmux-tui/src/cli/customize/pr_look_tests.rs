//! `use OWNER/REPO@REF` for a look: a fork layer whose release also carries
//! the look's settings as profile.json, against a fake GitHub on a local
//! port.

use std::fs;

use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::github::GitHub;
use super::super::github::tests::fake;
use super::super::render::Answer;
use super::super::source::Source;
use super::{App, Http, hex, use_with};

const PROFILE: &str = r#"{"cmuxProfile": 1, "name": "codex-look",
    "settings": {"appearance.density": "compact"}}"#;

fn archive() -> Vec<u8> {
    let mut builder =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
    let body = b"<p>look</p>";
    let mut header = tar::Header::new_gnu();
    header.set_size(body.len() as u64);
    header.set_mode(0o644);
    header.set_entry_type(tar::EntryType::Regular);
    builder
        .append_data(&mut header, "Resources/markdown-viewer/webviews-app/index.html", &body[..])
        .unwrap();
    builder.into_inner().unwrap().finish().unwrap()
}

/// A fork release of `o/r@look`: its archive, layer.json, and profile.json
/// when `profile` says what layer.json names (its sha256, and the bytes).
fn release(profile: Option<(&str, &'static str)>) -> (String, String) {
    let archive = archive();
    let key = hex(&Sha256::digest(&archive));
    let mut layer = json!({
        "schema": 1, "repo": "o/r", "kind": "fork", "ref": "look", "title": "a look",
        "head": "a".repeat(40), "base": "b".repeat(40), "key": key, "abi": 3,
        "classify": {"files": {"web-live": ["webviews/src/a.ts"]}},
    });
    if let Some((sha, _)) = profile {
        layer["profile"] = json!("profile.json");
        layer["profile_sha256"] = json!(sha);
    }
    let layer = layer.to_string().into_bytes();
    let body = profile.map(|(_, body)| body);
    let (origin, _log) = fake(move |seen| {
        let dir = "/o/r/releases/download/cmux-web-layer-look/";
        match seen.path.strip_prefix(dir) {
            Some("layer.json") => (200, vec![], layer.clone()),
            Some("web-bundles.tar.gz") => (200, vec![], archive.clone()),
            Some("profile.json") if body.is_some() => {
                (200, vec![], body.unwrap_or_default().as_bytes().to_vec())
            }
            _ => (404, vec![], vec![]),
        }
    });
    (origin, key)
}

struct Home {
    dir: tempfile::TempDir,
    customize: Customize,
}

fn home() -> Home {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("config")).unwrap();
    fs::write(dir.path().join("config/cmux-next.json"), "{}\n").unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    Home { dir, customize }
}

impl Home {
    fn settings(&self) -> String {
        fs::read_to_string(self.dir.path().join("config/cmux-next.json")).unwrap()
    }
}

fn use_look(home: &Home, origin: &str) -> Result<Answer, super::Failure> {
    let http =
        Http::for_test(GitHub { web: origin.to_owned(), api: origin.to_owned() }, None).unwrap();
    let app = App { path: None, commit: None, abi: Some(3) };
    let source = Source::Fork { repo: "o/r".into(), reference: "look".into() };
    use_with(&home.customize, &http, &app, source, "cli", 1_000)
}

fn json_of(answer: &Answer) -> Value {
    match answer {
        Answer::Library { json, .. } => json.clone(),
        _ => Value::Null,
    }
}

#[test]
fn a_layer_with_no_profile_puts_on_only_its_code() {
    let home = home();
    let (origin, key) = release(None);
    let answer = use_look(&home, &origin).unwrap();
    assert!(json_of(&answer).get("profile").is_none());
    assert!(home.customize.layer_ready(&key));
    assert_eq!(home.customize.library().unwrap().entries.len(), 1);
    assert!(home.customize.status().unwrap().draft.is_none());
    assert_eq!(home.settings(), "{}\n");
}

#[test]
fn a_look_brings_its_code_and_previews_its_settings() {
    let home = home();
    let sha = hex(&Sha256::digest(PROFILE.as_bytes()));
    let (origin, key) = release(Some((&sha, PROFILE)));
    let answer = use_look(&home, &origin).unwrap();
    assert_eq!(json_of(&answer)["profile"]["name"], "codex-look");
    let human = answer.human(1_000);
    assert!(human.contains("profile codex-look"), "{human}");
    assert!(human.contains("cmux customize discard"), "{human}");
    assert!(home.customize.layer_ready(&key));
    assert_eq!(home.customize.library().unwrap().entries.len(), 1);
    assert!(home.customize.status().unwrap().draft.is_some());
    assert!(home.settings().contains("compact"), "{}", home.settings());
    // `discard` takes the settings back; the code stays a library entry.
    home.customize.discard("cli", 2_000).unwrap();
    assert!(!home.settings().contains("compact"), "{}", home.settings());
}

#[test]
fn a_profile_whose_sha256_differs_is_refused_and_nothing_is_written() {
    let home = home();
    let (origin, key) = release(Some((&"0".repeat(64), PROFILE)));
    let error = use_look(&home, &origin).err().unwrap();
    assert!(error.message.contains("sha256"), "{}", error.message);
    assert!(!home.customize.layer_dir(&key).exists());
    assert!(home.customize.library().unwrap().entries.is_empty());
    assert!(home.customize.status().unwrap().draft.is_none());
    assert_eq!(home.settings(), "{}\n");
}
