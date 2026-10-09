use super::cert::session_certs;
use super::test_support::{b64, cert_blob};

#[test]
fn certificate_lines_give_serial_and_key_id() {
    let body = b64(&cert_blob(42, 1, "alice/grant/install/n1"));
    let info = format!(
        "password\npublickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA== plain\npublickey ssh-ed25519-cert-v01@openssh.com {body}\n"
    );
    let certs = session_certs(&info).expect("parses");
    assert_eq!(certs.len(), 1, "plain keys and other methods are skipped");
    assert_eq!(certs[0].serial, 42);
    assert_eq!(certs[0].key_id, "alice/grant/install/n1");
    assert_eq!(certs[0].line, format!("ssh-ed25519-cert-v01@openssh.com {body}"));
}

#[test]
fn unparsable_or_host_certificates_are_errors_not_silently_skipped() {
    let host = b64(&cert_blob(1, 2, "host"));
    assert!(session_certs(&format!("publickey ssh-ed25519-cert-v01@openssh.com {host}")).is_err());
    assert!(session_certs("publickey ssh-ed25519-cert-v01@openssh.com AAAA").is_err());
    assert!(session_certs("publickey ssh-ed25519-cert-v01@openssh.com %%%").is_err());
    assert!(session_certs("publickey ssh-rsa-cert-v01@openssh.com AAAA").is_err());
    assert_eq!(session_certs("").expect("empty"), vec![]);
}
