use super::*;

/// A chat's restart attach reply as it crosses the machine link: one JSON line
/// of agent message chunks, tool calls and their output (~75 KB).
pub(crate) fn chat_attach_line() -> Vec<u8> {
    let words = [
        "the",
        "daemon",
        "restart",
        "reads",
        "session",
        "journal",
        "attach",
        "reply",
        "tool",
        "call",
        "output",
        "cargo",
        "test",
        "passed",
        "Leo",
        "asked",
        "render",
        "pane",
        "link",
        "slow",
        "bytes",
        "socket",
        "connection",
        "settles",
        "line",
        "update",
        "machine",
        "chat",
    ];
    let mut records = Vec::new();
    let mut seed = 7_u32;
    let mut sentence = |count: usize| {
        (0..count)
            .map(|_| {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                words[(seed >> 16) as usize % words.len()]
            })
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut seq = 1_u64;
    while serde_json::to_vec(&records).unwrap().len() < 75_000 {
        records.push(serde_json::json!({
            "seq": seq,
            "update": {"sessionUpdate": "agent_message_chunk",
                       "content": {"type": "text", "text": sentence(40)}},
        }));
        records.push(serde_json::json!({
            "seq": seq + 1,
            "update": {"sessionUpdate": "tool_call", "toolCallId": format!("toolu_{seq:08}"),
                       "title": format!("Bash: {}", sentence(6)), "kind": "execute",
                       "status": "completed",
                       "rawInput": {"command": format!("cd /tmp && {}", sentence(8))},
                       "content": [{"type": "content",
                                    "content": {"type": "text", "text": sentence(60)}}]},
        }));
        seq += 2;
    }
    let mut line = serde_json::to_vec(&serde_json::json!({
        "id": 7, "ok": true, "result": {"session": "chat", "records": records},
    }))
    .unwrap();
    line.push(b'\n');
    line
}

fn assemble(assembler: &mut MuxLineAssembler, packets: Vec<Bytes>) -> Result<Bytes, MuxCodecError> {
    let mut line = None;
    for packet in packets {
        line = assembler.push_retaining(Lane::Bulk, packet, ())?;
    }
    Ok(line.expect("every part was pushed").payload().clone())
}

#[test]
fn a_stream_without_zlib_gets_the_plain_line() {
    let line = chat_attach_line();
    let packets = encode_line_for_client(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES, false).unwrap();
    assert!(packets.iter().all(|packet| packet.starts_with(&MAGIC)));
    // A client from before the codec (no `accepting_zlib`) reads it unchanged.
    let mut old = MuxLineAssembler::default();
    assert_eq!(assemble(&mut old, packets).unwrap(), line);
}

#[test]
fn a_zlib_stream_compresses_a_large_line_to_the_same_text() {
    let line = chat_attach_line();
    let packets = encode_line_for_client(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    assert!(packets.iter().all(|packet| packet.starts_with(&ZLIB_MAGIC)));
    let wire: usize = packets.iter().map(Bytes::len).sum();
    assert!(wire * 3 < line.len(), "{} bytes went to {wire}", line.len());
    let mut assembler = MuxLineAssembler::default().accepting_zlib(true);
    assert_eq!(assemble(&mut assembler, packets).unwrap(), line);
}

#[test]
fn a_zlib_stream_keeps_small_lines_plain() {
    let line = b"{\"id\":1,\"ok\":true}\n".to_vec();
    let packets = encode_line_for_client(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    assert!(packets.iter().all(|packet| packet.starts_with(&MAGIC)));
    let mut assembler = MuxLineAssembler::default().accepting_zlib(true);
    assert_eq!(assemble(&mut assembler, packets).unwrap(), line);
    // Just under the threshold stays plain too.
    let mut edge = vec![b'a'; MUX_LINE_ZLIB_MIN_BYTES - 1];
    edge[MUX_LINE_ZLIB_MIN_BYTES - 2] = b'\n';
    let packets = encode_line_for_client(2, &edge, MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    assert!(packets.iter().all(|packet| packet.starts_with(&MAGIC)));
}

#[test]
fn a_line_that_does_not_shrink_stays_plain() {
    let mut seed = 1_u64;
    let mut line: Vec<u8> = (0..MUX_LINE_ZLIB_MIN_BYTES * 2)
        .map(|_| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as u8
        })
        .collect();
    line.push(b'\n');
    let packets = encode_line_for_client(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    assert!(packets.iter().all(|packet| packet.starts_with(&MAGIC)));
}

#[test]
fn a_zlib_packet_on_a_stream_that_did_not_negotiate_it_is_refused() {
    let packets =
        encode_line_for_client(1, &chat_attach_line(), MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    let mut old = MuxLineAssembler::default();
    assert_eq!(
        old.push_retaining(Lane::Bulk, packets[0].clone(), ()).err(),
        Some(MuxCodecError::InvalidPacket)
    );
}

#[test]
fn a_garbage_zlib_line_is_refused() {
    let packets = encode_parts(ZLIB_MAGIC, 1, b"not a zlib stream at all").unwrap();
    let mut assembler = MuxLineAssembler::default().accepting_zlib(true);
    assert_eq!(assemble(&mut assembler, packets).err(), Some(MuxCodecError::InvalidCompressedLine));
}

#[test]
fn a_zlib_line_that_inflates_past_the_line_limit_is_refused_bounded() {
    // 4 MiB of zeros deflates to a few KB; the reader's limit is 64 KiB.
    let bomb = deflate(&vec![0_u8; 4 << 20]);
    assert!(bomb.len() < 64 << 10);
    let packets = encode_parts(ZLIB_MAGIC, 1, &bomb).unwrap();
    let mut assembler = MuxLineAssembler::with_maximum(64 << 10).accepting_zlib(true);
    assert!(matches!(
        assemble(&mut assembler, packets),
        Err(MuxCodecError::LineTooLarge(size)) if size == (64 << 10) + 1
    ));
}

#[test]
fn plain_and_zlib_parts_of_one_message_do_not_mix() {
    let line = chat_attach_line();
    let zlib = encode_line_for_client(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES, true).unwrap();
    let plain = encode_line_with_limit(1, &line, MAX_MUX_DOWNLOAD_LINE_BYTES).unwrap();
    assert!(zlib.len() > 1 || plain.len() > 1);
    let mut assembler = MuxLineAssembler::default().accepting_zlib(true);
    assert!(assembler.push_retaining(Lane::Bulk, plain[0].clone(), ()).unwrap().is_none());
    assert_eq!(
        assembler.push_retaining(Lane::Bulk, zlib[0].clone(), ()).err(),
        Some(MuxCodecError::InvalidPacket)
    );
}
