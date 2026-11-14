use super::record_engine_env;
use crate::chief_registry::Engine;

#[test]
fn a_record_harness_becomes_the_brains_starting_harness() {
    let engine =
        Engine { harness: Some("unii".into()), model: None, effort: Some("default".into()) };
    assert_eq!(
        record_engine_env(&engine),
        vec![("OPTCHAT_CHIEF_HARNESS".to_owned(), "unii".to_owned())]
    );
    assert!(record_engine_env(&Engine::default()).is_empty());
    let full = Engine {
        harness: Some("codex".into()),
        model: Some("gpt-5.5".into()),
        effort: Some("high".into()),
    };
    assert_eq!(record_engine_env(&full).len(), 3);
}
