use super::*;

#[test]
fn a_result_is_one_checked_line_with_its_refs() {
    let ok = json!({"summary": " Merged ", "prs": ["https://github.com/o/r/pull/1"], "shas": ["abc1234"]});
    let result = super::result(&ok, "done", "lane").expect("a done result");
    assert_eq!(result["summary"], "Merged");
    assert_eq!(result["prs"], json!(["https://github.com/o/r/pull/1"]));
    assert_eq!(result["by"], "lane");
    for bad in [
        json!({}),
        json!({"summary": "two\nlines"}),
        json!({"summary": "x", "prs": ["github.com/o/r/pull/1"]}),
        json!({"summary": "x", "prs": "https://github.com/o/r/pull/1"}),
        json!({"summary": "x", "shas": ["abc12"]}),
        json!({"summary": "x", "shas": ["not-a-sha"]}),
    ] {
        assert!(super::result(&bad, "done", "lane").is_err(), "{bad}");
    }
    // A blocked or failed task says why.
    assert!(super::result(&json!({"summary": "x"}), "blocked", "lane").is_err());
    let blocked = super::result(&json!({"summary": "x", "why": "CI is down"}), "blocked", "l");
    assert_eq!(blocked.expect("blocked")["why"], "CI is down");
}

#[test]
fn the_same_call_again_is_the_same_result() {
    let params = json!({"summary": "Merged", "shas": ["abc1234"]});
    let first = result(&params, "done", "lane").unwrap();
    let again = result(&params, "done", "someone").unwrap();
    assert!(same_result(&first, &again));
    let failed = json!({"summary": "Merged", "shas": ["abc1234"], "why": "reverted"});
    assert!(!same_result(&first, &result(&failed, "failed", "lane").unwrap()));
    let other = result(&json!({"summary": "Merged too"}), "done", "lane").unwrap();
    assert!(!same_result(&first, &other));
}
