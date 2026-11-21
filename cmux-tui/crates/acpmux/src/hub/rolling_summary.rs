//! Part of `Hub`; see `hub/mod.rs`. Each chat's rolling summary: one short line on where it
//! stands and its next action, kept current after each turn, for the sidebar and the chat header
//! (David Beyer, 2026-11-20, of cmux Next: rolling summaries of every chat with a next action for
//! each "might even make him consider switching").
//!
//! The summary rolls: each one is made from the one before it and the turn that just ended, never
//! from the transcript, so its cost stays flat however long the chat gets.
//!
//! - A turn that ends on a `wrap_up` call (`crate::wrap_up_suggestion`) is summarized from its
//!   recap and its question: the agent already said where it stands, so no model is asked. Any
//!   completed turn's wrap-up counts, an agent's or a trigger's too: it costs nothing.
//! - A turn a person's own prompt started (`prompt_sender::person_turn`) that ended with no wrap-up
//!   asks the summary model once (`summaries.command`, else one `_acpmux/complete` on the chat's
//!   harness, whose small model it picks: haiku on Claude). The request carries the last summary,
//!   the person's prompt (cut to [`PROMPT_CHARS`]) and the end of the reply (the row's preview, at
//!   most 2000 bytes), and asks for [`MAX_TOKENS`] tokens: about 1k tokens in, 60 out.
//! - Nothing else asks: another agent's message, a notice, a trigger, a throwaway session, a failed
//!   or stopped turn. Those were most of all turns on the team (the sr2 audit of 2026-11-20 found
//!   87% of away recaps went to chats only agents drove).
//! - One request per chat at a time; a person's turn that ends meanwhile asks once more after it,
//!   from the latest turn, so a burst of turns makes at most two requests.
//! - `summaries.generate: false` asks no model; a wrap-up still summarizes.
//!
//! The summary is kept on the chat's metadata (`SessionMeta::rolling_summary`), across restarts,
//! and on its row (`rollingSummary`); a `mux` `summarized` record tells watchers it changed.

use super::*;
use crate::store::RollingSummary;
use std::time::Duration;

/// The env that names a summary command (one program), over `summaries.command`.
const COMMAND_ENV: &str = "ACPMUX_SUMMARY_COMMAND";
const SYSTEM: &str = "You keep a one-line status of a chat between a person and a coding agent. Reply in the person's language with exactly two lines and nothing else:\nSummary: where the work stands now, at most 20 words.\nNext: the single next action, at most 10 words, starting with a verb; write \"Next: none\" when nothing is left.";
/// The completion's answer cap: the two lines fit in about 50 tokens.
const MAX_TOKENS: u64 = 80;
/// How much of the person's prompt goes in the request.
const PROMPT_CHARS: usize = 1500;
/// The longest summary and next action kept (the list row cuts strings at 160).
const TEXT_CHARS: usize = 160;
const NEXT_CHARS: usize = 100;
const TIMEOUT: Duration = Duration::from_secs(30);
const WRAP_UP: &str = "wrap_up";
const MODEL: &str = "model";

/// A chat's summary state, this daemon run only.
#[derive(Debug, Default)]
pub(crate) struct Rolling {
    /// The running turn was started by a person's own prompt.
    person_turn: bool,
    /// A summary request is running.
    asking: bool,
    /// A person's turn ended while one ran: ask once more after it.
    again: bool,
}

impl Hub {
    /// A turn of `session` starts; `by_person`: a person's own prompt started it.
    pub(super) fn summary_turn_started(&self, session: &Session, by_person: bool) {
        session.rolling.lock().unwrap_or_else(|e| e.into_inner()).person_turn = by_person;
    }

    /// A turn of `session` ended; `completed`: it ended well; `recap`: the wrap-up it ended on.
    pub(super) fn summary_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        completed: bool,
        recap: Option<crate::wrap_up_suggestion::Recap>,
    ) {
        let by_person = std::mem::take(
            &mut session.rolling.lock().unwrap_or_else(|e| e.into_inner()).person_turn,
        );
        if !completed || session.read_meta(|m| m.throwaway) {
            return;
        }
        if let Some(recap) = recap {
            let summary = RollingSummary {
                text: cut(&recap.text, TEXT_CHARS),
                next: recap.ask.as_deref().map(|a| cut(a, NEXT_CHARS)),
                source: WRAP_UP.to_owned(),
                turn: session.read_meta(|m| m.turn_count),
                at: crate::store::now_ms(),
            };
            self.apply_summary(session, summary);
            return;
        }
        if by_person {
            self.ask_summary(session);
        }
    }

    /// One summary request for `session`, unless one runs (then once more after it).
    fn ask_summary(self: &Arc<Self>, session: &Arc<Session>) {
        {
            let mut rolling = session.rolling.lock().unwrap_or_else(|e| e.into_inner());
            if rolling.asking {
                rolling.again = true;
                return;
            }
            rolling.asking = true;
        }
        let hub = self.clone();
        let session = session.clone();
        // A shutdown may drop it: the next person's turn after a restart asks again.
        self.scope.spawn_until_cancelled("chat-summary", async move {
            loop {
                let (request, harness, turn) = session.read_meta(|m| {
                    (
                        request(
                            m.rolling_summary.as_ref(),
                            m.last_prompt.as_deref(),
                            m.preview.as_deref(),
                        ),
                        m.harness.clone(),
                        m.turn_count,
                    )
                });
                let summary = hub.generate_summary(&harness, &request).await;
                if let Some((text, next)) = summary {
                    let summary = RollingSummary {
                        text,
                        next,
                        source: MODEL.to_owned(),
                        turn,
                        at: crate::store::now_ms(),
                    };
                    hub.apply_summary(&session, summary);
                }
                let mut rolling = session.rolling.lock().unwrap_or_else(|e| e.into_inner());
                if !std::mem::take(&mut rolling.again) {
                    rolling.asking = false;
                    return;
                }
            }
        });
    }

    /// The model's summary and next action for `request`, or None (off, no command applies, or
    /// an answer with no summary line).
    async fn generate_summary(
        self: &Arc<Self>,
        harness: &str,
        request: &str,
    ) -> Option<(String, Option<String>)> {
        let (custom, model) = {
            let cfg = self.config.read().await;
            if cfg.summaries.generate == Some(false) {
                return None;
            }
            let custom = std::env::var(COMMAND_ENV)
                .ok()
                .filter(|c| !c.trim().is_empty())
                .map(|c| vec![c])
                .or_else(|| cfg.summaries.command.clone().filter(|c| !c.is_empty()));
            (custom, cfg.summaries.model.clone().or_else(|| cfg.titles.model.clone()))
        };
        let started = std::time::Instant::now();
        let (answer, used) = match custom {
            Some(argv) => {
                // Never the shared temp dir or the daemon's folder (`titles.rs` `title_command`).
                let cwd = tokio::task::spawn_blocking(crate::protected_folders::unattended_cwd)
                    .await
                    .ok()?;
                let mut cmd = tokio::process::Command::new(&argv[0]);
                cmd.args(&argv[1..]).current_dir(&cwd);
                #[cfg(unix)]
                cmd.process_group(0);
                (super::titles::run_command(cmd, request, TIMEOUT).await, "custom".to_owned())
            }
            None => {
                let mut params =
                    json!({"prompt": request, "harness": harness, "maxTokens": MAX_TOKENS});
                if let Some(model) = model
                    && let Some(o) = params.as_object_mut()
                {
                    o.insert("model".into(), json!(model));
                }
                let result = self.complete(crate::server::Origin::Local, &params).await.ok()?;
                let used =
                    result.get("model").and_then(Value::as_str).unwrap_or("default").to_owned();
                (result.get("text").and_then(Value::as_str).map(str::to_owned), used)
            }
        };
        let parsed = answer.as_deref().and_then(parse);
        tracing::info!(
            event = "chat_summary",
            harness,
            model = used.as_str(),
            ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            input_bytes = request.len(),
            estimated_input_tokens = request.len().div_ceil(4),
            estimated_output_tokens = answer.as_deref().map_or(0, |a| a.len().div_ceil(4)),
            ok = parsed.is_some(),
            "chat summary completion"
        );
        parsed
    }

    /// Keeps `summary` as the chat's and tells watchers, unless a newer turn's summary is there.
    fn apply_summary(&self, session: &Session, summary: RollingSummary) {
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.rolling_summary.as_ref().is_some_and(|s| s.turn > summary.turn) {
                return;
            }
            let same = m
                .rolling_summary
                .as_ref()
                .is_some_and(|s| s.text == summary.text && s.next == summary.next);
            m.rolling_summary = Some(summary.clone());
            if same {
                return;
            }
        }
        self.append(session, "mux", "summarized", json!(summary));
        self.save_meta(session);
    }
}

/// The request: the last summary, the person's latest prompt and the end of the agent's reply.
fn request(last: Option<&RollingSummary>, prompt: Option<&str>, reply: Option<&str>) -> String {
    let mut text = format!("{SYSTEM}\n");
    if let Some(last) = last {
        text.push_str(&format!("\nThe status so far:\nSummary: {}\n", last.text));
        if let Some(next) = &last.next {
            text.push_str(&format!("Next: {next}\n"));
        }
    }
    if let Some(prompt) = prompt.map(str::trim).filter(|p| !p.is_empty()) {
        text.push_str(&format!(
            "\nThe person's latest message:\n{}\n",
            short_text(prompt, PROMPT_CHARS)
        ));
    }
    if let Some(reply) = reply.map(str::trim).filter(|r| !r.is_empty()) {
        text.push_str(&format!("\nThe end of the agent's reply:\n{reply}\n"));
    }
    text
}

/// The summary and next action of a model's answer: its `Summary:` and `Next:` lines, unquoted,
/// one line each; a first line with no label is the summary. None with no summary.
fn parse(answer: &str) -> Option<(String, Option<String>)> {
    let mut summary = None;
    let mut next = None;
    for line in answer.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if let Some(v) = label(line, "summary") {
            summary.get_or_insert_with(|| v.to_owned());
        } else if let Some(v) = label(line, "next") {
            next.get_or_insert_with(|| v.to_owned());
        } else if summary.is_none() {
            summary = Some(line.to_owned());
        }
    }
    let summary = clean(&summary?, TEXT_CHARS)?;
    let next = next
        .and_then(|n| clean(&n, NEXT_CHARS))
        .filter(|n| !matches!(n.to_lowercase().trim_end_matches('.'), "none" | "nothing" | "n/a"));
    Some((summary, next))
}

/// The value of `Label: value` (any case, markdown bold or not), if `line` is one.
fn label<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let line = line.trim_start_matches(['*', '-', ' ']);
    let (k, v) = line.split_once(':')?;
    k.trim_matches(['*', ' ']).eq_ignore_ascii_case(key).then(|| v.trim_matches(['*', ' ']))
}

/// `text` unquoted, on one line, cut to `chars`; None when nothing is left.
fn clean(text: &str, chars: usize) -> Option<String> {
    let text = one_line(text);
    let text = text.trim().trim_matches(['"', '“', '”', '\'', '`']).trim();
    (!text.is_empty()).then(|| cut(text, chars))
}

/// `text` on one line, at most `chars` characters with its ellipsis (`short_text` keeps `chars`
/// and then adds one).
fn cut(text: &str, chars: usize) -> String {
    let line = one_line(text);
    if line.chars().count() <= chars {
        return line;
    }
    short_text(&line, chars.saturating_sub(1))
}

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_two_line_answer_reads_as_summary_and_next() {
        let answer = "Summary: The parser now tolerates missing fields.\n\nNext: \"Open the PR.\"";
        assert_eq!(
            parse(answer),
            Some((
                "The parser now tolerates missing fields.".to_owned(),
                Some("Open the PR.".to_owned())
            ))
        );
    }

    #[test]
    fn bold_labels_an_unlabelled_first_line_and_next_none_read_right() {
        assert_eq!(
            parse("**Summary:** Done and pushed.\n**Next:** none"),
            Some(("Done and pushed.".to_owned(), None))
        );
        assert_eq!(parse("All tests pass now."), Some(("All tests pass now.".to_owned(), None)));
        assert_eq!(parse("Next: do it"), None);
        assert_eq!(parse("  \n"), None);
    }

    #[test]
    fn a_long_summary_is_cut_to_one_short_line() {
        let long = format!("Summary: {}\nNext: {}", "word ".repeat(80), "go ".repeat(80));
        let (text, next) = parse(&long).unwrap();
        assert!(text.chars().count() <= TEXT_CHARS, "{text}");
        assert!(next.unwrap().chars().count() <= NEXT_CHARS);
        assert!(!text.contains('\n'));
        assert!(text.ends_with('…'));
        // A summary at the limit stays whole.
        let whole = "a".repeat(TEXT_CHARS);
        assert_eq!(cut(&whole, TEXT_CHARS), whole);
    }

    #[test]
    fn the_request_rolls_the_last_summary_with_only_the_latest_turn() {
        let last = RollingSummary {
            text: "Menu has three dishes.".into(),
            next: Some("Pick a dessert.".into()),
            source: MODEL.into(),
            turn: 1,
            at: 1,
        };
        let text = request(
            Some(&last),
            Some("make it vegetarian"),
            Some("Done: all three are now vegetarian."),
        );
        assert!(text.contains("Summary: Menu has three dishes."));
        assert!(text.contains("Next: Pick a dessert."));
        assert!(text.contains("make it vegetarian"));
        assert!(text.contains("all three are now vegetarian"));
        let huge = "x".repeat(10_000);
        assert!(request(None, Some(&huge), None).len() < PROMPT_CHARS * 4 + SYSTEM.len() + 100);
    }
}
