use super::*;

fn self_signed(name: &str) -> CertificateDer<'static> {
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec![name.to_owned()]).unwrap();
    params.self_signed(&key).unwrap().der().clone()
}

/// A chain no web PKI root signed (a company root's re-signed
/// certificate) is inspected; nothing to judge is not.
#[test]
fn a_chain_outside_the_web_pki_is_inspected() {
    assert!(chain_inspected("relay.cmux.dev", &[self_signed("relay.cmux.dev")]));
    assert!(!chain_inspected("relay.cmux.dev", &[]));
    assert!(!chain_inspected("not a name", &[self_signed("x")]));
}
