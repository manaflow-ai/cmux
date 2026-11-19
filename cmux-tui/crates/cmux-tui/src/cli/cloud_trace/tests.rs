use serde_json::Value;

use super::*;

fn fixture(name: &str) -> Value {
    let text = match name {
        "one" => include_str!("fixtures/one.json"),
        "app_no_click" => include_str!("fixtures/app_no_click.json"),
        "list" => include_str!("fixtures/list.json"),
        "empty_list" => include_str!("fixtures/empty_list.json"),
        other => panic!("no fixture {other}"),
    };
    serde_json::from_str(text).expect("fixture JSON")
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

/// The row of `hop` in a rendered table.
fn row<'a>(text: &'a str, hop: &str) -> &'a str {
    text.lines()
        .find(|line| line.split_whitespace().next() == Some(hop))
        .unwrap_or_else(|| panic!("no row {hop} in\n{text}"))
}

#[test]
fn parse_reads_an_id_a_list_and_refuses_bad_words() {
    assert_eq!(
        parse(&words("tr_cli_0123456789abcdef")),
        Ok(Parsed::One { trace: "tr_cli_0123456789abcdef".into(), platform: None })
    );
    assert_eq!(parse(&[]), Ok(Parsed::List { limit: 20, platform: None }));
    assert_eq!(
        parse(&words("--limit 5 --platform https://p.example")),
        Ok(Parsed::List { limit: 5, platform: Some("https://p.example".into()) })
    );
    assert_eq!(parse(&words("--limit=200")), Ok(Parsed::List { limit: 200, platform: None }));
    assert_eq!(parse(&words("--help")), Ok(Parsed::Help));
    assert!(parse(&words("--limit 0")).is_err());
    assert!(parse(&words("--limit 201")).is_err());
    assert!(parse(&words("short")).is_err(), "under 8 characters");
    assert!(parse(&words("has/slash1")).is_err());
    assert!(parse(&words("tr_cli_0123456789abcdef --limit 3")).is_err());
    assert!(parse(&words("tr_cli_0123456789abcdef another_id_1234")).is_err());
    assert!(parse(&words("--wat")).is_err());
}

#[test]
fn trace_ids_follow_the_platform_pattern() {
    assert!(is_trace_id("abcdefgh"));
    assert!(is_trace_id(&"a".repeat(80)));
    assert!(!is_trace_id(&"a".repeat(81)));
    assert!(!is_trace_id("abcdefg"));
    assert!(!is_trace_id("abcd efgh"));
    assert!(is_trace_id("A-b_C-d_9"));
}

#[test]
fn waterfall_offsets_durations_and_bars_follow_the_spans() {
    let text = waterfall(&fixture("one"), Some(&fixture("list")));
    assert!(text.starts_with("trace tr_cli_0123456789abcdef\n"), "{text}");
    assert!(text.contains("machine vm_0123456789abcdefghij  path spare"), "{text}");
    assert!(text.contains("started 2026-11-25 13:00:00Z"), "{text}");
    assert!(text.contains("total 20.0 s"), "{text}");
    assert!(!text.contains("not timed"), "a trace with a click span: {text}");

    let click = row(&text, "click");
    assert!(click.contains("+0 ms"), "{click}");
    assert!(click.contains("200 ms"), "{click}");
    // 200 of 20000 ms is the first of 32 cells (at least one cell is drawn).
    assert!(click.contains("|#                               |"), "{click}");

    let boot = row(&text, "boot");
    assert!(boot.contains("+1.2 s"), "{boot}");
    assert!(boot.contains("4.0 s"), "{boot}");

    // Network sums the platform's prepare and attach and the client's connect: 200 + 100 + 1000.
    let network = row(&text, "network");
    assert!(network.contains("+700 ms"), "{network}");
    assert!(network.contains("1.3 s"), "{network}");
    // Its three spans are separate stretches of the bar.
    let bar = network.split('|').nth(1).expect("bar");
    assert_eq!(bar.chars().count(), 32);
    assert!(bar.contains("# "), "a gap between the parts: {bar:?}");

    // The machine's agent_auth wins over the client's longer one.
    let auth = row(&text, "agent_auth");
    assert!(auth.contains("8.0 s"), "{auth}");
    assert!(!auth.contains("9.0 s"), "{auth}");

    // A hop with no span is a dash row with its day numbers.
    let restore = row(&text, "restore");
    assert!(restore.contains("|                                |"), "{restore}");
    assert!(restore.contains("(0)"), "{restore}");

    // The day's p50/p95 sit beside each hop.
    assert!(row(&text, "api").contains("1.0 s    1.5 s  (2)"), "{text}");
    assert!(row(&text, "first_token").contains("5.8 s    5.8 s  (1)"), "{text}");

    // Every hop, in the start's order.
    let order: Vec<&str> = text
        .lines()
        .filter_map(|line| line.split_whitespace().next())
        .filter(|word| HOPS.contains(word))
        .collect();
    assert_eq!(order, HOPS.to_vec());
}

#[test]
fn waterfall_without_a_click_says_the_click_is_not_timed_and_starts_at_the_server() {
    let text = waterfall(&fixture("app_no_click"), None);
    assert!(
        text.contains(
            "the click is not timed: the trace starts at the platform's receipt of the create"
        ),
        "{text}"
    );
    assert!(text.contains("machine -  path -"), "{text}");
    let api = row(&text, "api");
    assert!(api.contains("+0 ms"), "{api}");
    assert!(api.contains("1.5 s"), "{api}");
    assert!(api.contains(&format!("|{}|", "#".repeat(32))), "{api}");
    // No day list: the stats column is a dash.
    assert!(row(&text, "placement").trim_end().ends_with('-'), "{text}");
}

#[test]
fn waterfall_keeps_a_hop_it_does_not_know() {
    let mut trace = fixture("app_no_click");
    trace["spans"].as_array_mut().unwrap().push(serde_json::json!(
        {"hop": "warm_cache", "start_ms": 1795611600000_i64, "end_ms": 1795611600100_i64, "source": "platform", "attrs": {}}
    ));
    let text = waterfall(&trace, None);
    assert!(row(&text, "warm_cache").contains("100 ms"), "{text}");
}

#[test]
fn summary_lists_the_day_per_hop_and_the_newest_traces() {
    let text = summary(&fixture("list"));
    assert!(text.starts_with("Cloud start hops, last 24 h\n"), "{text}");
    assert_eq!(words(row(&text, "boot")), ["boot", "1", "4.0", "s", "4.0", "s"]);
    assert_eq!(words(row(&text, "restore")), ["restore", "0", "-", "-"]);
    assert!(text.contains("Newest traces (`cmux vm trace ID` draws one)"), "{text}");
    let first = row(&text, "tr_cli_0123456789abcdef");
    assert!(first.contains("2026-11-25 13:00:00Z"), "{first}");
    assert!(first.contains("20.0 s"), "{first}");
    assert!(first.contains("spare"), "{first}");
    assert!(first.contains("8/9"), "{first}");
    assert!(first.ends_with("vm_0123456789abcdefghij"), "{first}");
    let app = row(&text, "app-idempotency-key-0001");
    assert!(app.contains("2/9"), "{app}");
    assert!(app.trim_end().ends_with('-'), "no machine yet: {app}");
}

#[test]
fn summary_of_an_empty_day_says_so() {
    let text = summary(&fixture("empty_list"));
    assert!(text.contains("No Cloud starts in this window."), "{text}");
    assert_eq!(words(row(&text, "api")), ["api", "0", "-", "-"]);
}

#[test]
fn durations_and_times_read_for_a_person() {
    assert_eq!(duration_text(0), "0 ms");
    assert_eq!(duration_text(999), "999 ms");
    assert_eq!(duration_text(1000), "1.0 s");
    assert_eq!(duration_text(59_949), "59.9 s");
    assert_eq!(duration_text(125_000), "2m 05s");
    assert_eq!(duration_text(-5), "0 ms");
    assert_eq!(utc_text(0), "1970-01-01 00:00:00Z");
    assert_eq!(utc_text(951_782_400_000), "2000-02-29 00:00:00Z");
}

#[test]
fn help_names_the_verb() {
    assert!(super::super::cloud_help::verb_help(TRACE, false).unwrap().contains("cmux vm trace"));
    assert!(super::super::cloud_help::overview(false).contains("trace [TRACE_ID]"));
}
