//! Parity tests for the toast rules, ported value for value from the Swift suites
//! (CmuxToastDetailCopyTests, PlainErrorText cases, CmuxToastQuietTests, CmuxToastOneWindowTests,
//! CmuxToastNeverShowTests, CmuxToastUndoKeyTests, CmuxToastStyleTests), plus the C ABI.

use cmux_design_core::ffi::*;
use cmux_design_core::toast::*;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::ffi::CString;
use std::ptr::null_mut;

fn call(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxDesignBytes { ptr: null_mut(), len: 0 };
    let status =
        unsafe { cmux_design_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_DESIGN_OK {
        return (status, None);
    }
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    unsafe { cmux_design_bytes_free(out) };
    (status, value)
}

fn ok(op: &str, request: Value) -> Value {
    let (status, value) = call(op, &request.to_string());
    assert_eq!(status, CMUX_DESIGN_OK, "{op} {request}");
    value.expect("reply")
}

// MARK: Detail copy

#[test]
fn a_no_space_detail_reads_in_plain_words_with_its_code() {
    let copy = DetailCopy::plain(
        "cannot copy the build to the machine: fs.no_space: no space left on the device",
    );
    assert_eq!(copy.text, "The machine is out of disk space.");
    assert_eq!(copy.code.as_deref(), Some("fs.no_space"));
    assert_eq!(DetailCopy::code_line("fs.no_space"), "Error code: fs.no_space");
}

#[test]
fn every_mapped_code_has_words() {
    for code in MAPPED_CODES {
        let copy = DetailCopy::plain(&format!("push failed: {code}."));
        assert_eq!(copy.code.as_deref(), Some(code), "{code}");
        assert_eq!(Some(copy.text.as_str()), DetailCopy::words(code), "{code}");
        assert_ne!(copy.text, FILE_FAILED, "{code}");
    }
}

#[test]
fn unknown_and_raw_details_stay_as_they_are() {
    for detail in [
        "Bootstrap failed: 125: Domain does not support specified action",
        "acpmux exited without a status",
        "",
    ] {
        assert_eq!(DetailCopy::plain(detail), DetailCopy::raw(detail), "{detail}");
    }
}

#[test]
fn an_unknown_fs_code_is_a_file_failure() {
    let copy = DetailCopy::plain("the machine answered fs.something_new: who knows");
    assert_eq!(copy.text, FILE_FAILED);
    assert_eq!(copy.code.as_deref(), Some("fs.something_new"));
}

#[test]
fn a_detail_of_several_lines_stays_raw() {
    let detail = "fs.no_space\nsecond line";
    assert_eq!(DetailCopy::plain(detail), DetailCopy::raw(detail));
}

#[test]
fn detail_copy_through_the_c_abi() {
    let reply = ok("toast.detailCopy", json!({"detail": "push failed: fs.read_only."}));
    assert_eq!(reply, json!({"text": "The machine's disk is read-only.", "code": "fs.read_only"}));
    assert_eq!(ok("toast.detailCodeLine", json!({"code": "fs.io"})), json!("Error code: fs.io"));
    assert_eq!(ok("toast.detailWords", json!({"code": "nope"})), Value::Null);
}

// MARK: Plain error text

fn err(domain: &str, code: i64) -> ErrorChain {
    ErrorChain::new(domain, code)
}

#[test]
fn system_errors_read_as_one_sentence() {
    use PlainErrorKind::*;
    let cases = [
        (URL_DOMAIN, -1009, Offline),
        (URL_DOMAIN, -1005, Offline),
        (URL_DOMAIN, -1001, TimedOut),
        (URL_DOMAIN, -1004, Unreachable),
        (URL_DOMAIN, -1003, Unreachable),
        (URL_DOMAIN, -1006, Unreachable),
        (URL_DOMAIN, -1200, SecureConnection),
        (POSIX_DOMAIN, 28, NoSpace),
        (POSIX_DOMAIN, 13, Permission),
        (POSIX_DOMAIN, 30, ReadOnly),
        (POSIX_DOMAIN, 17, Exists),
        (COCOA_DOMAIN, 640, NoSpace),
        (COCOA_DOMAIN, 642, ReadOnly),
        (COCOA_DOMAIN, 4, NotFound),
    ];
    for (domain, code, kind) in cases {
        let error = err(domain, code);
        assert_eq!(PlainErrorText::kind(&error), Some(kind), "{domain} {code}");
        assert_eq!(PlainErrorText::text(&error), PlainErrorText::words_for(kind));
    }
    assert_eq!(
        PlainErrorText::text(&err(URL_DOMAIN, -1009)),
        "You're offline. Check your network, then try again."
    );
}

#[test]
fn a_wrapped_error_reads_as_what_it_wraps() {
    let mut outer = err(COCOA_DOMAIN, 512);
    outer.underlying = Some(Box::new(err(POSIX_DOMAIN, 28)));
    assert_eq!(PlainErrorText::kind(&outer), Some(PlainErrorKind::NoSpace));
    assert_eq!(PlainErrorText::text(&outer), "The disk is full. Free some space, then try again.");
}

#[test]
fn an_unknown_error_is_the_generic_line() {
    let sparkle = err("SUSparkleErrorDomain", 1001);
    assert_eq!(PlainErrorText::kind(&sparkle), None);
    assert_eq!(PlainErrorText::text(&sparkle), GENERIC);
    let mut described = sparkle;
    described.description = Some("The update feed is empty.".into());
    assert_eq!(PlainErrorText::personal(&described), "The update feed is empty.");
    let mut system = err(URL_DOMAIN, 1);
    system.description = Some("raw system text".into());
    assert_eq!(PlainErrorText::personal(&system), GENERIC);
}

#[test]
fn plain_error_through_the_c_abi() {
    let error = json!({"domain": COCOA_DOMAIN, "code": 512,
        "underlying": {"domain": POSIX_DOMAIN, "code": 28}});
    assert_eq!(ok("toast.errorKind", json!({"error": error})), json!("noSpace"));
    assert_eq!(ok("toast.errorText", json!({"error": {"domain": "X", "code": 1}})), json!(GENERIC));
}

// MARK: Center harness

/// The center plus the serials that finished, as the Swift handles see them.
struct Center {
    center: ToastCenter,
    finished: Vec<(i64, DismissReason)>,
    rendered: Vec<Vec<ToastShown>>,
    now_ms: f64,
}

impl Center {
    fn new() -> Self {
        Self { center: ToastCenter::default(), finished: vec![], rendered: vec![], now_ms: 0.0 }
    }

    fn send(&mut self, event: CenterEvent) -> Vec<CenterEffect> {
        let effects = self.center.handle(event);
        for effect in &effects {
            match effect {
                CenterEffect::Finished { serial, reason } => self.finished.push((*serial, *reason)),
                CenterEffect::Render { shown, .. } => self.rendered.push(shown.clone()),
                _ => {}
            }
        }
        effects
    }

    fn show(&mut self, toast: Toast, window: &str) -> i64 {
        let serial = self.center.next_serial;
        self.send(CenterEvent::Show { toast, window: window.into(), now_ms: self.now_ms });
        serial
    }

    fn dismissed(&self, serial: i64) -> bool {
        self.finished.iter().any(|(s, _)| *s == serial)
    }

    fn close(&mut self, serial: i64) {
        self.send(CenterEvent::PersonClosed { serial, now_ms: self.now_ms });
    }

    fn dismiss(&mut self, serial: i64) {
        self.send(CenterEvent::Dismiss { serial });
    }

    fn messages(&self, window: &str) -> Vec<String> {
        self.center.toasts(window).into_iter().map(|t| t.message).collect()
    }

    fn quiet(&self, toast: &Toast) -> bool {
        self.center.is_quieted(toast, self.now_ms)
    }
}

fn toast(id: &str, message: &str) -> Toast {
    Toast::new(id, message)
}

fn with_action(mut t: Toast, action: ToastAction) -> Toast {
    t.action = Some(action);
    t
}

fn working(id: &str, message: &str, one_window: bool) -> Toast {
    let mut t = toast(id, message);
    t.duration = Some(UNTIL_CLOSED);
    t.one_window = one_window;
    t.working = true;
    t
}

fn until_closed(id: &str, message: &str, one_window: bool) -> Toast {
    let mut t = toast(id, message);
    t.duration = Some(UNTIL_CLOSED);
    t.one_window = one_window;
    t
}

// MARK: Quiet

#[test]
fn a_closed_notice_does_not_come_back_at_once() {
    let mut c = Center::new();
    let notice = toast(REFUSAL_ID, "The agent chat column holds only agent chats.");
    let first = c.show(notice.clone(), "w");
    c.close(first);
    assert!(c.center.toasts("w").is_empty());
    let again = c.show(notice.clone(), "w");
    assert!(c.dismissed(again));
    assert_eq!(c.finished.last(), Some(&(again, DismissReason::Closed)));
    assert!(c.center.toasts("w").is_empty());
    let shown: HashSet<i64> = c.rendered.iter().flatten().map(|s| s.serial).collect();
    assert_eq!(shown.len(), 1, "the quiet notice showed a second toast");
    assert!(c.quiet(&notice));
}

#[test]
fn another_message_still_shows() {
    let mut c = Center::new();
    let first = c.show(toast(REFUSAL_ID, "Not enough room to split this column"), "w");
    c.close(first);
    let other = c.show(toast(REFUSAL_ID, "Can\u{2019}t close the last tab"), "w");
    assert!(!c.dismissed(other));
    assert_eq!(c.messages("w"), ["Can\u{2019}t close the last tab"]);
}

#[test]
fn another_detail_still_shows() {
    let mut c = Center::new();
    let mut first = toast("home.stopAllAgents", "1 could not be stopped");
    first.detail = Some("a2: refused".into());
    let serial = c.show(first.clone(), "w");
    c.close(serial);
    assert!(c.quiet(&first));
    let mut other = first;
    other.detail = Some("a4: refused".into());
    let other = c.show(other, "w");
    assert!(!c.dismissed(other));
}

#[test]
fn a_toast_with_an_action_is_never_quieted() {
    let mut c = Center::new();
    let undo = with_action(toast("tab-closed", "Closed \u{201C}zsh\u{201D}"), ToastAction::undo());
    let first = c.show(undo.clone(), "w");
    c.close(first);
    let again = c.show(undo, "w");
    assert!(!c.dismissed(again));
    assert_eq!(c.center.toasts("w").len(), 1);
}

#[test]
fn only_the_persons_close_quiets() {
    let mut c = Center::new();
    let notice = toast("saved", "Saved");
    let first = c.show(notice.clone(), "w");
    c.dismiss(first);
    let again = c.show(notice.clone(), "w");
    assert!(!c.dismissed(again));
    assert!(!c.quiet(&notice));
}

#[test]
fn the_quiet_ends_after_the_cooldown() {
    let mut c = Center::new();
    c.center.closed_cooldown = 0.05;
    let notice = toast(REFUSAL_ID, "No pane to the left");
    let first = c.show(notice.clone(), "w");
    c.close(first);
    assert!(c.quiet(&notice));
    c.now_ms += 49.0;
    assert!(c.quiet(&notice));
    c.now_ms += 1.0;
    assert!(!c.quiet(&notice));
    let again = c.show(notice, "w");
    assert!(!c.dismissed(again));
    // The default cooldown is two minutes.
    assert_eq!(ToastCenter::default().closed_cooldown, 120.0);
}

#[test]
fn a_closed_working_toast_stays_closed_until_its_result() {
    let mut c = Center::new();
    let first = c.show(
        working(
            "cloud-move-t1",
            "Moving to Cloud\u{2026}\n1 of 4 \u{00B7} Connecting to dev \u{00B7} about 35 s left",
            true,
        ),
        "w",
    );
    c.close(first);
    let shown = c.rendered.iter().flatten().map(|s| s.serial).collect::<HashSet<_>>().len();
    for line in ["2 of 4 \u{00B7} Copying files", "3 of 4 \u{00B7} Starting the agent"] {
        let s = c
            .show(working("cloud-move-t1", &format!("Moving to Cloud\u{2026}\n{line}"), true), "w");
        assert!(c.dismissed(s));
    }
    let update = c.show(working("cloud-move-t1", "Updating dev\u{2026}", true), "w");
    assert!(c.dismissed(update), "a machine update's toast is the same run's");
    let now = c.rendered.iter().flatten().map(|s| s.serial).collect::<HashSet<_>>().len();
    assert!(c.center.toasts("w").is_empty() && now == shown, "a closed working toast came back");
    let other = c.show(working("cloud-move-t2", "Moving to Cloud\u{2026}", false), "w");
    assert!(!c.dismissed(other), "another run's working toast shows");
    let mut result = toast("cloud-move-t1", "Moved to dev");
    result.one_window = true;
    let result = c.show(result, "w");
    assert!(!c.dismissed(result), "the result shows after its working toast was closed");
    let next = c.show(working("cloud-move-t1", "Moving to Cloud\u{2026}", true), "w");
    assert!(!c.dismissed(next), "the next run's working toast shows, even with the same headline");
}

#[test]
fn a_working_toasts_quiet_ends_with_its_run() {
    let mut c = Center::new();
    let run = working("cloud-bring-back-t1", "Bringing back\u{2026}", false);
    let first = c.show(run.clone(), "w");
    c.close(first);
    let failure = with_action(
        toast("cloud-bring-back-t1", "Couldn't copy the folder"),
        ToastAction::new("Retry"),
    );
    let failure = c.show(failure, "w");
    assert!(!c.dismissed(failure));
    assert!(!c.quiet(&run));
    let second = c.show(run.clone(), "w");
    c.close(second);
    assert!(c.quiet(&run));
    c.send(CenterEvent::Close { id: "cloud-bring-back-t1".into() });
    assert!(!c.quiet(&run));
    let third = c.show(run.clone(), "w");
    c.dismiss(third);
    assert!(!c.quiet(&run), "only the person's close quiets");
}

#[test]
fn a_zero_cooldown_never_quiets() {
    let mut c = Center::new();
    c.center.closed_cooldown = 0.0;
    let notice = toast(REFUSAL_ID, "No pane to the left");
    let first = c.show(notice.clone(), "w");
    c.close(first);
    assert!(!c.quiet(&notice));
    let again = c.show(notice, "w");
    assert!(!c.dismissed(again));
}

// MARK: One window

#[test]
fn a_one_window_toast_in_another_window_ends_the_one_left_behind() {
    let mut c = Center::new();
    let working = c.show(until_closed("cloud-move-t1", "Moving", true), "first");
    let other = c.show(until_closed("cloud-move-t2", "Moving", true), "first");
    let mut result = toast("cloud-move-t1", "Moved");
    result.one_window = true;
    c.show(result, "second");
    assert!(c.dismissed(working), "the working toast stayed in the window the person left");
    assert!(c.finished.contains(&(working, DismissReason::Replaced)));
    assert!(!c.dismissed(other), "another run's toast ended");
    assert_eq!(c.messages("first"), ["Moving"]);
    assert_eq!(c.messages("second"), ["Moved"]);
}

#[test]
fn a_quiet_result_still_ends_the_working_toast() {
    let mut c = Center::new();
    let mut failure = toast("cloud-start-t4", "Couldn't copy the folder");
    failure.duration = Some(12.0);
    failure.one_window = true;
    let first = c.show(failure.clone(), "w");
    c.close(first);
    assert!(c.quiet(&failure));
    let working = c.show(until_closed("cloud-start-t4", "Moving", true), "w");
    let again = c.show(failure, "w");
    assert!(c.dismissed(again));
    assert!(c.dismissed(working), "the working toast stayed up after a quiet result");
    assert!(c.center.toasts("w").is_empty());
}

#[test]
fn close_by_id_ends_it_in_every_window() {
    let mut c = Center::new();
    let working = c.show(until_closed("cloud-start-t5", "Moving", true), "first");
    c.send(CenterEvent::Close { id: "cloud-start-t5".into() });
    assert!(c.dismissed(working));
    assert!(c.center.toasts("first").is_empty() && c.center.toasts("second").is_empty());
}

#[test]
fn an_ordinary_toast_stays_per_window() {
    let mut c = Center::new();
    let a = c.show(toast("notice", "One"), "first");
    let b = c.show(toast("notice", "Two"), "second");
    assert!(!c.dismissed(a) && !c.dismissed(b));
    assert_eq!(c.messages("first"), ["One"]);
    assert_eq!(c.messages("second"), ["Two"]);
}

// MARK: Never show

#[test]
fn dont_show_again_hides_the_kind_for_good() {
    let mut c = Center::new();
    let notice = c.show(
        toast("cloud-close-keeps-machine", "The Cloud machine keeps running until 5 PM"),
        "w",
    );
    let effects = c.send(CenterEvent::PersonChoseNeverShow { serial: notice });
    assert!(effects.contains(&CenterEffect::PersistNeverShow {
        kinds: Some(vec!["cloud-close-keeps-machine".into()])
    }));
    assert!(c.center.toasts("w").is_empty());
    let again = c.show(toast("cloud-close-keeps-machine", "Keeps running until 6 PM"), "other");
    assert!(c.dismissed(again));
    assert!(c.center.toasts("other").is_empty());
    let unrelated = c.show(toast("density", "Compact"), "w");
    assert!(!c.dismissed(unrelated));
}

#[test]
fn the_kind_not_the_id_is_hidden() {
    let mut c = Center::new();
    let mut a = toast("file-recovery:/a.txt", "No recovered copy of a.txt");
    a.kind = Some("file-recovery".into());
    let first = c.show(a, "w");
    c.send(CenterEvent::PersonChoseNeverShow { serial: first });
    let mut b = toast("file-recovery:/b.txt", "No recovered copy of b.txt");
    b.kind = Some("file-recovery".into());
    let next = c.show(b, "w");
    assert!(c.dismissed(next));
}

#[test]
fn the_choice_lasts_until_shown_again() {
    let mut store = NeverShowStore::default();
    assert!(store.hide("density"));
    assert!(!store.hide("density"));
    let relaunched = NeverShowStore::load(&store.persisted().unwrap());
    assert!(relaunched.is_hidden("density"));
    assert_eq!(relaunched.hidden_kinds(), ["density"]);
    let mut shown = relaunched;
    assert!(shown.show_all());
    assert_eq!(shown.persisted(), None);
    assert!(!NeverShowStore::load(&[]).is_hidden("density"));
}

#[test]
fn undo_and_answer_toasts_cannot_be_hidden() {
    let undo = with_action(toast("tab-closed", "Closed \u{201C}zsh\u{201D}"), ToastAction::undo());
    let prompt = until_closed("server-update", "Update the server?", false);
    let notice = toast("density", "Compact");
    assert!(!undo.offers_never_show());
    assert!(!prompt.offers_never_show());
    assert!(notice.offers_never_show());
    let mut c = Center::new();
    let serial = c.show(undo, "w");
    c.send(CenterEvent::PersonChoseNeverShow { serial });
    assert!(c.center.never_show.hidden_kinds().is_empty());
    assert_eq!(c.center.toasts("w").len(), 1);
}

#[test]
fn toasts_show_longer() {
    let tuning = ToastTuning::default();
    assert_eq!(tuning.shown_duration(&toast("a", "m")), 12.0);
    let mut short = toast("a", "m");
    short.duration = Some(2.0);
    assert_eq!(tuning.shown_duration(&short), 6.0);
    let mut kept = toast("z", "110%");
    kept.duration = Some(1.0);
    kept.keeps_duration = true;
    assert_eq!(tuning.shown_duration(&kept), 1.0);
    assert_eq!(tuning.shown_duration(&until_closed("p", "?", false)), UNTIL_CLOSED);
    let scaled = ToastTuning { duration_scale: 3.0, ..ToastTuning::default() };
    assert_eq!(scaled.shown_duration(&toast("a", "m")), 18.0);
}

#[test]
fn the_center_schedules_the_longer_time() {
    let mut c = Center::new();
    let mut six = toast("a", "Saved");
    six.duration = Some(6.0);
    let serial = c.center.next_serial;
    let effects = c.send(CenterEvent::Show { toast: six, window: "w".into(), now_ms: 0.0 });
    assert!(effects.contains(&CenterEffect::Schedule { serial, seconds: 12.0 }));
    let effects = c.send(CenterEvent::Timeout { serial });
    assert!(effects.contains(&CenterEffect::Finished { serial, reason: DismissReason::Timeout }));
}

// MARK: Undo key

#[test]
fn only_the_newest_undo_toast_shows_cmd_z() {
    let mut c = Center::new();
    let first = c.show(
        with_action(toast("tab-closed", "Closed \u{201C}zsh\u{201D}"), ToastAction::undo()),
        "w",
    );
    let newer =
        c.show(with_action(toast("pane-closed", "Closed a pane"), ToastAction::undo()), "w");
    let notice = c.show(toast("notice", "Copied"), "w");
    let last = c.rendered.last().unwrap();
    let ids: Vec<&str> = last.iter().map(|s| s.toast.id.as_str()).collect();
    assert_eq!(ids, ["tab-closed", "pane-closed", "notice"]);
    let keys: Vec<bool> = last.iter().map(|s| s.shows_undo_key).collect();
    assert_eq!(
        keys,
        [false, true, false],
        "an older Undo still names a key that runs the newer one"
    );
    c.dismiss(newer);
    let last = c.rendered.last().unwrap();
    let ids: Vec<&str> = last.iter().map(|s| s.toast.id.as_str()).collect();
    assert_eq!(ids, ["tab-closed", "notice"]);
    assert_eq!(last.iter().map(|s| s.shows_undo_key).collect::<Vec<_>>(), [true, false]);
    c.dismiss(first);
    c.dismiss(notice);
    assert!(c.rendered.last().unwrap().is_empty());
}

#[test]
fn the_undo_key_goes_to_the_toast_unless_the_responder_owns_it() {
    let mut c = Center::new();
    let undo = c.show(with_action(toast("tab-closed", "Closed"), ToastAction::undo()), "w");
    let takes = |c: &mut Center, can: bool, owns: bool| {
        c.send(CenterEvent::TakesUndoKey {
            window: "w".into(),
            responder_can_undo: can,
            owns_undo_top: owns,
        })
    };
    assert_eq!(takes(&mut c, false, false), [CenterEffect::Answer { value: true }]);
    assert_eq!(takes(&mut c, true, false), [CenterEffect::Answer { value: false }]);
    assert_eq!(takes(&mut c, true, true), [CenterEffect::Answer { value: true }]);
    let effects = c.send(CenterEvent::RunUndo { window: "w".into() });
    assert_eq!(effects.first(), Some(&CenterEffect::RunAction { serial: undo }));
    assert_eq!(effects.last(), Some(&CenterEffect::Answer { value: true }));
    assert!(c.finished.contains(&(undo, DismissReason::Action)));
}

// MARK: Style

#[test]
fn a_picked_style_persists_over_the_configured_one() {
    let mut store = StyleStore::default();
    assert_eq!(store.style(), ToastStyle::Standard);
    assert_eq!(store.pick(ToastStyle::Capsule), Some(StyleWrite::Set("capsule")));
    let relaunched = StyleStore::load(Some("capsule"), ToastStyle::Standard);
    assert_eq!(relaunched.style(), ToastStyle::Capsule);
    assert_eq!(store.pick(ToastStyle::Capsule), None);
    assert_eq!(store.pick(ToastStyle::Standard), Some(StyleWrite::Remove));
}

#[test]
fn the_configured_style_is_the_default_under_a_pick() {
    let mut store = StyleStore::default();
    assert!(store.configure(ToastStyle::Compact));
    assert_eq!(store.style(), ToastStyle::Compact);
    store.pick(ToastStyle::Solid);
    assert!(!store.configure(ToastStyle::Flat), "a pick hides the configured style");
    assert_eq!(store.style(), ToastStyle::Solid);
    assert_eq!(store.pick(ToastStyle::Flat), Some(StyleWrite::Remove));
    assert_eq!(store.style(), ToastStyle::Flat);
}

#[test]
fn an_unknown_stored_style_is_the_default() {
    let store = StyleStore::load(Some("removed-style"), ToastStyle::Standard);
    assert_eq!(store.picked, None);
    assert_eq!(store.style(), ToastStyle::Standard);
}

#[test]
fn the_styles_are_distinct() {
    assert!(ToastStyle::ALL.len() >= 8);
    let looks: HashSet<String> =
        ToastStyle::ALL.iter().map(|s| serde_json::to_string(&s.look()).unwrap()).collect();
    assert_eq!(looks.len(), ToastStyle::ALL.len(), "two styles draw the same");
    let titles: HashSet<&str> = ToastStyle::ALL.iter().map(|s| s.title()).collect();
    assert_eq!(titles.len(), ToastStyle::ALL.len());
    for style in ToastStyle::ALL {
        assert!(!style.summary().is_empty(), "{style:?}");
        assert_eq!(ToastStyle::from_raw(style.raw_value()), Some(style));
    }
    assert_eq!(PlaygroundFocus::all_cases().len(), ToastStyle::ALL.len() + 1);
    assert_eq!(PlaygroundFocus::from_raw("removed-style"), None);
}

// MARK: C ABI

#[test]
fn the_center_runs_through_the_c_abi() {
    let shown = ok(
        "toast.center",
        json!({"event": {"event": "show", "window": "w", "nowMs": 0,
            "toast": {"id": "saved", "message": "Saved"}}}),
    );
    let effects = shown["effects"].as_array().unwrap();
    let names: Vec<&str> = effects.iter().map(|e| e["effect"].as_str().unwrap()).collect();
    assert_eq!(names, ["schedule", "render", "announce"]);
    assert_eq!(effects[0], json!({"effect": "schedule", "serial": 1, "seconds": 12.0}));
    assert_eq!(effects[1]["shown"][0]["toast"]["duration"], json!(6.0));
    assert_eq!(effects[1]["shown"][0]["showsUndoKey"], json!(false));
    let closed = ok(
        "toast.center",
        json!({"center": shown["center"], "event": {"event": "personClosed", "serial": 1, "nowMs": 0}}),
    );
    let effects = closed["effects"].as_array().unwrap();
    assert_eq!(
        effects.last().unwrap(),
        &json!({"effect": "finished", "serial": 1, "reason": "closed"})
    );
    assert_eq!(closed["center"]["quieted"][0]["untilMs"], json!(120000.0));
    let (status, _) = call("toast.center", r#"{"event":{"event":"nope"}}"#);
    assert_ne!(status, CMUX_DESIGN_OK);
}

#[test]
fn the_stores_run_through_the_c_abi() {
    let hidden = ok("toast.neverShowHide", json!({"store": {}, "kind": "density"}));
    assert_eq!(hidden, json!({"store": {"kinds": ["density"]}, "persist": ["density"]}));
    let again = ok("toast.neverShowHide", json!({"store": hidden["store"], "kind": "density"}));
    assert_eq!(again["persist"], Value::Null);
    let picked = ok("toast.stylePick", json!({"store": {}, "style": "capsule"}));
    assert_eq!(picked["change"], json!({"write": "set", "value": "capsule"}));
    assert_eq!(picked["style"], json!("capsule"));
    let duration = ok(
        "toast.shownDuration",
        json!({"toast": {"id": "a", "message": "m"}, "tuning": ToastTuning::default()}),
    );
    assert_eq!(duration, json!(12.0));
    assert_eq!(ok("toast.focus", json!({"focus": "removed-style"})), Value::Null);
    assert_eq!(ok("toast.focuses", json!({})).as_array().unwrap().len(), ToastStyle::ALL.len() + 1);
    let (status, _) = call("toast.nope", "{}");
    assert_ne!(status, CMUX_DESIGN_OK);
}
