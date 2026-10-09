use super::*;

#[test]
fn model_label_drops_date_stamps() {
    assert_eq!(model_label("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
    assert_eq!(model_label("gpt-6-astra"), "gpt-6-astra");
    assert_eq!(model_label("subrouter/gpt-6-astra"), "subrouter/gpt-6-astra");
    assert_eq!(model_label("20251001"), "20251001");
}
