use serde_json::json;

use super::{
    HELP, LowerChange, VERB_USAGE, not_bundled_note, refusal, routes_to_app, share_off_result,
    still_open,
};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_string()).collect()
}

/// A known verb with missing or wrong arguments names its own usage, not
/// "unknown remote-host command" (a bare `cmux remote-host access` said that).
#[test]
fn a_known_verb_with_wrong_arguments_names_its_usage() {
    assert_eq!(
        refusal(&words(&["access"])),
        "usage: cmux remote-host access DEVICE none|ask|view|full"
    );
    assert_eq!(
        refusal(&words(&["access", "my-iphone"])),
        "usage: cmux remote-host access DEVICE none|ask|view|full"
    );
    assert_eq!(
        refusal(&words(&["access", "my-iphone", "admin"])),
        "usage: cmux remote-host access DEVICE none|ask|view|full"
    );
    assert_eq!(
        refusal(&words(&["request"])),
        "usage: cmux remote-host request accessibility|screen-recording"
    );
    assert_eq!(
        refusal(&words(&["share"])),
        "usage: cmux remote-host share on|off, or share on --device DEVICE"
    );
    assert_eq!(refusal(&words(&["frobnicate"])), "unknown remote-host command \"frobnicate\"");
    assert_eq!(refusal(&words(&["--bogus"])), "remote-host does not take \"--bogus\"");
}

/// Every verb usage names a verb HELP lists, so the two cannot drift apart.
#[test]
fn every_verb_usage_is_a_verb_help_lists() {
    for (verb, _) in VERB_USAGE {
        assert!(HELP.contains(&format!("cmux remote-host {verb}")), "{verb} is not in HELP");
    }
}

/// A build without cmux Remote (`bundled: false`) sends share off and stop
/// to the app, as share on already goes; a build with it, an older daemon
/// without the field, or no answer keeps cmux Remote's worker.
#[test]
fn share_off_and_stop_go_to_the_app_only_without_cmux_remote() {
    let absent = json!({"state": "off", "config": {"screen_sharing": false}, "bundled": false});
    assert!(routes_to_app(Some(&absent)));
    assert!(!routes_to_app(Some(&json!({"state": "running", "bundled": true}))));
    assert!(!routes_to_app(Some(&json!({"state": "off"}))));
    assert!(!routes_to_app(None));
    assert_eq!(LowerChange::ShareOff.worker_call()["method"], "screen.share");
    assert_eq!(LowerChange::ShareOff.worker_call()["params"], json!({"on": false}));
    assert_eq!(LowerChange::StopSession.worker_call()["method"], "screen.stop_session");
}

/// The app actions they route to are in the catalog the app reads.
#[test]
fn the_app_actions_for_share_off_and_stop_are_cataloged() {
    let catalog: serde_json::Value =
        serde_json::from_str(&cmux_tui_core::packed_catalogs::ACTION_SURFACES.inflate())
            .expect("the action catalog is valid JSON");
    for change in [LowerChange::ShareOff, LowerChange::StopSession] {
        let id = change.app_action();
        assert!(
            catalog["actions"].as_array().into_iter().flatten().any(|action| action["id"] == id),
            "{id} is not in the action catalog"
        );
    }
}

/// status names the absent cmux Remote in plain words, and only then.
#[test]
fn status_says_plainly_when_cmux_remote_is_not_in_this_build() {
    let note = not_bundled_note(&json!({"state": "off", "bundled": false}));
    assert_eq!(note, Some(crate::localization::catalog().app_control.remote_not_bundled));
    assert_eq!(not_bundled_note(&json!({"state": "off", "bundled": true})), None);
    assert_eq!(not_bundled_note(&json!({"state": "off"})), None);
}

#[test]
fn a_confirmation_past_its_wait_says_the_dialog_still_counts() {
    let expected = crate::localization::catalog().app_control.remote_confirm_still_open;
    let read = json!({"code": "app.transport", "message": "the cmux app did not answer", "details": {"timeout_seconds": 130}});
    assert_eq!(still_open(read)["message"], expected);
    let app =
        json!({"code": "timeout", "message": "remote.confirm did not finish within 130000 ms"});
    assert_eq!(still_open(app)["message"], expected);
    let other = json!({"code": "app.unreachable", "message": "no app"});
    assert_eq!(still_open(other.clone()), other);
}

/// The person gets minutes, not the old 130 s, to answer; the app's deadline matches.
#[test]
fn share_confirmation_waits_for_the_person_past_the_old_timeout() {
    assert_eq!(super::CONFIRM_TIMEOUT, std::time::Duration::from_secs(600));
    assert!(super::CONFIRM_TIMEOUT > std::time::Duration::from_secs(130));
}

/// On a joined Mac, share off is the share host's: the hub's answer, or its failure with the
/// next step; a machine with no share host keeps cmux Remote's worker or the app.
#[test]
fn share_off_on_a_joined_mac_is_the_share_hosts() {
    use acpmux::share_host::OffHere;
    assert_eq!(share_off_result(OffHere::NoHost), None);
    let answer = json!({"device": {"id": "d1", "macScreenShared": false}});
    assert_eq!(
        share_off_result(OffHere::Off(answer)),
        Some(Ok(json!({"sharing": false, "via": "share-host",
            "device": {"id": "d1", "macScreenShared": false}})))
    );
    assert_eq!(
        share_off_result(OffHere::Failed("why; what to do".into())),
        Some(Err(json!({"code": "share_host.off_failed", "message": "why; what to do"})))
    );
}
