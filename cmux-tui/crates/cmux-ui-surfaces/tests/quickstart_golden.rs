//! Every quickstart sample (tests/fixtures/quickstart, copied from the A2UI
//! 1.0 spec repo and the a2ui.org quickstart) parses, and its normalized
//! output matches tests/golden/<sample>.json. The Mac and iPhone renderers use
//! the goldens as fixtures. Regenerate with `UPDATE_GOLDEN=1 cargo test -p
//! cmux-ui-surfaces --test quickstart_golden`.

use cmux_ui_surfaces::a2ui::{self, Message};
use cmux_ui_surfaces::model::{Source, SourceKind, Status};
use cmux_ui_surfaces::{Surface, SurfaceStore};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const FUNCTION_SUITES: &[&str] =
    &["call_function_message.json", "call_agent_function_message.json", "function_response.json"];

fn dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests")
}

fn samples() -> Vec<(String, PathBuf)> {
    let mut out: Vec<_> = std::fs::read_dir(dir().join("fixtures/quickstart"))
        .expect("fixtures dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            !FUNCTION_SUITES.contains(&p.file_name().and_then(|n| n.to_str()).unwrap_or(""))
        })
        .map(|p| (p.file_stem().unwrap().to_string_lossy().into_owned(), p))
        .collect();
    out.sort();
    out
}

fn messages(path: &Path) -> Vec<Result<Message, cmux_ui_surfaces::Refusal>> {
    let text = std::fs::read_to_string(path).unwrap();
    if path.extension().is_some_and(|e| e == "jsonl") {
        a2ui::parse_jsonl(&text, true)
    } else {
        a2ui::parse_value(&serde_json::from_str(&text).unwrap())
    }
}

/// Apply one message at a time; a deleted surface keeps its last drawn state
/// (marked `deleted`) so renderers still get a fixture for it.
fn normalize(name: &str, path: &Path) -> Value {
    let source = Source {
        kind: SourceKind::A2ui,
        server: Some("cmux".into()),
        tool: Some("ui_surface".into()),
        ..Default::default()
    };
    let mut store = SurfaceStore::new();
    let mut last: BTreeMap<String, Surface> = BTreeMap::new();
    let mut order = Vec::new();
    let mut deleted = Vec::new();
    let mut errors = Vec::new();
    let mut replies = Vec::new();
    for m in messages(path) {
        let out = store.apply_all(vec![m], &source);
        errors.extend(out.errors);
        replies.extend(out.replies);
        for id in &out.changed {
            if !order.contains(id) {
                order.push(id.clone());
            }
            last.insert(id.clone(), store.surface(id).unwrap());
        }
        deleted.extend(out.deleted);
    }
    store.finish_all();
    let surfaces: Vec<Value> = order
        .iter()
        .map(|id| {
            let mut s = store.surface(id).unwrap_or_else(|| last[id].clone());
            if s.status == Status::Streaming {
                s.status = Status::Ready;
            }
            let mut v = serde_json::to_value(&s).unwrap();
            if deleted.contains(id) {
                v["deleted"] = json!(true);
            }
            v
        })
        .collect();
    json!({ "sample": name, "surfaces": surfaces, "errors": errors, "replies": replies })
}

#[test]
fn every_sample_parses_and_matches_its_golden() {
    let update = std::env::var_os("UPDATE_GOLDEN").is_some();
    let mut failures = Vec::new();
    for (name, path) in samples() {
        for (i, m) in messages(&path).iter().enumerate() {
            assert!(m.is_ok(), "{name} message {i} refused: {:?}", m.as_ref().err());
        }
        let got = normalize(&name, &path);
        assert!(got["errors"].as_array().unwrap().is_empty(), "{name}: {}", got["errors"]);
        assert!(!got["surfaces"].as_array().unwrap().is_empty(), "{name} drew nothing");
        let golden = dir().join("golden").join(format!("{name}.json"));
        let text = serde_json::to_string_pretty(&got).unwrap() + "\n";
        if update {
            std::fs::write(&golden, &text).unwrap();
        } else if std::fs::read_to_string(&golden).ok().as_deref() != Some(text.as_str()) {
            failures.push(name);
        }
    }
    assert!(failures.is_empty(), "goldens differ (UPDATE_GOLDEN=1 to rewrite): {failures:?}");
}

#[test]
fn goldens_are_valid_surfaces() {
    for (name, _) in samples() {
        let golden = dir().join("golden").join(format!("{name}.json"));
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&golden).unwrap()).unwrap();
        for s in v["surfaces"].as_array().unwrap() {
            let mut s = s.clone();
            s.as_object_mut().unwrap().remove("deleted");
            let parsed: Surface =
                serde_json::from_value(s).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(parsed.schema, "cmux.ui-surface/1");
        }
    }
}

#[test]
fn function_message_suites_match_their_validity() {
    for file in FUNCTION_SUITES {
        let v: Value = serde_json::from_str(
            &std::fs::read_to_string(dir().join("fixtures/quickstart").join(file)).unwrap(),
        )
        .unwrap();
        let renderer_bound = v["schema"] == "agent_to_renderer.json";
        for t in v["tests"].as_array().unwrap() {
            let ok = if renderer_bound {
                a2ui::parse_message(&t["data"]).is_ok()
            } else {
                a2ui::validate_client_message(&t["data"]).is_ok()
            };
            assert_eq!(ok, t["valid"].as_bool().unwrap(), "{file}: {}", t["description"]);
        }
    }
}
