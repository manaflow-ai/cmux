use super::*;

#[tokio::test]
async fn a_scope_names_its_own_values_and_leaves_the_rest_to_the_process() {
    let env = HashMap::from([("ACPMUX_TOOL_ENV_TEST".to_owned(), "chat".to_owned())]);
    let inside = scope(env, async { (var("ACPMUX_TOOL_ENV_TEST"), var("PATH")) }).await;
    assert_eq!(inside.0.as_deref(), Some("chat"));
    assert_eq!(inside.1, std::env::var("PATH").ok());
    assert_eq!(var("ACPMUX_TOOL_ENV_TEST"), None, "outside the scope: the process env");
}
