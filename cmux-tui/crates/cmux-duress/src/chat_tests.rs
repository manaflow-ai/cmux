use super::rename_ids;

#[test]
fn ids_get_the_suffix_and_nothing_else_moves() {
    let msg = r#"{"a":"id","toolCallId":"toolu_1","text":"say \"id\":\"x\"","_meta":{"segment":"turn.4"},"id":7}"#;
    assert_eq!(
        rename_ids(msg, "-d2"),
        r#"{"a":"id","toolCallId":"toolu_1-d2","text":"say \"id\":\"x\"","_meta":{"segment":"turn-d2.4"},"id":7}"#
    );
}
