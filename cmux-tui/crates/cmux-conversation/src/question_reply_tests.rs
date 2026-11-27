use super::*;
use crate::{QuestionAnswer, QuestionHarness, QuestionItem, QuestionOption};

fn identity() -> QuestionIdentity {
    QuestionIdentity { request_id: "request-1".into(), question_id: "question-1".into() }
}

fn item(id: &str, prompt: &str, labels: &[&str]) -> QuestionItem {
    QuestionItem {
        id: id.into(),
        header: None,
        prompt: prompt.into(),
        options: labels
            .iter()
            .enumerate()
            .map(|(index, label)| QuestionOption {
                id: format!("{id}-option-{index}"),
                label: (*label).into(),
                detail: None,
                preview: None,
            })
            .collect(),
        multi_select: false,
        allows_other: true,
    }
}

fn question() -> Question {
    Question {
        harness: QuestionHarness::Chief,
        session: "session-1".into(),
        permission: Some("permission-1".into()),
        agent: Some("Chief".into()),
        items: vec![item("color", "Which color?", &["Red", "Blue"])],
        state: QuestionState::Pending,
    }
}

fn prompt(question: Question) -> QuestionReplyPrompt {
    QuestionReplyPrompt::new(identity(), "thread-1".into(), question).unwrap()
}

fn resolve(prompt: &QuestionReplyPrompt, text: &str) -> Result<ResolvedChoice, ReplyError> {
    prompt.resolve(
        prompt.identity(),
        Some(prompt.question()),
        "thread-1",
        QuestionReply::Text(text),
    )
}

#[test]
fn renders_stable_global_numbers_and_normalizes_multiline_labels() {
    let mut question = question();
    question.items.push(item("size", "Which size?", &["Small\n  size", "Large"]));
    question.items[0].options[0].detail = Some("Warm\n tone".into());
    let prompt = prompt(question);
    let expected = "Question: Which color?\n1. Red\n   Warm tone\n2. Blue\n\n\
        Question: Which size?\n3. Small size\n4. Large\n\n\
        Reply with an option number or its exact text.";
    assert_eq!(prompt.render(), expected);
    assert_eq!(prompt.render(), expected);
    let choice = resolve(&prompt, "3").unwrap();
    assert_eq!(choice.item_id, "size");
    assert_eq!(choice.selection.option_ids, ["size-option-0"]);
    assert_eq!(resolve(&prompt, "Small size"), Ok(choice));
}

#[test]
fn number_and_text_preserve_original_identifiers_without_authorizing() {
    let prompt = prompt(question());
    let expected = ResolvedChoice {
        identity: identity(),
        session: "session-1".into(),
        permission: Some("permission-1".into()),
        item_id: "color".into(),
        selection: QuestionSelection { option_ids: vec!["color-option-1".into()], other: None },
        completes_question: true,
    };
    for text in ["2", " Blue ", "blue", "BLUE"] {
        assert_eq!(resolve(&prompt, text), Ok(expected.clone()));
    }
    assert_eq!(prompt.question().state, QuestionState::Pending);
}

#[test]
fn all_rendered_numbers_round_trip_for_multiple_items_and_harnesses() {
    for harness in [
        QuestionHarness::Chief,
        QuestionHarness::Claude,
        QuestionHarness::Codex,
        QuestionHarness::Acp,
    ] {
        let mut question = question();
        question.harness = harness;
        question.items.push(item("size", "Which size?", &["Small", "Large"]));
        question.items[1].multi_select = true;
        let prompt = prompt(question);
        for (index, (item, option)) in prompt
            .question()
            .items
            .iter()
            .flat_map(|item| item.options.iter().map(move |option| (item, option)))
            .enumerate()
        {
            let choice = resolve(&prompt, &(index + 1).to_string()).unwrap();
            assert_eq!(choice.item_id, item.id);
            assert_eq!(choice.selection.option_ids.as_slice(), std::slice::from_ref(&option.id));
            assert!(!choice.completes_question);
        }
    }
}

#[test]
fn duplicate_text_never_chooses_the_first_match() {
    let mut question = question();
    question.items.push(item("other", "Another color?", &[" red "]));
    let prompt = prompt(question);
    assert_eq!(resolve(&prompt, "Red"), Err(ReplyError::Ambiguous));
    assert_eq!(resolve(&prompt, "RED"), Err(ReplyError::Ambiguous));
    assert_eq!(resolve(&prompt, "3").unwrap().item_id, "other");
}

#[test]
fn numeric_labels_cannot_silently_override_rendered_numbers() {
    let mut question = question();
    question.items[0].options[0].label = "2".into();
    let prompt = prompt(question);
    assert_eq!(resolve(&prompt, "2"), Err(ReplyError::Ambiguous));
    assert_eq!(resolve(&prompt, "1").unwrap().selection.option_ids, ["color-option-0"]);
}

#[test]
fn number_matching_its_own_label_is_one_choice() {
    let mut question = question();
    question.items[0].options[1].label = "2".into();
    assert_eq!(resolve(&prompt(question), "2").unwrap().selection.option_ids, ["color-option-1"]);
}

#[test]
fn unmatched_text_never_guesses_an_approval_or_other_answer() {
    let prompt = prompt(question());
    for text in [
        "",
        " ",
        "0",
        "3",
        "-1",
        "+1",
        "1,2",
        "Blue please",
        "allow",
        "yes",
        "👍",
        "color-option-0",
        "999999999999999999999999999999999",
    ] {
        assert_eq!(resolve(&prompt, text), Err(ReplyError::NoMatch), "{text}");
    }
}

#[test]
fn a_literal_allow_option_is_only_a_selection_and_does_not_change_state() {
    let mut question = question();
    question.items[0].options[0].label = "Allow".into();
    let prompt = prompt(question);
    assert_eq!(resolve(&prompt, "allow").unwrap().selection.option_ids, ["color-option-0"]);
    assert_eq!(prompt.question().state, QuestionState::Pending);
    assert_eq!(resolve(&prompt, "yes"), Err(ReplyError::NoMatch));
}

#[test]
fn changed_closed_missing_or_replaced_questions_are_stale() {
    let original = question();
    let prompt = prompt(original.clone());
    let mut variants = Vec::new();
    let mut changed = original.clone();
    changed.items[0].options.swap(0, 1);
    variants.push(changed);
    let mut changed = original.clone();
    changed.items[0].prompt = "Replaced prompt?".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.session = "another-session".into();
    variants.push(changed);
    let mut changed = original.clone();
    changed.permission = Some("another-permission".into());
    variants.push(changed);
    let mut changed = original.clone();
    changed.state = QuestionState::Cancelled;
    variants.push(changed);
    let mut changed = original;
    changed.state = QuestionState::Answered {
        answer: QuestionAnswer {
            selections: Default::default(),
            respondent: None,
            answered_at: None,
        },
    };
    variants.push(changed);
    for changed in &variants {
        assert_eq!(
            prompt.resolve(&identity(), Some(changed), "thread-1", QuestionReply::Text("1")),
            Err(ReplyError::Stale)
        );
    }
    assert_eq!(
        prompt.resolve(&identity(), None, "thread-1", QuestionReply::Text("1")),
        Err(ReplyError::Stale)
    );
    for id in [
        QuestionIdentity { request_id: "new-request".into(), ..identity() },
        QuestionIdentity { question_id: "new-question".into(), ..identity() },
    ] {
        assert_eq!(
            prompt.resolve(&id, Some(prompt.question()), "thread-1", QuestionReply::Text("1")),
            Err(ReplyError::Stale)
        );
    }
}

#[test]
fn reply_requires_the_exact_thread_even_with_a_valid_choice() {
    let prompt = prompt(question());
    for thread in ["thread-2", "", " thread-1"] {
        assert_eq!(
            prompt.resolve(&identity(), Some(prompt.question()), thread, QuestionReply::Text("1")),
            Err(ReplyError::WrongThread)
        );
    }
}

#[test]
fn tapback_requires_an_explicit_target_and_reaction_binding() {
    let prompt = prompt(question());
    let reaction = QuestionReply::Tapback { message_id: "message-1", reaction: Tapback::Like };
    assert_eq!(
        prompt.resolve(&identity(), Some(prompt.question()), "thread-1", reaction),
        Err(ReplyError::UnboundTapback)
    );
    // Like explicitly selects the SECOND choice; it never means "yes" by itself.
    let prompt = prompt.with_tapback("message-1".into(), Tapback::Like, 2).unwrap();
    assert_eq!(
        prompt.resolve(&identity(), Some(prompt.question()), "thread-1", reaction),
        resolve(&prompt, "2")
    );
    for reply in [
        QuestionReply::Tapback { message_id: "message-2", reaction: Tapback::Like },
        QuestionReply::Tapback { message_id: "message-1", reaction: Tapback::Dislike },
    ] {
        assert_eq!(
            prompt.resolve(&identity(), Some(prompt.question()), "thread-1", reply),
            Err(ReplyError::UnboundTapback)
        );
    }
    assert_eq!(
        prompt.resolve(&identity(), Some(prompt.question()), "thread-2", reaction),
        Err(ReplyError::WrongThread)
    );
    assert_eq!(prompt.resolve(&identity(), None, "thread-1", reaction), Err(ReplyError::Stale));
}

#[test]
fn conflicting_and_invalid_tapback_bindings_fail() {
    let prompt = prompt(question()).with_tapback("message-1".into(), Tapback::Like, 1).unwrap();
    assert!(prompt.clone().with_tapback("message-1".into(), Tapback::Like, 1).is_ok());
    assert_eq!(
        prompt.clone().with_tapback("message-1".into(), Tapback::Like, 2).unwrap_err(),
        ReplyError::Ambiguous
    );
    for (message, number) in [("", 1), ("message-1", 0), ("message-1", 3)] {
        assert_eq!(
            prompt.clone().with_tapback(message.into(), Tapback::Like, number).unwrap_err(),
            ReplyError::InvalidBinding
        );
    }
}

#[test]
fn malformed_or_already_closed_questions_cannot_be_offered() {
    let mut invalid = question();
    invalid.items[0].options[1].id = invalid.items[0].options[0].id.clone();
    assert_eq!(
        QuestionReplyPrompt::new(identity(), "thread-1".into(), invalid).unwrap_err(),
        ReplyError::InvalidQuestion
    );
    let mut closed = question();
    closed.state = QuestionState::Cancelled;
    assert_eq!(
        QuestionReplyPrompt::new(identity(), "thread-1".into(), closed).unwrap_err(),
        ReplyError::Stale
    );
    assert_eq!(
        QuestionReplyPrompt::new(identity(), " ".into(), question()).unwrap_err(),
        ReplyError::InvalidQuestion
    );
}

#[test]
fn a_free_text_question_is_not_reinterpreted_as_numbered_choices() {
    let mut question = question();
    question.items[0].options.clear();
    let prompt = prompt(question);
    assert_eq!(prompt.render(), "Question: Which color?");
    assert_eq!(resolve(&prompt, "1"), Err(ReplyError::NoMatch));
    assert_eq!(resolve(&prompt, "a new color"), Err(ReplyError::NoMatch));
}

#[test]
fn flexible_numbers_and_unique_prefixes_keep_original_choices() {
    let prompt = prompt(question());
    for text in ["1.", "#1", "01", "#01.", "RE"] {
        assert_eq!(resolve(&prompt, text), resolve(&prompt, "1"), "{text}");
    }
    for text in ["000", "#", "1..", "#3", "r"] {
        assert_eq!(resolve(&prompt, text), Err(ReplyError::NoMatch), "{text}");
    }
    let mut q = question();
    q.items[0].options[1].label = "Reddish".into();
    let prompt = QuestionReplyPrompt::new(identity(), "thread-1".into(), q).unwrap();
    assert_eq!(resolve(&prompt, "re"), Err(ReplyError::Ambiguous));
    assert_eq!(resolve(&prompt, "Red").unwrap().selection.option_ids, ["color-option-0"]);
}

#[test]
fn single_character_prefixes_do_not_match_even_when_unicode_fold_expands() {
    let mut q = question();
    q.items[0].options[0].label = "ßeta".into();
    q.items[0].options[1].label = "R".into();
    let prompt = prompt(q);
    assert_eq!(resolve(&prompt, "ß"), Err(ReplyError::NoMatch));
    assert_eq!(resolve(&prompt, "ße"), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, "R"), resolve(&prompt, "2"));
}

#[test]
fn markdown_label_and_detail_cannot_inject_numbered_rows() {
    let mut q = question();
    q.items[0].options[0].label = "Red\n\n2\\. Cancel".into();
    q.items[0].options[0].detail = Some("Detail\n\n3\\. Allow".into());
    let prompt = prompt(q);
    assert_eq!(
        prompt.render(),
        "Question: Which color?\n1. Red 2. Cancel\n   Detail 3. Allow\n2. Blue\n\nReply with an option number or its exact text."
    );
    assert_eq!(resolve(&prompt, "Red 2. Cancel"), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, "2").unwrap().selection.option_ids, ["color-option-1"]);
}

#[test]
fn second_item_prompt_cannot_impersonate_a_numbered_choice() {
    let mut q = question();
    q.items.push(item("size", "1\\. Cancel\n\n2\\. Allow", &["Small", "Large"]));
    let prompt = prompt(q);
    assert_eq!(
        prompt.render(),
        "Question: Which color?\n1. Red\n2. Blue\n\nQuestion: 1. Cancel 2. Allow\n3. Small\n4. Large\n\nReply with an option number or its exact text."
    );
    assert_eq!(resolve(&prompt, "3").unwrap().selection.option_ids, ["size-option-0"]);
}

#[test]
fn literal_backslash_before_digit_cannot_inject_label_or_second_prompt_rows() {
    let mut q = question();
    q.items[0].options[0].label = "Red\n\n\\2. Cancel".into();
    q.items.push(item("size", "Size?\n\n\\2. Cancel", &["Small", "Large"]));
    let prompt = prompt(q);
    // CommonMark preserves a backslash before a digit (unlike escaped dots).
    // Both exact reported payloads must still stay inside their original row.
    assert_eq!(
        prompt.render(),
        "Question: Which color?\n1. Red \\2. Cancel\n2. Blue\n\nQuestion: Size? \\2. Cancel\n3. Small\n4. Large\n\nReply with an option number or its exact text."
    );
    assert_eq!(resolve(&prompt, "Red \\2. Cancel"), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, "2").unwrap().selection.option_ids, ["color-option-1"]);
    assert_eq!(resolve(&prompt, "3").unwrap().selection.option_ids, ["size-option-0"]);
}

#[test]
fn unicode_case_folding_handles_expansions_and_detects_collisions() {
    let mut q = question();
    q.items[0].options[0].label = "Straße".into();
    q.items[0].options[1].label = "ΟΣ".into();
    let prompt = prompt(q.clone());
    assert_eq!(resolve(&prompt, "STRASSE"), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, "ος"), resolve(&prompt, "2"));
    assert_eq!(resolve(&prompt, "STRASS"), resolve(&prompt, "1"));
    q.items[0].options[1].label = "STRASSE".into();
    assert_eq!(
        resolve(&QuestionReplyPrompt::new(identity(), "thread-1".into(), q).unwrap(), "straße"),
        Err(ReplyError::Ambiguous)
    );
}

#[test]
fn yes_no_need_explicit_permission_aliases_not_labels_or_prefixes() {
    let mut q = question();
    q.items[0].options[0].label = "Yes today".into();
    q.items[0].options[1].label = "No tomorrow".into();
    let prompt = prompt(q);
    assert_eq!(resolve(&prompt, "yes"), Err(ReplyError::NoMatch));
    assert_eq!(resolve(&prompt, "no"), Err(ReplyError::NoMatch));
    let prompt = prompt.with_permission_aliases(1, 2).unwrap();
    assert_eq!(resolve(&prompt, "YES"), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, "no"), resolve(&prompt, "2"));
    assert_eq!(prompt.question().state, QuestionState::Pending);
    let mut q = question();
    q.items[0].multi_select = true;
    assert_eq!(
        QuestionReplyPrompt::new(identity(), "thread-1".into(), q)
            .unwrap()
            .with_permission_aliases(1, 2)
            .unwrap_err(),
        ReplyError::InvalidBinding
    );
}

#[test]
fn oversized_input_is_rejected_before_matching_and_boundary_is_accepted() {
    let prompt = prompt(question());
    let text = format!("1{}", " ".repeat(MAX_REPLY_BYTES - 1));
    assert_eq!(resolve(&prompt, &text), resolve(&prompt, "1"));
    assert_eq!(resolve(&prompt, &(text + " ")), Err(ReplyError::InputTooLong));
}

#[test]
fn markdown_options_match_the_plain_label_the_person_sees() {
    let mut q = question();
    q.items[0].options[0].label = "**Red**".into();
    let prompt = prompt(q);
    assert!(prompt.render().contains("1. Red"));
    assert_eq!(resolve(&prompt, "Red"), resolve(&prompt, "1"));
    let mut q = question();
    q.items[0].options[0].label = "---".into();
    let hidden_label = QuestionReplyPrompt::new(identity(), "thread-1".into(), q).unwrap();
    assert_eq!(resolve(&hidden_label, ""), Err(ReplyError::NoMatch));
}

fn observed() -> ObservedReply<'static> {
    ObservedReply {
        thread: "thread-1",
        reply: QuestionReply::Text("1"),
        now_ms: 150,
        window: ReplyWindow { offered_at_ms: 100, expires_at_ms: 200 },
        envelope: ReplyEnvelope {
            is_from_me: false,
            confirmed_self_thread: false,
            emitted_by_chief: false,
            sent_at_ms: Some(140),
            associated_message_type: None,
        },
    }
}

#[test]
fn connector_observations_reject_echoes_but_accept_confirmed_self_thread() {
    let prompt = prompt(question());
    let check = |event| prompt.resolve_observed(&identity(), Some(prompt.question()), event);
    assert_eq!(check(observed()), resolve(&prompt, "1"));
    let mut event = observed();
    event.envelope.is_from_me = true;
    assert_eq!(check(event), Err(ReplyError::Echo));
    event.envelope.confirmed_self_thread = true;
    assert_eq!(check(event), resolve(&prompt, "1"));
    event.envelope.emitted_by_chief = true;
    assert_eq!(check(event), Err(ReplyError::Echo));
}

#[test]
fn connector_observations_reject_missing_old_future_and_expired_times() {
    let prompt = prompt(question());
    let check = |event| prompt.resolve_observed(&identity(), Some(prompt.question()), event);
    for sent in [None, Some(99), Some(151)] {
        let mut event = observed();
        event.envelope.sent_at_ms = sent;
        assert_eq!(check(event), Err(ReplyError::Stale));
    }
    let mut event = observed();
    event.now_ms = 200;
    assert_eq!(check(event), Err(ReplyError::Stale));
    event = observed();
    event.window.expires_at_ms = event.window.offered_at_ms;
    assert_eq!(check(event), Err(ReplyError::Stale));
}

#[test]
fn connector_tapback_removals_and_summary_text_never_become_choices() {
    let prompt = prompt(question()).with_tapback("sent-message".into(), Tapback::Like, 1).unwrap();
    let check = |event| prompt.resolve_observed(&identity(), Some(prompt.question()), event);
    let mut event = observed();
    event.reply = QuestionReply::Tapback { message_id: "sent-message", reaction: Tapback::Like };
    event.envelope.associated_message_type = Some(2001);
    assert_eq!(check(event), resolve(&prompt, "1"));
    for removal in [3000, 3001, 3005, 4000] {
        event.envelope.associated_message_type = Some(removal);
        assert_eq!(check(event), Err(ReplyError::RemovedTapback));
    }
    event = observed();
    event.envelope.associated_message_type = Some(2001);
    assert_eq!(check(event), Err(ReplyError::UnboundTapback));
}
