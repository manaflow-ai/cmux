use super::*;
use cmux_conversation::Participant;

/// The shared corpus case (home-core conversation-import-cases.json): the TypeScript core
/// decides which imported messages are agent turns, and the local import must agree.
#[test]
fn an_imported_agent_work_card_is_not_an_agent_turn_as_the_corpus_says() {
    let corpus: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../backend/packages/home-core/conformance/conversation-import-cases.json"
    ))
    .unwrap();
    let case = corpus["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "import: an imported agent work card is not an agent turn")
        .expect("the shared import case");
    let people: Vec<Participant> = serde_json::from_value(serde_json::json!([
        {"id":"user_me","kind":"human","display_name":"Me"},
        {"id":"agent_chief","kind":"agent","display_name":"Chief","agent_class":"mux"}
    ]))
    .unwrap();
    let messages: Vec<ImportedMessage> = case["params"]["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| ImportedMessage {
            id: None,
            client_msg_id: m["client_msg_id"].as_str().unwrap().to_string(),
            author: m["author"].as_str().unwrap().to_string(),
            parts: serde_json::from_value(m["parts"].clone()).unwrap(),
            created_at: cmux_conversation::format_rfc3339_millis(
                cmux_conversation::parse_rfc3339_millis(m["created_at"].as_str().unwrap()).unwrap(),
            ),
        })
        .collect();
    let mut store = ConversationStore::open(None).unwrap();
    let id = store.create("home-chief", "user_me", "Chief", &people).unwrap().summary.id;
    store.import(&id, &messages).unwrap();
    let head = load_head(&store.connection, &id).unwrap().unwrap();
    assert_eq!(
        u64::from(head.agent_text_streak),
        case["expect"]["head"]["agent_text_streak"].as_u64().unwrap()
    );
}
