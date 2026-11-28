use super::*;

fn params(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn an_add_takes_a_session_an_absolute_path_and_the_macs_path() {
    let add = parse(&params(
        json!({"session": "chat-1", "path": "/root/work/local/x-1/", "from": "~/x"}),
    ));
    assert_eq!(
        add,
        Ok(Add {
            session: "chat-1".into(),
            path: "/root/work/local/x-1".into(),
            from: Some("~/x".into())
        })
    );
}

#[test]
fn an_add_refuses_relative_dotted_and_extra_params() {
    for bad in [
        json!({"session": "chat-1", "path": "work/x"}),
        json!({"session": "chat-1", "path": "/root/../etc"}),
        json!({"session": "chat-1", "path": "/"}),
        json!({"session": "chat 1", "path": "/root/x"}),
        json!({"session": "chat-1", "path": "/root/x", "cwd": "/"}),
        json!({"session": "chat-1", "path": "/root/x", "from": "relative"}),
        json!({"path": "/root/x"}),
    ] {
        assert_eq!(parse(&params(bad.clone())), Err(Refusal::BadRequest), "{bad}");
    }
}

#[test]
fn a_folder_goes_at_the_end_once() {
    let current = json!(["/a", "/b"]);
    assert_eq!(with_folder(&current, "/c"), Ok(Some(vec!["/a".into(), "/b".into(), "/c".into()])));
    assert_eq!(with_folder(&current, "/b"), Ok(None));
    assert_eq!(with_folder(&Value::Null, "/c"), Ok(Some(vec!["/c".into()])));
}

#[test]
fn a_chat_with_64_folders_takes_no_more() {
    let full: Vec<String> = (0..MAX_DIRS).map(|n| format!("/d{n}")).collect();
    assert_eq!(with_folder(&json!(full), "/new"), Err(Refusal::TooMany));
}
