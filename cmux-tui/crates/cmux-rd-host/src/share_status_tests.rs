use super::*;

fn mac(screen_recording: bool, accessibility: bool, frame: FrameProbe) -> Facts {
    Facts {
        os: HostOs::Mac,
        host: "Lawrence's MacBook Pro".into(),
        grantee: "cmux".into(),
        screen_recording: Some(screen_recording),
        accessibility: Some(accessibility),
        wants_control: true,
        frame,
    }
}

#[test]
fn no_screen_recording_names_the_host_and_the_setting() {
    let status = evaluate(&mac(false, true, FrameProbe::NotTried));
    assert_eq!(status.state, ShareState::NeedsScreenRecording);
    assert_eq!(
        status.message,
        "Lawrence's MacBook Pro can't share its screen yet: Screen Recording isn't allowed. On \
         that Mac, open System Settings › Privacy & Security › Screen Recording and turn on cmux."
    );
    assert!(!status.can_view && !status.can_control);
    assert!(status.settings.as_deref().is_some_and(|s| s.ends_with("Privacy_ScreenCapture")));
}

#[test]
fn a_missing_grant_wins_over_every_other_fact() {
    // Even when the frame probe saw a picture (a cached answer), no grant is no grant.
    let status = evaluate(&mac(false, false, FrameProbe::Frame { black: false }));
    assert_eq!(status.state, ShareState::NeedsScreenRecording);
}

#[test]
fn a_black_picture_is_a_capture_failure_never_ready() {
    // The 2026-11-16 report: frames flowing, all black.
    let status = evaluate(&mac(true, true, FrameProbe::Frame { black: true }));
    assert_eq!(status.state, ShareState::CaptureFailed);
    assert!(status.message.contains("its screen comes through black"), "{}", status.message);
    assert!(status.message.contains("Screen Recording has cmux turned on"), "{}", status.message);
    assert!(!status.can_view);
}

#[test]
fn no_frame_and_a_start_error_are_capture_failures_with_the_reason() {
    let none = evaluate(&mac(true, true, FrameProbe::NoFrame));
    assert_eq!(none.state, ShareState::CaptureFailed);
    assert!(none.message.contains("no picture came from its display in 2 seconds"));
    let err = evaluate(&mac(true, true, FrameProbe::Failed("The user declined TCCs.".into())));
    assert_eq!(err.state, ShareState::CaptureFailed);
    assert_eq!(
        err.message,
        "Lawrence's MacBook Pro can't share its screen yet: The user declined TCCs."
    );
}

#[test]
fn control_without_accessibility_still_shows_the_screen() {
    let status = evaluate(&mac(true, false, FrameProbe::Frame { black: false }));
    assert_eq!(status.state, ShareState::NeedsAccessibility);
    assert!(status.can_view && !status.can_control);
    // A view session never needs Accessibility.
    let view = evaluate(&Facts {
        wants_control: false,
        ..mac(true, false, FrameProbe::Frame { black: false })
    });
    assert_eq!(view.state, ShareState::Ready);
    assert!(view.can_view && !view.can_control);
}

#[test]
fn ready_with_every_grant_and_a_real_picture() {
    let status = evaluate(&mac(true, true, FrameProbe::Frame { black: false }));
    assert_eq!(
        status,
        ShareStatus {
            state: ShareState::Ready,
            message: String::new(),
            settings: None,
            can_view: true,
            can_control: true
        }
    );
}

#[test]
fn linux_and_windows_use_the_same_states_with_their_own_words() {
    let linux = |os, frame| Facts {
        os,
        host: "devbox".into(),
        grantee: "cmux".into(),
        screen_recording: None,
        accessibility: None,
        wants_control: true,
        frame,
    };
    let declined = evaluate(&linux(
        HostOs::LinuxPortal,
        FrameProbe::Failed("the person at the screen did not allow sharing".into()),
    ));
    assert_eq!(declined.state, ShareState::NeedsScreenRecording);
    assert!(declined
        .message
        .starts_with("devbox can't share its screen yet: screen sharing wasn't allowed"));
    // The portal applies no input: ready is view only.
    let portal = evaluate(&linux(HostOs::LinuxPortal, FrameProbe::NotTried));
    assert_eq!(
        (portal.state, portal.can_view, portal.can_control),
        (ShareState::Ready, true, false)
    );
    let x11 = evaluate(&linux(
        HostOs::LinuxX11,
        FrameProbe::Failed("the X display :0 could not be opened (refused)".into()),
    ));
    assert_eq!(x11.state, ShareState::CaptureFailed);
    assert!(x11.message.ends_with("the X display :0 could not be opened (refused)."));
    let windows = evaluate(&linux(HostOs::Windows, FrameProbe::Frame { black: true }));
    assert_eq!(windows.state, ShareState::CaptureFailed);
    assert!(windows.message.contains("Unlock that computer"));
    assert!(windows.settings.is_none());
}

#[test]
fn black_means_every_sample_dark() {
    assert!(is_black(&[16, 17, 20, 24], 16));
    assert!(!is_black(&[16, 16, 200], 16), "one bright pixel (a menu bar) is a real picture");
    assert!(!is_black(&[40; 64], 16), "a dark theme is not black");
    assert!(!is_black(&[], 16), "no samples is no answer, not black");
    assert!(is_black(&[0, 3, 8], 0));
}

#[test]
fn bgrx_grid_samples_spread_pixels() {
    // 4x2 BGRX: left half black, right half white.
    let mut px = Vec::new();
    for _row in 0..2 {
        for x in 0..4 {
            let v = if x < 2 { 0 } else { 255 };
            px.extend_from_slice(&[v, v, v, 0]);
        }
    }
    let grid = bgrx_luma_grid(&px, 4, 2, 16, 2, 1);
    assert_eq!(grid.len(), 2);
    assert_eq!(grid[0], 0);
    assert!(grid[1] >= 250);
    assert!(bgrx_luma_grid(&px, 0, 2, 16, 2, 1).is_empty());
}

#[test]
fn the_status_line_is_snake_case_json() {
    let mut out = Vec::new();
    write_status(&mut out, &evaluate(&mac(false, true, FrameProbe::NotTried))).expect("write");
    let value: serde_json::Value = serde_json::from_slice(&out).expect("json");
    assert_eq!(value["state"], "needs_screen_recording");
    assert_eq!(value["can_view"], false);
    assert_eq!(out.last(), Some(&b'\n'));
    let ready =
        serde_json::to_value(evaluate(&mac(true, true, FrameProbe::Frame { black: false })))
            .expect("json");
    assert!(ready.get("settings").is_none());
}

#[test]
fn share_status_rejects_unknown_scope_and_frame_words() {
    assert_eq!(crate::run_cli(&["share-status".into(), "--scope".into(), "all".into()]), 1);
    assert_eq!(crate::run_cli(&["share-status".into(), "--frame".into(), "maybe".into()]), 1);
}
