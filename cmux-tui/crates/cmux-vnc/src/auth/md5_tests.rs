use super::digest;

fn hex(bytes: [u8; 16]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn md5_matches_rfc_1321_vectors() {
    assert_eq!(hex(digest(b"")), "d41d8cd98f00b204e9800998ecf8427e");
    assert_eq!(hex(digest(b"abc")), "900150983cd24fb0d6963f7d28e17f72");
    assert_eq!(hex(digest(b"message digest")), "f96b697d7cb7938d525a2f31aaf161d0");
    assert_eq!(
        hex(digest(
            b"12345678901234567890123456789012345678901234567890123456789012345678901234567890"
        )),
        "57edf4a22be3c955ac49da2e2107b67a"
    );
}
