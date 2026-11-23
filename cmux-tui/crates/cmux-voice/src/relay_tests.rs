//! The iPhone's `AgentVoiceSessionTests` and `AgentVoiceSessionRecoveryTests`, case by case, plus
//! the cascade's own barge-in.

use super::*;

fn read(text: &str) -> Effect {
    Effect::Read(text.into())
}
fn prompt(text: &str) -> Effect {
    Effect::Prompt(text.into())
}
fn text(t: &str) -> Event {
    Event::AgentText(t.into())
}
fn started(item: &str) -> Event {
    Event::SpeechStarted { item: Some(item.into()) }
}
fn done(item: &str, said: &str) -> Event {
    Event::UserDone { item: item.into(), text: said.into() }
}
const COMPLETED: Event = Event::ReadingDone { cancelled: false };
const CANCELLED: Event = Event::ReadingDone { cancelled: true };

fn live(transport: Transport) -> Relay {
    let mut r = Relay::new(transport);
    assert_eq!(r.apply(Event::Connected), vec![Effect::Microphone(true)]);
    assert!(r.is_live());
    r
}

/// Every reading asked for, across a run of events.
fn readings(r: &mut Relay, events: impl IntoIterator<Item = Event>) -> Vec<Effect> {
    events.into_iter().flat_map(|e| r.apply(e)).collect()
}

#[test]
fn agent_words_are_read_verbatim() {
    let mut r = live(Transport::Realtime);
    assert_eq!(r.apply(text("All 43 tests pass.")), vec![read("All 43 tests pass.")]);
}

#[test]
fn readings_queue_in_order_one_at_a_time() {
    let mut r = live(Transport::Realtime);
    assert_eq!(r.apply(text("First.")), vec![read("First.")]);
    assert!(r.apply(text("Second.")).is_empty());
    assert!(r.apply(text("Third.")).is_empty());
    assert_eq!(r.apply(COMPLETED), vec![read("Second.\n\nThird.")]);
}

#[test]
fn nothing_is_read_over_the_person() {
    let mut r = live(Transport::Realtime);
    assert!(r.apply(started("u1")).is_empty());
    assert!(r.apply(text("The build finished.")).is_empty());
    assert_eq!(r.apply(Event::SpeechStopped), vec![read("The build finished.")]);
}

#[test]
fn what_the_person_says_goes_to_the_agent() {
    let mut r = live(Transport::Realtime);
    let out = readings(
        &mut r,
        [
            started("u1"),
            Event::UserDelta { item: "u1".into(), text: "Run the".into() },
            done("u1", "Run the tests again."),
        ],
    );
    assert_eq!(out, vec![prompt("Run the tests again.")]);
    assert_eq!(
        r.lines().last(),
        Some(&Line {
            id: "u1".into(),
            role: Role::You,
            text: "Run the tests again.".into(),
            is_final: true
        })
    );
}

#[test]
fn a_refused_reading_is_said_again() {
    let mut r = live(Transport::Realtime);
    r.apply(text("Needs your permission: Run make."));
    assert!(r.apply(Event::ReadingRefused(Refusal::Busy)).is_empty());
    assert_eq!(r.apply(COMPLETED), vec![read("Needs your permission: Run make.")]);
}

#[test]
fn skip_stops_the_voice_and_drops_the_queue() {
    let mut r = live(Transport::Realtime);
    r.apply(text("One."));
    r.apply(text("Two."));
    assert_eq!(r.apply(Event::Skip), vec![Effect::CancelReading, Effect::ClearOutput]);
    assert!(r.apply(CANCELLED).is_empty());
}

#[test]
fn ending_reports_once() {
    let mut r = live(Transport::Realtime);
    assert_eq!(r.apply(Event::End), vec![Effect::End(None)]);
    assert!(r.apply(Event::End).is_empty());
    assert!(r.apply(text("Too late.")).is_empty());
    assert_eq!(r.phase(), &Phase::Ended(None));
}

#[test]
fn a_dropped_connection_ends_offline() {
    let mut r = live(Transport::Realtime);
    let out = r.apply(Event::Closed);
    assert!(matches!(&out[..], [Effect::End(Some(e))] if e.code == ErrorCode::Offline));
}

#[test]
fn text_relayed_while_connecting_is_read_once_live() {
    let mut r = Relay::new(Transport::Realtime);
    assert!(r.apply(text("Early words.")).is_empty());
    assert_eq!(r.apply(Event::Connected), vec![Effect::Microphone(true), read("Early words.")]);
}

#[test]
fn noise_is_never_sent_as_a_prompt() {
    let mut r = live(Transport::Realtime);
    let mut out = Vec::new();
    for (i, noise) in ["Thank you.", "  ", "Bye!", "Hmm…", "you"].iter().enumerate() {
        out.extend(r.apply(done(&format!("n{i}"), noise)));
    }
    out.extend(r.apply(done("u1", "Yes, go ahead.")));
    assert_eq!(out, vec![prompt("Yes, go ahead.")]);
    assert_eq!(r.lines().iter().map(|l| l.id.as_str()).collect::<Vec<_>>(), ["u1"]);
}

#[test]
fn a_reading_refused_for_another_reason_does_not_stall_voice_mode() {
    let mut r = live(Transport::Realtime);
    r.apply(text("First."));
    r.apply(text("Second."));
    // Retried once, with what was queued behind it.
    assert_eq!(r.apply(Event::ReadingRefused(Refusal::Other)), vec![read("First.\n\nSecond.")]);
    // Refused again: dropped, and voice mode goes on with what comes next.
    assert!(r.apply(Event::ReadingRefused(Refusal::Other)).is_empty());
    assert_eq!(r.apply(text("Third.")), vec![read("Third.")]);
}

#[test]
fn a_reading_cut_off_by_noise_is_said_again() {
    let mut r = live(Transport::Realtime);
    r.apply(text("Needs your permission: Run make."));
    let out = readings(
        &mut r,
        [Event::ReadingStarted, started("c1"), CANCELLED, Event::SpeechStopped, done("c1", "Hmm.")],
    );
    assert_eq!(out, vec![read("Needs your permission: Run make.")]);
}

#[test]
fn a_reading_cut_off_by_a_real_prompt_is_not_repeated() {
    let mut r = live(Transport::Realtime);
    r.apply(text("Here is a long answer."));
    let out = readings(
        &mut r,
        [
            Event::ReadingStarted,
            started("u1"),
            CANCELLED,
            Event::SpeechStopped,
            done("u1", "Stop, do the other thing."),
        ],
    );
    assert_eq!(out, vec![prompt("Stop, do the other thing.")]);
}

#[test]
fn a_failed_transcript_resumes_an_interrupted_reading() {
    let mut r = live(Transport::Realtime);
    r.apply(text("Kept."));
    let out = readings(
        &mut r,
        [
            Event::ReadingStarted,
            started("c1"),
            CANCELLED,
            Event::SpeechStopped,
            Event::UserFailed { item: "c1".into() },
        ],
    );
    assert_eq!(out, vec![read("Kept.")]);
    assert!(r.lines().is_empty());
}

#[test]
fn realtime_leaves_barge_in_to_the_server() {
    let mut r = live(Transport::Realtime);
    r.apply(text("Long."));
    r.apply(Event::ReadingStarted);
    assert!(r.apply(started("u1")).is_empty());
}

#[test]
fn the_cascade_cancels_the_reading_when_the_person_speaks() {
    let mut r = live(Transport::Cascade);
    r.apply(text("Long."));
    // Not playing yet: nothing to cut.
    assert!(r.apply(Event::SpeechStarted { item: None }).is_empty());
    r.apply(Event::SpeechStopped);
    r.apply(Event::ReadingStarted);
    assert_eq!(
        r.apply(Event::SpeechStarted { item: None }),
        vec![Effect::CancelReading, Effect::ClearOutput]
    );
    // The engine reports the cut; a real prompt drops the rest.
    assert!(r.apply(CANCELLED).is_empty());
    assert_eq!(r.apply(done("u1", "Never mind.")), vec![prompt("Never mind.")]);
    assert!(!r.user_speaking());
}

#[test]
fn the_cascade_resumes_after_a_cough() {
    let mut r = live(Transport::Cascade);
    r.apply(text("Read me."));
    r.apply(Event::ReadingStarted);
    r.apply(Event::SpeechStarted { item: None });
    r.apply(CANCELLED);
    r.apply(Event::SpeechStopped);
    assert_eq!(r.apply(done("c1", "um")), vec![read("Read me.")]);
}

#[test]
fn a_cascade_transcript_without_a_stop_still_frees_the_reading() {
    let mut r = live(Transport::Cascade);
    r.apply(Event::SpeechStarted { item: None });
    assert!(r.apply(text("Queued.")).is_empty());
    assert_eq!(r.apply(done("u1", "Go on.")), vec![prompt("Go on."), read("Queued.")]);
}

#[test]
fn mute_turns_the_microphone_off_and_holds_across_connecting() {
    let mut r = Relay::new(Transport::Cascade);
    assert!(r.apply(Event::SetMuted(true)).is_empty());
    assert_eq!(r.apply(Event::Connected), vec![Effect::Microphone(false)]);
    assert_eq!(r.apply(Event::SetMuted(false)), vec![Effect::Microphone(true)]);
}

#[test]
fn captions_keep_the_recent_past_and_finalize_on_reading_end() {
    let mut r = live(Transport::Realtime);
    for i in 0..(MAX_LINES + 5) {
        r.apply(done(&format!("u{i}"), "Do the thing."));
    }
    assert_eq!(r.lines().len(), MAX_LINES);
    r.apply(text("Ok."));
    r.apply(Event::AgentCaptionDelta { item: "a1".into(), text: "O".into() });
    assert_eq!(r.lines().last().map(|l| l.is_final), Some(false));
    r.apply(COMPLETED);
    assert_eq!(r.lines().last().map(|l| (l.role, l.is_final)), Some((Role::Agent, true)));
}

#[test]
fn a_failure_ends_with_it_and_drops_empty_captions() {
    let mut r = live(Transport::Realtime);
    r.apply(started("u1"));
    let err = VoiceError::bare(ErrorCode::KeyInvalid);
    assert_eq!(r.apply(Event::Failed(err.clone())), vec![Effect::End(Some(err))]);
    assert!(r.lines().is_empty());
    assert!(!r.user_speaking());
}
