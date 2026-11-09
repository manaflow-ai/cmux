use super::*;

fn data(index: [u8; 4], counter: u64, len: usize, fill: u8) -> Vec<u8> {
    let mut out = vec![4, 0, 0, 0];
    out.extend_from_slice(&index);
    out.extend_from_slice(&counter.to_le_bytes());
    out.extend((0..len).map(|i| fill.wrapping_add(i as u8)));
    out
}

#[test]
fn the_environment_overrides_the_setting() {
    let on = Some(UltraMode::SETTING);
    assert_eq!(UltraMode::resolve_with(None, None), UltraMode::Off);
    assert_eq!(UltraMode::resolve_with(None, on), UltraMode::SETTING);
    assert_eq!(UltraMode::resolve_with(Some(""), on), UltraMode::SETTING);
    assert_eq!(UltraMode::resolve_with(Some("  "), None), UltraMode::Off);
    assert_eq!(UltraMode::resolve_with(Some("off"), on), UltraMode::Off);
    assert_eq!(UltraMode::resolve_with(Some("dup"), on), UltraMode::Duplicate { copies: 2 });
    assert_eq!(
        UltraMode::resolve_with(Some("fec:8:2"), None),
        UltraMode::Fec { group: 8, parity: 2 }
    );
    assert_eq!(UltraMode::resolve_with(Some("bogus"), on), UltraMode::SETTING);
    assert_eq!(UltraMode::resolve_with(Some("bogus"), None), UltraMode::Off);
}

#[test]
fn the_setting_is_rs_4_4() {
    assert_eq!(UltraMode::parse("rs"), Some(UltraMode::SETTING));
    assert_eq!(UltraMode::SETTING.normalized(), UltraMode::SETTING);
}

#[test]
fn parses_modes() {
    assert_eq!(UltraMode::parse("off"), Some(UltraMode::Off));
    assert_eq!(UltraMode::parse("dup"), Some(UltraMode::Duplicate { copies: 2 }));
    assert_eq!(UltraMode::parse("dup3"), Some(UltraMode::Duplicate { copies: 3 }));
    assert_eq!(UltraMode::parse("fec"), Some(UltraMode::Fec { group: 8, parity: 2 }));
    assert_eq!(UltraMode::parse("fec:10:3"), Some(UltraMode::Fec { group: 10, parity: 3 }));
    assert_eq!(UltraMode::parse("fec:2:3"), None);
    assert_eq!(UltraMode::parse("dup9"), None);
    assert_eq!(UltraMode::parse("brutal"), None);
}

#[test]
fn parity_count_follows_group_size() {
    assert_eq!(UltraMode::parities_for(8, 2, 1), 1);
    assert_eq!(UltraMode::parities_for(8, 2, 4), 1);
    assert_eq!(UltraMode::parities_for(8, 2, 5), 2);
    assert_eq!(UltraMode::parities_for(8, 2, 8), 2);
}

#[test]
fn widen_picks_the_nearest_epoch() {
    assert_eq!(widen(5, 7), 5);
    assert_eq!(widen(0xFFFF_FFFE, 0x1_0000_0001), 0xFFFF_FFFE);
    assert_eq!(widen(1, 0xFFFF_FFFF), 0x1_0000_0001);
}

/// Every single loss in every subgroup of a group, with members of
/// different lengths, is rebuilt byte for byte.
#[test]
fn rebuilds_any_one_lost_member_per_parity() {
    let index = [9, 8, 7, 6];
    let first = 0xFFFF_FFFC_u64; // the counter crosses a 32-bit boundary
    let sent: Vec<Vec<u8>> =
        (0..8).map(|i| data(index, first + i, 40 + 37 * i as usize, i as u8)).collect();
    let group = Group {
        index,
        first,
        ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
        priority: None,
    };
    let parities = parity_datagrams(&group, 8, 2);
    assert_eq!(parities.len(), 2);
    let longest = sent.iter().map(Vec::len).max().unwrap();
    assert!(parities.iter().all(|p| p.len() <= longest), "parity fits the path MTU");
    for lost in 0..8 {
        let mut received = Kept::default();
        for (i, d) in sent.iter().enumerate() {
            if i != lost {
                received.keep(index, first + i as u64, &d[WG_DATA_HEADER..]);
            }
        }
        let rebuilt: Vec<Vec<u8>> = parities
            .iter()
            .filter_map(|p| received.rebuild(&parse_parity(p).unwrap()).rebuilt())
            .collect();
        assert_eq!(rebuilt, vec![sent[lost].clone()], "lost member {lost}");
    }
}

#[test]
fn two_losses_in_one_subgroup_rebuild_nothing() {
    let index = [1, 2, 3, 4];
    let sent: Vec<Vec<u8>> = (0..4).map(|i| data(index, 100 + i, 64, i as u8)).collect();
    let group = Group {
        index,
        first: 100,
        ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
        priority: None,
    };
    let parity = &parity_datagrams(&group, 4, 1)[0];
    let mut received = Kept::default();
    received.keep(index, 100, &sent[0][WG_DATA_HEADER..]);
    received.keep(index, 103, &sent[3][WG_DATA_HEADER..]);
    assert_eq!(received.rebuild(&parse_parity(parity).unwrap()), Rebuild::Waiting);
}

/// What a test carrier sent.
type Wire = Arc<std::sync::Mutex<Vec<Vec<u8>>>>;

/// A carrier that hands out queued datagrams and records what is sent.
struct Script {
    inbox: VecDeque<(Vec<u8>, Origin)>,
    sent: Wire,
}

impl Underlay for Script {
    fn send(&mut self, datagram: &[u8]) {
        self.sent.lock().unwrap().push(datagram.to_vec());
    }
    fn poll_recv(
        &mut self,
        _cx: &mut Context<'_>,
        buffer: &mut [u8],
    ) -> Poll<io::Result<Received>> {
        match self.inbox.pop_front() {
            Some((datagram, origin)) => {
                buffer[..datagram.len()].copy_from_slice(&datagram);
                Poll::Ready(Ok(Received { len: datagram.len(), origin }))
            }
            None => Poll::Pending,
        }
    }
    fn has_peer(&self) -> bool {
        true
    }
}

fn origin(port: u16) -> Origin {
    Origin { path: PathId(0), addr: Some(SocketAddr::from(([127, 0, 0, 1], port))) }
}

/// An ultra underlay in `mode` that will receive `inbox`, and what it
/// handed the tunnel. Like the driver, it reports each handed-over
/// datagram in `authentic` as authenticated before the next receive.
fn receive(
    mode: UltraMode,
    trusted: Option<Origin>,
    inbox: Vec<(Vec<u8>, Origin)>,
    authentic: &[Vec<u8>],
) -> (UltraUnderlay, Vec<Vec<u8>>, Wire) {
    let sent = Arc::default();
    let script = Script { inbox: inbox.into(), sent: Arc::clone(&sent) };
    let mut ultra = UltraUnderlay::new(Box::new(script), mode, Arc::default());
    if let Some(origin) = trusted {
        ultra.authenticated(origin);
    }
    let mut cx = Context::from_waker(std::task::Waker::noop());
    let mut buffer = vec![0u8; 4096];
    let mut out = Vec::new();
    while let Poll::Ready(Ok(received)) = ultra.poll_recv(&mut cx, &mut buffer) {
        let datagram = buffer[..received.len].to_vec();
        if authentic.contains(&datagram) {
            ultra.authenticated(received.origin);
        }
        out.push(datagram);
    }
    (ultra, out, sent)
}

fn group_of(index: [u8; 4], first: u64, n: u64) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let sent: Vec<Vec<u8>> = (0..n).map(|i| data(index, first + i, 80, i as u8)).collect();
    let group = Group {
        index,
        first,
        ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
        priority: None,
    };
    let parities = parity_datagrams(&group, n as u8, 1);
    (sent, parities)
}

/// Parity from an origin WireGuard never authenticated turns nothing on:
/// no buffering, no rebuilding, no parity of our own.
#[test]
fn parity_from_an_unauthenticated_origin_is_ignored() {
    let index = [5, 5, 5, 5];
    let (sent, parities) = group_of(index, 10, 4);
    let stranger = origin(9999);
    let mut inbox: Vec<_> = parities.iter().map(|p| (p.clone(), stranger)).collect();
    inbox.extend(sent.iter().skip(1).map(|d| (d.clone(), stranger)));
    inbox.extend(parities.iter().map(|p| (p.clone(), stranger)));
    let (mut ultra, out, wire) = receive(UltraMode::Off, Some(origin(1)), inbox, &[]);
    assert_eq!(out.len(), 3, "data is still delivered, nothing is rebuilt");
    assert!(!ultra.decoding, "an untrusted parity starts no buffering");
    assert_eq!(ultra.mode, UltraMode::Off, "and does not turn our parity on");
    assert_eq!(ultra.counters.snapshot().parity_received, 0);
    ultra.send(&data(index, 1, 40, 0));
    ultra.flush();
    assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
}

/// From an authenticated origin, the same parity turns rebuilding on,
/// but never this side's own parity.
#[test]
fn parity_from_the_authenticated_origin_rebuilds_without_sending_parity() {
    let index = [6, 6, 6, 6];
    let peer = origin(1);
    let (first_group, first_parity) = group_of(index, 0, 4);
    let (sent, parity) = group_of(index, 4, 4);
    let mut inbox: Vec<_> = first_group.iter().map(|d| (d.clone(), peer)).collect();
    inbox.push((first_parity[0].clone(), peer));
    inbox.extend([0, 1, 3].map(|i| (sent[i].clone(), peer)));
    inbox.push((parity[0].clone(), peer));
    // WireGuard accepts every genuine datagram, the rebuilt one too.
    let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &sent);
    assert_eq!(out.last(), Some(&sent[2]), "the lost member is rebuilt");
    assert_eq!(ultra.mode, UltraMode::Off, "the peer's mode is not adopted");
    ultra.send(&data(index, 1, 40, 0));
    ultra.flush();
    assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
}

/// A side with the mode off keeps nothing until the peer's first trusted
/// parity: a loss in that first group stays lost (TCP retransmits it),
/// and every later group is rebuilt.
#[test]
fn an_off_receiver_rebuilds_from_the_second_group_on() {
    let index = [7, 7, 7, 7];
    let peer = origin(1);
    let (first_group, first_parity) = group_of(index, 0, 4);
    let (second_group, second_parity) = group_of(index, 4, 4);
    let mut inbox: Vec<_> = [0, 1, 3].map(|i| (first_group[i].clone(), peer)).to_vec();
    inbox.push((first_parity[0].clone(), peer));
    inbox.extend([0, 2, 3].map(|i| (second_group[i].clone(), peer)));
    inbox.push((second_parity[0].clone(), peer));
    let authentic: Vec<_> = first_group.iter().chain(&second_group).cloned().collect();
    let (ultra, out, _) = receive(UltraMode::Off, Some(peer), inbox, &authentic);
    assert!(!out.contains(&first_group[2]), "the first group is not rebuilt: {out:?}");
    assert_eq!(out.last(), Some(&second_group[1]), "the second group is: {out:?}");
    assert_eq!(ultra.counters.snapshot().recovered, 1);
}

/// An on-path attacker drops a genuine datagram and sends its unchanged
/// ciphertext as single-member parity with a costly mode in the header.
/// The rebuilt datagram is the genuine one and authenticates, and still
/// this side sends nothing extra.
#[test]
fn rewrapped_genuine_ciphertext_does_not_switch_the_mode() {
    let index = [8, 8, 8, 8];
    let peer = origin(1);
    let (sent, _) = group_of(index, 0, 3);
    let rewrapped = parity_datagrams(
        &Group {
            index,
            first: 1,
            ciphertexts: vec![sent[1][WG_DATA_HEADER..].to_vec()],
            priority: None,
        },
        1,
        1,
    );
    let inbox = vec![
        (sent[0].clone(), peer),
        (rewrapped[0].clone(), peer), // stands in for the dropped counter 1
        (sent[2].clone(), peer),      // places the counter epoch
    ];
    let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &sent);
    assert_eq!(
        out,
        vec![sent[0].clone(), sent[2].clone(), sent[1].clone()],
        "the genuine datagram is rebuilt and authenticates"
    );
    assert_eq!(ultra.mode, UltraMode::Off, "the attacker's mode is not adopted");
    ultra.send(&data(index, 3, 40, 0));
    ultra.flush();
    assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
}

/// The session's first data datagram is lost and its group of one has a
/// parity: the parity waits until a later datagram places the epoch.
#[test]
fn a_lost_first_datagram_is_rebuilt_once_the_epoch_is_known() {
    let index = [3, 3, 3, 3];
    let peer = origin(1);
    let (first, parity) = group_of(index, 7, 1);
    let (later, _) = group_of(index, 8, 1);
    let inbox = vec![(parity[0].clone(), peer), (later[0].clone(), peer)];
    let authentic = [first[0].clone(), later[0].clone()];
    let (_, out, _) =
        receive(UltraMode::Fec { group: 1, parity: 1 }, Some(peer), inbox, &authentic);
    assert_eq!(out, vec![later[0].clone(), first[0].clone()]);
}

/// A datagram WireGuard refuses is never kept: a forged one from the
/// peer's address cannot move the counter epoch and break rebuilding.
#[test]
fn a_refused_datagram_cannot_move_the_counter_epoch() {
    let index = [2, 2, 2, 2];
    let peer = origin(1);
    let forged = data(index, 1 << 32, 80, 0xEE);
    let (sent, parity) = group_of(index, 100, 4);
    let mut inbox = vec![(forged, peer)];
    inbox.extend([0, 1, 3].map(|i| (sent[i].clone(), peer)));
    inbox.push((parity[0].clone(), peer));
    let (_, out, _) = receive(UltraMode::Fec { group: 4, parity: 1 }, Some(peer), inbox, &sent);
    assert_eq!(out.last(), Some(&sent[2]), "the lost member is still rebuilt: {out:?}");
}

/// The first datagram WireGuard authenticates from a new origin is kept,
/// so a loss later in its group is still rebuilt.
#[test]
fn the_first_authenticated_datagram_is_kept() {
    let index = [1, 1, 1, 1];
    let peer = origin(1);
    let (sent, parity) = group_of(index, 0, 4);
    let mut inbox: Vec<_> = [0, 1, 3].map(|i| (sent[i].clone(), peer)).to_vec();
    inbox.push((parity[0].clone(), peer));
    let (_, out, _) = receive(UltraMode::Fec { group: 4, parity: 1 }, None, inbox, &sent);
    assert_eq!(out.last(), Some(&sent[2]), "rebuilt with the first member kept: {out:?}");
}

/// A flood of parity makes `poll_recv` yield after `PARITY_PER_POLL` of
/// them, with a wake to come back, so the driver keeps doing its other
/// work; the data behind the flood still arrives on a later poll.
#[test]
fn a_parity_flood_yields_to_the_driver() {
    let index = [4, 4, 4, 4];
    let (sent, parities) = group_of(index, 0, 1);
    let stranger = origin(9999);
    let mut inbox: Vec<_> =
        (0..PARITY_PER_POLL + 10).map(|_| (parities[0].clone(), stranger)).collect();
    inbox.push((sent[0].clone(), origin(1)));
    let script = Script { inbox: inbox.into(), sent: Arc::default() };
    let mut ultra = UltraUnderlay::new(Box::new(script), UltraMode::Off, Arc::default());
    let mut cx = Context::from_waker(std::task::Waker::noop());
    let mut buffer = vec![0u8; 4096];
    assert!(ultra.poll_recv(&mut cx, &mut buffer).is_pending(), "the flood yields");
    match ultra.poll_recv(&mut cx, &mut buffer) {
        Poll::Ready(Ok(received)) => assert_eq!(buffer[..received.len], sent[0][..]),
        other => panic!("the data behind the flood arrives: {other:?}"),
    }
    assert_eq!(ultra.counters.snapshot().parity_received, 0, "untrusted parity is unread");
}

/// A parity that arrives before a reordered member waits for it, and
/// rebuilds the member that is really lost once the late one lands.
#[test]
fn parity_waits_for_a_reordered_member() {
    let index = [7, 7, 7, 7];
    let peer = origin(1);
    let (sent, parity) = group_of(index, 20, 4);
    let mut inbox: Vec<_> = [0, 3].map(|i| (sent[i].clone(), peer)).to_vec();
    inbox.push((parity[0].clone(), peer)); // members 1 and 2 still missing
    inbox.push((sent[1].clone(), peer)); // 1 arrives late; 2 is lost
    let (ultra, out, _) = receive(UltraMode::Fec { group: 4, parity: 1 }, Some(peer), inbox, &sent);
    assert_eq!(out.last(), Some(&sent[2]), "rebuilt after the late member: {out:?}");
    assert!(ultra.pending.is_empty());
}

/// The hello that agrees on FEC arrives in the session's first data
/// datagram, while this side is still off. The driver sets the mode
/// before reporting that datagram authenticated, so it is kept and a loss
/// in the first group is rebuilt (no parity had arrived before).
#[test]
fn an_agreed_mode_rebuilds_the_first_group() {
    let index = [6, 5, 4, 3];
    let peer = origin(1);
    let (sent, parity) = group_of(index, 0, 4);
    let inbox: Vec<_> = [0, 1, 3].map(|i| (sent[i].clone(), peer)).to_vec();
    let script = Script { inbox: inbox.into(), sent: Arc::default() };
    let mut ultra = UltraUnderlay::new(Box::new(script), UltraMode::Off, Arc::default());
    let mut cx = Context::from_waker(std::task::Waker::noop());
    let mut buffer = vec![0u8; 4096];
    let mut first = true;
    while let Poll::Ready(Ok(received)) = ultra.poll_recv(&mut cx, &mut buffer) {
        if first {
            // The hello this datagram carried.
            ultra.set_mode(UltraMode::Fec { group: 4, parity: 1 });
            first = false;
        }
        ultra.authenticated(received.origin);
    }
    ultra.on_parity(&parity[0], peer);
    let rebuilt = ultra.rebuilt.pop_front().map(|(datagram, _)| datagram);
    assert_eq!(rebuilt, Some(sent[2].clone()), "the first group is rebuilt");
}

#[test]
fn modes_built_in_code_are_brought_within_limits() {
    assert_eq!(UltraMode::Duplicate { copies: 0 }.normalized(), UltraMode::Off);
    assert_eq!(UltraMode::Duplicate { copies: 1 }.normalized(), UltraMode::Off);
    assert_eq!(
        UltraMode::Duplicate { copies: 9 }.normalized(),
        UltraMode::Duplicate { copies: MAX_COPIES }
    );
    assert_eq!(UltraMode::Fec { group: 8, parity: 0 }.normalized(), UltraMode::Off);
    assert_eq!(UltraMode::Fec { group: 0, parity: 1 }.normalized(), UltraMode::Off);
    assert_eq!(UltraMode::Fec { group: 2, parity: 3 }.normalized(), UltraMode::Off);
    let ultra = UltraUnderlay::new(
        Box::new(Script { inbox: VecDeque::new(), sent: Arc::default() }),
        UltraMode::Duplicate { copies: 0 },
        Arc::default(),
    );
    assert_eq!(ultra.mode, UltraMode::Off);
}

#[test]
fn parses_reed_solomon_modes() {
    assert_eq!(UltraMode::parse("rs"), Some(UltraMode::Rs { group: 4, parity: 4 }));
    assert_eq!(UltraMode::parse("RS:16:8"), Some(UltraMode::Rs { group: 16, parity: 8 }));
    assert_eq!(UltraMode::parse("rs:2:3"), Some(UltraMode::Rs { group: 2, parity: 3 }));
    assert_eq!(UltraMode::parse("rs:8:16"), None);
    assert_eq!(UltraMode::parse("rs:33:4"), None);
    assert_eq!(UltraMode::parse("rs:8:0"), None);
    assert_eq!(UltraMode::Rs { group: 8, parity: 0 }.normalized(), UltraMode::Off);
    assert_eq!(UltraMode::Rs { group: 8, parity: 4 }.overhead_under_load(), 1.5);
    assert_eq!(UltraMode::rs_parities_for(8, 4, 1), 2, "at least two");
    assert_eq!(UltraMode::rs_parities_for(8, 4, 5), 3);
    assert_eq!(UltraMode::rs_parities_for(8, 4, 8), 4);
    assert_eq!(UltraMode::rs_parities_for(8, 1, 8), 1, "never more than M");
    assert_eq!(UltraMode::rs_parities_for(1, 3, 1), 3, "not capped at the members");
}

fn rs_group(index: [u8; 4], first: u64, lengths: &[usize], m: u8) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let sent: Vec<Vec<u8>> = lengths
        .iter()
        .enumerate()
        .map(|(i, len)| data(index, first.wrapping_add(i as u64), *len, i as u8 * 13))
        .collect();
    let group = Group {
        index,
        first,
        ciphertexts: sent.iter().map(|d| d[WG_DATA_HEADER..].to_vec()).collect(),
        priority: None,
    };
    let parities = rs_parity_datagrams(&group, lengths.len() as u8, m, None);
    (sent, parities)
}

/// Every way to lose up to M of a group's K+M datagrams (data and parity),
/// with members of mixed lengths and the counter crossing a 32-bit
/// boundary, rebuilds every lost data datagram byte for byte; every way to
/// lose M+1 that takes a data datagram rebuilds nothing.
#[test]
fn reed_solomon_rebuilds_any_m_losses_of_a_group() {
    let index = [9, 9, 9, 9];
    let first = 0xFFFF_FFFD_u64;
    let lengths = [40, 1380, 16, 77, 1200, 300, 17, 999];
    let (sent, parities) = rs_group(index, first, &lengths, 4);
    assert_eq!(parities.len(), 4);
    let longest = sent.iter().map(Vec::len).max().unwrap();
    assert!(parities.iter().all(|p| p.len() == longest), "parity fits the path MTU");
    let total = sent.len() + parities.len();
    let mut checked = 0;
    for lost in 0u32..(1 << total) {
        let losses = lost.count_ones() as usize;
        let lost_data: Vec<usize> = (0..sent.len()).filter(|i| lost & (1 << i) != 0).collect();
        if losses > 5 || lost_data.is_empty() {
            continue;
        }
        let mut received = Kept::default();
        for (i, d) in sent.iter().enumerate() {
            if lost & (1 << i) == 0 {
                received.keep(index, first.wrapping_add(i as u64), &d[WG_DATA_HEADER..]);
            }
        }
        let arrived: Vec<Parity<'_>> = (0..parities.len())
            .filter(|j| lost & (1 << (sent.len() + j)) == 0)
            .map(|j| parse_parity(&parities[j]).unwrap())
            .collect();
        if arrived.is_empty() {
            continue; // nothing to rebuild from
        }
        // The epoch is known once any member arrived; with all of them
        // lost a later group would place it.
        if received.newest.is_empty() {
            received.newest.insert(index, first);
        }
        let outcome = received.rebuild_rs(&arrived);
        if losses <= 4 {
            let expected: Vec<Vec<u8>> = lost_data.iter().map(|i| sent[*i].clone()).collect();
            assert_eq!(outcome, Rebuild::DoneAll(expected), "lost {lost:b}");
        } else {
            assert_eq!(outcome, Rebuild::Waiting, "M+1 losses {lost:b}");
        }
        checked += 1;
    }
    assert!(checked > 1000, "{checked} loss patterns");
}

/// Through the underlay: two losses in what would be one XOR subgroup
/// are rebuilt once the second parity lands, and the first parity waits
/// for it.
#[test]
fn reed_solomon_parity_waits_for_its_sibling() {
    let index = [6, 5, 4, 3];
    let peer = origin(1);
    let (sent, parities) = rs_group(index, 40, &[80, 90, 100, 110, 120, 130, 140, 150], 4);
    let mut inbox: Vec<_> = [0, 1, 3, 4, 5, 7].map(|i| (sent[i].clone(), peer)).to_vec();
    inbox.push((parities[1].clone(), peer));
    inbox.push((parities[3].clone(), peer));
    let mode = UltraMode::Rs { group: 8, parity: 4 };
    let (ultra, out, _) = receive(mode, Some(peer), inbox, &sent);
    assert_eq!(out[6..], [sent[2].clone(), sent[6].clone()], "both rebuilt: {out:?}");
    assert!(ultra.pending.is_empty());
    assert_eq!(ultra.counters.snapshot().recovered, 2);
}

/// Reed-Solomon parity from an origin WireGuard never authenticated is
/// ignored, and from the peer it never turns this side's parity on.
#[test]
fn reed_solomon_parity_follows_the_trust_rules() {
    let index = [5, 4, 3, 2];
    let peer = origin(1);
    let stranger = origin(9999);
    let (sent, parities) = rs_group(index, 0, &[60, 70, 80, 90], 2);
    let mut inbox: Vec<_> = [0, 3].map(|i| (sent[i].clone(), peer)).to_vec();
    inbox.extend(parities.iter().map(|p| (p.clone(), stranger)));
    let (ultra, out, _) = receive(UltraMode::Off, Some(peer), inbox.clone(), &sent);
    assert_eq!(out.len(), 2, "nothing rebuilt from a stranger: {out:?}");
    assert_eq!(ultra.counters.snapshot().parity_received, 0);
    // From the peer: its first parity turns rebuilding on (that group is
    // whole), and the next group's two losses are rebuilt.
    let (earlier, earlier_parity) = rs_group(index, 100, &[60], 1);
    let mut inbox = vec![(earlier[0].clone(), peer), (earlier_parity[0].clone(), peer)];
    inbox.extend([0, 3].map(|i| (sent[i].clone(), peer)));
    inbox.extend(parities.iter().map(|p| (p.clone(), peer)));
    let authentic: Vec<_> = earlier.iter().chain(&sent).cloned().collect();
    let (mut ultra, out, wire) = receive(UltraMode::Off, Some(peer), inbox, &authentic);
    // (The earlier group's datagram was not kept, so it is rebuilt too.)
    assert_eq!(
        out[out.len() - 2..],
        [sent[1].clone(), sent[2].clone()],
        "rebuilt from the peer: {out:?}"
    );
    assert_eq!(ultra.mode, UltraMode::Off, "the peer's mode is not adopted");
    ultra.send(&data(index, 9, 40, 0));
    ultra.flush();
    assert_eq!(wire.lock().unwrap().len(), 1, "no parity goes out");
}

/// Bytes a group of `lengths` (ciphertext bytes) costs in `mode`, sent by
/// a side started `configured`: (sent bytes / data bytes, parities).
fn group_cost(configured: UltraMode, mode: UltraMode, lengths: &[usize]) -> (f64, u64) {
    let script = Script { inbox: VecDeque::new(), sent: Arc::default() };
    let mut ultra = UltraUnderlay::new(Box::new(script), configured, Arc::default());
    ultra.set_mode(mode);
    for (i, len) in lengths.iter().enumerate() {
        ultra.send(&data([2, 2, 2, 2], i as u64, *len, 0));
    }
    ultra.flush();
    let stats = ultra.counters.snapshot();
    let ratio = (stats.data_bytes + stats.overhead_bytes) as f64 / stats.data_bytes as f64;
    (ratio, stats.parity_sent)
}

/// The 4x a peer can ask for counts bytes. Reed-Solomon parity is as
/// long as the group's longest datagram, so a full datagram among small
/// ones (the case from the review: `rs:5:15` with one 1232-byte member
/// and four of 80) sent 12.9x its bytes; taken up from the peer, it now
/// sends at most 4x, with fewer parities. The side's own mode is the
/// user's choice and is not capped, and groups of like sizes keep every
/// parity.
#[test]
fn a_mode_taken_up_from_the_peer_sends_at_most_four_times_the_bytes() {
    let mixed = [1232 - WG_DATA_HEADER, 64, 64, 64, 64];
    let costly = UltraMode::Rs { group: 5, parity: 15 };
    let (own, parities) = group_cost(costly, costly, &mixed);
    assert!(own > 12.0 && parities == 15, "own mode, uncapped: {own:.2}x, {parities}");
    let (taken_up, parities) = group_cost(UltraMode::Off, costly, &mixed);
    assert!(taken_up <= 4.0, "{taken_up:.2}x with {parities} parities");
    assert!(parities >= 1);

    let setting = UltraMode::Rs { group: 4, parity: 4 };
    let shapes: [&[usize]; 5] =
        [&[1216, 64, 64, 64], &[1216], &[64], &[1216, 1216, 1216, 1216], &[1216, 64]];
    for lengths in shapes {
        let (ratio, _) = group_cost(UltraMode::Off, setting, lengths);
        assert!(ratio <= 4.0, "{lengths:?}: {ratio:.2}x");
    }
    let full = [1216; 4];
    assert_eq!(group_cost(UltraMode::Off, setting, &full).1, 4, "like sizes keep all four");
    assert_eq!(group_cost(UltraMode::Off, setting, &[64]).1, 2, "a lone datagram keeps two");
    let (own, parities) = group_cost(setting, setting, &[1216, 64, 64, 64]);
    assert!(own > 4.0 && parities == 4, "the setting at its own side: {own:.2}x");
}

/// A Reed-Solomon sender sends its parities after each group, and an XOR
/// receiver's parser and a Reed-Solomon one tell them apart.
#[test]
fn a_reed_solomon_sender_sends_versioned_parity() {
    let wire: Wire = Arc::default();
    let script = Script { inbox: VecDeque::new(), sent: Arc::clone(&wire) };
    let mode = UltraMode::Rs { group: 4, parity: 2 };
    let mut ultra = UltraUnderlay::new(Box::new(script), mode, Arc::default());
    for i in 0..4 {
        ultra.send(&data([1, 1, 1, 1], i, 50, 0));
    }
    ultra.send(&data([1, 1, 1, 1], 4, 50, 0));
    ultra.flush();
    let wire = wire.lock().unwrap();
    let parity: Vec<&Vec<u8>> = wire.iter().filter(|d| is_parity(d)).collect();
    assert_eq!(parity.len(), 4, "2 for the full group, and 2 for the lone datagram");
    assert!(parity.iter().all(|p| p[1] == VERSION_RS && classify(p) == DatagramClass::Unknown));
    assert!(parity.iter().all(|p| parse_parity(p).unwrap().code == Code::ReedSolomon));
}

#[test]
fn parity_is_never_a_wireguard_or_stun_message() {
    let group = Group { index: [0; 4], first: 0, ciphertexts: vec![vec![0; 32]], priority: None };
    let parity = &parity_datagrams(&group, 8, 2)[0];
    assert_eq!(classify(parity), DatagramClass::Unknown);
}
