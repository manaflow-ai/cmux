use super::*;

fn key() -> Vec<u8> {
    (0u8..32).collect()
}

const NONCE: [u8; NONCE_LEN] = [0xa5; NONCE_LEN];
/// The same vector the Swift side tests (`FrontendInstallKeyTests`).
const VECTOR: &str = "1878e5949b7e511bb06b3f98939beabd11626e5519834bb0fa371420cecb6793";

#[test]
fn hello_proof_matches_the_shared_vector() {
    assert_eq!(hello_proof(&key(), "inst_test-01", &NONCE), VECTOR);
    assert!(verify_hello_proof(&key(), "inst_test-01", &NONCE, VECTOR));
    assert!(verify_hello_proof(&key(), "inst_test-01", &NONCE, &VECTOR.to_uppercase()));
}
