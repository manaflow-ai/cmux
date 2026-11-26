//! `when` clauses: the parser and printer the app used to run in Swift (`WhenClauseParser`,
//! `WhenClause+Text`), case for case, and the JSON the app decodes.

use cmux_action_catalog::when_clause::{
    ContextValue as V, ParseError, WhenClause as W, from_json, parse, parse_double, swift_double,
    text, to_json,
};

fn has(key: &str) -> W {
    W::Has(key.into())
}

fn not(clause: W) -> W {
    W::Not(Box::new(clause))
}

fn s(text: &str) -> V {
    V::String(text.into())
}

fn err(message: &'static str, offset: usize) -> Result<W, ParseError> {
    Err(ParseError { message, offset })
}

#[test]
fn parses_every_operator() {
    assert_eq!(parse("terminalFocused"), Ok(has("terminalFocused")));
    assert_eq!(parse("true"), Ok(W::Constant(true)));
    assert_eq!(parse(" false "), Ok(W::Constant(false)));
    assert_eq!(parse("trueish"), Ok(has("trueish")));
    assert_eq!(parse("!a"), Ok(not(has("a"))));
    assert_eq!(parse("!!a"), Ok(not(not(has("a")))));
    assert_eq!(parse("a && b || c"), Ok(W::Or(vec![W::And(vec![has("a"), has("b")]), has("c")])));
    assert_eq!(parse("a || b && c"), Ok(W::Or(vec![has("a"), W::And(vec![has("b"), has("c")])])));
    assert_eq!(parse("a && (b || c)"), Ok(W::And(vec![has("a"), W::Or(vec![has("b"), has("c")])])));
    assert_eq!(parse("keyMode == 'pane'"), Ok(W::Equals("keyMode".into(), s("pane"))));
    assert_eq!(parse("k == \"it's\""), Ok(W::Equals("k".into(), s("it's"))));
    assert_eq!(parse("k == ''"), Ok(W::Equals("k".into(), s(""))));
    assert_eq!(parse("k != pane"), Ok(W::NotEquals("k".into(), s("pane"))));
    assert_eq!(parse("k==true"), Ok(W::Equals("k".into(), V::Bool(true))));
    assert_eq!(parse("k == 'true'"), Ok(W::Equals("k".into(), s("true"))));
    assert_eq!(parse("k == 3"), Ok(W::Equals("k".into(), V::Number(3.0))));
    assert_eq!(parse("k == -2.5"), Ok(W::Equals("k".into(), V::Number(-2.5))));
    assert_eq!(parse("k == 1e3"), Ok(W::Equals("k".into(), V::Number(1000.0))));
    assert_eq!(parse("k == 0x10"), Ok(W::Equals("k".into(), V::Number(16.0))));
    assert_eq!(parse("k == a/b@c+d#e"), Ok(W::Equals("k".into(), s("a/b@c+d#e"))));
    assert_eq!(parse("k =~ /^a\\/b$/"), Ok(W::Matches("k".into(), "^a\\/b$".into())));
    assert_eq!(parse("k =~ /Foo/i"), Ok(W::Matches("k".into(), "(?i)Foo".into())));
    assert_eq!(parse("k in list"), Ok(W::IsIn("k".into(), "list".into())));
    assert_eq!(parse("k not in list"), Ok(not(W::IsIn("k".into(), "list".into()))));
    assert_eq!(parse("k inbox"), err("unexpected text", 2));
    assert_eq!(parse("k notable"), err("unexpected text", 2));
    assert_eq!(parse("a:b.c_d-e"), Ok(has("a:b.c_d-e")));
    assert_eq!(parse("\ta\t&&\tb"), Ok(W::And(vec![has("a"), has("b")])));
    // A lone `!` is no operator (Swift looked one byte past it).
    assert_eq!(parse("!"), err("expected a context key", 0));
    assert_eq!(parse("a != b"), Ok(W::NotEquals("a".into(), s("b"))));
}

#[test]
fn errors_name_the_offset() {
    assert_eq!(parse(""), err("expected a context key", 0));
    assert_eq!(parse("(a"), err("expected )", 2));
    assert_eq!(parse("a &&"), err("expected a context key", 4));
    assert_eq!(parse("a b"), err("unexpected text", 2));
    assert_eq!(parse("k =="), err("expected a value", 4));
    assert_eq!(parse("k == )"), err("expected a value", 5));
    assert_eq!(parse("k == 'open"), err("unterminated string", 10));
    assert_eq!(parse("k =~ x"), err("expected /regex/", 5));
    assert_eq!(parse("k =~ /open"), err("unterminated /regex/", 10));
    assert_eq!(parse("k in"), err("expected a context key", 4));
    assert_eq!(parse("é"), err("expected a context key", 0));
    assert_eq!(parse("k == 'é' x"), err("unexpected text", 10));
}

#[test]
fn prints_text_that_parses_back() {
    let cases = [
        ("a", "a"),
        ("!a", "!a"),
        ("!(a && b)", "!(a && b)"),
        ("!(a || b)", "!(a || b)"),
        ("!(k == 1)", "!(k == 1)"),
        ("!(k in l)", "k not in l"),
        ("!(k not in l)", "!(k not in l)"),
        ("!!a", "!!a"),
        ("!true", "!true"),
        ("k not in l", "k not in l"),
        ("a && (b || c)", "a && (b || c)"),
        ("(a && b) || c", "a && b || c"),
        ("k == pane", "k == pane"),
        ("k == 'pane'", "k == pane"),
        ("k == 'two words'", "k == 'two words'"),
        ("k == \"it's\"", "k == \"it's\""),
        ("k == ''", "k == ''"),
        ("k == 'true'", "k == 'true'"),
        ("k == '3'", "k == '3'"),
        ("k == 'inf'", "k == 'inf'"),
        ("k == true", "k == true"),
        ("k == 3.0", "k == 3"),
        ("k == -2.5", "k == -2.5"),
        ("k == 0.00001", "k == 1e-05"),
        ("k == 1e15", "k == 1000000000000000.0"),
        ("k == 1e20", "k == 1e+20"),
        ("k == inf", "k == inf"),
        ("k != x", "k != x"),
        ("k =~ /a.b/", "k =~ /a.b/"),
        ("k =~ /a.b/i", "k =~ /a.b/i"),
        ("k in l", "k in l"),
    ];
    for (input, expected) in cases {
        let clause = parse(input).unwrap_or_else(|e| panic!("{input}: {e:?}"));
        assert_eq!(text(&clause), expected, "{input}");
        assert_eq!(parse(&text(&clause)), Ok(clause), "{input} parses back");
    }
    assert_eq!(
        text(&W::Equals("k".into(), V::Strings(vec!["a".into(), "b".into()]))),
        "k == 'a,b'"
    );
}

/// Every default binding's clause in the catalog parses and its text parses back to it.
#[test]
fn catalog_bindings_round_trip() {
    let mut count = 0;
    for binding in cmux_action_catalog::bindings::alias_entries() {
        let Some(when) = binding.when else { continue };
        let clause = parse(when).unwrap_or_else(|e| panic!("{when}: {e:?}"));
        assert_eq!(parse(&text(&clause)), Ok(clause.clone()), "{when}");
        assert_eq!(from_json(&to_json(&clause)), Some(clause), "{when} JSON");
        count += 1;
    }
    assert!(count > 0);
}

#[test]
fn numbers_read_as_swift_double_reads_them() {
    for (text, value) in [
        ("1", 1.0),
        ("+1", 1.0),
        ("-.5", -0.5),
        ("1.", 1.0),
        ("1e3", 1000.0),
        ("0x1p3", 8.0),
        ("0X1A", 26.0),
        ("0x.8", 0.5),
        ("-0x1p-1", -0.5),
    ] {
        assert_eq!(parse_double(text), Some(value), "{text}");
    }
    assert_eq!(parse_double("inf"), Some(f64::INFINITY));
    assert_eq!(parse_double("-Infinity"), Some(f64::NEG_INFINITY));
    assert!(parse_double("nan").is_some_and(f64::is_nan));
    for text in ["", ".", "e5", "1e", "0x", "0xg", "++1", "+-1", "1_0", "abc", "1.2.3", "0x1p"] {
        assert_eq!(parse_double(text), None, "{text}");
    }
    assert_eq!(swift_double(0.5), "0.5");
    assert_eq!(swift_double(0.0001), "0.0001");
    assert_eq!(swift_double(1.5e20), "1.5e+20");
    assert_eq!(swift_double(1e15), "1000000000000000.0");
    assert_eq!(swift_double(f64::NEG_INFINITY), "-inf");
}

#[test]
fn json_round_trips_and_refuses_what_is_not_a_tree() {
    let clause = parse("a && !(k == 'x y') || k != 2.5 || k =~ /z/i || k not in l || false")
        .expect("parses");
    assert_eq!(from_json(&to_json(&clause)), Some(clause));
    let infinite = W::Equals("k".into(), V::Number(f64::INFINITY));
    assert_eq!(to_json(&infinite), serde_json::json!({ "eq": ["k", { "number": "inf" }] }));
    assert_eq!(from_json(&to_json(&infinite)), Some(infinite));
    assert_eq!(from_json(&serde_json::json!({ "bogus": 1 })), None);
    assert_eq!(from_json(&serde_json::json!("a")), None);
}
