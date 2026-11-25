use super::*;
use std::io::Write;

/// A map file of one slice, as `write-app-symbol-map.py` writes it.
fn map_file(uuid: [u8; 16], symbols: &[(u64, &str)]) -> Vec<u8> {
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
    body.extend(symbols.iter().map(|(_, name)| *name).collect::<Vec<_>>().join("\0").bytes());
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(&body).unwrap();
    let payload = encoder.finish().unwrap();
    let mut file = b"CMXSYM1\0".to_vec();
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
    assert_eq!(map.function(0x1000), Some(("_ZN4cmux4main17h0123456789abcdefE", 0)));
    assert_eq!(map.function(0x11ff), Some(("_ZN4cmux4main17h0123456789abcdefE", 0x1ff)));
    assert_eq!(map.function(0x1234), Some(("tokio_poll", 0x34)));
    // Before the first function and past the end of __text: no name.
    assert_eq!(map.function(0xfff), None);
    assert_eq!(map.function(0x2000), None);
}

#[test]
fn another_build_or_a_bad_file_has_no_map() {
    let file = map_file([7u8; 16], &[(0x1000, "f"), (0x2000, "")]);
    assert!(SymbolMap::parse(&file, &[8u8; 16]).is_none());
    assert!(SymbolMap::parse(b"CMXSYM1\0garbage", &[7u8; 16]).is_none());
    assert!(SymbolMap::parse(b"", &[7u8; 16]).is_none());
}
