use super::*;

#[test]
fn variables_found_by_reference_only() {
    let mut out = Vec::new();
    conductor_variables(
        "cd \"$CONDUCTOR_ROOT_PATH\" && PORT=${CONDUCTOR_PORT} npm run dev # CONDUCTOR_NOTE",
        &mut out,
    );
    assert_eq!(out, ["CONDUCTOR_ROOT_PATH", "CONDUCTOR_PORT"]);
}

#[test]
fn env_names_never_values() {
    let value: Value =
        serde_json::json!({"API_KEY": "secret", "local": {"DB_URL": "postgres://x"}});
    let mut names = Vec::new();
    env_names(&value, &mut names);
    names.sort();
    assert_eq!(names, ["API_KEY", "DB_URL"]);
    assert!(!format!("{names:?}").contains("secret"));
}
