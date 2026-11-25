use super::*;

fn with(class: Value) -> Value {
    json!({"_meta": {"acpmux": {"class": class}}})
}

#[test]
fn the_four_classes_are_accepted_and_nothing_else() {
    for class in PromptClass::ALL {
        assert_eq!(declared(&with(json!(class.as_str()))).unwrap(), Some(class));
        assert_eq!(serde_json::to_value(class).unwrap(), json!(class.as_str()));
    }
    assert_eq!(declared(&json!({})).unwrap(), None);
    assert_eq!(declared(&with(Value::Null)).unwrap(), None);
    for bad in [json!("Block"), json!("urgent"), json!(""), json!(" fyi"), json!(1)] {
        let err = declared(&with(bad.clone())).expect_err(&bad.to_string());
        assert_eq!(err.data.as_ref().unwrap()["reason"], "class.value_refused");
    }
}

#[test]
fn an_agent_message_with_no_class_is_a_result_and_the_person_has_none() {
    assert_eq!(of_message(None, true), Some(PromptClass::Result));
    assert_eq!(of_message(Some(PromptClass::Block), true), Some(PromptClass::Block));
    assert_eq!(of_message(Some(PromptClass::Question), false), None);
    assert_eq!(of_message(None, false), None);
}

#[test]
fn only_blocks_and_questions_are_urgent() {
    let urgent: Vec<_> = PromptClass::ALL.into_iter().filter(|c| c.urgent()).collect();
    assert_eq!(urgent, [PromptClass::Block, PromptClass::Question]);
    assert_eq!(recorded(&json!({"class": "fyi"})), Some(PromptClass::Fyi));
    assert_eq!(recorded(&json!({"class": "nope"})), None);
    assert_eq!(recorded(&json!({})), None);
}

#[test]
fn a_queued_record_from_before_classes_restores_an_agents_message_as_a_result() {
    let old = json!({"promptId": "p", "fromAgent": "lane-a"});
    assert_eq!(of_message(recorded(&old), true), Some(PromptClass::Result));
    assert_eq!(of_message(recorded(&old), false), None);
}
