//! The `list-workspaces` reply against `cmux-tui/spec/sdk-schema.json`: every key the
//! daemon writes into the tree (Tree, Workspace, Screen, Pane, Tab and everything they
//! reference) is a field the schema declares, with a value of the declared shape. The tree
//! is built with `json!` literals, so nothing derives the schema from a Rust type; this test
//! is what keeps the result side of the schema in step with the serializer, which the
//! generated Swift mirrors (cmux-tui/bindings/codegen/swift_app) read.

use super::*;

fn schema() -> Value {
    serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap()
}

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request.clone()).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
        .unwrap_or_else(|error| panic!("{request}: {error:?}"))
}

/// Walks `value` against the schema type `ty`, recording `path: problem` for every key the
/// schema does not declare and every value whose JSON kind differs from the declared one.
struct Walker<'a> {
    types: &'a serde_json::Map<String, Value>,
    problems: std::collections::BTreeSet<String>,
}

impl Walker<'_> {
    fn check(&mut self, path: &str, ty: &Value, value: &Value) {
        let kind = ty["kind"].as_str().unwrap_or_default();
        match kind {
            "ref" => {
                let name = ty["name"].as_str().unwrap();
                let target = self.types.get(name).unwrap_or_else(|| panic!("no type {name}"));
                self.check(name, target, value);
            }
            "alias" => self.check(path, &ty["target"], value),
            "opaque_json" => {}
            "scalar" => {
                let ok = match ty["name"].as_str().unwrap() {
                    "string" => value.is_string(),
                    "boolean" => value.is_boolean(),
                    "float32" | "float64" => value.is_number(),
                    "int32" | "int64" => value.is_i64() || value.is_u64(),
                    _ => value.is_u64(),
                };
                if !ok {
                    self.problems.insert(format!("{path}: {value} is not a {}", ty["name"]));
                }
            }
            "literal" => {
                if value != &ty["value"] {
                    self.problems.insert(format!("{path}: {value} is not {}", ty["value"]));
                }
            }
            "enum" => {
                let values = ty["values"].as_array().unwrap();
                if !values.contains(value) {
                    self.problems.insert(format!("{path}: {value} is not one of {values:?}"));
                }
            }
            "array" => match value.as_array() {
                Some(items) => {
                    for item in items {
                        self.check(&format!("{path}[]"), &ty["items"], item);
                    }
                }
                None => {
                    self.problems.insert(format!("{path}: {value} is not an array"));
                }
            },
            "map" => match value.as_object() {
                Some(entries) => {
                    for item in entries.values() {
                        self.check(&format!("{path}{{}}"), &ty["values"], item);
                    }
                }
                None => {
                    self.problems.insert(format!("{path}: {value} is not a map"));
                }
            },
            "object" => self.object(path, ty, value),
            "tagged_union" => {
                let tag = ty["tag"].as_str().unwrap();
                let Some(name) = value[tag].as_str() else {
                    self.problems.insert(format!("{path}: no `{tag}` tag"));
                    return;
                };
                match ty["variants"].get(name) {
                    Some(variant) => self.check(&format!("{path}.{name}"), variant, value),
                    None => {
                        self.problems.insert(format!("{path}: unknown {tag} {name:?}"));
                    }
                }
            }
            "untagged_union" => {
                let variants = ty["variants"].as_array().unwrap();
                let mut best: Option<std::collections::BTreeSet<String>> = None;
                for variant in variants {
                    let mut trial = Walker { types: self.types, problems: Default::default() };
                    trial.check(path, variant, value);
                    if best.as_ref().is_none_or(|b| trial.problems.len() < b.len()) {
                        best = Some(trial.problems);
                    }
                }
                self.problems.extend(best.unwrap_or_default());
            }
            other => panic!("{path}: schema kind {other} is not walked"),
        }
    }

    fn object(&mut self, path: &str, ty: &Value, value: &Value) {
        let Some(object) = value.as_object() else {
            self.problems.insert(format!("{path}: {value} is not an object"));
            return;
        };
        let fields = ty["fields"].as_object().unwrap();
        for (key, item) in object {
            let Some(field) = fields.get(key) else {
                self.problems.insert(format!("{path}.{key}: not in the schema ({item})"));
                continue;
            };
            if item.is_null() {
                if field["nullable"] != true {
                    self.problems.insert(format!("{path}.{key}: null but not nullable"));
                }
                continue;
            }
            self.check(&format!("{path}.{key}"), &field["type"], item);
        }
        for (key, field) in fields {
            if field["presence"] == "required" && !object.contains_key(key) {
                self.problems.insert(format!("{path}.{key}: required but missing"));
            }
        }
    }
}

/// A tree with each kind of thing the daemon writes: two workspaces, a second screen, a split,
/// a terminal, a browser and a conversation tab.
fn rich_tree() -> Value {
    let mux = Mux::new_for_test("tree-schema", crate::SurfaceOptions::default());
    let first = mux.new_workspace(Some("first".into()), Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    mux.new_pane_right_with_options(pane, 0.5, crate::TerminalSpawnOptions::default(), None)
        .unwrap();
    mux.new_tab_with_options(Some(pane), crate::TerminalSpawnOptions::default(), None).unwrap();
    mux.new_browser_tab_with_fields(
        "https://example.com/".into(),
        Some(pane),
        None,
        serde_json::Map::new(),
    )
    .unwrap();
    run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","harness":"claude"}}),
    );
    mux.new_screen_named(None, Some("second".into()), crate::TerminalSpawnOptions::default(), None)
        .unwrap();
    mux.new_workspace(Some("other".into()), Some((80, 24))).unwrap();
    run(&mux, json!({"cmd":"list-workspaces"}))
}

#[test]
fn the_list_workspaces_tree_is_what_the_sdk_schema_declares() {
    let schema = schema();
    let types = schema["types"].as_object().unwrap();
    let tree = rich_tree();
    let mut walker = Walker { types, problems: Default::default() };
    walker.check("Tree", &json!({"kind":"ref","name":"Tree"}), &tree);
    assert!(
        walker.problems.is_empty(),
        "list-workspaces wrote what cmux-tui/spec/sdk-schema.json does not declare; add each \
         field to its type there (the Swift mirrors are generated from it):\n{}",
        walker.problems.iter().cloned().collect::<Vec<_>>().join("\n")
    );
}
