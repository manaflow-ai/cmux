//! `apps-cli` resolution: `cmux <cli.name> <path…>` finds one installed app
//! and the op with the longest matching `cli.path`.

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::super::catalog::Package;
use super::super::mirror::{Record, Source, Tier};
use super::resolve;

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// App `acme/<dir>` called `demo` with ops `ping`, `session start` and
/// `session` (a shorter path that the longer one must win over).
fn demo(dir: &str) -> (Package, Dir) {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let root = std::env::temp_dir().join(format!(
        "cmux-cli-cmd-{dir}-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let op = |verb: &str, path: &str| {
        json!({ "name": format!("acme_{dir}.{verb}"), "docs": format!("{verb} docs"),
                "input": { "type": "object", "properties": { "text": { "type": "string" } } },
                "cli": { "path": path, "positional": ["text"] } })
    };
    let catalog = json!({ "family": format!("acme_{dir}"), "operations": [
        op("ping", "ping"), op("start", "session start"), op("session", "session"),
        { "name": format!("acme_{dir}.quiet"), "docs": "no cli", "input": { "type": "object" } },
    ]});
    std::fs::write(root.join("catalog.json"), catalog.to_string()).unwrap();
    let manifest = json!({ "id": format!("acme/{dir}"), "name": "Demo", "catalog": "catalog.json", "cli": { "name": "demo" } });
    let package = Package {
        id: format!("acme/{dir}"),
        version: "1.0.0".into(),
        tier: Tier::Unverified,
        source: Source::User,
        dir: root.clone(),
        manifest,
    };
    (package, Dir(root))
}

fn record(enabled: bool) -> Record {
    Record {
        installed: true,
        source: Source::User,
        enabled,
        hidden: false,
        hidden_access: Default::default(),
        sandboxed: false,
        grants: BTreeSet::new(),
    }
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn the_longest_cli_path_names_the_op_and_says_how_many_words_it_took() {
    let (package, _dir) = demo("a");
    let on = record(true);
    let claims = [(&package, &on)];
    let ping = resolve("demo", &words("ping hello"), &claims).unwrap();
    assert_eq!(ping["app"], "acme/a");
    assert_eq!(ping["op"], "acme_a.ping");
    assert_eq!(ping["consumed"], 1);
    assert_eq!(ping["positional"], json!(["text"]));
    assert_eq!(ping["input"]["properties"]["text"]["type"], "string");
    let start = resolve("demo", &words("session start now"), &claims).unwrap();
    assert_eq!((start["op"].as_str(), start["consumed"].as_u64()), (Some("acme_a.start"), Some(2)));
    let session = resolve("demo", &words("session"), &claims).unwrap();
    assert_eq!(session["op"], "acme_a.session");
}

#[test]
fn help_lists_the_commands_and_an_unknown_path_names_them() {
    let (package, _dir) = demo("b");
    let on = record(true);
    let claims = [(&package, &on)];
    for asked in ["", "help", "--help"] {
        let help = resolve("demo", &words(asked), &claims).unwrap();
        assert!(help.get("op").is_none(), "{help}");
        let paths: Vec<&str> = help["commands"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|c| c["path"].as_str())
            .collect();
        assert_eq!(paths, ["ping", "session start", "session"]);
    }
    let unknown = resolve("demo", &words("pong"), &claims).unwrap_err();
    assert_eq!(unknown.code, "apps.cli.path_unknown");
    assert_eq!(unknown.details.unwrap()["commands"].as_array().map(Vec::len), Some(3));
}

#[test]
fn no_app_two_apps_and_a_disabled_app_each_answer_their_own_error() {
    let none = resolve("demo", &words("ping"), &[]).unwrap_err();
    assert_eq!(none.code, "apps.cli.unknown");
    let (a, _a) = demo("c");
    let (b, _b) = demo("d");
    let on = record(true);
    let both = resolve("demo", &words("ping"), &[(&a, &on), (&b, &on)]).unwrap_err();
    assert_eq!(both.code, "apps.cli.conflict");
    let details: Value = both.details.unwrap();
    assert_eq!(details["forms"], json!(["cmux apps run acme/c <op>", "cmux apps run acme/d <op>"]));
    let off = record(false);
    assert_eq!(resolve("demo", &words("ping"), &[(&a, &off)]).unwrap_err().code, "apps.disabled");
}
