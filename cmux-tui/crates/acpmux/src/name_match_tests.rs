use super::*;

fn names<'a>(key: &str, all: &[&'a str]) -> Result<Option<&'a str>, Vec<&'a str>> {
    pick(all.iter().copied(), key, |n| n)
}

#[test]
fn a_key_in_another_case_names_the_one_session_with_that_name() {
    assert_eq!(names("td2-a", &["td2-A", "td2-B"]), Ok(Some("td2-A")));
}

#[test]
fn a_prefix_several_names_share_is_refused_with_every_one() {
    let all = ["td2-A", "td2-B", "td2-C", "td2-D", "other"];
    assert_eq!(names("td2", &all), Err(vec!["td2-A", "td2-B", "td2-C", "td2-D"]));
    assert_eq!(names("TD2-c", &all), Ok(Some("td2-C")));
    assert_eq!(names("oth", &all), Ok(Some("other")));
}

#[test]
fn an_exact_name_wins_over_one_in_another_case() {
    assert_eq!(names("td2-a", &["td2-A", "td2-a"]), Ok(Some("td2-a")));
    // Two that differ only in case tie for a third spelling.
    assert_eq!(names("TD2-a", &["td2-A", "td2-a"]), Err(vec!["td2-A", "td2-a"]));
    // A whole name in another case wins over a longer name it starts.
    assert_eq!(names("review", &["Review", "review-2"]), Ok(Some("Review")));
}

#[test]
fn a_short_name_is_read_by_the_same_steps_but_never_as_a_prefix() {
    assert_eq!(short_step("coord/td2-A", "td2-a"), Some(Step::Case));
    assert_eq!(short_step("coord/td2-A", "td2_a"), Some(Step::Separators));
    assert_eq!(short_step("a/coord/td2-A", "COORD/td2-a"), Some(Step::Case));
    assert_eq!(short_step("coord/td2-A", "td2"), None);
    assert_eq!(short_step("td2-A", "td2-a"), None);
}

#[test]
fn separators_and_case_are_ignored_last() {
    assert_eq!(names("td2_a", &["td2-A", "td2-B"]), Ok(Some("td2-A")));
    assert_eq!(names("td2 a", &["td2-A"]), Ok(Some("td2-A")));
    assert_eq!(names("td2a", &["td2-A"]), Ok(Some("td2-A")));
    assert_eq!(names("ab", &["a-b", "a_b"]), Err(vec!["a-b", "a_b"]));
    assert_eq!(names("-", &["a-b"]), Ok(None));
    assert_eq!(names("", &["a"]), Ok(None));
}
