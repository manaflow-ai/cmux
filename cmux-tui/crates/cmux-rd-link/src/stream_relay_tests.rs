use super::*;

fn stun(kind: u8, body: usize) -> Vec<u8> {
    let mut m = vec![0u8; 20 + body];
    m[0] = kind;
    m[1] = 0x01;
    m[2..4].copy_from_slice(&u16::try_from(body).unwrap().to_be_bytes());
    for (i, b) in m[20..].iter_mut().enumerate() {
        *b = i as u8;
    }
    m
}

fn channel_data(number: u16, payload: &[u8]) -> Vec<u8> {
    let mut m = number.to_be_bytes().to_vec();
    m.extend_from_slice(&u16::try_from(payload.len()).unwrap().to_be_bytes());
    m.extend_from_slice(payload);
    m
}

fn drain(d: &mut Deframer) -> Result<Vec<Vec<u8>>, Desync> {
    let mut out = Vec::new();
    while let Some(m) = d.next_frame()? {
        out.push(m.to_vec());
    }
    Ok(out)
}

#[test]
fn channel_data_is_padded_to_four_on_the_stream_and_stun_is_left_alone() {
    let mut out = Vec::new();
    frame(&channel_data(0x4001, &[7; 5]), &mut out);
    assert_eq!(out.len(), 12, "4-byte header + 5 bytes, padded to 12");
    assert_eq!(&out[9..], &[0, 0, 0]);
    let mut aligned = Vec::new();
    frame(&channel_data(0x4001, &[7; 8]), &mut aligned);
    assert_eq!(aligned.len(), 12, "already aligned: no padding");
    let mut message = Vec::new();
    frame(&stun(0x01, 8), &mut message);
    assert_eq!(message, stun(0x01, 8));
}

#[test]
fn messages_split_at_every_byte_come_out_whole_and_without_padding() {
    let messages = vec![
        stun(0x01, 12),
        channel_data(0x4000, &[1, 2, 3]),
        channel_data(0x4FFF, &[]),
        channel_data(0x4002, &[9; 1001]),
        stun(0x01, 0),
        channel_data(0x4003, &[5; 4]),
    ];
    let mut wire = Vec::new();
    for m in &messages {
        frame(m, &mut wire);
    }
    // One byte at a time: the worst split a stream can make.
    let mut d = Deframer::default();
    let mut got = Vec::new();
    for byte in &wire {
        d.push(std::slice::from_ref(byte));
        got.extend(drain(&mut d).unwrap());
    }
    assert_eq!(got, messages);
    // Every two-piece split, the header itself cut included.
    for cut in 0..=wire.len() {
        let mut d = Deframer::default();
        d.push(&wire[..cut]);
        let mut got = drain(&mut d).unwrap();
        d.push(&wire[cut..]);
        got.extend(drain(&mut d).unwrap());
        assert_eq!(got, messages, "split at {cut}");
    }
}

#[test]
fn a_channel_data_message_waits_for_its_padding() {
    let mut wire = Vec::new();
    frame(&channel_data(0x4000, &[1, 2, 3, 4, 5]), &mut wire);
    let mut d = Deframer::default();
    d.push(&wire[..9]);
    assert_eq!(d.next_frame().unwrap(), None, "payload whole, padding not yet");
    d.push(&wire[9..11]);
    assert_eq!(d.next_frame().unwrap(), None);
    d.push(&wire[11..]);
    assert_eq!(d.next_frame().unwrap(), Some(&channel_data(0x4000, &[1, 2, 3, 4, 5])[..]));
    assert_eq!(d.next_frame().unwrap(), None);
}

#[test]
fn a_stream_that_is_not_turn_framing_is_refused() {
    let mut d = Deframer::default();
    d.push(&[0x16, 0x03, 0x01, 0x00]);
    assert_eq!(d.next_frame(), Err(Desync(0x16)), "a TLS record on a plain TCP relay");
    let mut d = Deframer::default();
    let mut bad = stun(0x01, 4);
    bad[3] = 3;
    d.push(&bad);
    assert_eq!(d.next_frame(), Err(Desync(0x01)), "a STUN length that is not aligned");
}

#[test]
fn a_connect_to_a_closed_port_fails_the_relay() {
    // A listener bound then dropped: its port refuses connections.
    let addr = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    // Loopback may refuse at once; that is the same failure, earlier.
    let Ok(mut relay) = StreamRelay::connect(addr, None, 0) else { return };
    let start = std::time::Instant::now();
    let failed = loop {
        sys::wait_ready(&[(relay.raw(), relay.wants_write())], 50);
        if let Err(why) = relay.poll(0) {
            break why;
        }
        assert!(start.elapsed() < std::time::Duration::from_secs(5), "never failed");
    };
    assert!(failed.starts_with("connect"), "{failed}");
    if let Ok(mut late) = StreamRelay::connect(addr, None, 0) {
        assert_eq!(late.poll(CONNECT_US).map_err(|e| e.contains("connect")), Err(true));
    }
}

#[test]
fn a_tcp_relay_writes_framed_messages_and_reads_split_ones() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let mut relay = StreamRelay::connect(listener.local_addr().unwrap(), None, 0).unwrap();
    let (mut server, _) = listener.accept().unwrap();
    let start = std::time::Instant::now();
    while !relay.is_ready() {
        sys::wait_ready(&[(relay.raw(), relay.wants_write())], 50);
        relay.poll(1).unwrap();
        assert!(start.elapsed() < std::time::Duration::from_secs(5), "never connected");
    }
    assert_eq!(relay.send(&channel_data(0x4000, &[1, 2, 3])), Some(8));
    let mut got = [0u8; 8];
    server.read_exact(&mut got).unwrap();
    assert_eq!(got, [0x40, 0x00, 0x00, 0x03, 1, 2, 3, 0]);
    // The server's two messages arrive in three writes, cut mid-header.
    let mut wire = Vec::new();
    frame(&stun(0x01, 4), &mut wire);
    frame(&channel_data(0x4000, &[8; 6]), &mut wire);
    server.write_all(&wire[..2]).unwrap();
    server.flush().unwrap();
    let mut seen = Vec::new();
    relay.read(|m| seen.push(m.to_vec())).unwrap();
    server.write_all(&wire[2..27]).unwrap();
    server.write_all(&wire[27..]).unwrap();
    let start = std::time::Instant::now();
    while seen.len() < 2 && start.elapsed() < std::time::Duration::from_secs(5) {
        sys::wait_ready(&[(relay.raw(), false)], 50);
        relay.read(|m| seen.push(m.to_vec())).unwrap();
    }
    assert_eq!(seen, vec![stun(0x01, 4), channel_data(0x4000, &[8; 6])]);
    drop(server);
    let start = std::time::Instant::now();
    let ended = loop {
        sys::wait_ready(&[(relay.raw(), false)], 50);
        if let Err(why) = relay.read(|_| {}) {
            break why;
        }
        assert!(start.elapsed() < std::time::Duration::from_secs(5), "close never seen");
    };
    assert!(ended.contains("closed"), "{ended}");
}
