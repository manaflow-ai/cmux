//! The tab state machine, pinned to what the Swift `BrowserTabStateMachine` did: the cases of
//! `BrowserMediaFramesTests`, `BrowserScrollReportTests` and `NewTabHoverPreviewTests` that drive
//! it, and every rule its doc comments state.

use crate::ops;
use crate::tab_state::*;
use serde_json::json;

const A: NavigationId = NavigationId::new(1);
const B: NavigationId = NavigationId::new(2);

fn url(text: &str) -> Option<String> {
    Some(text.to_owned())
}

fn started(id: NavigationId, to: &str) -> NavigationEvent {
    NavigationEvent::Started { id, url: url(to) }
}

fn committed(id: NavigationId, to: &str) -> NavigationEvent {
    NavigationEvent::Committed { id, url: url(to) }
}

fn finished(id: NavigationId) -> NavigationEvent {
    NavigationEvent::Finished { id }
}

fn cancelled(id: NavigationId, failing: &str) -> NavigationEvent {
    NavigationEvent::Failed {
        id,
        error: LoadError::new(
            NSURL_ERROR_DOMAIN,
            NSURL_ERROR_CANCELLED,
            "cancelled",
            Some(failing),
        ),
    }
}

fn offline(failing: &str) -> LoadError {
    LoadError::new(NSURL_ERROR_DOMAIN, -1009, "offline", Some(failing))
}

fn loaded(at: &str) -> TabStateMachine {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, at));
    machine.apply(committed(A, at));
    machine.apply(finished(A));
    machine
}

fn media(title: &str, is_playing: bool) -> MediaState {
    MediaState::new(title, is_playing)
}

fn paused() -> MediaState {
    MediaState {
        is_video: true,
        position: Some(30.0),
        duration: Some(600.0),
        ..media("Talk", false)
    }
}

fn ad() -> MediaState {
    MediaState { is_video: true, position: Some(1.0), duration: Some(15.0), ..media("Ad", true) }
}

fn media_changed(media: Option<MediaState>, frame: &str) -> NavigationEvent {
    NavigationEvent::MediaChanged { media, frame: frame.to_owned() }
}

// BrowserMediaFramesTests

#[test]
fn another_frames_null_keeps_this_frames_paused_report() {
    let mut machine = TabStateMachine::default();
    machine.apply(media_changed(Some(paused()), "main"));
    machine.apply(media_changed(Some(ad()), "ad"));
    assert_eq!(
        machine.state().media.as_ref().unwrap().title,
        "Ad",
        "what plays shows over what is paused"
    );
    machine.apply(media_changed(None, "ad"));
    assert_eq!(
        machine.state().media.as_ref().unwrap().title,
        "Talk",
        "the ad's null erased the main frame's paused video"
    );
    machine.apply(media_changed(None, "main"));
    assert_eq!(machine.state().media, None);
}

#[test]
fn the_frame_that_started_playing_last_shows_and_a_heartbeat_does_not_flip() {
    let mut frames = MediaFrames::default();
    frames.apply(Some(media("A", true)), "a");
    frames.apply(Some(media("B", true)), "b");
    assert_eq!(frames.current().unwrap().title, "B");
    // A's heartbeat (same state, later position) does not take the card back.
    let heartbeat = MediaState { position: Some(3.0), ..media("A", true) };
    assert_eq!(frames.apply(Some(heartbeat), "a").unwrap().title, "B");
    assert_eq!(frames.apply(Some(media("B", false)), "b").unwrap().title, "A");
    let floating = MediaState { is_picture_in_picture: true, ..media("B", true) };
    assert_eq!(frames.apply(Some(floating), "b").unwrap().title, "B");
}

/// Issue 38062: a frame's Web Audio (a report with no element) must not take the tab's media
/// from another frame's video, playing or paused; it lends the shown report its speaker.
#[test]
fn sound_with_no_element_never_hides_another_frames_video() {
    let sound = MediaState { is_sound_only: true, is_other_sound: true, ..media("Game", true) };
    let mut frames = MediaFrames::default();
    frames.apply(Some(MediaState { is_video: true, ..media("Talk", true) }), "main");
    assert_eq!(
        frames.apply(Some(sound.clone()), "ad").unwrap().title,
        "Talk",
        "a later Web Audio frame took the playing video's place"
    );
    let shown = frames.apply(Some(paused()), "main").unwrap();
    assert_eq!(shown.title, "Talk", "a Web Audio frame took the paused video's place");
    assert!(
        shown.is_sounding() && shown.is_other_sound,
        "the other frame's sound lost the speaker"
    );
    assert_eq!(frames.apply(None, "main"), Some(sound), "alone, the sound shows");
    assert_eq!(frames.apply(None, "ad"), None);
}

#[test]
fn a_new_document_drops_every_frames_report() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://example.com/"));
    machine.apply(committed(A, "https://example.com/"));
    machine.apply(media_changed(Some(paused()), "main"));
    machine.apply(media_changed(Some(ad()), "ad"));
    machine.apply(started(B, "https://example.org/"));
    machine.apply(committed(B, "https://example.org/"));
    assert_eq!(machine.state().media, None);
    machine.apply(media_changed(None, "new"));
    assert_eq!(machine.state().media, None, "a frame of the old document came back");
}

#[test]
fn a_heartbeat_keeps_the_earlier_media_state() {
    let earlier = MediaState { position: Some(10.0), position_date: 100.0, ..media("A", true) };
    let heartbeat = MediaState { position: Some(15.2), position_date: 105.0, ..earlier.clone() };
    assert_eq!(MediaState::settled(Some(&earlier), Some(&heartbeat)), Some(earlier.clone()));
    let seeked = MediaState { position: Some(60.0), ..heartbeat.clone() };
    assert_eq!(MediaState::settled(Some(&earlier), Some(&seeked)), Some(seeked));
    let paused = MediaState { is_playing: false, ..heartbeat };
    assert_eq!(MediaState::settled(Some(&earlier), Some(&paused)), Some(paused));
    assert_eq!(MediaState::settled(Some(&earlier), None), None);
}

#[test]
fn a_process_exit_drops_every_frames_report() {
    let mut machine = loaded("https://example.com/");
    machine.apply(media_changed(Some(paused()), "main"));
    machine.apply(NavigationEvent::ProcessExited {
        exit: ProcessExit { reason: ProcessExitReason::Crashed, code: None, engine: None },
    });
    assert_eq!(machine.state().media, None);
    machine.apply(media_changed(None, "ad"));
    assert_eq!(machine.state().media, None, "the gone page's frame came back");
}

// BrowserScrollReportTests

const TALL: &str = "http://127.0.0.1:8000/tall";
const OTHER: &str = "http://127.0.0.1:8000/other";

#[test]
fn a_settled_scroll_is_the_shown_pages_report() {
    let mut machine = loaded(TALL);
    machine.apply(NavigationEvent::PageScrolled { y: 1500.0 });
    assert_eq!(
        machine.state().scroll_report,
        Some(ScrollReport { url: TALL.to_owned(), y: 1500.0 })
    );
}

#[test]
fn another_pages_report_is_not_the_shown_pages() {
    let mut machine = loaded(TALL);
    machine.apply(NavigationEvent::PageScrolled { y: 1500.0 });
    machine.apply(NavigationEvent::UrlChanged { url: url(OTHER) });
    assert_eq!(machine.state().url.as_deref(), Some(OTHER));
    assert_eq!(machine.state().scroll_report.as_ref().unwrap().url, TALL);
}

#[test]
fn a_page_with_no_address_reports_no_scroll() {
    let mut machine = TabStateMachine::default();
    assert!(!machine.apply(NavigationEvent::PageScrolled { y: 10.0 }));
    assert_eq!(machine.state().scroll_report, None);
}

// NewTabHoverPreviewTests

/// macOS 27 CI (#20342): WebKit reports the New Tab address (the URL KVO) while the old load is
/// provisional, then the old load's cancellation, which put the committed address back.
#[test]
fn a_new_tab_load_that_cancels_an_unfinished_page_keeps_the_new_tab_address() {
    let shown = "https://example.com/";
    let old = "data:text/html,<h1>cmux</h1>";
    let blank = "about:blank";
    let mut machine = loaded(shown);
    machine.apply(started(B, old));
    machine.apply(NavigationEvent::UrlChanged { url: url(blank) });
    machine.apply(cancelled(B, old));
    assert_eq!(
        machine.state().url.as_deref(),
        Some(blank),
        "the cancelled load put the page before back"
    );
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
}

// The doc comments' rules

#[test]
fn callbacks_for_another_navigation_are_ignored() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://a.example/"));
    machine.apply(started(B, "https://b.example/"));
    let late = NavigationEvent::Failed { id: A, error: offline("https://a.example/") };
    assert!(!machine.apply(late));
    assert!(!machine.apply(committed(A, "https://a.example/")));
    assert!(!machine.apply(finished(A)));
    assert!(!machine.apply(NavigationEvent::Redirected { id: A, url: url("https://c.example/") }));
    assert_eq!(machine.state().phase, LoadPhase::Provisional {});
    assert_eq!(machine.state().active_navigation, Some(B));
    assert_eq!(machine.state().url.as_deref(), Some("https://b.example/"));
}

#[test]
fn a_start_shows_initial_progress_and_a_finish_completes_it() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://example.com/"));
    assert_eq!(machine.state().progress, INITIAL_PROGRESS);
    assert!(machine.state().is_waiting());
    machine.apply(committed(A, "https://example.com/"));
    assert!(machine.state().is_loading() && !machine.state().is_waiting());
    machine.apply(finished(A));
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
    assert_eq!(machine.state().progress, 1.0);
    assert_eq!(machine.state().active_navigation, None);
    assert!(machine.state().has_ended_load);
}

#[test]
fn progress_is_clamped_monotonic_and_ignored_when_nothing_loads() {
    let mut machine = TabStateMachine::default();
    assert!(!machine.apply(NavigationEvent::Progress { value: 0.5 }), "progress while idle");
    machine.apply(started(A, "https://example.com/"));
    machine.apply(NavigationEvent::Progress { value: 0.6 });
    assert_eq!(machine.state().progress, 0.6);
    machine.apply(NavigationEvent::Progress { value: 0.3 });
    assert_eq!(machine.state().progress, 0.6, "progress went backwards");
    machine.apply(NavigationEvent::Progress { value: 7.0 });
    assert_eq!(machine.state().progress, 1.0);
    machine.apply(NavigationEvent::Progress { value: -1.0 });
    assert_eq!(machine.state().progress, 1.0);
}

#[test]
fn a_cancelled_load_before_it_commits_reverts_the_address_without_an_error() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://example.org/"));
    machine.apply(cancelled(B, "https://example.org/"));
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/"));
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
    assert_eq!(machine.state().progress, 0.0);
    assert_eq!(machine.state().active_navigation, None);
}

#[test]
fn a_download_interruption_ends_the_load_without_an_error() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://example.com/file.zip"));
    let interrupted = LoadError::new("WebKitErrorDomain", 102, "interrupted", None);
    machine.apply(NavigationEvent::Failed { id: B, error: interrupted });
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
    assert_eq!(machine.state().load_error(), None);
}

#[test]
fn a_cancelled_first_load_goes_back_to_idle() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://example.com/"));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().url, None);
    assert_eq!(machine.state().phase, LoadPhase::Idle {});
    assert!(machine.state().has_ended_load);
}

#[test]
fn a_stop_after_commit_finishes_and_keeps_the_address() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://example.com/"));
    machine.apply(committed(A, "https://example.com/"));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/"));
    assert!(!machine.apply(NavigationEvent::Stopped {}), "a stop with nothing loading");
}

#[test]
fn a_real_failure_shows_its_error() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://down.example/"));
    machine.apply(NavigationEvent::Failed { id: B, error: offline("https://down.example/") });
    assert_eq!(machine.state().load_error(), Some(&offline("https://down.example/")));
    assert!(machine.state().phase.has_ended());
    assert_eq!(machine.state().progress, 0.0);
    assert_eq!(machine.state().active_navigation, None);
}

/// Chromium retries a network error on its own and may cancel that retry: the error page shows
/// again.
#[test]
fn a_cancelled_retry_of_the_failed_address_shows_its_error_again() {
    let down = "https://down.example/";
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, down));
    machine.apply(NavigationEvent::Failed { id: A, error: offline(down) });
    machine.apply(started(B, down));
    machine.apply(cancelled(B, down));
    assert_eq!(machine.state().load_error(), Some(&offline(down)));
}

#[test]
fn a_stop_of_a_retry_shows_the_error_again() {
    let down = "https://down.example/";
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, down));
    machine.apply(NavigationEvent::Failed { id: A, error: offline(down) });
    machine.apply(started(B, down));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().load_error(), Some(&offline(down)));
}

#[test]
fn a_cancelled_load_of_another_address_after_an_error_does_not_show_it() {
    let down = "https://down.example/";
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, down));
    machine.apply(NavigationEvent::Failed { id: A, error: offline(down) });
    machine.apply(started(B, "https://other.example/"));
    machine.apply(cancelled(B, "https://other.example/"));
    assert_eq!(machine.state().load_error(), None);
    assert_eq!(machine.state().phase, LoadPhase::Idle {});
}

#[test]
fn a_redirect_moves_the_address_and_the_loads_own_address() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://short.example/"));
    machine.apply(NavigationEvent::Redirected { id: B, url: url("https://long.example/") });
    assert_eq!(machine.state().url.as_deref(), Some("https://long.example/"));
    assert!(!machine.apply(NavigationEvent::Redirected { id: B, url: None }));
    // The redirect target is the load's own address: its cancellation is not a replacement.
    machine.apply(cancelled(B, "https://long.example/"));
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/"));
}

#[test]
fn committing_to_another_host_clears_the_favicon_and_every_commit_the_title() {
    let mut machine = loaded("https://example.com/");
    machine.apply(NavigationEvent::FaviconChanged { url: url("https://example.com/icon.png") });
    machine.apply(NavigationEvent::TitleChanged { title: Some("Example".into()) });
    machine.apply(started(B, "https://example.com/next"));
    machine.apply(committed(B, "https://example.com/next"));
    assert_eq!(machine.state().favicon_url.as_deref(), Some("https://example.com/icon.png"));
    assert_eq!(machine.state().title, None);
    machine.apply(finished(B));
    let c = NavigationId::new(3);
    machine.apply(started(c, "https://example.org/"));
    machine.apply(committed(c, "https://example.org/"));
    assert_eq!(machine.state().favicon_url, None);
}

#[test]
fn a_commit_sets_scheme_level_security() {
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://example.com/"));
    machine.apply(committed(A, "https://example.com/"));
    assert_eq!(machine.state().security, SecurityState::Secure {});
    machine.apply(started(B, "http://example.com/"));
    machine.apply(committed(B, "http://example.com/"));
    assert_eq!(machine.state().security, SecurityState::Insecure {});
}

#[test]
fn a_same_document_change_keeps_the_engines_security_and_a_new_origin_resets_it() {
    let mut machine = loaded("https://example.com/");
    machine.apply(NavigationEvent::SecurityChanged { security: SecurityState::MixedContent {} });
    machine.apply(NavigationEvent::UrlChanged { url: url("https://EXAMPLE.com/#part") });
    assert_eq!(machine.state().security, SecurityState::MixedContent {});
    machine.apply(NavigationEvent::UrlChanged { url: url("https://example.com:8443/") });
    assert_eq!(machine.state().security, SecurityState::Secure {});
    machine.apply(NavigationEvent::SecurityChanged { security: SecurityState::Dangerous {} });
    machine.apply(NavigationEvent::UrlChanged { url: url("http://example.com:8443/") });
    assert_eq!(machine.state().security, SecurityState::Insecure {});
    assert!(!machine.apply(NavigationEvent::UrlChanged { url: None }));
}

#[test]
fn a_url_change_while_provisional_is_not_the_committed_address() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://example.org/"));
    machine.apply(NavigationEvent::UrlChanged { url: url("https://example.org/") });
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/"));
}

#[test]
fn a_url_change_after_commit_is_the_committed_address() {
    let mut machine = loaded("https://example.com/");
    machine.apply(NavigationEvent::UrlChanged { url: url("https://example.com/pushed") });
    machine.apply(started(B, "https://example.org/"));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/pushed"));
}

#[test]
fn a_pending_address_shows_but_never_while_loading() {
    let mut machine = TabStateMachine::default();
    machine.apply(NavigationEvent::AddressPending { url: "https://pending.example/".into() });
    assert_eq!(machine.state().url.as_deref(), Some("https://pending.example/"));
    assert_eq!(machine.state().phase, LoadPhase::Idle {});
    assert!(!machine.state().is_loading());
    machine.apply(started(A, "https://example.com/"));
    assert!(
        !machine.apply(NavigationEvent::AddressPending { url: "https://late.example/".into() })
    );
}

#[test]
fn a_title_is_trimmed_and_a_blank_one_is_none() {
    let mut machine = TabStateMachine::default();
    machine.apply(NavigationEvent::TitleChanged { title: Some("\u{a0} Inbox \n".into()) });
    assert_eq!(machine.state().title.as_deref(), Some("Inbox"));
    machine.apply(NavigationEvent::TitleChanged { title: Some(" \t\u{2028}".into()) });
    assert_eq!(machine.state().title, None);
    machine.apply(NavigationEvent::TitleChanged { title: Some("x".into()) });
    machine.apply(NavigationEvent::TitleChanged { title: None });
    assert_eq!(machine.state().title, None);
}

#[test]
fn history_zoom_fullscreen_and_mute_are_taken_as_reported() {
    let mut machine = TabStateMachine::default();
    machine.apply(NavigationEvent::HistoryChanged { can_go_back: true, can_go_forward: false });
    machine
        .apply(NavigationEvent::HistoryListed { back: vec!["https://a/".into()], forward: vec![] });
    machine.apply(NavigationEvent::ContentFullscreenChanged { on: true });
    machine.apply(NavigationEvent::AudioMutedChanged { muted: true });
    let state = machine.state();
    assert!(state.can_go_back && !state.can_go_forward);
    assert_eq!(state.back_urls, Some(vec!["https://a/".to_owned()]));
    assert_eq!(state.forward_urls, Some(vec![]));
    assert!(state.is_content_fullscreen && state.is_audio_muted);
    for (zoom, clamped) in
        [(1.5, 1.5), (0.1, 0.25), (9.0, 5.0), (f64::NAN, 1.0), (f64::INFINITY, 1.0)]
    {
        machine.apply(NavigationEvent::ZoomChanged { zoom });
        assert_eq!(machine.state().zoom, clamped, "{zoom}");
    }
}

#[test]
fn a_process_exit_ends_the_load_keeps_the_address_and_is_never_unresponsive() {
    let mut machine = loaded("https://example.com/");
    machine.apply(started(B, "https://example.org/"));
    machine.apply(NavigationEvent::UnresponsiveChanged { unresponsive: true });
    assert!(machine.state().is_unresponsive);
    let exit = ProcessExit {
        reason: ProcessExitReason::Killed,
        code: Some(9),
        engine: Some(EngineKind::Cef),
    };
    machine.apply(NavigationEvent::ProcessExited { exit });
    let state = machine.state();
    assert_eq!(state.process_exit, Some(exit));
    assert!(!state.is_unresponsive);
    assert_eq!(
        state.url.as_deref(),
        Some("https://example.org/"),
        "Reload opens what was asked for"
    );
    assert_eq!(state.phase, LoadPhase::Finished {});
    assert_eq!(state.progress, 0.0);
    assert_eq!(state.active_navigation, None);
    assert!(state.has_ended_load);
    assert!(!machine.apply(NavigationEvent::UnresponsiveChanged { unresponsive: true }));
    // The next navigation (Reload) clears it.
    machine.apply(started(NavigationId::new(3), "https://example.org/"));
    assert_eq!(machine.state().process_exit, None);
}

#[test]
fn a_process_exit_with_no_address_is_idle_and_a_failed_page_is_finished() {
    let exit = ProcessExit { reason: ProcessExitReason::Crashed, code: None, engine: None };
    let mut machine = TabStateMachine::default();
    machine.apply(NavigationEvent::ProcessExited { exit });
    assert_eq!(machine.state().phase, LoadPhase::Idle {});
    let mut machine = TabStateMachine::default();
    machine.apply(started(A, "https://down.example/"));
    machine.apply(NavigationEvent::Failed { id: A, error: offline("https://down.example/") });
    machine.apply(NavigationEvent::ProcessExited { exit });
    assert_eq!(machine.state().phase, LoadPhase::Finished {});
}

#[test]
fn apply_reports_whether_the_state_changed() {
    let mut machine = TabStateMachine::default();
    assert!(machine.apply(NavigationEvent::TitleChanged { title: Some("A".into()) }));
    assert!(!machine.apply(NavigationEvent::TitleChanged { title: Some("A".into()) }));
}

#[test]
fn a_machine_made_from_a_shown_page_reverts_a_stopped_load_to_it() {
    let shown = TabState {
        url: url("https://example.com/"),
        phase: LoadPhase::Finished {},
        ..TabState::default()
    };
    let mut machine = TabStateMachine::new(shown);
    machine.apply(started(A, "https://example.org/"));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().url.as_deref(), Some("https://example.com/"));
    // An idle state's address is not a committed one.
    let idle = TabState { url: url("https://example.com/"), ..TabState::default() };
    let mut machine = TabStateMachine::new(idle);
    machine.apply(started(A, "https://example.org/"));
    machine.apply(NavigationEvent::Stopped {});
    assert_eq!(machine.state().url, None);
}

#[test]
fn security_is_the_schemes_and_the_engines_refinement() {
    for (address, level) in [
        (Some("HTTPS://example.com/"), SecurityState::Secure {}),
        (Some("http://example.com/"), SecurityState::Insecure {}),
        (Some("file:///tmp/a.html"), SecurityState::Local {}),
        (Some("about:blank"), SecurityState::Local {}),
        (Some("data:text/plain,hi"), SecurityState::Local {}),
        (Some("blob:https://example.com/1"), SecurityState::Local {}),
        (Some("chrome://settings"), SecurityState::None {}),
        (None, SecurityState::None {}),
    ] {
        assert_eq!(security(address), level, "{address:?}");
    }
    let https = Some("https://example.com/");
    assert_eq!(committed_security(https, true, false), SecurityState::Secure {});
    assert_eq!(committed_security(https, false, false), SecurityState::MixedContent {});
    assert_eq!(committed_security(https, true, true), SecurityState::Broken {});
    assert_eq!(committed_security(Some("http://a/"), false, true), SecurityState::Insecure {});
}

#[test]
fn same_origin_reads_scheme_host_and_port() {
    assert!(same_origin(Some("https://Example.com/a"), Some("HTTPS://example.COM/b#c")));
    assert!(!same_origin(Some("https://example.com/"), Some("http://example.com/")));
    assert!(!same_origin(Some("https://example.com/"), Some("https://example.com:443/")));
    assert!(same_origin(Some("https://u:p@[::1]:8080/"), Some("https://[::1]:8080/x")));
    assert!(same_origin(Some("about:blank"), Some("about:srcdoc")));
    assert!(!same_origin(None, Some("https://example.com/")));
}

#[test]
fn url_parts_split_an_absolute_url() {
    let parts = UrlParts::of("https://user@Example.com:8080/path?q#f");
    assert_eq!(parts.scheme, Some("https"));
    assert_eq!(parts.host, Some("Example.com"));
    assert_eq!(parts.port, Some(8080));
    assert_eq!(UrlParts::of("http://[::1]/").host, Some("::1"));
    assert_eq!(UrlParts::of("http://a:/").port, None);
    assert_eq!(UrlParts::of("file:///tmp").host, None);
    assert_eq!(UrlParts::of("data:text/html,<h1>").host, None);
    assert_eq!(UrlParts::of("no scheme").scheme, None);
}

// The wire

#[test]
fn events_and_state_take_swifts_codable_shape() {
    let events = json!([
        {"started": {"_0": {"rawValue": 1}, "url": "https://example.com/"}},
        {"progress": {"_0": 0.5}},
        {"committed": {"_0": {"rawValue": 1}}},
        {"historyChanged": {"canGoBack": true, "canGoForward": false}},
        {"mediaChanged": {"_0": {"title": "Talk", "isPlaying": true, "actions": ["play", "nexttrack"]},
                          "frame": "main"}},
        {"securityChanged": {"_0": {"mixedContent": {}}}},
        {"stopped": {}},
    ]);
    let events: Vec<NavigationEvent> = serde_json::from_value(events).unwrap();
    assert_eq!(events[2], NavigationEvent::Committed { id: A, url: None });
    let mut machine = TabStateMachine::default();
    for event in events {
        machine.apply(event);
    }
    let state = serde_json::to_value(machine.state()).unwrap();
    assert_eq!(state["url"], "https://example.com/");
    assert_eq!(state["phase"], json!({"finished": {}}));
    assert_eq!(state["security"], json!({"mixedContent": {}}));
    assert_eq!(state["canGoBack"], true);
    assert_eq!(state["hasEndedLoad"], true);
    assert_eq!(state["media"]["actions"], json!(["play", "nexttrack"]));
    assert!(state.get("activeNavigation").is_none(), "a nil optional is left out");

    let failed = NavigationEvent::Failed { id: B, error: offline("https://down.example/") };
    assert_eq!(
        serde_json::to_value(&failed).unwrap(),
        json!({"failed": {"_0": {"rawValue": 2}, "_1": {"domain": "NSURLErrorDomain", "code": -1009,
                 "message": "offline", "failingURL": "https://down.example/", "engineShowsPage": false}}})
    );
    let exit = json!({"processExited": {"_0": {"reason": "outOfMemory", "engine": "cef"}}});
    let exit: NavigationEvent = serde_json::from_value(exit).unwrap();
    assert_eq!(
        exit,
        NavigationEvent::ProcessExited {
            exit: ProcessExit {
                reason: ProcessExitReason::OutOfMemory,
                code: None,
                engine: Some(EngineKind::Cef)
            }
        }
    );
}

#[test]
fn a_machine_round_trips_with_its_private_state() {
    let mut machine = loaded("https://example.com/");
    machine.apply(media_changed(Some(paused()), "main"));
    machine.apply(started(B, "https://example.org/"));
    let wire = serde_json::to_value(&machine).unwrap();
    assert_eq!(wire["committedURL"], "https://example.com/");
    assert_eq!(wire["startedURL"], "https://example.org/");
    let mut back: TabStateMachine = serde_json::from_value(wire).unwrap();
    assert_eq!(back, machine);
    back.apply(NavigationEvent::Stopped {});
    assert_eq!(back.state().url.as_deref(), Some("https://example.com/"));
}

#[test]
fn the_ops_make_and_drive_a_machine() {
    let machine = ops::call("browser_rules_tab_state_new", json!({})).unwrap();
    assert_eq!(machine["state"]["phase"], json!({"idle": {}}));
    let reply = ops::call(
        "browser_rules_tab_state_apply",
        json!({"machine": machine, "events": [
            {"started": {"_0": {"rawValue": 1}, "url": "https://example.com/"}},
            {"committed": {"_0": {"rawValue": 1}}},
            {"finished": {"_0": {"rawValue": 1}}},
        ]}),
    )
    .unwrap();
    assert_eq!(reply["changed"], true);
    assert_eq!(reply["machine"]["state"]["security"], json!({"secure": {}}));
    let again = ops::call(
        "browser_rules_tab_state_apply",
        json!({"machine": reply["machine"], "event": {"finished": {"_0": {"rawValue": 1}}}}),
    )
    .unwrap();
    assert_eq!(again["changed"], false, "a finished navigation's late callback");
    assert_eq!(
        ops::call("browser_rules_tab_state_security", json!({"url": "file:///a"})).unwrap(),
        json!({"local": {}})
    );
    assert_eq!(
        ops::call(
            "browser_rules_tab_state_committed_security",
            json!({"url": "https://a/", "hasOnlySecureContent": true, "certificateBypassed": true})
        )
        .unwrap(),
        json!({"broken": {}})
    );
    assert!(ops::call("browser_rules_tab_state_apply", json!({})).is_err());
    assert!(ops::call("browser_rules_tab_state_apply", json!({"event": {"wave": {}}})).is_err());
}
