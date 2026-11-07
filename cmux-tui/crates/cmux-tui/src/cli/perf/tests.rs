use std::path::PathBuf;

use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn record(
    seconds: u64,
    interval_ms: u64,
    out: Option<&str>,
    app: Option<&str>,
    signposts: bool,
) -> Invocation {
    Invocation::Record(Options {
        seconds,
        interval_ms,
        out: out.map(PathBuf::from),
        app: app.map(str::to_owned),
        signposts,
    })
}

#[test]
fn record_parses_its_flags_and_bounds() {
    assert_eq!(parse(&words("record")), Ok(record(10, 250, None, None, true)));
    assert_eq!(
        parse(&words(
            "record --seconds 30 --out /tmp/p --app 123 --interval-ms 100 --no-signposts"
        )),
        Ok(record(30, 100, Some("/tmp/p"), Some("123"), false))
    );
    assert_eq!(
        parse(&words("record --seconds=600 --app=/Applications/cmux.app")),
        Ok(record(600, 250, None, Some("/Applications/cmux.app"), true))
    );
    assert_eq!(parse(&[]), Ok(Invocation::Help));
    assert_eq!(parse(&words("record --help")), Ok(Invocation::Help));
    for bad in [
        "record --seconds 0",
        "record --seconds 601",
        "record --seconds x",
        "record --interval-ms 49",
        "record --interval-ms 5001",
        "record --seconds",
        "record --bogus",
        "record extra",
        "replay",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn perf_messages_keep_their_placeholders_in_japanese() {
    let english = &crate::localization::catalog_for_locale("en_US.UTF-8").perf;
    let japanese = &crate::localization::catalog_for_locale("ja_JP.UTF-8").perf;
    let pairs = [
        (english.unknown_verb, japanese.unknown_verb),
        (english.bad_seconds, japanese.bad_seconds),
        (english.bad_interval, japanese.bad_interval),
        (english.not_an_app, japanese.not_an_app),
        (english.no_process, japanese.no_process),
        (english.recording, japanese.recording),
        (english.write_failed, japanese.write_failed),
    ];
    let placeholders = |text: &str| {
        let mut found: Vec<String> = text
            .split('{')
            .skip(1)
            .filter_map(|part| part.split_once('}'))
            .map(|(name, _)| name.to_owned())
            .collect();
        found.sort();
        found
    };
    for (en, ja) in pairs {
        assert_ne!(en, ja);
        assert_eq!(placeholders(en), placeholders(ja), "{en}");
    }
    assert!(japanese.usage.starts_with("使い方: cmux perf record"));
}
