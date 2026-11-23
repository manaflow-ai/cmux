#[test]
fn an_invalid_pattern_says_why_on_one_line() {
    let Err(error) = super::compile("(") else { panic!("( compiled") };
    let message = super::invalid_message("(", &error);
    assert_eq!(
        message,
        "terminal wait pattern \"(\" is not a valid regular expression: unclosed group"
    );
}

#[test]
fn w4j_anchors_match_at_each_line_unless_the_pattern_turns_multi_line_off() {
    let text = "step 1\nBENCH_OK\nstep 3\n$ ";
    assert!(super::compile("^BENCH_OK$").unwrap().is_match(text));
    assert!(!super::compile("(?-m)^BENCH_OK$").unwrap().is_match(text));
    assert!(!super::compile(r"\ABENCH_OK").unwrap().is_match(text));
    assert!(super::compile("(?m)^BENCH_OK$").unwrap().is_match(text));
    assert!(super::compile("BENCH").unwrap().is_match(text));
    assert!(super::compile("(").is_err());
}
