use super::*;

#[derive(Clone, Copy)]
enum Event<'a> {
    User(&'a str),
    UserMissing,
    Agent(&'a str),
    Summary(&'a str),
}

fn old(events: &[Event<'_>], max_chars: usize) -> Option<String> {
    let mut summary: Option<String> = None;
    let mut lines: Vec<String> = Vec::new();
    let mut agent_buf = String::new();
    let flush = |agent_buf: &mut String, lines: &mut Vec<String>| {
        if !agent_buf.trim().is_empty() {
            lines.push(format!("assistant: {}", agent_buf.trim()));
        }
        agent_buf.clear();
    };
    for event in events {
        match event {
            Event::User(text) => {
                flush(&mut agent_buf, &mut lines);
                lines.push(format!("user: {text}"));
            }
            Event::UserMissing => flush(&mut agent_buf, &mut lines),
            Event::Agent(text) => agent_buf.push_str(text),
            Event::Summary(text) => {
                agent_buf.clear();
                lines.clear();
                summary = Some((*text).to_owned());
            }
        }
    }
    flush(&mut agent_buf, &mut lines);
    if lines.is_empty() && summary.is_none() {
        return None;
    }
    let head = summary.map(|s| {
        let skip = s.chars().count().saturating_sub(max_chars / 2);
        let s: String = s.chars().skip(skip).collect();
        format!("<compaction_summary>\n{s}\n</compaction_summary>")
    });
    let room = max_chars.saturating_sub(head.as_ref().map_or(0, |h| h.chars().count()));
    let mut text = lines.join("\n\n");
    if text.chars().count() > room {
        let skip = text.chars().count() - room;
        text = format!(
            "[… {skip} earlier characters omitted …]\n{}",
            text.chars().skip(skip).collect::<String>()
        );
    }
    Some(match head {
        Some(head) if text.is_empty() => head,
        Some(head) => format!("{head}\n\n{text}"),
        None => text,
    })
}

fn new(events: &[Event<'_>], max_chars: usize) -> Option<String> {
    let mut builder = TranscriptBuilder::new(max_chars);
    for event in events {
        match event {
            Event::User(text) => builder.user(Some(text)),
            Event::UserMissing => builder.user(None),
            Event::Agent(text) => builder.agent_chunk(text),
            Event::Summary(text) => builder.compaction_summary(text),
        }
    }
    builder.finish()
}

#[test]
fn bounded_builder_matches_the_original_table() {
    let long = "🙂漢字".repeat(10_000);
    let cases = [
        (vec![], 0),
        (vec![Event::User("hello")], 100),
        (vec![Event::Agent("  a "), Event::Agent("b  ")], 100),
        (vec![Event::Agent("answer"), Event::UserMissing], 100),
        (vec![Event::Agent(&long), Event::User("next")], 37),
        (
            vec![
                Event::User("before"),
                Event::Agent("ignored"),
                Event::Summary("summary \u{1f600}"),
                Event::User("after"),
                Event::Agent("  answer  "),
            ],
            24,
        ),
        (vec![Event::User(&long), Event::Agent(&long), Event::Summary(&long)], 37),
    ];
    for (events, max) in cases {
        assert_eq!(new(&events, max), old(&events, max), "max={max}");
    }
}

#[test]
fn bounded_builder_matches_original_across_stream_boundaries() {
    let long = " \t\n\u{2003}".repeat(5000);
    let alphabet = ["", "x", "漢🙂", " ", "\n", "\t", "\u{2003}", &long];
    let mut seed = 0x9367_4271_u64;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed as usize
    };
    for case in 0..512 {
        let events: Vec<_> = (0..32)
            .map(|_| {
                let text = alphabet[next() % alphabet.len()];
                match next() % 8 {
                    0 => Event::UserMissing,
                    1 => Event::User(text),
                    2 => Event::Summary(text),
                    _ => Event::Agent(text),
                }
            })
            .collect();
        for max in [0, 1, 7, 37, 128, 24_000] {
            assert_eq!(new(&events, max), old(&events, max), "case={case}, max={max}");
        }
    }
}
