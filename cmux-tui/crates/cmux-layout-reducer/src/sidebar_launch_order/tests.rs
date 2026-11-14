use super::*;

fn keys(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[test]
fn a_reordered_pass_keeps_the_order_drawn_at_launch() {
    let (order, reference) = hold(&keys("a b c d"), &keys("d c b a"));
    assert_eq!(order, keys("a b c d"));
    assert_eq!(reference, keys("a b c d"));
}

#[test]
fn a_new_row_goes_after_the_row_it_follows_in_the_new_order() {
    // `x` follows `c` in the pass, `y` leads it: neither moves a drawn row.
    let (order, reference) = hold(&keys("a b c d"), &keys("y d c x b a"));
    assert_eq!(order, keys("y a b c x d"));
    assert_eq!(reference, keys("y a b c x d"));
}

#[test]
fn a_partial_then_full_delivery_puts_every_row_back_where_it_was() {
    // The owner first lists some rows (in another order), then the rest.
    let launch = keys("a b c d e");
    let (partial, reference) = hold(&launch, &keys("e c a"));
    assert_eq!(partial, keys("a c e"));
    assert_eq!(reference, launch, "a row that left is remembered");
    let (full, reference) = hold(&reference, &keys("e d c b a"));
    assert_eq!(full, launch);
    assert_eq!(reference, launch);
}

#[test]
fn with_nothing_drawn_the_pass_order_shows() {
    let (order, reference) = hold(&[], &keys("c a b"));
    assert_eq!(order, keys("c a b"));
    assert_eq!(reference, keys("c a b"));
}

#[test]
fn a_key_listed_twice_is_answered_as_it_is() {
    let (order, _) = hold(&keys("a b"), &keys("b a b"));
    assert_eq!(order, keys("b a b"));
}

#[test]
fn ending_the_hold_moves_only_the_rows_whose_place_changed() {
    assert_eq!(moved(&keys("a b c d e"), &keys("a c d e b")), keys("b"));
    assert!(moved(&keys("a b c"), &keys("a x b c")).is_empty(), "an insert is no move");
    assert!(moved(&keys("a b c"), &keys("a c")).is_empty(), "a removal is no move");
    assert_eq!(moved(&keys("a b c"), &keys("c b a")).len(), 2);
}

#[test]
fn the_request_answers_every_list() {
    let request: Request = serde_json::from_str(
        r#"{"hold":true,"lists":[{"key":"s","reference":["a","b"],"next":["b","a","c"]},
                                    {"key":"g","next":["x"]}]}"#,
    )
    .expect("request");
    let reply = respond(&request);
    assert_eq!(reply.lists[0].order, keys("a c b"));
    assert_eq!(reply.lists[1].order, keys("x"));
    let release: Request = serde_json::from_str(
        r#"{"lists":[{"key":"s","reference":["a","b","c"],"next":["b","a","c"]}]}"#,
    )
    .expect("request");
    let reply = respond(&release);
    assert_eq!(reply.lists[0].order, keys("b a c"));
    assert_eq!(reply.lists[0].moved.len(), 1);
    assert!(reply.lists[0].reference.is_empty());
}

#[test]
fn a_remembered_row_that_returns_at_release_is_an_insert_not_a_move() {
    // Launch drew `a b c`, a pass listed only `a`, and the release lists `b c a`: `b` and
    // `c` open their slots; `a` keeps its place among the drawn rows.
    let request = Request {
        hold: false,
        lists: vec![List {
            key: "rows".into(),
            reference: keys("a b c"),
            drawn: keys("a"),
            next: keys("b c a"),
        }],
    };
    assert_eq!(respond(&request).lists[0].moved, Vec::<String>::new());
}
