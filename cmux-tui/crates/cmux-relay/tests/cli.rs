//! The relay binary's refusals at its command line: an open relay never starts without
//! --allow-open, and the ticket command never mints a ticket that lives past five minutes.

use std::process::{Command, Output};

const SECRET: &str = "0123456789abcdef0123456789abcdef";

fn relay(arguments: &[&str], secret: Option<&str>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-relay"));
    command.args(arguments).env_remove("CMUX_RELAY_HMAC_SECRET").env_remove("CMUX_RELAY_BIND");
    if let Some(secret) = secret {
        command.env("CMUX_RELAY_HMAC_SECRET", secret);
    }
    command.output().expect("run cmux-relay")
}

#[test]
fn a_relay_without_a_secret_refuses_to_start() {
    let output = relay(&["--bind", "127.0.0.1:0"], None);
    assert!(!output.status.success(), "an open relay started: {output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("refusing an open relay"), "{stderr}");
}

#[test]
fn the_ticket_command_refuses_a_lifetime_over_five_minutes() {
    let output = relay(
        &["ticket", "--permission", "register", "--slot", "slot-a", "--ttl-seconds", "301"],
        Some(SECRET),
    );
    assert!(!output.status.success(), "a 301 s ticket was minted: {output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("cannot exceed 300 seconds"), "{stderr}");

    let output = relay(
        &["ticket", "--permission", "register", "--slot", "slot-a", "--ttl-seconds", "300"],
        Some(SECRET),
    );
    assert!(output.status.success(), "a 300 s ticket was refused: {output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("v2."));
}
