//! Part of `Hub`; see `hub/mod.rs`. Each chat's rolling summary: one short line on where it
//! stands and its next action, kept current after each turn, for the sidebar and the chat header
//! (David Beyer, 2026-11-20, of cmux Next: rolling summaries of every chat with a next action for
//! each "might even make him consider switching").
//!
//! The summary rolls: each one is made from the one before it and the turn that just ended, never
//! from the transcript, so its cost stays flat however long the chat gets.
//!
//! - The line is a state and a next action, not a sentence of the reply: at most [`WORDS`] words
//!   each ("CI green, PR open" / "Merge the PR"). Leo, 2026-11-22, of a header line that read
//!   "I posted <host>'s 14-day permission-stall history on <issue> (htt…": "im not sure if this
//!   is useful"; it was the wrap-up recap's first sentence, cut mid-link, its question hidden.
//! - A turn that ends on a `wrap_up` call (`crate::wrap_up_suggestion`) gets a line from its
//!   recap and its question at once, with no model ([`condense_state`], [`condense_ask`]): any
//!   completed turn's wrap-up counts, an agent's or a trigger's too: it costs nothing. When a
//!   person started that turn and the recap is longer than the line kept, the summary model is
//!   asked once too, with the recap as the reply, and its answer replaces the line.
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
const SYSTEM: &str = "You keep a glanceable status of a chat between a person and a coding agent, shown beside the chat's name. Reply in the person's language with exactly two lines and nothing else:\nSummary: the state of the work now, at most 6 words, a noun phrase or terse clause, no \"I\" or \"we\", no links, never the reply's first sentence (good: \"CI green, PR #412 open\", \"Reconnect race found, fix drafted\"; bad: \"I posted the history on the issue\").\nNext: the person's single next action, at most 6 words, an imperative starting with a verb (good: \"Merge PR #412\", \"Pick a dessert\", \"Answer: keep the old API?\"); write \"Next: none\" when nothing is left.";
/// The most words a state or next action keeps: the prompt asks for 6, a model's answer may run
/// a word or two over, and the line still reads at a glance.
const WORDS: usize = 8;
/// The words a state made without a model keeps (a wrap-up's recap, [`condense_state`]).
const RECAP_WORDS: usize = 6;
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
    /// The wrap-up recap the next request reads as the agent's reply, over the row's preview.
    recap: Option<String>,
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
            let text = condense_state(&recap.text);
            let summary = RollingSummary {
                next: recap.ask.as_deref().and_then(condense_ask),
                source: WRAP_UP.to_owned(),
                turn: session.read_meta(|m| m.turn_count),
                at: crate::store::now_ms(),
                text: text.clone(),
            };
            self.apply_summary(session, summary);
            // A long recap cut to a few words loses its point: a person's turn asks the model too.
            if by_person && one_line(&recap.text) != text {
                let reply = match &recap.ask {
                    Some(ask) => format!("{}\n{ask}", recap.text),
                    None => recap.text.clone(),
                };
                session.rolling.lock().unwrap_or_else(|e| e.into_inner()).recap = Some(reply);
                self.ask_summary(session);
            }
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
                let recap = session.rolling.lock().unwrap_or_else(|e| e.into_inner()).recap.take();
                let (request, harness, turn) = session.read_meta(|m| {
                    (
                        request(
                            m.rolling_summary.as_ref(),
                            m.last_prompt.as_deref(),
                            recap.as_deref().or(m.preview.as_deref()),
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
    let summary = clean(&summary?, TEXT_CHARS).map(|s| glance(&s, WORDS))?;
    let next = next
        .and_then(|n| clean(&n, NEXT_CHARS))
        .filter(|n| !matches!(n.to_lowercase().trim_end_matches('.'), "none" | "nothing" | "n/a"))
        .map(|n| glance(&n, WORDS));
    Some((summary, next))
}

/// A wrap-up recap as a state of a few words: its first sentence with no links, no
/// parentheses and no leading "I", cut to [`RECAP_WORDS`] words.
fn condense_state(recap: &str) -> String {
    let line = one_line(&strip_asides(recap));
    let first = first_sentence(&line);
    let first = drop_first_person(first);
    let state = glance(first.trim_end_matches(['.', ',', ';', ':', ' ']), RECAP_WORDS);
    if state.is_empty() { cut(recap, TEXT_CHARS) } else { cut(&state, TEXT_CHARS) }
}

/// A wrap-up's question as the person's next action: "Should I open the PR?" reads "OK to open
/// the PR?", any other question stays a question, a few words long. None when it is empty.
fn condense_ask(ask: &str) -> Option<String> {
    let line = one_line(&strip_asides(ask));
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    const OFFERS: [&str; 9] = [
        "do you want me to ",
        "would you like me to ",
        "want me to ",
        "should i go ahead and ",
        "should i ",
        "shall i ",
        "can i ",
        "may i ",
        "should we ",
    ];
    let lower = line.to_lowercase();
    let question = line.ends_with('?');
    let offer = OFFERS
        .iter()
        .find(|o| lower.starts_with(*o))
        .and_then(|o| line.get(o.len()..))
        .map(|rest| format!("OK to {rest}"));
    // "OK to" is the affordance, not the action: it does not count against the words.
    let words = if offer.is_some() { RECAP_WORDS + 2 } else { RECAP_WORDS };
    let body = offer.unwrap_or_else(|| line.to_owned());
    let body = body.trim_end_matches(['?', '.', ' ']);
    let mut next = glance(body, words);
    if question && !next.ends_with('…') {
        next.push('?');
    }
    Some(cut(&next, NEXT_CHARS))
}

/// `text` with its links and parenthesized asides taken out.
fn strip_asides(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0usize;
    for c in text.chars() {
        match c {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace()
        .filter(|w| !w.contains("://") && !w.starts_with("www."))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The first sentence or clause of `line`: up to ". ", "; ", " - ", " — " or ": ".
fn first_sentence(line: &str) -> &str {
    let mut end = line.len();
    for stop in [". ", "; ", " — ", " - ", ": ", "! ", "? "] {
        if let Some(i) = line.find(stop) {
            end = end.min(i);
        }
    }
    line.get(..end).unwrap_or(line)
}

/// `text` without a leading "I", "I've", "We" or "I'm", its next word capitalized.
fn drop_first_person(text: &str) -> String {
    let text = text.trim();
    let lower = text.to_lowercase();
    for lead in ["i've ", "i have ", "i'm ", "i am ", "i ", "we've ", "we have ", "we "] {
        if lower.starts_with(lead)
            && let Some(rest) = text.get(lead.len()..).filter(|r| !r.is_empty())
        {
            let mut chars = rest.chars();
            return match chars.next() {
                Some(c) => c.to_uppercase().chain(chars).collect(),
                None => String::new(),
            };
        }
    }
    text.to_owned()
}

/// `text` cut to `words` words, with no dangling "on", "the" or "to" before its ellipsis.
fn glance(text: &str, words: usize) -> String {
    let all: Vec<&str> = text.split_whitespace().collect();
    if all.len() <= words {
        return all.join(" ");
    }
    let mut kept = all.get(..words).unwrap_or(&all);
    const DANGLING: [&str; 14] =
        ["a", "an", "the", "on", "to", "of", "for", "in", "and", "with", "at", "by", "or", "from"];
    while let Some((last, rest)) = kept.split_last()
        && !rest.is_empty()
        && DANGLING.contains(&last.to_lowercase().as_str())
    {
        kept = rest;
    }
    let mut out = kept.join(" ");
    out = out.trim_end_matches([',', ';', ':', '.']).to_owned();
    out.push('…');
    out
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
        let next = next.unwrap();
        assert!(next.chars().count() <= NEXT_CHARS);
        assert!(!text.contains('\n'));
        assert!(text.ends_with('…'));
        // A model that runs long still reads at a glance: a few words, not a sentence.
        assert!(text.split_whitespace().count() <= WORDS, "{text}");
        assert!(next.split_whitespace().count() <= WORDS, "{next}");
        // A summary at the limit stays whole.
        let whole = "a".repeat(TEXT_CHARS);
        assert_eq!(cut(&whole, TEXT_CHARS), whole);
    }

    #[test]
    fn leos_header_example_condenses_to_a_state_not_the_replys_first_sentence() {
        // Leo, 2026-11-22: the header read the recap's first sentence, cut mid-link.
        let recap = "I posted build-mac's 14-day permission-stall history on #7645 \
                     (https://github.com/manaflow-ai/cmux/issues/7645). The stalls cluster \
                     around auto-mode refusals; three were mine.";
        let state = condense_state(recap);
        assert_eq!(state, "Posted build-mac's 14-day permission-stall history…");
        assert!(!state.contains("http"));
        assert!(!state.starts_with("I "));
        assert!(state.split_whitespace().count() <= RECAP_WORDS);
    }

    #[test]
    fn a_short_recap_stays_whole_and_loses_only_its_i() {
        assert_eq!(condense_state("I merged the PR."), "Merged the PR");
        assert_eq!(condense_state("CI green, PR open"), "CI green, PR open");
        assert_eq!(condense_state("We've shipped it; tests pass."), "Shipped it");
        // A recap that is all aside still says something.
        assert_eq!(condense_state("(https://x.test)"), "(https://x.test)");
    }

    #[test]
    fn a_wrap_up_question_reads_as_the_persons_next_action() {
        assert_eq!(condense_ask("Should I open the PR?").as_deref(), Some("OK to open the PR?"));
        assert_eq!(
            condense_ask("Want me to merge it once CI is green?").as_deref(),
            Some("OK to merge it once CI is green?")
        );
        assert_eq!(
            condense_ask("Keep the old API or not?").as_deref(),
            Some("Keep the old API or not?")
        );
        assert_eq!(
            condense_ask("Which of the three reconnect fixes should land first?").as_deref(),
            Some("Which of the three reconnect fixes…")
        );
        assert_eq!(condense_ask("  ").as_deref(), None);
    }

    #[test]
    fn a_cut_never_ends_on_a_dangling_word() {
        assert_eq!(glance("Wrote the fix for the race in the link", 5), "Wrote the fix…");
        assert_eq!(glance("Three words only", 5), "Three words only");
    }

    #[test]
    fn the_prompt_asks_for_a_state_and_an_imperative_of_a_few_words() {
        assert!(SYSTEM.contains("at most 6 words"));
        assert!(SYSTEM.contains("imperative"));
        assert!(SYSTEM.contains("never the reply's first sentence"));
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
