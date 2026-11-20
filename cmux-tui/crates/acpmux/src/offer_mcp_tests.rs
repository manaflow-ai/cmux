use super::*;

#[test]
fn a_task_is_checked_as_the_daemon_checks_it() {
    let task = |title: &str| json!({"title": title, "prompt": "Do it."});
    assert_eq!(check_task(&task("Fix the flaky upload test")), Ok(()));
    assert_eq!(check_task(&task(&"é".repeat(MAX_TITLE_CHARS))), Ok(()));
    let long = check_task(&task(&"a".repeat(MAX_TITLE_CHARS + 1)));
    assert_eq!(long, Err("title must be 1 to 80 characters".to_owned()));
    assert!(check_task(&task("   ")).is_err());
    assert!(check_task(&json!({"title": "No prompt"})).is_err());
    assert!(check_task(&json!("Fix it")).is_err());
}

#[test]
fn both_titles_carry_the_limit_in_the_schema() {
    let tools = tools();
    let titles = [
        &tools[0]["inputSchema"]["properties"]["title"],
        &tools[1]["inputSchema"]["properties"]["tasks"]["items"]["properties"]["title"],
    ];
    for title in titles {
        assert_eq!(title["maxLength"], MAX_TITLE_CHARS, "{title}");
        assert_eq!(title["minLength"], 1, "{title}");
    }
}
