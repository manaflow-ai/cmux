use super::*;

fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect()
}

/// A user's launch uses the system center, with or without the variable.
#[test]
fn a_users_launch_uses_the_system_center() {
    assert!(center(&env(&[]), false).uses_system_center);
    assert!(center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), false).uses_system_center);
}

/// An automation launch does not, unless it opts in with exactly "1".
#[test]
fn an_automation_launch_does_not_unless_it_opts_in() {
    assert!(!center(&env(&[]), true).uses_system_center);
    assert!(center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), true).uses_system_center);
    for other in ["0", "", "true", "yes"] {
        assert!(
            !center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", other)]), true).uses_system_center,
            "{other:?}"
        );
    }
}

/// A GUI job asks for permission only when it opts in.
#[test]
fn a_gui_job_asks_for_permission_only_when_it_opts_in() {
    assert!(center(&env(&[]), false).asks_permission);
    for job in ["NX_REMOTE", "CMUX_TEST_REQUIRE_GUI"] {
        assert!(!center(&env(&[(job, "1")]), false).asks_permission, "{job}");
        assert!(
            center(&env(&[(job, "1"), ("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), false)
                .asks_permission
        );
        assert!(
            center(&env(&[(job, "1"), ("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), true)
                .asks_permission
        );
        assert!(center(&env(&[(job, "0")]), false).asks_permission, "only \"1\" marks a GUI job");
    }
    let automation = center(&env(&[]), true);
    assert_eq!(automation.asks_permission, automation.uses_system_center);
    assert!(center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), true).asks_permission);
}

/// Only an opted-in automation launch starts without the delivered banners.
#[test]
fn only_an_opted_in_automation_launch_starts_without_delivered_banners() {
    assert!(!center(&env(&[]), false).starts_without_delivered_banners);
    assert!(!center(&env(&[]), true).starts_without_delivered_banners);
    assert!(
        center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), true)
            .starts_without_delivered_banners
    );
    // A user's launch that happens to set the variable keeps its Notification Center history.
    assert!(
        !center(&env(&[("CMUX_NEXT_NATIVE_NOTIFICATIONS", "1")]), false)
            .starts_without_delivered_banners
    );
}

/// The category: the poster's own, else a prompt's, a reply banner's or the default.
#[test]
fn a_banners_category_follows_what_it_carries() {
    let plain = BannerAsk::default();
    assert_eq!(
        banner(&plain),
        BannerShape { category: DEFAULT_CATEGORY.into(), approval: false, redacted: false }
    );
    let reply = BannerAsk { reply: true, ..BannerAsk::default() };
    assert_eq!(banner(&reply).category, REPLY_CATEGORY);
    let prompt = BannerAsk { approval: true, reply: true, ..BannerAsk::default() };
    assert_eq!(
        banner(&prompt),
        BannerShape { category: APPROVAL_CATEGORY.into(), approval: true, redacted: false }
    );
    let always = BannerAsk { approval: true, always_allow: true, ..BannerAsk::default() };
    assert_eq!(banner(&always).category, APPROVAL_ALWAYS_CATEGORY);
    let own = BannerAsk {
        approval: true,
        category: Some(ATTENTION_CATEGORY.into()),
        ..BannerAsk::default()
    };
    assert_eq!(banner(&own).category, ATTENTION_CATEGORY);
    // Always Allow alone, without a prompt, is no prompt's category.
    let stray = BannerAsk { always_allow: true, ..BannerAsk::default() };
    assert_eq!(banner(&stray).category, DEFAULT_CATEGORY);
}

/// An incognito window's banner names nothing and carries no prompt's answers.
#[test]
fn an_incognito_banner_is_redacted_and_carries_no_prompt() {
    let prompt =
        BannerAsk { approval: true, always_allow: true, incognito: true, ..BannerAsk::default() };
    assert_eq!(
        banner(&prompt),
        BannerShape { category: DEFAULT_CATEGORY.into(), approval: false, redacted: true }
    );
    let reply = BannerAsk { reply: true, incognito: true, ..BannerAsk::default() };
    assert_eq!(
        banner(&reply),
        BannerShape { category: REPLY_CATEGORY.into(), approval: false, redacted: true }
    );
}

/// Each action does its one thing; an unknown one does nothing.
#[test]
fn each_banner_action_does_its_one_thing() {
    let open = Response { open: true, ..Response::default() };
    assert_eq!(response("com.apple.UNNotificationDefaultActionIdentifier", true), open);
    for action in [OPEN_ACTION, SHOW_ACTION, IPHONE_PAIR_REVIEW_ACTION] {
        assert_eq!(response(action, false), open, "{action}");
    }
    assert_eq!(response(REPLY_ACTION, false), Response { reply: true, ..Response::default() });
    assert_eq!(
        response(MARK_READ_ACTION, false),
        Response { mark_read: true, ..Response::default() }
    );
    assert_eq!(
        response(ALLOW_ACTION, false),
        Response { approve: Some(true), ..Response::default() }
    );
    assert_eq!(
        response(DENY_ACTION, false),
        Response { approve: Some(false), ..Response::default() }
    );
    assert_eq!(response(ALWAYS_ACTION, false), Response { always: true, ..Response::default() });
    assert_eq!(
        response("com.apple.UNNotificationDismissActionIdentifier", false),
        Response::default()
    );
    assert_eq!(response("", false), Response::default());
}
