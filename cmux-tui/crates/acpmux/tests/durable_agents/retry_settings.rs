//! Exercise app retry settings through a real daemon, with process-local environment.
use super::*;

#[tokio::test]
async fn app_retry_settings_control_delay_success_cancel_and_disabled() {
    let mut daemon = Daemon::new("retry-settings", "approve-all");
    daemon.sigterm();
    let settings = daemon.home.join("app-settings.json");
    let configure = |enabled: bool, seconds: u64| {
        std::fs::write(
            &settings,
            json!({"agents.retry.enabled": enabled, "agents.retry.intervalSeconds": seconds})
                .to_string(),
        )
        .unwrap();
    };
    configure(true, 1);
    daemon.env.push(("CMUX_NEXT_CONFIG_FILE".into(), settings.display().to_string()));
    daemon.start();

    for mode in ["success", "cancel", "disabled", "restart-disabled"] {
        if mode == "cancel" || mode == "restart-disabled" {
            // Leave enough time to cancel even on a loaded fleet runner.
            configure(true, 30);
        } else if mode == "disabled" {
            configure(false, 1);
        }
        let session = new_session(&daemon).await;
        let mut rpc = daemon.rpc().await;
        let failed = rpc
            .reply(
                "session/prompt",
                json!({"sessionId": session,
                    "prompt": [{"type": "text", "text": "net-fail-once: keep working"}],
                    "_meta": {"acpmux": {"promptId": mode}}}),
            )
            .await;
        assert!(failed.get("error").is_some(), "{failed}");

        if mode == "disabled" {
            daemon.wait_event(&session, "disabled retry decision", |e| {
                e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "off"
            });
        } else {
            let scheduled = daemon
                .wait_event(&session, "configured retry", |e| e["kind"] == "auto_resume_scheduled");
            let delay = scheduled["msg"]["delayMs"].as_u64().unwrap();
            let expected = if mode == "success" { 1000 } else { 30000 };
            assert!(
                (expected..=expected + expected / 5).contains(&delay),
                "configured seconds plus existing stagger must set the timer: {scheduled}"
            );
            assert_eq!(scheduled["msg"]["of"], 4, "default attempt count is unchanged");
            if mode == "restart-disabled" {
                daemon.sigkill();
                drop(rpc);
                configure(false, 30);
                daemon.start();
                rpc = daemon.rpc().await;
                // Attaching loads the session and its persisted retry journal after restart.
                rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
                daemon.wait_event(&session, "disabled persisted retry decision", |e| {
                    e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "off"
                });
                assert!(
                    !daemon.events(&session).iter().any(|e| e["kind"] == "auto_resume_restored"),
                    "disabled retry must not restore its pending attempt"
                );
            } else if mode == "cancel" {
                rpc.call("session/cancel", json!({"sessionId": session})).await;
                daemon.wait_event(&session, "cancelled retry decision", |e| {
                    e["kind"] == "auto_resume_settled" && e["msg"]["why"] == "stopped"
                });
                // The cancelled timer wakes and settles without waiting out its deadline.
                daemon.wait_event(&session, "cancelled timer exiting", |e| {
                    e["kind"] == "auto_resume_skipped"
                });
            } else {
                let result = daemon.wait_event(&session, "successful automatic retry", |e| {
                    e["kind"] == "turn_result" && e["msg"]["promptId"] == "success~resume-1"
                });
                assert_eq!(result["msg"]["status"], "completed", "{result}");
                assert!(
                    result["at"].as_u64().unwrap() >= scheduled["msg"]["nextAt"].as_u64().unwrap()
                );
            }
        }
        let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
        assert_eq!(attached["session"]["retry"], Value::Null, "{mode}: {attached}");
        let events = daemon.events(&session);
        assert_eq!(
            events.iter().filter(|e| e["kind"] == "auto_resume_scheduled").count(),
            usize::from(mode != "disabled"),
            "{mode} must not schedule another attempt"
        );
        assert_eq!(
            events.iter().filter(|e| e["kind"] == "turn_started").count(),
            if mode == "success" { 2 } else { 1 },
            "{mode} must not send an extra prompt"
        );
    }
}
