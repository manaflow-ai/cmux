use super::*;

#[test]
fn malformed_probes_are_refused() {
    let ping = Probe { kind: ProbeKind::Ping, id: 1, path: PathId(1) }.encode();
    assert_eq!(Probe::decode(&ping[..14]), Err(ProbeError::Length(14)));
    let mut magic = ping;
    magic[0] = b'x';
    assert_eq!(Probe::decode(&magic), Err(ProbeError::Magic));
    let mut kind = ping;
    kind[4] = 9;
    assert_eq!(Probe::decode(&kind), Err(ProbeError::Kind(9)));
}
