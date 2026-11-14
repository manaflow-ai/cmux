use super::*;

#[test]
fn the_first_creation_in_a_scope_takes_the_id_once_and_the_scope_restores() {
    assert_eq!(take(), None);
    scoped(Some("tab_a"), || {
        let mut fields = Map::new();
        insert_field(&mut fields);
        assert_eq!(fields.get(FIELD).and_then(Value::as_str), Some("tab_a"));
        let mut second = Map::new();
        insert_field(&mut second);
        assert!(second.get(FIELD).is_none(), "a second creation reused the id");
    });
    scoped(Some("tab_outer"), || {
        scoped(Some("tab_inner"), || assert_eq!(take().as_deref(), Some("tab_inner")));
        assert_eq!(take().as_deref(), Some("tab_outer"));
    });
    assert_eq!(take(), None);
}
