use super::*;

static LEAVE_PACKET_BYTES: [u8; 8] = [0x17, 0x00, 0x02, 0x69, 0xe0, 0x00, 0x06, 0x96];
static REPORT_PACKET_BYTES: [u8; 8] = [0x16, 0x00, 0x08, 0xda, 0xe1, 0x00, 0x00, 0x25];

#[test]
fn test_leave_group_deconstruct() {
    let packet = Packet::new_unchecked(&LEAVE_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::LeaveGroup);
    assert_eq!(packet.max_resp_code(), 0);
    assert_eq!(packet.checksum(), 0x269);
    assert_eq!(
        packet.group_addr(),
        Ipv4Address::from_octets([224, 0, 6, 150])
    );
    assert!(packet.verify_checksum());
}

#[test]
fn test_report_deconstruct() {
    let packet = Packet::new_unchecked(&REPORT_PACKET_BYTES[..]);
    assert_eq!(packet.msg_type(), Message::MembershipReportV2);
    assert_eq!(packet.max_resp_code(), 0);
    assert_eq!(packet.checksum(), 0x08da);
    assert_eq!(
        packet.group_addr(),
        Ipv4Address::from_octets([225, 0, 0, 37])
    );
    assert!(packet.verify_checksum());
}

#[test]
fn test_leave_construct() {
    let mut bytes = vec![0xa5; 8];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::LeaveGroup);
    packet.set_max_resp_code(0);
    packet.set_group_address(Ipv4Address::from_octets([224, 0, 6, 150]));
    packet.fill_checksum();
    assert_eq!(&*packet.into_inner(), &LEAVE_PACKET_BYTES[..]);
}

#[test]
fn test_report_construct() {
    let mut bytes = vec![0xa5; 8];
    let mut packet = Packet::new_unchecked(&mut bytes);
    packet.set_msg_type(Message::MembershipReportV2);
    packet.set_max_resp_code(0);
    packet.set_group_address(Ipv4Address::from_octets([225, 0, 0, 37]));
    packet.fill_checksum();
    assert_eq!(&*packet.into_inner(), &REPORT_PACKET_BYTES[..]);
}

#[test]
fn max_resp_time_to_duration_and_back() {
    for i in 0..256usize {
        let time1 = i as u8;
        let duration = max_resp_code_to_duration(time1);
        let time2 = duration_to_max_resp_code(duration);
        assert!(time1 == time2);
    }
}

#[test]
fn duration_to_max_resp_time_max() {
    for duration in 31744..65536 {
        let time = duration_to_max_resp_code(Duration::from_millis(duration * 100));
        assert_eq!(time, 0xFF);
    }
}
