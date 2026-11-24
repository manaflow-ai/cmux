use super::*;

#[test]
fn a_sender_shows_its_app_and_persona_and_keeps_its_routing_name() {
    let sender = AgentSender::new("grok-bot.ada", Some("question"), None)
        .unwrap()
        .with_display("Grok bot", Some("Ada"));
    assert_eq!(sender.labelled("hi"), "[from Grok bot › Ada] hi");
    assert_eq!(sender.unlabelled("[from Grok bot › Ada] hi"), "hi");
    assert!(sender.client_msg_id("n1").starts_with("agent~grok-bot.ada~question~"));
    assert_eq!(display_of("Grok bot > Ada"), Some(("Grok bot".into(), Some("Ada".into()))));
    assert_eq!(display_of(" Muse "), Some(("Muse".into(), None)));
    assert_eq!(display_label("Dot]\n[x", None).as_deref(), Some("Dot x"));
    assert_eq!(display_of("  "), None);
}

#[test]
fn a_marked_id_names_its_sender_class_and_thread() {
    let sender = AgentSender::new("claude-sr2-coord", Some("question"), Some("pr:123")).unwrap();
    let id = sender.client_msg_id("0123456789abcdef0123");
    assert_eq!(id, "agent~claude-sr2-coord~question~pr:123~0123456789abcdef");
    assert!(crate::valid_token(&id));
    assert_eq!(of_client_msg_id(&id), Some(sender));
}

#[test]
fn an_unmarked_id_is_no_agent() {
    assert_eq!(of_client_msg_id("cli-0123"), None);
    assert_eq!(of_client_msg_id("send-1"), None);
    assert_eq!(of_client_msg_id("agent~~result~~x"), None);
}

#[test]
fn names_and_threads_are_cleaned_and_the_class_defaults_to_result() {
    let long = "x".repeat(200);
    let sender = AgentSender::new(&format!(" lane a~{long}"), Some("urgent"), Some("t 1")).unwrap();
    assert_eq!(sender.name.len(), MAX_NAME);
    assert!(sender.name.starts_with("lane-a-"));
    assert_eq!(sender.class, "result");
    assert_eq!(sender.thread.as_deref(), Some("t-1"));
    let id = sender.client_msg_id(&"f".repeat(64));
    assert!(id.len() <= 128 && crate::valid_token(&id), "{id}");
    assert_eq!(of_client_msg_id(&id), Some(sender));
}

#[test]
fn the_label_round_trips() {
    let sender = AgentSender::new("lane-a", None, None).unwrap();
    let shown = sender.labelled("rebase when free");
    assert_eq!(shown, "[from lane-a] rebase when free");
    assert_eq!(sender.unlabelled(&shown), "rebase when free");
    assert_eq!(sender.unlabelled("plain"), "plain");
}
