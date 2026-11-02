//! The VM's original identity, not a replacement grant returned during refresh.

use std::cell::RefCell;
use std::rc::Rc;

use cmux_server_core::install_key::{InstallKey, SystemRandom, verify};
use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::sender::Answer;
use super::wire::{Bound, Env};

const NOW: u64 = 1_792_000_000_000;
const TEAM: &str = "team_00000000000000000001";
const MACHINE: &str = "vm_00000000000000000004";
const INSTALL: &str = "inst_00000000000000000004";
const USER: &str = "user_00000000000000000001";
const GRANT: &str = "grant_00000000000000000004";

type Seen = Rc<RefCell<Vec<String>>>;

#[derive(Clone)]
struct Server {
    public: Value,
    token: Value,
    seen: Seen,
}

impl Http for Server {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.seen.borrow_mut().push(url.to_owned());
        if url.ends_with("/v1/auth/challenge") {
            assert!(bearer.is_none());
            return Ok((
                200,
                json!({ "install": INSTALL, "nonce": "00000000000000000000000000000001",
                "expires_at": NOW + 60_000, "message_prefix": format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n") }),
            ));
        }
        if url.ends_with("/v1/auth/token") {
            assert!(bearer.is_none());
            let signed =
                format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n00000000000000000000000000000001");
            assert!(verify(&self.public, signed.as_bytes(), body["signature"].as_str().unwrap()));
            return Ok((200, self.token.clone()));
        }
        assert!(url.ends_with("/v1/read"));
        assert_eq!(bearer, Some("test-vm-bearer"));
        Ok((
            200,
            json!({ "op": body["op"], "value": { "machine": MACHINE },
            "stream": format!("cloud:{TEAM}"), "revision": "1" }),
        ))
    }
}

fn client(change: impl FnOnce(&mut Bound, &mut Value)) -> (CloudClient<Server>, Seen) {
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let mut bound = Bound {
        machine: MACHINE.into(),
        team: TEAM.into(),
        host: "host_00000000000000000004".into(),
        epoch: 2,
        install: INSTALL.into(),
        user: USER.into(),
        grant: GRANT.into(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().into(),
        keyset: Value::Null,
        bound_at: NOW,
    };
    let mut token = json!({ "access_token": "test-vm-bearer", "token_type": "Bearer", "expires_at": NOW + 600_000,
        "user": USER, "install": INSTALL, "grant": GRANT, "team": TEAM });
    change(&mut bound, &mut token);
    let seen = Rc::new(RefCell::new(Vec::new()));
    let server = Server { public: key.public_jwk(), token, seen: seen.clone() };
    (CloudClient::new(server, bound, key), seen)
}

macro_rules! refuses_field {
    ($test:ident, $field:literal) => {
        #[test]
        fn $test() {
            let (mut client, seen) =
                client(|_, token| token[$field] = "another-original-identity".into());
            assert!(
                client.token(NOW).is_err(),
                "a token for another original {} was accepted",
                $field
            );
            assert_eq!(seen.borrow().len(), 2);
        }
    };
}

refuses_field!(vm_receiver_client_refuses_replacement_grant, "grant");
refuses_field!(vm_receiver_client_refuses_other_team, "team");
refuses_field!(vm_receiver_client_refuses_other_install, "install");
refuses_field!(vm_receiver_client_refuses_other_user, "user");

#[test]
fn vm_receiver_client_refuses_other_origin_before_signing_or_sending() {
    let (mut client, seen) = client(|bound, _| bound.api_origin = "https://another.test".into());
    assert!(client.token(NOW).is_err());
    assert!(seen.borrow().is_empty(), "an unpinned origin received a request");
}

#[test]
fn vm_receiver_client_generic_read_has_no_receiving_authority_context() {
    let (mut client, _) = client(|_, _| {});
    assert!(matches!(
        client.read("cloud.vm.network_policy", &json!({ "machine": MACHINE }), NOW),
        Answer::Transport
    ));
}

#[test]
fn vm_receiver_client_keeps_original_auth_and_existing_self_read() {
    let (mut client, seen) = client(|_, _| {});
    assert_eq!(client.token(NOW).unwrap(), "test-vm-bearer");
    assert!(matches!(
        client.read("cloud.vm.self.get", &json!({ "machine": MACHINE }), NOW),
        Answer::Http { status: 200, .. }
    ));
    assert_eq!(seen.borrow().len(), 3, "the self read reuses the original token");
}

#[test]
fn team_ssh_binding_without_a_grant_still_authenticates() {
    // team_ssh::sync::client_bound records no grant; its CA and account sync
    // must keep a token while user, install and team stay pinned.
    let (mut team_ssh, _) = client(|bound, _| bound.grant = String::new());
    assert_eq!(team_ssh.token(NOW).unwrap(), "test-vm-bearer");
    let (mut other_team, _) = client(|bound, token| {
        bound.grant = String::new();
        token["team"] = "another-original-identity".into();
    });
    assert!(other_team.token(NOW).is_err());
}
