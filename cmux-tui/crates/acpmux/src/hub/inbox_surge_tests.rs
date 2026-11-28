use super::*;
#[test]
fn surge_starts_and_recovers_at_the_receivers_measured_rate() {
    let mut fast = SurgeRate::default();
    let mut slow = SurgeRate::default();
    assert!(!fast.arrival(100, Some(10)));
    assert!(!slow.arrival(100, Some(100)));
    assert!(!fast.arrival(150, Some(10)));
    assert!(slow.arrival(150, Some(100)));
    assert!(slow.arrival(249, Some(100)));
    assert!(!slow.arrival(349, Some(100)));
    slow.restore(500);
    assert!(slow.arrival(520, Some(100)));
}

#[test]
fn surge_bypasses_people_questions_blocks_and_fire() {
    let blocks = [json!({"type":"text","text":"ordinary report"})];
    let mut opts = PromptOptions { agent: Some("lane".into()), ..Default::default() };
    assert!(eligible(&opts, &blocks).is_some());
    opts.human_authenticated = true;
    assert!(eligible(&opts, &blocks).is_none());
    opts.human_authenticated = false;
    let (_reader, receiver) = tokio::sync::watch::channel(false);
    opts.reply_reader = Some(receiver);
    assert!(eligible(&opts, &blocks).is_none());
    opts.reply_reader = None;
    for urgent in [PromptClass::Question, PromptClass::Block] {
        opts.class = Some(urgent);
        assert!(eligible(&opts, &blocks).is_none());
    }
    opts.class = Some(PromptClass::Fyi);
    opts.agent = None;
    opts.provenance = Some(crate::prompt_provenance::notice(
        &json!({"sender":"watcher","severity":"warn"}),
        "receiver",
    ));
    assert_eq!(eligible(&opts, &blocks).as_deref(), Some("watcher"));
    opts.provenance = Some(crate::prompt_provenance::notice(
        &json!({"sender":"watcher","severity":"fire"}),
        "receiver",
    ));
    assert!(eligible(&opts, &blocks).is_none());
}
