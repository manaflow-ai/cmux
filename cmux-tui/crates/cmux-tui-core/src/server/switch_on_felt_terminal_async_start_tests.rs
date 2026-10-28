//! The daemon's `terminalAsyncStart` gate follows the channel-resolved features the
//! owner installs at start ([`install_daemon_features`]), not only the env lists:
//! on by default in DEV and NIGHTLY, off in Release, and a disable wins
//! (plans/cmux-next/feature-switch-policy.md rule 2).

use std::sync::Arc;

use cmux_features::{Channel, Live, Snapshot};

use crate::Mux;
use crate::server::install_daemon_features;

const NAME: &str = "terminalAsyncStart";

fn installed(label: &str, snapshot: Snapshot) -> Arc<Mux> {
    let mux = Mux::new_for_test(
        format!("felt-terminal_async_start-{label}"),
        crate::SurfaceOptions::default(),
    );
    assert!(install_daemon_features(&mux, Live::new(snapshot)));
    mux
}

fn gate(mux: &Mux) -> bool {
    mux.terminal_async_start_enabled()
}

#[test]
fn the_channel_default_reaches_the_terminal_async_start_gate() {
    for (channel, on) in [(Channel::Dev, true), (Channel::Nightly, true), (Channel::Release, false)]
    {
        let mux = installed(&format!("{channel:?}"), Snapshot::defaults(channel));
        assert_eq!(gate(&mux), on, "{NAME} in {channel:?}");
    }
}

#[test]
fn a_disable_turns_the_terminal_async_start_gate_off_in_dev() {
    let mux = installed("disabled", Snapshot::from_env(Channel::Dev, None, Some(NAME)));
    assert!(!gate(&mux));
}
