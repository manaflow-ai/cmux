use super::*;

// A Fragment Header with more fragments remaining
static BYTES_HEADER_MORE_FRAG: [u8; 6] = [0x0, 0x1, 0x0, 0x0, 0x30, 0x39];

// A Fragment Header with no more fragments remaining
static BYTES_HEADER_LAST_FRAG: [u8; 6] = [0xa, 0x0, 0x0, 0x1, 0x9, 0x32];

#[test]
fn test_check_len() {
    // less than 6 bytes
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&BYTES_HEADER_MORE_FRAG[..5]).check_len()
    );
    // valid
    assert_eq!(
        Ok(()),
        Header::new_unchecked(&BYTES_HEADER_MORE_FRAG).check_len()
    );
}

#[test]
fn test_header_deconstruct() {
    let header = Header::new_unchecked(&BYTES_HEADER_MORE_FRAG);
    assert_eq!(header.frag_offset(), 0);
    assert!(header.more_frags());
    assert_eq!(header.ident(), 12345);

    let header = Header::new_unchecked(&BYTES_HEADER_LAST_FRAG);
    assert_eq!(header.frag_offset(), 320);
    assert!(!header.more_frags());
    assert_eq!(header.ident(), 67890);
}

#[test]
fn test_repr_parse_valid() {
    let header = Header::new_unchecked(&BYTES_HEADER_MORE_FRAG);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(
        repr,
        Repr {
            frag_offset: 0,
            more_frags: true,
            ident: 12345
        }
    );

    let header = Header::new_unchecked(&BYTES_HEADER_LAST_FRAG);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(
        repr,
        Repr {
            frag_offset: 320,
            more_frags: false,
            ident: 67890
        }
    );
}

#[test]
fn test_repr_emit() {
    let repr = Repr {
        frag_offset: 0,
        more_frags: true,
        ident: 12345,
    };
    let mut bytes = [0u8; 6];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);
    assert_eq!(header.into_inner(), &BYTES_HEADER_MORE_FRAG[0..6]);

    let repr = Repr {
        frag_offset: 320,
        more_frags: false,
        ident: 67890,
    };
    let mut bytes = [0u8; 6];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);
    assert_eq!(header.into_inner(), &BYTES_HEADER_LAST_FRAG[0..6]);
}

#[test]
fn test_buffer_len() {
    let header = Header::new_unchecked(&BYTES_HEADER_MORE_FRAG);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(repr.buffer_len(), BYTES_HEADER_MORE_FRAG.len());
}
