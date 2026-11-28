use super::{CHANNEL_BASE, channel_base};

#[test]
fn a_named_channel_url_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    assert_eq!(channel_base(None), CHANNEL_BASE);
    assert!(cmux_egress::check("server-channel-named-test.org", "test").is_err());
    let base = channel_base(Some("https://server-channel-named-test.org/server/channel"));
    assert_eq!(base, "https://server-channel-named-test.org/server/channel");
    assert!(cmux_egress::check("server-channel-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-server-channel-test.org", "test").is_err());
}
