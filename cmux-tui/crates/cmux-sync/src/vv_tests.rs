use super::*;

#[test]
fn join_is_the_pointwise_max_and_dominates_after() {
    let mut a = Vv::from([("a", 3), ("b", 1)]);
    let b = Vv::from([("b", 4), ("c", 2)]);
    assert_eq!(a.partial_cmp_vv(&b), None);
    a.join(&b);
    assert_eq!(a, Vv::from([("a", 3), ("b", 4), ("c", 2)]));
    assert_eq!(a.partial_cmp_vv(&b), Some(Ordering::Greater));
}

#[test]
fn meet_keeps_only_what_everyone_covers() {
    let all =
        [Vv::from([("a", 3), ("b", 5)]), Vv::from([("a", 2)]), Vv::from([("a", 9), ("b", 1)])];
    assert_eq!(Vv::meet(&all), Vv::from([("a", 2)]));
    assert_eq!(Vv::meet(&[]), Vv::new());
}

#[test]
fn it_serializes_as_a_plain_object() {
    let vv = Vv::from([("mac:1", 3)]);
    assert_eq!(serde_json::to_string(&vv).unwrap(), r#"{"mac:1":3}"#);
}
