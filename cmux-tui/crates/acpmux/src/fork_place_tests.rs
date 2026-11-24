use super::*;

fn vm(fork: bool) -> Parent {
    Parent { machine: "vm_0123456789abcdefghij".into(), fork }
}

#[test]
fn off_says_nothing_whatever_the_parent() {
    assert_eq!(decide(false, Some(&vm(true)), "s1"), None);
    assert_eq!(decide(false, None, "s1"), None);
}

#[test]
fn on_with_a_forkable_cloud_parent_forks_it_under_the_starts_key() {
    assert_eq!(
        decide(true, Some(&vm(true)), "s1"),
        Some(ForkPlace::Fork {
            machine: "vm_0123456789abcdefghij".into(),
            client_key: "autocloud-s1".into()
        })
    );
}

#[test]
fn on_without_a_way_to_fork_keeps_the_warm_path_and_says_why() {
    let warm = |d: Option<ForkPlace>| match d {
        Some(ForkPlace::Warm { why }) => why,
        other => panic!("{other:?}"),
    };
    assert!(warm(decide(true, None, "s1")).contains("not run on a Cloud machine"));
    assert!(warm(decide(true, Some(&vm(false)), "s1")).contains("cannot be forked"));
    assert!(warm(decide(true, Some(&vm(true)), "  ")).contains("no key"));
    let bad = Parent { machine: "../v1/teams".into(), fork: true };
    assert!(warm(decide(true, Some(&bad), "s1")).contains("not a machine id"));
}

#[test]
fn a_long_key_is_cut_to_the_platforms_limit() {
    let Some(ForkPlace::Fork { client_key, .. }) = decide(true, Some(&vm(true)), &"k".repeat(300))
    else {
        panic!()
    };
    assert_eq!(client_key.chars().count(), MAX_CLIENT_KEY);
}

#[test]
fn the_setting_is_on_only_for_a_json_true() {
    assert!(on(&json!({"cloud": {"autoCloud": true}})));
    assert!(on(&json!({"cloud.autoCloud": true})));
    for doc in
        [json!({}), json!({"cloud": {"autoCloud": "true"}}), json!({"cloud.autoCloud": false})]
    {
        assert!(!on(&doc), "{doc}");
    }
}

#[test]
fn the_parent_and_the_reply_round_trip() {
    let p = parent_of(&json!({"parent": {"machine": "vm_a", "fork": true}})).unwrap();
    assert_eq!(p, Parent { machine: "vm_a".into(), fork: true });
    assert_eq!(parent_of(&json!({"parent": {"machine": "vm_a"}})).unwrap().fork, false);
    assert_eq!(parent_of(&json!({})), None);
    assert_eq!(
        to_json(&ForkPlace::Fork { machine: "vm_a".into(), client_key: "autocloud-k".into() }),
        json!({"at": "fork", "machine": "vm_a", "clientKey": "autocloud-k"})
    );
}
