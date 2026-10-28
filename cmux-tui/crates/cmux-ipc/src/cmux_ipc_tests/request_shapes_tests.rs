//! The request-shape reader (build-support/request_shapes.rs) keeps every
//! framed command, resolves refs, aliases, unions and recursion, never
//! refuses a kind it does not know, and its table (feature `fuzzing`) agrees
//! with the method table.

use serde_json::json;

#[allow(dead_code, reason = "the build script uses the emitter; the tests use the reader")]
#[path = "../../build-support/request_shapes.rs"]
mod reader;

use reader::{Node, read};

fn object_fields(shapes: &reader::Shapes, index: usize) -> &[reader::FieldNode] {
    match &shapes.nodes[index] {
        Node::Object { fields, .. } => fields,
        other => panic!("node {index} is {other:?}, not an object"),
    }
}

#[test]
fn reader_keeps_only_framed_commands_sorted_by_id() {
    let sdk = json!({
        "types": {},
        "commands": {
            "b-cmd": {"method_id": 0x0102, "request": {"kind": "object", "fields": {}}},
            "a-cmd": {"method_id": 0x0101, "request": {"kind": "object", "fields": {}}},
            "unframed": {"request": {"kind": "object", "fields": {}}},
        }
    });
    let shapes = read(&sdk);
    let names: Vec<(u16, &str)> =
        shapes.requests.iter().map(|r| (r.method_id, r.name.as_str())).collect();
    assert_eq!(names, vec![(0x0101, "a-cmd"), (0x0102, "b-cmd")]);
}

#[test]
fn reader_resolves_refs_aliases_unions_bounds_and_recursion() {
    let sdk = json!({
        "types": {
            "Tree": {"kind": "object", "additional_properties": false, "fields": {
                "children": {"type": {"kind": "array", "items": {"kind": "ref", "name": "Tree"},
                                       "min_items": 1, "max_items": 4},
                             "presence": "required", "nullable": false},
            }},
            "Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}},
            "Event": {"kind": "tagged_union", "tag": "kind", "variants": {
                "focus": {"kind": "object", "fields": {
                    "kind": {"type": {"kind": "literal", "value": "focus"}, "presence": "required"},
                }},
            }},
        },
        "commands": {"cmd": {"method_id": 0x0101, "request": {"kind": "object", "fields": {
            "tree": {"type": {"kind": "ref", "name": "Tree"}, "presence": "required"},
            "again": {"type": {"kind": "ref", "name": "Tree"}, "presence": "optional"},
            "id": {"type": {"kind": "ref", "name": "Id"}, "presence": "optional", "nullable": true},
            "event": {"type": {"kind": "ref", "name": "Event"}, "presence": "required"},
            "cols": {"type": {"kind": "scalar", "name": "uint16"}, "presence": "optional",
                     "constraints": [{"minimum": 1}, {"maximum": 500}]},
            "name": {"type": {"kind": "scalar", "name": "string"}, "presence": "optional",
                     "constraints": [{"max_utf8_bytes": 64}]},
            "future": {"type": {"kind": "quaternion"}, "presence": "optional"},
        }}}}
    });
    let shapes = read(&sdk);
    let fields = object_fields(&shapes, shapes.requests[0].params);
    let field = |name: &str| fields.iter().find(|f| f.name == name).unwrap();
    assert_eq!(field("tree").shape, field("again").shape, "a named type is one node");
    assert!(field("tree").required && !field("again").required);
    let tree = field("tree").shape;
    let children = object_fields(&shapes, tree)[0].shape;
    assert_eq!(shapes.nodes[children], Node::Array { items: tree, min: 1, max: Some(4) });
    assert!(field("id").nullable);
    assert_eq!(shapes.nodes[field("id").shape], Node::Unsigned { min: 0, max: u64::MAX });
    assert_eq!(shapes.nodes[field("cols").shape], Node::Unsigned { min: 1, max: 500 });
    assert_eq!(shapes.nodes[field("name").shape], Node::Text { max_bytes: Some(64) });
    assert_eq!(shapes.nodes[field("future").shape], Node::Any);
    let Node::OneOf(variants) = &shapes.nodes[field("event").shape] else {
        panic!("a tagged union is OneOf");
    };
    let tag = &object_fields(&shapes, variants[0])[0];
    assert_eq!(shapes.nodes[tag.shape], Node::LiteralText("focus".into()));
    for node in &shapes.nodes {
        let children: Vec<usize> = match node {
            Node::Array { items, .. } => vec![*items],
            Node::Map { values } => vec![*values],
            Node::Object { fields, .. } => fields.iter().map(|f| f.shape).collect(),
            Node::OneOf(variants) => variants.clone(),
            _ => Vec::new(),
        };
        assert!(children.iter().all(|child| *child < shapes.nodes.len()), "{node:?}");
    }
}

#[test]
fn reader_reads_the_real_schema_without_any_request_left_untyped() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/sdk-schema.json");
    let sdk: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let shapes = read(&sdk);
    let framed = sdk["commands"]
        .as_object()
        .unwrap()
        .values()
        .filter(|command| command.get("method_id").is_some())
        .count();
    assert_eq!(shapes.requests.len(), framed);
    for request in &shapes.requests {
        assert!(
            matches!(shapes.nodes[request.params], Node::Object { .. }),
            "{} has no object request",
            request.name
        );
    }
}

#[cfg(feature = "fuzzing")]
#[test]
fn table_has_a_shape_for_every_framed_v12_method() {
    use crate::methods::MethodTables;
    use crate::request_shapes::{RequestShapes, Shape};

    let shapes = RequestShapes::schema();
    let tables = MethodTables::schema();
    let mut methods = 0;
    for method in tables.v12_families().flat_map(|family| family.iter()) {
        methods += 1;
        let request = shapes.request(method.id).unwrap_or_else(|| panic!("{}", method.name));
        assert_eq!(request.name, method.name);
        assert!(matches!(shapes.shape(request.params), Some(Shape::Object { .. })));
    }
    assert_eq!(methods, shapes.requests().len());
    let new_workspace = tables.v12_id("new-workspace").and_then(|id| shapes.request(id)).unwrap();
    let Some(Shape::Object { fields, open: false }) = shapes.shape(new_workspace.params) else {
        panic!("new-workspace takes a closed object");
    };
    let name = fields.iter().find(|field| field.name == "name").unwrap();
    assert!(!name.required && name.nullable);
    assert_eq!(shapes.shape(name.shape), Some(&Shape::Text { max_bytes: Some(1024) }));
}
