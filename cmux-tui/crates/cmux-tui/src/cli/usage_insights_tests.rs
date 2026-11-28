use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn hours_default_parse_and_refuse_out_of_range() {
    assert_eq!(parse_hours(&[]), Ok(DEFAULT_HOURS));
    assert_eq!(parse_hours(&words(&["--hours", "6"])), Ok(6));
    assert_eq!(parse_hours(&words(&["--hours=48"])), Ok(48));
    assert!(parse_hours(&words(&["--hours", "0"])).is_err());
    assert!(parse_hours(&words(&["--hours", "721"])).is_err());
    assert!(parse_hours(&words(&["--hours"])).is_err());
    assert!(parse_hours(&words(&["--days", "2"])).is_err());
}

#[test]
fn other_scopes_pass_through() {
    assert_eq!(run_if_requested(&words(&["video", "open", "x.mp4"])), None);
    assert_eq!(run_if_requested(&words(&[])), None);
}
