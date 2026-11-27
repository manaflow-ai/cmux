use super::*;

const TX: TransactionId = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

#[test]
fn rfc5769_ipv4_response_vector() {
    // RFC 5769 section 2.2, attributes other than XOR-MAPPED-ADDRESS
    // replaced by nothing: 192.0.2.1:32853.
    let tx = [0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae];
    let mut bytes = vec![0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42];
    bytes.extend_from_slice(&tx);
    bytes.extend_from_slice(&[
        0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43,
    ]);
    let addr = parse_binding_success(&bytes, &tx).expect("vector parses");
    assert_eq!(addr, "192.0.2.1:32853".parse().expect("address"));
}

#[test]
fn foreign_transactions_are_refused() {
    let response = binding_success(TX, "203.0.113.9:1".parse().expect("address"));
    assert_eq!(parse_binding_success(&response, &[0; 12]), Err(StunError::WrongTransaction));
    assert_eq!(parse_binding_success(&binding_request(TX), &TX), Err(StunError::NotBindingSuccess));
}
