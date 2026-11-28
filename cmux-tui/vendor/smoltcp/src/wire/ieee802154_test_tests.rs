use super::*;

#[test]
fn test_broadcast() {
    assert!(Address::BROADCAST.is_broadcast());
    assert!(!Address::BROADCAST.is_unicast());
}

#[test]
fn prepare_frame() {
    let mut buffer = [0u8; 128];

    let repr = Repr {
        frame_type: FrameType::Data,
        security_enabled: false,
        frame_pending: false,
        ack_request: true,
        pan_id_compression: true,
        frame_version: FrameVersion::Ieee802154,
        sequence_number: Some(1),
        dst_pan_id: Some(Pan(0xabcd)),
        dst_addr: Some(Address::BROADCAST),
        src_pan_id: None,
        src_addr: Some(Address::Extended([
            0xc7, 0xd9, 0xb5, 0x14, 0x00, 0x4b, 0x12, 0x00,
        ])),
    };

    let buffer_len = repr.buffer_len();

    let mut frame = Frame::new_unchecked(&mut buffer[..buffer_len]);
    repr.emit(&mut frame);

    println!("{frame:2x?}");

    assert_eq!(frame.frame_type(), FrameType::Data);
    assert!(!frame.security_enabled());
    assert!(!frame.frame_pending());
    assert!(frame.ack_request());
    assert!(frame.pan_id_compression());
    assert_eq!(frame.frame_version(), FrameVersion::Ieee802154);
    assert_eq!(frame.sequence_number(), Some(1));
    assert_eq!(frame.dst_pan_id(), Some(Pan(0xabcd)));
    assert_eq!(frame.dst_addr(), Some(Address::BROADCAST));
    assert_eq!(frame.src_pan_id(), None);
    assert_eq!(
        frame.src_addr(),
        Some(Address::Extended([
            0xc7, 0xd9, 0xb5, 0x14, 0x00, 0x4b, 0x12, 0x00
        ]))
    );
}

macro_rules! vector_test {
    ($name:ident $bytes:expr ; $($test_method:ident -> $expected:expr,)*) => {
        #[test]
        #[allow(clippy::bool_assert_comparison)]
        fn $name() -> Result<()> {
            let frame = &$bytes;
            let frame = Frame::new_checked(frame)?;

            $(
                assert_eq!(frame.$test_method(), $expected, stringify!($test_method));
            )*

            Ok(())
        }
    }
}

vector_test! {
    extended_addr
    [
        0b0000_0001, 0b1100_1100, // frame control
        0b0, // seq
        0xcd, 0xab, // pan id
        0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, // dst addr
        0x03, 0x04, // pan id
        0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, // src addr
    ];
    frame_type -> FrameType::Data,
    dst_addr -> Some(Address::Extended([0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00])),
    src_addr -> Some(Address::Extended([0x02, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00])),
    dst_pan_id -> Some(Pan(0xabcd)),
}

vector_test! {
    short_addr
    [
        0x01, 0x98,             // frame control
        0x00,                   // sequence number
        0x34, 0x12, 0x78, 0x56, // PAN identifier and address of destination
        0x34, 0x12, 0xbc, 0x9a, // PAN identifier and address of source
    ];
    frame_type -> FrameType::Data,
    security_enabled -> false,
    frame_pending -> false,
    ack_request -> false,
    pan_id_compression -> false,
    dst_addressing_mode -> AddressingMode::Short,
    frame_version -> FrameVersion::Ieee802154_2006,
    src_addressing_mode -> AddressingMode::Short,
    dst_pan_id -> Some(Pan(0x1234)),
    dst_addr -> Some(Address::Short([0x56, 0x78])),
    src_pan_id -> Some(Pan(0x1234)),
    src_addr -> Some(Address::Short([0x9a, 0xbc])),
}

vector_test! {
    zolertia_remote
    [
        0x41, 0xd8, // frame control
        0x01, // sequence number
        0xcd, 0xab, // Destination PAN id
        0xff, 0xff, // Short destination address
        0xc7, 0xd9, 0xb5, 0x14, 0x00, 0x4b, 0x12, 0x00, // Extended source address
        0x2b, 0x00, 0x00, 0x00, // payload
    ];
    frame_type -> FrameType::Data,
    security_enabled -> false,
    frame_pending -> false,
    ack_request -> false,
    pan_id_compression -> true,
    dst_addressing_mode -> AddressingMode::Short,
    frame_version -> FrameVersion::Ieee802154_2006,
    src_addressing_mode -> AddressingMode::Extended,
    payload -> Some(&[0x2b, 0x00, 0x00, 0x00][..]),
}

vector_test! {
    security
    [
        0x69,0xdc, // frame control
        0x32, // sequence number
        0xcd,0xab, // destination PAN id
        0xbf,0x9b,0x15,0x06,0x00,0x4b,0x12,0x00, // extended destination address
        0xc7,0xd9,0xb5,0x14,0x00,0x4b,0x12,0x00, // extended source address
        0x05, // security control field
        0x31,0x01,0x00,0x00, // frame counter
        0x3e,0xe8,0xfb,0x85,0xe4,0xcc,0xf4,0x48,0x90,0xfe,0x56,0x66,0xf7,0x1c,0x65,0x9e,0xf9, // data
        0x93,0xc8,0x34,0x2e,// MIC
    ];
    frame_type -> FrameType::Data,
    security_enabled -> true,
    frame_pending -> false,
    ack_request -> true,
    pan_id_compression -> true,
    dst_addressing_mode -> AddressingMode::Extended,
    frame_version -> FrameVersion::Ieee802154_2006,
    src_addressing_mode -> AddressingMode::Extended,
    dst_pan_id -> Some(Pan(0xabcd)),
    dst_addr -> Some(Address::Extended([0x00,0x12,0x4b,0x00,0x06,0x15,0x9b,0xbf])),
    src_pan_id -> None,
    src_addr -> Some(Address::Extended([0x00,0x12,0x4b,0x00,0x14,0xb5,0xd9,0xc7])),
    security_level -> 5,
    key_identifier_mode -> 0,
    frame_counter -> Some(305),
    key_source -> None,
    key_index -> None,
    payload -> Some(&[0x3e,0xe8,0xfb,0x85,0xe4,0xcc,0xf4,0x48,0x90,0xfe,0x56,0x66,0xf7,0x1c,0x65,0x9e,0xf9,0x93,0xc8,0x34,0x2e][..]),
    message_integrity_code -> Some(&[0x93, 0xC8, 0x34, 0x2E][..]),
    mac_header -> &[
        0x69,0xdc, // frame control
        0x32, // sequence number
        0xcd,0xab, // destination PAN id
        0xbf,0x9b,0x15,0x06,0x00,0x4b,0x12,0x00, // extended destination address
        0xc7,0xd9,0xb5,0x14,0x00,0x4b,0x12,0x00, // extended source address
        0x05, // security control field
        0x31,0x01,0x00,0x00, // frame counter
    ][..],
}
