use super::*;

// A Hop-by-Hop Option header with a PadN option of option data length 4.
static REPR_PACKET_PAD4: [u8; 8] = [0x6, 0x0, 0x1, 0x4, 0x0, 0x0, 0x0, 0x0];

// A Hop-by-Hop Option header with a PadN option of option data length 12.
static REPR_PACKET_PAD12: [u8; 16] = [
    0x06, 0x1, 0x1, 0x0C, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
];

#[test]
fn test_check_len() {
    // zero byte buffer
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&REPR_PACKET_PAD4[..0]).check_len()
    );
    // no length field
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&REPR_PACKET_PAD4[..1]).check_len()
    );
    // less than 8 bytes
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&REPR_PACKET_PAD4[..7]).check_len()
    );
    // valid
    assert_eq!(Ok(()), Header::new_unchecked(&REPR_PACKET_PAD4).check_len());
    // valid
    assert_eq!(
        Ok(()),
        Header::new_unchecked(&REPR_PACKET_PAD12).check_len()
    );
    // length field value greater than number of bytes
    let header: [u8; 8] = [0x06, 0x2, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0];
    assert_eq!(Err(Error), Header::new_unchecked(&header).check_len());
}

#[test]
fn test_header_deconstruct() {
    let header = Header::new_unchecked(&REPR_PACKET_PAD4);
    assert_eq!(header.next_header(), IpProtocol::Tcp);
    assert_eq!(header.header_len(), 0);
    assert_eq!(header.payload(), &REPR_PACKET_PAD4[2..]);

    let header = Header::new_unchecked(&REPR_PACKET_PAD12);
    assert_eq!(header.next_header(), IpProtocol::Tcp);
    assert_eq!(header.header_len(), 1);
    assert_eq!(header.payload(), &REPR_PACKET_PAD12[2..]);
}

#[test]
fn test_overlong() {
    let mut bytes = vec![];
    bytes.extend(&REPR_PACKET_PAD4[..]);
    bytes.push(0);

    assert_eq!(
        Header::new_unchecked(&bytes).payload().len(),
        REPR_PACKET_PAD4[2..].len()
    );
    assert_eq!(
        Header::new_unchecked(&mut bytes).payload_mut().len(),
        REPR_PACKET_PAD4[2..].len()
    );

    let mut bytes = vec![];
    bytes.extend(&REPR_PACKET_PAD12[..]);
    bytes.push(0);

    assert_eq!(
        Header::new_unchecked(&bytes).payload().len(),
        REPR_PACKET_PAD12[2..].len()
    );
    assert_eq!(
        Header::new_unchecked(&mut bytes).payload_mut().len(),
        REPR_PACKET_PAD12[2..].len()
    );
}

#[test]
fn test_header_len_overflow() {
    let mut bytes = vec![];
    bytes.extend(REPR_PACKET_PAD4);
    let len = bytes.len() as u8;
    Header::new_unchecked(&mut bytes).set_header_len(len + 1);

    assert_eq!(Header::new_checked(&bytes).unwrap_err(), Error);

    let mut bytes = vec![];
    bytes.extend(REPR_PACKET_PAD12);
    let len = bytes.len() as u8;
    Header::new_unchecked(&mut bytes).set_header_len(len + 1);

    assert_eq!(Header::new_checked(&bytes).unwrap_err(), Error);
}

#[test]
fn test_repr_parse_valid() {
    let header = Header::new_unchecked(&REPR_PACKET_PAD4);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(
        repr,
        Repr {
            next_header: IpProtocol::Tcp,
            length: 0,
            data: &REPR_PACKET_PAD4[2..]
        }
    );

    let header = Header::new_unchecked(&REPR_PACKET_PAD12);
    let repr = Repr::parse(&header).unwrap();
    assert_eq!(
        repr,
        Repr {
            next_header: IpProtocol::Tcp,
            length: 1,
            data: &REPR_PACKET_PAD12[2..]
        }
    );
}

#[test]
fn test_repr_emit() {
    let repr = Repr {
        next_header: IpProtocol::Tcp,
        length: 0,
        data: &REPR_PACKET_PAD4[2..],
    };
    let mut bytes = [0u8; 2];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);
    assert_eq!(header.into_inner(), &REPR_PACKET_PAD4[..2]);

    let repr = Repr {
        next_header: IpProtocol::Tcp,
        length: 1,
        data: &REPR_PACKET_PAD12[2..],
    };
    let mut bytes = [0u8; 2];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);
    assert_eq!(header.into_inner(), &REPR_PACKET_PAD12[..2]);
}
