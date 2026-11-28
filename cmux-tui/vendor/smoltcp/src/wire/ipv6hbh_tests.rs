use super::*;
use crate::wire::Error;

// A Hop-by-Hop Option header with a PadN option of option data length 4.
static REPR_PACKET_PAD4: [u8; 6] = [0x1, 0x4, 0x0, 0x0, 0x0, 0x0];

// A Hop-by-Hop Option header with a PadN option of option data length 12.
static REPR_PACKET_PAD12: [u8; 14] = [
    0x1, 0x0C, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
];

#[test]
fn test_check_len() {
    // zero byte buffer
    assert_eq!(
        Err(Error),
        Header::new_unchecked(&REPR_PACKET_PAD4[..0]).check_len()
    );
    // valid
    assert_eq!(Ok(()), Header::new_unchecked(&REPR_PACKET_PAD4).check_len());
    // valid
    assert_eq!(
        Ok(()),
        Header::new_unchecked(&REPR_PACKET_PAD12).check_len()
    );
}

#[test]
fn test_repr_parse_valid() {
    let header = Header::new_unchecked(&REPR_PACKET_PAD4);
    let repr = Repr::parse(&header).unwrap();

    let mut options = Vec::new();
    options.push(Ipv6OptionRepr::PadN(4)).unwrap();
    assert_eq!(repr, Repr { options });

    let header = Header::new_unchecked(&REPR_PACKET_PAD12);
    let repr = Repr::parse(&header).unwrap();

    let mut options = Vec::new();
    options.push(Ipv6OptionRepr::PadN(12)).unwrap();
    assert_eq!(repr, Repr { options });
}

#[test]
fn test_repr_emit() {
    let mut options = Vec::new();
    options.push(Ipv6OptionRepr::PadN(4)).unwrap();
    let repr = Repr { options };

    let mut bytes = [0u8; 6];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);

    assert_eq!(header.into_inner(), &REPR_PACKET_PAD4[..]);

    let mut options = Vec::new();
    options.push(Ipv6OptionRepr::PadN(12)).unwrap();
    let repr = Repr { options };

    let mut bytes = [0u8; 14];
    let mut header = Header::new_unchecked(&mut bytes);
    repr.emit(&mut header);

    assert_eq!(header.into_inner(), &REPR_PACKET_PAD12[..]);
}
