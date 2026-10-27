//! Path probe (`Probe::decode`): only `PROBE_LEN` bytes decode, a probe
//! re-encodes to the same bytes, and only a ping has a pong.
#![no_main]

use cmux_transport::probe::PROBE_LEN;
use cmux_transport::{Probe, ProbeKind};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(probe) = Probe::decode(data) else { return };
    assert_eq!(data.len(), PROBE_LEN);
    assert_eq!(probe.encode().as_slice(), data);
    match probe.pong() {
        Some(pong) => {
            assert_eq!(probe.kind, ProbeKind::Ping);
            assert_eq!((pong.kind, pong.id, pong.path), (ProbeKind::Pong, probe.id, probe.path));
        }
        None => assert_eq!(probe.kind, ProbeKind::Pong),
    }
});
