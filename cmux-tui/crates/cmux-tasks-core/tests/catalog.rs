//! The catalog is the single source: every mutation entry maps to an `Op`
//! variant with exactly its params, and every `Op` has an entry.

use cmux_tasks_core::catalog::{self, Class, Ty};
use cmux_tasks_core::op::Op;
use serde_json::{Map, Value, json};

fn sample(ty: Ty) -> Value {
    match ty {
        Ty::Str => json!("x"),
        Ty::Id { prefix, .. } => json!(format!("{prefix}x")),
        Ty::TaskRef => json!("CMX-1"),
        Ty::Bool => json!(false),
        Ty::U32 | Ty::U64 | Ty::I64 => json!(1),
        Ty::Enum(values) => json!(values[0]),
        Ty::Json => json!([{"content": "a", "status": "pending"}]),
    }
}

#[test]
fn every_mutation_entry_round_trips_into_its_op() {
    for entry in catalog::all().iter().filter(|e| e.class == Class::Mutation) {
        let mut params = Map::new();
        for p in entry.params {
            let value = sample(p.ty);
            params.insert(p.name.to_owned(), if p.repeated { json!([value]) } else { value });
        }
        let wire = json!({"op": entry.name, "params": params});
        let op: Op = serde_json::from_value(wire.clone())
            .unwrap_or_else(|e| panic!("{}: {e}: {wire}", entry.name));
        assert_eq!(op.name(), entry.name);
    }
}

#[test]
fn names_and_cli_paths_are_unique() {
    let mut names = std::collections::BTreeSet::new();
    let mut paths = std::collections::BTreeSet::new();
    for e in catalog::all() {
        assert!(names.insert(e.name), "duplicate {}", e.name);
        assert!(paths.insert(e.cli), "duplicate cli {}", e.cli);
        assert!(
            e.params.iter().filter(|p| p.positional).count() <= 1,
            "{}: one positional at most",
            e.name
        );
    }
}

#[test]
fn exports_are_well_formed() {
    let exported = catalog::export_json();
    assert_eq!(exported["operations"].as_array().unwrap().len(), catalog::all().len());
    let tools = catalog::mcp_tools(false);
    assert!(tools.as_array().unwrap().iter().any(|t| t["name"] == "task_create"));
    assert!(
        !tools.as_array().unwrap().iter().any(|t| t["name"] == "task_delete"),
        "delete is opt-in"
    );
    let ts = catalog::export_typescript();
    assert!(ts.contains("export interface TaskCreateParams"));
    assert!(ts.contains("create(params: TaskCreateParams): Promise<OpResult>;"));
}

/// The checked-in exports (merged-catalog input, mux code-mode
/// declarations, the app's palette copy) must equal a fresh export, so
/// every op change shows up as a reviewed catalog diff.
#[test]
fn checked_in_exports_match() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let fresh = catalog::export_json();
    for path in [
        root.join("catalog/tasks-catalog.json"),
        root.join(
            "../../../Packages/macOS/CmuxNext/Sources/CmuxNextTasks/Resources/tasks-catalog.json",
        ),
    ] {
        let text =
            std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let stored: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            stored,
            fresh,
            "{} is stale: run `cmux-tasks catalog > {}`",
            path.display(),
            path.display()
        );
    }
    let ts = std::fs::read_to_string(root.join("catalog/mux-task.d.ts")).unwrap();
    assert_eq!(
        ts.trim_end(),
        catalog::export_typescript().trim_end(),
        "mux-task.d.ts is stale: run `cmux-tasks catalog --format ts`"
    );
}
