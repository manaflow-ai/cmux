//! Swift `LayoutTemplateRepository` and `LayoutTemplateLibrary`'s list rules:
//! saving a template under a name replaces the one of that name (any case),
//! a rename refuses a missing id or a taken name, a delete a missing id. A
//! template is the app's JSON object (`id`, `name`, `blueprint`, `savedAt`);
//! fields these rules do not read pass through unchanged. The app writes the
//! file and makes the ids and dates.

use serde::Serialize;
use serde_json::{Map, Value};

/// A refused change (Swift `LayoutTemplateRepository.Failure`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    NotFound,
    NameTaken,
}

/// Whether two template names are the same name: equal ignoring case (Swift
/// `caseInsensitiveCompare`).
pub fn same(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

fn field<'a>(template: &'a Value, key: &str) -> &'a str {
    template.get(key).and_then(Value::as_str).unwrap_or("")
}

fn set(template: &mut Value, key: &str, value: Value) {
    if let Value::Object(object) = template {
        object.insert(key.to_owned(), value);
    }
}

/// Saves `blueprint` as `name` at `saved_at`: over the template of that name
/// (keeping its id, taking this name's case), else as a new template `new_id`
/// at the end.
pub fn put(
    mut templates: Vec<Value>,
    name: &str,
    blueprint: Value,
    saved_at: Value,
    new_id: &str,
) -> Vec<Value> {
    if let Some(template) =
        templates.iter_mut().find(|template| same(field(template, "name"), name))
    {
        set(template, "name", Value::from(name));
        set(template, "blueprint", blueprint);
        set(template, "savedAt", saved_at);
    } else {
        let mut object = Map::new();
        object.insert("id".into(), Value::from(new_id));
        object.insert("name".into(), Value::from(name));
        object.insert("blueprint".into(), blueprint);
        object.insert("savedAt".into(), saved_at);
        templates.push(Value::Object(object));
    }
    templates
}

/// Renames template `id` to `name`.
pub fn rename(mut templates: Vec<Value>, id: &str, name: &str) -> Result<Vec<Value>, Failure> {
    let index = templates
        .iter()
        .position(|template| field(template, "id") == id)
        .ok_or(Failure::NotFound)?;
    if templates
        .iter()
        .any(|template| field(template, "id") != id && same(field(template, "name"), name))
    {
        return Err(Failure::NameTaken);
    }
    set(&mut templates[index], "name", Value::from(name));
    Ok(templates)
}

/// Deletes template `id`.
pub fn delete(mut templates: Vec<Value>, id: &str) -> Result<Vec<Value>, Failure> {
    if !templates.iter().any(|template| field(template, "id") == id) {
        return Err(Failure::NotFound);
    }
    templates.retain(|template| field(template, "id") != id);
    Ok(templates)
}

/// The index of the template named `name`, ignoring case and surrounding
/// whitespace and newlines (Swift `LayoutTemplateLibrary.template(named:)`).
pub fn named(templates: &[Value], name: &str) -> Option<usize> {
    let name = name.trim();
    templates.iter().position(|template| same(field(template, "name"), name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn names(templates: &[Value]) -> Vec<&str> {
        templates.iter().map(|template| field(template, "name")).collect()
    }

    // LayoutTemplateTests.savingALayoutOffersItAsATemplate: a second save under one name replaces it.
    #[test]
    fn a_save_under_a_taken_name_replaces_it_and_keeps_its_id() {
        let list =
            put(vec![], "Two up", json!({"panes": 2}), json!("2026-11-26T00:00:00Z"), "id-1");
        assert_eq!(
            list,
            vec![
                json!({"id": "id-1", "name": "Two up", "blueprint": {"panes": 2}, "savedAt": "2026-11-26T00:00:00Z"})
            ]
        );
        let list = put(list, "TWO UP", json!({"panes": 3}), json!("2026-11-27T00:00:00Z"), "id-2");
        assert_eq!(
            list,
            vec![
                json!({"id": "id-1", "name": "TWO UP", "blueprint": {"panes": 3}, "savedAt": "2026-11-27T00:00:00Z"})
            ]
        );
        let list = put(list, "Solo", json!({"panes": 1}), json!(1), "id-3");
        assert_eq!(names(&list), ["TWO UP", "Solo"]);
        assert_eq!(field(&list[1], "id"), "id-3");
    }

    #[test]
    fn fields_the_rules_do_not_read_pass_through() {
        let list =
            vec![json!({"id": "a", "name": "X", "blueprint": 1, "savedAt": 0, "extra": true})];
        let list = put(list, "x", json!(2), json!(5), "b");
        assert_eq!(
            list,
            vec![json!({"id": "a", "name": "x", "blueprint": 2, "savedAt": 5, "extra": true})]
        );
    }

    // LayoutTemplateTests.templatesPersistAndRenameAndDeleteThroughTheFile
    #[test]
    fn rename_and_delete() {
        let list = vec![json!({"id": "a", "name": "Two up"}), json!({"id": "b", "name": "Solo"})];
        let renamed = rename(list.clone(), "a", "Side by side").unwrap();
        assert_eq!(names(&renamed), ["Side by side", "Solo"]);
        assert_eq!(rename(renamed.clone(), "a", "solo"), Err(Failure::NameTaken));
        // Its own name in another case is no clash.
        assert_eq!(
            names(&rename(renamed.clone(), "a", "SIDE BY SIDE").unwrap()),
            ["SIDE BY SIDE", "Solo"]
        );
        assert_eq!(rename(renamed.clone(), "zz", "New"), Err(Failure::NotFound));
        let deleted = delete(renamed, "b").unwrap();
        assert_eq!(names(&deleted), ["Side by side"]);
        assert_eq!(delete(deleted, "b"), Err(Failure::NotFound));
    }

    #[test]
    fn named_ignores_case_and_surrounding_whitespace() {
        let list = vec![json!({"id": "a", "name": "Two up"}), json!({"id": "b", "name": "Solo"})];
        assert_eq!(named(&list, "  solo\n"), Some(1));
        assert_eq!(named(&list, "Two Up"), Some(0));
        assert_eq!(named(&list, "Nope"), None);
        assert_eq!(named(&[], "Solo"), None);
    }

    #[test]
    fn same_ignores_case_only() {
        assert!(same("Two up", "two UP"));
        assert!(same("Émile", "émile"));
        assert!(!same("Two up", "Two up "));
    }
}
