//! Keeps a subset of an OpenAPI document: the operations whose first tag is
//! on an allowlist, and only the component schemas those operations reach.
//! `cmux-cloud-client` uses it to generate the NEXT Cloud client from
//! cmux-platform's whole public spec without the routes it never calls
//! (Slack, inference, MCP...), so the generated file and its compile stay
//! small. The cmux VM client passes no allowlist and keeps everything.

use std::collections::{BTreeSet, VecDeque};

use serde_json::Value;

const METHODS: [&str; 8] = [
    "get", "put", "post", "delete", "options", "head", "patch", "trace",
];

/// Drops every operation whose first tag is not in `tags`, every path left
/// with no operation, and every component schema no kept operation reaches.
/// Returns the tags in `tags` that no operation carries, so a renamed group
/// fails the regeneration instead of silently dropping its routes.
pub fn keep_tags(doc: &mut Value, tags: &BTreeSet<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    if let Some(paths) = doc.get_mut("paths").and_then(Value::as_object_mut) {
        for item in paths.values_mut().filter_map(Value::as_object_mut) {
            item.retain(|key, operation| {
                if !METHODS.contains(&key.as_str()) {
                    return true;
                }
                let tag = operation
                    .pointer("/tags/0")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                seen.insert(tag.to_owned());
                tags.contains(tag)
            });
        }
        paths.retain(|_, item| {
            item.as_object()
                .is_some_and(|item| item.keys().any(|k| METHODS.contains(&k.as_str())))
        });
    }
    prune_schemas(doc);
    tags.iter()
        .filter(|t| !seen.contains(*t))
        .cloned()
        .collect()
}

/// Removes the component schemas that nothing under `paths` reaches,
/// following `$ref`s through other schemas.
fn prune_schemas(doc: &mut Value) {
    let mut reached = BTreeSet::new();
    let mut queue = VecDeque::new();
    if let Some(paths) = doc.get("paths") {
        refs(paths, &mut queue);
    }
    while let Some(name) = queue.pop_front() {
        if !reached.insert(name.clone()) {
            continue;
        }
        if let Some(schema) = doc.pointer(&format!("/components/schemas/{name}")) {
            refs(schema, &mut queue);
        }
    }
    if let Some(schemas) = doc
        .pointer_mut("/components/schemas")
        .and_then(Value::as_object_mut)
    {
        schemas.retain(|name, _| reached.contains(name));
    }
}

fn refs(value: &Value, out: &mut VecDeque<String>) {
    match value {
        Value::Object(obj) => {
            if let Some(name) = obj
                .get("$ref")
                .and_then(Value::as_str)
                .and_then(|r| r.strip_prefix("#/components/schemas/"))
            {
                out.push_back(name.replace("~1", "/").replace("~0", "~"));
            }
            for v in obj.values() {
                refs(v, out);
            }
        }
        Value::Array(values) => values.iter().for_each(|v| refs(v, out)),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_tagged_operations_and_the_schemas_they_reach() {
        let mut doc = json!({
            "paths": {
                "/v1/machines": {
                    "get": {"tags": ["Machines"], "responses": {"200": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Machine"}}}}}},
                    "post": {"tags": ["Slack"]}
                },
                "/v1/slack": {"get": {"tags": ["Slack"], "responses": {"200": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Slack"}}}}}}}
            },
            "components": {"schemas": {
                "Machine": {"properties": {"state": {"$ref": "#/components/schemas/State"}}},
                "State": {"type": "string"},
                "Slack": {"type": "object"}
            }}
        });
        let tags: BTreeSet<String> = ["Machines".to_owned(), "Gone".to_owned()].into();
        let missing = keep_tags(&mut doc, &tags);
        assert_eq!(missing, vec!["Gone".to_owned()]);
        assert!(doc.pointer("/paths/~1v1~1slack").is_none());
        assert!(doc.pointer("/paths/~1v1~1machines/post").is_none());
        assert!(doc.pointer("/paths/~1v1~1machines/get").is_some());
        let schemas = doc
            .pointer("/components/schemas")
            .unwrap()
            .as_object()
            .unwrap();
        assert_eq!(
            schemas.keys().cloned().collect::<Vec<_>>(),
            vec!["Machine".to_owned(), "State".to_owned()]
        );
    }
}
