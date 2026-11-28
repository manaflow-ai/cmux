//! The calculator, pinned to what the Swift `OmniboxCalculator` answered.

use crate::calculator::*;
use crate::ops;
use serde_json::json;

#[test]
fn arithmetic_follows_precedence_and_associativity() {
    assert_eq!(evaluate("1+2*3"), Some(7.0));
    assert_eq!(evaluate("(1+2)*3"), Some(9.0));
    assert_eq!(evaluate("2^3^2"), Some(512.0));
    assert_eq!(evaluate("-2^2"), Some(4.0));
    assert_eq!(evaluate("10 % 4"), Some(2.0));
    assert_eq!(evaluate("-7 % 3"), Some(-1.0));
    assert_eq!(evaluate("6 ÷ 4 × 2"), Some(3.0));
    assert_eq!(evaluate("--3+1"), Some(4.0));
    assert_eq!(evaluate(" 1.5 + .5 "), Some(2.0));
    assert_eq!(evaluate("1. + 1"), Some(2.0));
    assert_eq!(evaluate("10-2-3"), Some(5.0));
    assert_eq!(evaluate("8/2/2"), Some(2.0));
}

#[test]
fn text_that_is_not_a_whole_expression_with_an_operator_has_no_value() {
    for text in [
        "", "42", "-42", "(3)", "abc", "1+", "1++", "(1+2", "1+2)", "1..2+1", ".+1", "1/0", "0/0",
        "2^9999", "1,000+1", "1e3+1", "１+１",
    ] {
        assert_eq!(evaluate(text), None, "{text:?}");
    }
}

#[test]
fn answers_are_integers_or_ten_significant_digits_in_plain_notation() {
    assert_eq!(format(3.0), "3");
    assert_eq!(format(-0.0), "0");
    assert_eq!(format(-12.0), "-12");
    assert_eq!(format(1.0 / 3.0), "0.3333333333");
    assert_eq!(format(-2.0 / 3.0), "-0.6666666667");
    assert_eq!(format(0.1 + 0.2), "0.3");
    assert_eq!(format(2f64.sqrt()), "1.414213562");
    assert_eq!(format(1e20), "100000000000000000000");
    assert_eq!(format(123456789012.5), "123456789000");
    assert_eq!(format(1e-12), "0.000000000001");
    assert_eq!(format(0.000123456789123), "0.0001234567891");
    assert_eq!(format(2.5), "2.5");
    assert_eq!(format(999999999999999.5), "1000000000000000");
}

#[test]
fn the_answer_row_skips_text_that_already_is_its_answer() {
    assert_eq!(answer("1+1"), Some("2".into()));
    assert_eq!(answer("  1/3 "), Some("0.3333333333".into()));
    assert_eq!(answer("hello"), None);
    assert_eq!(answer(&"1+".repeat(200)), None);
}

#[test]
fn calculator_op_answers_text_or_null() {
    assert_eq!(
        ops::call("browser_rules_calculator_answer", json!({"text": "2*21"})).unwrap(),
        json!("42")
    );
    assert_eq!(
        ops::call("browser_rules_calculator_answer", json!({"text": "news"})).unwrap(),
        json!(null)
    );
}
