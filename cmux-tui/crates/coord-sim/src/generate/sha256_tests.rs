use super::*;

fn hash(b: &[u8]) -> String {
    let mut s = Sha256::default();
    s.update(b);
    s.hex()
}

#[test]
fn known_vectors() {
    assert_eq!(hash(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert_eq!(hash(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    let long = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    assert_eq!(hash(long), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    let mut s = Sha256::default();
    for chunk in vec![b'a'; 1_000_000].chunks(777) {
        s.update(chunk);
    }
    assert_eq!(s.hex(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}
