use super::*;

/// Every type an error contract can look up is kept, and only those.
#[test]
fn the_error_catalog_keeps_exactly_the_types_error_contracts_reach() {
    let full = parse_error_catalog();
    let kept = &error_catalog().types;
    assert!(
        !kept.is_empty() && kept.len() < full.types.len(),
        "{} of {}",
        kept.len(),
        full.types.len()
    );
    let mut reached = std::collections::BTreeSet::new();
    let mut pending = Vec::new();
    collect_type_refs(&full.errors, &mut pending);
    while let Some(name) = pending.pop() {
        if reached.insert(name.clone()) {
            let descriptor = full.types.get(&name).expect("a ref names a catalog type");
            collect_type_refs(descriptor, &mut pending);
        }
    }
    assert_eq!(kept.keys().cloned().collect::<std::collections::BTreeSet<_>>(), reached);
    for (name, descriptor) in kept {
        assert_eq!(Some(descriptor), full.types.get(name), "{name}");
    }
}

#[test]
fn type_refs_are_found_at_any_depth() {
    let mut names = Vec::new();
    collect_type_refs(
        &json!({"a": [{"kind": "ref", "name": "x"}, {"b": {"kind": "ref", "name": "y"}}],
                    "kind": "object", "name": "not-a-ref"}),
        &mut names,
    );
    names.sort();
    assert_eq!(names, ["x", "y"]);
}
