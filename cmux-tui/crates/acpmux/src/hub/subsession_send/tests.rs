use super::*;

#[test]
fn a_child_waiting_on_the_user_says_what_for() {
    let waiting = |on: &str, prompt: Value| {
        json!({"lane": {"state": "input"}, "turn": {"prompt": "fix it"},
                   "waitingOn": on, "waitingPrompt": prompt})
    };
    assert_eq!(
        doing(&waiting("question", json!("Which branch?"))),
        "Waiting for the user to answer, in the app: Which branch?"
    );
    assert_eq!(
        doing(&waiting("permission", Value::Null)),
        "Waiting for the user to allow a tool, in the app"
    );
    let input = json!({"lane": {"state": "input"}, "turn": {"prompt": "fix it"}});
    assert_eq!(doing(&input), "Waiting for the user to answer it");
    let working = json!({"lane": {"state": "working"}, "turn": {"activity": "Run cargo test"}});
    assert_eq!(doing(&working), "Run cargo test");
    assert_eq!(doing(&json!({"lane": {"state": "idle"}, "turn": null})), Value::Null);
}
