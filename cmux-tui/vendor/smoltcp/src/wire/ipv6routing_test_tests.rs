use super::*;

// A Type 2 Routing Header
static BYTES_TYPE2: [u8; 22] = [
    0x2, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
    0x0, 0x0, 0x1,
];

// A representation of a Type 2 Routing header
static REPR_TYPE2: Repr = Repr::Type2 {
    segments_left: 1,
    home_address: Address::LOCALHOST,
};

// A Source Routing Header with full IPv6 addresses in bytes
static BYTES_SRH_FULL: [u8; 38] = [
    0x3, 0x2, 0x0, 0x0, 0x0, 0x0, 0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
    0x0, 0x0, 0x2, 0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x3, 0x1,
];

// A representation of a Source Routing Header with full IPv6 addresses
static REPR_SRH_FULL: Repr = Repr::Rpl {
    segments_left: 2,
    cmpr_i: 0,
    cmpr_e: 0,
    pad: 0,
    addresses: &[
        0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x2, 0xfd, 0x0,
        0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x3, 0x1,
    ],
};

// A Source Routing Header with elided IPv6 addresses in bytes
static BYTES_SRH_ELIDED: [u8; 14] = [
    0x3, 0x2, 0xfe, 0x50, 0x0, 0x0, 0x2, 0x3, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0,
];

// A representation of a Source Routing Header with elided IPv6 addresses
static REPR_SRH_ELIDED: Repr = Repr::Rpl {
    segments_left: 2,
    cmpr_i: 15,
    cmpr_e: 14,
    pad: 5,
    addresses: &[0x2, 0x3, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0],
};

#[test]
fn test_check_len() {
    // less than min header size
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&BYTES_TYPE2[..3]).check_len()
    );
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&BYTES_SRH_FULL[..3]).check_len()
    );
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&BYTES_SRH_ELIDED[..3]).check_len()
    );
    // valid
    assert_eq!(Ok(()), Header::new_unchecked(&BYTES_TYPE2[..]).check_len());
    assert_eq!(
        Ok(()),
        Header::new_unchecked(&BYTES_SRH_FULL[..]).check_len()
    );
    assert_eq!(
        Ok(()),
        Header::new_unchecked(&BYTES_SRH_ELIDED[..]).check_len()
    );
}

#[test]
fn test_header_deconstruct() {
    let header = Header::new_unchecked(&BYTES_TYPE2[..]);
    assert_eq!(header.routing_type(), Type::Type2);
    assert_eq!(header.segments_left(), 1);
    assert_eq!(header.home_address(), Address::LOCALHOST);

    let header = Header::new_unchecked(&BYTES_SRH_FULL[..]);
    assert_eq!(header.routing_type(), Type::Rpl);
    assert_eq!(header.segments_left(), 2);
    assert_eq!(header.addresses(), &BYTES_SRH_FULL[6..]);

    let header = Header::new_unchecked(&BYTES_SRH_ELIDED[..]);
    assert_eq!(header.routing_type(), Type::Rpl);
    assert_eq!(header.segments_left(), 2);
    assert_eq!(header.addresses(), &BYTES_SRH_ELIDED[6..]);
}

#[test]
fn test_repr_parse_valid() {
    let header = Header::new_checked(&BYTES_TYPE2[..]).unwrap();
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(repr, REPR_TYPE2);

    let header = Header::new_checked(&BYTES_SRH_FULL[..]).unwrap();
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(repr, REPR_SRH_FULL);

    let header = Header::new_checked(&BYTES_SRH_ELIDED[..]).unwrap();
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(repr, REPR_SRH_ELIDED);
}

#[test]
fn test_repr_emit() {
    let mut bytes = [0xFFu8; 22];
    let mut header = Header::new_unchecked(&mut bytes[..]);
    REPR_TYPE2.emit(&mut header);
    assert_eq!(header.into_inner(), &BYTES_TYPE2[..]);

    let mut bytes = [0xFFu8; 38];
    let mut header = Header::new_unchecked(&mut bytes[..]);
    REPR_SRH_FULL.emit(&mut header);
    assert_eq!(header.into_inner(), &BYTES_SRH_FULL[..]);

    let mut bytes = [0xFFu8; 14];
    let mut header = Header::new_unchecked(&mut bytes[..]);
    REPR_SRH_ELIDED.emit(&mut header);
    assert_eq!(header.into_inner(), &BYTES_SRH_ELIDED[..]);
}

#[test]
fn test_buffer_len() {
    assert_eq!(REPR_TYPE2.buffer_len(), 22);
    assert_eq!(REPR_SRH_FULL.buffer_len(), 38);
    assert_eq!(REPR_SRH_ELIDED.buffer_len(), 14);
}
