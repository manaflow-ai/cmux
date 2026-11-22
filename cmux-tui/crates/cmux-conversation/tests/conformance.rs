//! Runs the shared conformance corpus of the cloud TypeScript reducer
//! (backend/packages/home-core, format `cmux-conversation-conformance/1`)
//! against this crate, so the local and cloud owners stay equal: the
//! local-head op cases (`conversation-cases.json`) and the search cases
//! (`conversation-search-cases.json`). The cloud cases need the cloud head
//! fields this owner does not have. A required part of the cmux-tui gate.

use cmux_conversation::{
    ConversationHead, CreateRequest, Message, Op, OpRequest, Participant, SearchInput,
    SearchSource, apply, check_agent_streak, create, parse_rfc3339_millis, search_conversations,
};
use serde::Deserialize;
use serde_json::{Value, json};

const CORPUS: &str =
    include_str!("../../../../backend/packages/home-core/conformance/conversation-cases.json");
const SEARCH_CORPUS: &str = include_str!(
    "../../../../backend/packages/home-core/conformance/conversation-search-cases.json"
);

#[derive(Deserialize)]
struct Corpus {
    format: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    head: Option<ConversationHead>,
    request: Option<Request>,
    create: Option<Create>,
    expect: Value,
}

#[derive(Deserialize)]
struct Request {
    actor: String,
    idempotency_key: String,
    op: Op,
    now: String,
    new_message_id: String,
    target: Option<Message>,
    reply_target: Option<Message>,
    last_message: Option<Message>,
}

#[derive(Deserialize)]
struct Create {
    id: String,
    actor: String,
    title: String,
    now: String,
    participants: Vec<Participant>,
}

fn reject(code: &str) -> Value {
    json!({ "reject": code })
}

fn run_op(head: &ConversationHead, request: &Request) -> Value {
    let op_request = OpRequest {
        actor: &request.actor,
        idempotency_key: &request.idempotency_key,
        op: &request.op,
        now: &request.now,
        new_message_id: &request.new_message_id,
        target: request.target.as_ref(),
        reply_target: request.reply_target.as_ref(),
        last_message: request.last_message.as_ref(),
    };
    let commit = match apply(head, &op_request) {
        Ok(commit) => commit,
        Err(error) => return reject(error.code()),
    };
    // The loop guard runs after every other rule passes, over the head's
    // counters (corpus notes), as the store does.
    if let Op::MessageSend { parts, .. } = &request.op {
        let now = parse_rfc3339_millis(&request.now).expect("corpus timestamps are well formed");
        if let Err(error) = check_agent_streak(head, &request.actor, parts, now) {
            return reject(error.code());
        }
    }
    let mut value = json!({
        "head": serde_json::to_value(&commit.head).unwrap(),
        "change": serde_json::to_value(&commit.change).unwrap(),
    });
    if let Some(message) = &commit.message {
        value["message"] = serde_json::to_value(message).unwrap();
    }
    json!({ "commit": value })
}

fn run_create(create_case: &Create) -> Value {
    let request = CreateRequest {
        id: &create_case.id,
        actor: &create_case.actor,
        title: &create_case.title,
        participants: &create_case.participants,
        now: &create_case.now,
    };
    match create(&request) {
        Ok(head) => json!({ "head": serde_json::to_value(&head).unwrap() }),
        Err(error) => reject(error.code()),
    }
}

#[test]
fn conversation_conformance_corpus_local_cases() {
    let corpus: Corpus = serde_json::from_str(CORPUS).expect("corpus parses");
    assert_eq!(corpus.format, "cmux-conversation-conformance/1");
    assert!(!corpus.cases.is_empty());
    let mut failures = Vec::new();
    for case in &corpus.cases {
        let actual = match (&case.create, &case.head, &case.request) {
            (Some(create_case), _, _) => run_create(create_case),
            (None, Some(head), Some(request)) => run_op(head, request),
            _ => panic!("case {} has neither create nor head and request", case.name),
        };
        if actual != case.expect {
            let line = format!("{}\n  expected {}\n  actual   {}", case.name, case.expect, actual);
            failures.push(line);
        }
    }
    let summary = format!("{} of {} cases differ", failures.len(), corpus.cases.len());
    assert!(failures.is_empty(), "{summary}:\n{}", failures.join("\n"));
}

#[derive(Deserialize)]
struct SearchCorpus {
    format: String,
    cases: Vec<SearchCase>,
}

#[derive(Deserialize)]
struct SearchCase {
    name: String,
    actor: String,
    input: SearchInput,
    sources: Vec<SearchSource>,
    expect: Value,
}

#[test]
fn conversation_conformance_corpus_search_cases() {
    let corpus: SearchCorpus = serde_json::from_str(SEARCH_CORPUS).expect("search corpus parses");
    assert_eq!(corpus.format, "cmux-conversation-search/1");
    assert!(!corpus.cases.is_empty());
    let mut failures = Vec::new();
    for case in &corpus.cases {
        let actual = match search_conversations(&case.actor, &case.input, &case.sources) {
            Ok(hits) => json!({ "hits": hits }),
            Err(error) => reject(error.code()),
        };
        if actual != case.expect {
            failures
                .push(format!("{}\n  expected {}\n  actual   {}", case.name, case.expect, actual));
        }
    }
    let summary = format!("{} of {} cases differ", failures.len(), corpus.cases.len());
    assert!(failures.is_empty(), "{summary}:\n{}", failures.join("\n"));
}
