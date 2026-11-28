use super::platform_key_session;

const KEYS: &str = "restrict,expiry-time=\"20261125224500\",command=\"/home/cmux/.cmux/bin/cmux-tui remote-link --stdio\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne cmux-ssh:1764110700:n1\nrestrict,expiry-time=\"20261125224500\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo cmux-ssh:1764110701:n2\n";

#[test]
fn a_login_with_the_platforms_carrier_key_is_a_platform_session() {
    assert!(platform_key_session("publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne\n", KEYS));
    assert!(platform_key_session("publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo", KEYS));
}

#[test]
fn anything_else_is_not() {
    assert!(!platform_key_session("", KEYS), "no method at all");
    assert!(
        !platform_key_session("publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther\n", KEYS),
        "unlisted key"
    );
    assert!(
        !platform_key_session("publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne\n", ""),
        "no key file"
    );
    assert!(
        !platform_key_session(
            "publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne\npassword\n",
            KEYS
        ),
        "a second method"
    );
    assert!(
        !platform_key_session(
            "publickey ssh-ed25519-cert-v01@openssh.com AAAAC3NzaC1lZDI1NTE5AAAAIOne\n",
            KEYS
        ),
        "a certificate"
    );
    assert!(
        !platform_key_session(
            "publickey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne\n",
            &format!("# {KEYS}")
        ),
        "a commented-out line"
    );
}
