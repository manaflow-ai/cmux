use cmux_automations::Trigger;
use cmux_automations::webhook::{DEFAULT_DEDUPE_SECONDS, WebhookFilter};

use super::super::{Args, SPEC_FLAGS, SPEC_VALUED, parse_trigger};
use super::*;

fn args(words: &[&str]) -> Result<Args, Failure> {
    spec_args(&words.iter().map(|s| s.to_string()).collect::<Vec<_>>(), SPEC_VALUED, SPEC_FLAGS)
}

fn parsed(words: &[&str]) -> Result<Option<Trigger>, Failure> {
    parse_trigger(&args(words)?, 0)
}

#[test]
fn webhook_flags_parse_to_a_trigger() {
    assert_eq!(
        parsed(&["--webhook"]).ok().flatten(),
        Some(Trigger::Webhook { filters: vec![], dedupe_seconds: DEFAULT_DEDUPE_SECONDS })
    );
    assert_eq!(
        parsed(&[
            "--webhook",
            "--match",
            "action=opened",
            "--match=pull_request.base.ref=main",
            "--header",
            "X-GitHub-Event=pull_request",
            "--dedupe",
            "10m",
        ])
        .ok()
        .flatten(),
        Some(Trigger::Webhook {
            filters: vec![
                WebhookFilter::parse_json("action=opened").unwrap(),
                WebhookFilter::parse_json("pull_request.base.ref=main").unwrap(),
                WebhookFilter::Header {
                    name: "x-github-event".into(),
                    value: "pull_request".into()
                },
            ],
            dedupe_seconds: 600,
        })
    );
}

#[test]
fn webhook_options_need_the_flag_and_one_trigger() {
    // An option on another trigger is refused, not dropped.
    assert!(parsed(&["--hourly", "--match", "a=b"]).is_err());
    // Two triggers, a bad filter, a window past seven days.
    assert!(parsed(&["--webhook", "--hourly"]).is_err());
    assert!(parsed(&["--webhook", "--match", "noequals"]).is_err());
    assert!(parsed(&["--webhook", "--dedupe", "8d"]).is_err());
    // `--webhook` takes no value.
    assert!(args(&["--webhook=x"]).is_err());
    // With no trigger flag, `create` decides (it names the missing `--webhook`).
    let a = args(&["--match", "a=b"]).ok().unwrap();
    assert_eq!(option_given(&a), Some("match"));
    assert!(parse_trigger(&a, 0).ok().unwrap().is_none());
}

#[test]
fn edit_keeps_what_no_option_replaces() {
    let base = Trigger::Webhook {
        filters: vec![WebhookFilter::parse_json("action=opened").unwrap()],
        dedupe_seconds: 60,
    };
    let only_window = trigger(&args(&["--dedupe", "2h"]).ok().unwrap(), Some(&base)).ok().unwrap();
    assert_eq!(
        only_window,
        Trigger::Webhook {
            filters: vec![WebhookFilter::parse_json("action=opened").unwrap()],
            dedupe_seconds: 7_200,
        }
    );
    let new_filters =
        trigger(&args(&["--header", "X-A=b"]).ok().unwrap(), Some(&base)).ok().unwrap();
    assert_eq!(
        new_filters,
        Trigger::Webhook {
            filters: vec![WebhookFilter::Header { name: "x-a".into(), value: "b".into() }],
            dedupe_seconds: 60,
        }
    );
}
