use super::*;
use std::io::Write;

/// Where a Rust legacy name's `17h<hash>E` tail starts, as `write-app-symbol-map.py`'s
/// `rust_hash_at` finds it: a `_ZN` name whose last path component is the hash.
fn rust_hash_at(name: &[u8]) -> Option<usize> {
    let mut at = if name.starts_with(b"_ZN") { 3 } else { None? };
    while name.get(at).is_some_and(u8::is_ascii_digit) {
        let digits = at + name[at..].iter().take_while(|b| b.is_ascii_digit()).count();
        let end = digits + std::str::from_utf8(&name[at..digits]).ok()?.parse::<usize>().ok()?;
        if end + 1 == name.len() && name[end] == b'E' {
            let hash = &name[digits..end];
            let is_hash = &name[at..digits] == b"17"
                && hash[0] == b'h'
                && hash[1..].iter().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
            return is_hash.then_some(at);
        }
        at = end;
    }
    None
}

/// A map file of one slice, as `write-app-symbol-map.py` writes it: CMXSYM2, or CMXSYM1
/// when a name holds the hash mark byte.
fn map_file(uuid: [u8; 16], symbols: &[(u64, &str)]) -> Vec<u8> {
    let v2 = !symbols.iter().any(|(_, name)| name.contains('\u{1}'));
    let mut body = (symbols.len() as u32).to_le_bytes().to_vec();
    let mut previous = 0;
    for (offset, _) in symbols {
        let mut delta = offset - previous;
        previous = *offset;
        loop {
            let byte = (delta & 0x7F) as u8;
            delta >>= 7;
            body.push(byte | if delta != 0 { 0x80 } else { 0 });
            if delta == 0 {
                break;
            }
        }
    }
    let mut previous: Vec<u8> = Vec::new();
    let (mut shared, mut rests) = (Vec::new(), Vec::new());
    for (_, name) in symbols.iter().filter(|_| v2) {
        let mut name = name.as_bytes().to_vec();
        // As the writer does: a legacy Rust hash becomes the one byte 0x01.
        if let Some(at) = rust_hash_at(&name) {
            name.truncate(at);
            name.push(1);
        }
        let same = name.iter().zip(&previous).take_while(|(a, b)| a == b).count().min(255);
        shared.push(same as u8);
        rests.extend_from_slice(&name[same..]);
        rests.push(0);
        previous = name;
    }
    if v2 {
        body.extend(shared);
        body.extend(rests);
    } else {
        body.extend(symbols.iter().map(|(_, name)| *name).collect::<Vec<_>>().join("\0").bytes());
    }
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(&body).unwrap();
    let payload = encoder.finish().unwrap();
    let mut file = if v2 { b"CMXSYM2\0" } else { b"CMXSYM1\0" }.to_vec();
    file.extend(1u32.to_le_bytes());
    file.extend(uuid);
    file.extend((payload.len() as u32).to_le_bytes());
    file.extend(payload);
    file
}

#[test]
fn names_the_function_holding_an_offset() {
    let uuid = [7u8; 16];
    let file = map_file(
        uuid,
        &[(0x1000, "_ZN4cmux4main17h0123456789abcdefE"), (0x1200, "tokio_poll"), (0x2000, "")],
    );
    let map = SymbolMap::parse(&file, &uuid).expect("slice for uuid");
    // The hash is not kept: it reads back as zeros, which the demangler never prints.
    let main = "_ZN4cmux4main17h0000000000000000E";
    assert_eq!(map.function(0x1000), Some((main, 0)));
    assert_eq!(map.function(0x11ff), Some((main, 0x1ff)));
    assert_eq!(map.function(0x1234), Some(("tokio_poll", 0x34)));
    // Before the first function and past the end of __text: no name.
    assert_eq!(map.function(0xfff), None);
    assert_eq!(map.function(0x2000), None);
}

#[test]
fn names_sharing_a_prefix_read_back_whole() {
    let uuid = [7u8; 16];
    let file = map_file(
        uuid,
        &[
            (0x10, "_ZN4core3fmt5write17h00000000000000aaE"),
            (0x20, "_ZN4core3fmt5write17h00000000000000bbE"),
            (0x30, "_ZN4core3fmt3foo17h00000000000000ccE"),
            (0x40, "_ZN4core3fmt3foo"),
            (0x50, "_ZN4core3fmt3foobar"),
            (0x60, ""),
        ],
    );
    let map = SymbolMap::parse(&file, &uuid).expect("slice for uuid");
    assert_eq!(map.function(0x10).unwrap().0, "_ZN4core3fmt5write17h0000000000000000E");
    assert_eq!(map.function(0x20).unwrap().0, "_ZN4core3fmt5write17h0000000000000000E");
    assert_eq!(map.function(0x30).unwrap().0, "_ZN4core3fmt3foo17h0000000000000000E");
    assert_eq!(map.function(0x40).unwrap().0, "_ZN4core3fmt3foo");
    assert_eq!(map.function(0x50).unwrap().0, "_ZN4core3fmt3foobar");
    assert_eq!(map.function(0x60), None);
}

#[test]
fn only_a_rust_legacy_hash_reads_back_as_zeros() {
    // cmux#52364 F3: a C++ name can hold `17h<16 hex>E` inside a parameter type, and a Rust
    // name can hold one before its last component; both read back whole.
    let names = [
        "_Z3fooN1A17h0123456789abcdefE",
        "_ZN1A17h0123456789abcdefE3fooE",
        "_ZN4core3ptr17h0123456789abcdefE",
        "_ZN4core3ptr17h0123456789abcdefE.llvm.42",
        "_ZN4core3ptr17h0123456789ABCDEFE",
        "_ZN4core3ptr17g0123456789abcdefE",
    ];
    let uuid = [7u8; 16];
    let symbols: Vec<(u64, &str)> = names
        .iter()
        .enumerate()
        .map(|(i, n)| (0x10 * (i as u64 + 1), *n))
        .chain([(0x100, "")])
        .collect();
    let map = SymbolMap::parse(&map_file(uuid, &symbols), &uuid).expect("slice for uuid");
    assert_eq!(map.function(0x10).unwrap().0, names[0]);
    assert_eq!(map.function(0x20).unwrap().0, names[1]);
    assert_eq!(map.function(0x30).unwrap().0, "_ZN4core3ptr17h0000000000000000E");
    assert_eq!(map.function(0x40).unwrap().0, names[3]);
    assert_eq!(map.function(0x50).unwrap().0, names[4]);
    assert_eq!(map.function(0x60).unwrap().0, names[5]);
}

#[test]
fn a_name_with_the_hash_mark_byte_reads_back_from_the_first_format() {
    // cmux#52364 F4: a 0x01 in a name makes the writer fall back to CMXSYM1, not fail.
    let uuid = [7u8; 16];
    let file = map_file(
        uuid,
        &[(0x10, "odd\u{1}"), (0x20, "_ZN4cmux4main17h0123456789abcdefE"), (0x30, "")],
    );
    assert_eq!(&file[..8], b"CMXSYM1\0");
    let map = SymbolMap::parse(&file, &uuid).expect("slice for uuid");
    assert_eq!(map.function(0x10).unwrap().0, "odd\u{1}");
    assert_eq!(map.function(0x20).unwrap().0, "_ZN4cmux4main17h0123456789abcdefE");
}

#[test]
fn another_build_or_a_bad_file_has_no_map() {
    let file = map_file([7u8; 16], &[(0x1000, "f"), (0x2000, "")]);
    assert!(SymbolMap::parse(&file, &[8u8; 16]).is_none());
    assert!(SymbolMap::parse(b"CMXSYM1\0garbage", &[7u8; 16]).is_none());
    assert!(SymbolMap::parse(b"", &[7u8; 16]).is_none());
}
