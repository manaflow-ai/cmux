//! Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 2, the
//! measurement window; the felt queue): `admitThenReply` is on by default in DEV and
//! NIGHTLY and stays off in Release, so the optimized dogfood build measures it.

use cmux_features::{Channel, Snapshot};

const NAME: &str = "admitThenReply";

#[test]
fn admit_then_reply_is_on_in_dev_and_nightly_and_off_in_release() {
    for (channel, on) in [(Channel::Dev, true), (Channel::Nightly, true), (Channel::Release, false)]
    {
        let snapshot = Snapshot::defaults(channel);
        let feature = snapshot.feature(NAME).expect("the registry declares the feature");
        assert_eq!(snapshot.is_enabled(feature), on, "{NAME} in {channel:?}");
    }
}

#[test]
fn admit_then_reply_stays_off_when_the_disable_list_names_it() {
    let snapshot = Snapshot::from_env(Channel::Dev, None, Some(NAME));
    let feature = snapshot.feature(NAME).expect("the registry declares the feature");
    assert!(!snapshot.is_enabled(feature));
}
