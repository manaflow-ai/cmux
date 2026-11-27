//! The whole path against an in-memory server shaped like cmux-platform's SealedVaultRoute.ts: the Mac turns the
//! vault on and imports a .env, the iPhone joins and is approved by its code, the Mac goes away, the iPhone seals to
//! a new machine, the machine opens its values; rotation, rollback, scopes, and that no value reaches the server in
//! the clear.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::client::{DeviceStore, Http, Vault, VaultRef};
use crate::crypto::{self, DeviceKey, Sealed};
use crate::{Scope, dotenv, machine};

#[derive(Default)]
struct Server {
    epoch: u64,
    devices: Vec<Value>,
    wraps: BTreeMap<String, Value>,
    items: BTreeMap<String, Value>,
    deliveries: BTreeMap<String, Vec<Value>>,
    machines: Vec<(String, Vec<u8>)>,
    /// Every body the server was sent, to check no value went in the clear.
    seen: Vec<String>,
}

struct Fake<'s>(&'s RefCell<Server>);

impl Http for Fake<'_> {
    fn send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let mut s = self.0.borrow_mut();
        if let Some(body) = body {
            s.seen.push(body.to_string());
        }
        let device = headers
            .iter()
            .find(|(k, _)| *k == crate::client::DEVICE_HEADER)
            .map(|(_, v)| (*v).to_owned());
        let (route, _query) = path.split_once('?').unwrap_or((path, ""));
        let rest = route.strip_prefix(crate::client::BASE).unwrap_or(route);
        let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
        let ok = |v: Value| Ok((200, v));
        match (method, parts.as_slice()) {
            ("GET", []) => {
                let wrap = device.and_then(|d| s.wraps.get(&d).cloned());
                let mut answer = json!({"vault": "personal", "epoch": s.epoch, "devices": s.devices, "items": s.items.values().collect::<Vec<_>>()});
                if let Some(wrap) = wrap {
                    answer["wrap"] = wrap;
                }
                ok(answer)
            }
            ("POST", ["devices"]) => {
                let body = body.unwrap();
                let id = body["id"].as_str().unwrap().to_owned();
                let empty = !s.devices.iter().any(|d| d["state"] == "active") && s.items.is_empty();
                let active = empty && body.get("wrap").is_some();
                if active && body["wrap"]["epoch"].as_u64() != Some(s.epoch + 1) {
                    return Ok((
                        409,
                        json!({"error": {"code": "vault.epoch.stale", "message": "the first device's wrap is for the next epoch"}}),
                    ));
                }
                if active {
                    s.epoch += 1;
                    s.wraps.insert(id.clone(), body["wrap"].clone());
                }
                s.devices.push(json!({"id": id, "kind": body["kind"], "label": body["label"], "publicKey": body["publicKey"], "state": if active {"active"} else {"pending"}, "createdAt": 1}));
                ok(json!({"device": id}))
            }
            ("POST", ["devices", target, "approve"]) => {
                let body = body.unwrap();
                s.wraps.insert(
                    (*target).to_owned(),
                    json!({"epoch": body["epoch"], "enc": body["enc"], "ct": body["ct"]}),
                );
                for d in &mut s.devices {
                    if d["id"] == *target {
                        d["state"] = json!("active");
                    }
                }
                ok(json!({}))
            }
            ("DELETE", ["devices", target]) => {
                s.devices.retain(|d| d["id"] != *target);
                s.wraps.remove(*target);
                ok(json!({}))
            }
            ("PUT", ["items", id]) => {
                let body = body.unwrap();
                let current = s.items.get(*id).map_or(0, |i| i["revision"].as_u64().unwrap());
                if body["expectedRevision"].as_u64() != Some(current) {
                    return Ok((
                        409,
                        json!({"error": {"code": "vault.item.conflict", "message": "moved"}}),
                    ));
                }
                let mut item = body.clone();
                item["id"] = json!(id);
                item["updatedAt"] = json!(2);
                s.items.insert((*id).to_owned(), item);
                ok(json!({}))
            }
            ("DELETE", ["items", id]) => {
                s.items.remove(*id);
                ok(json!({}))
            }
            ("POST", ["rotate"]) => {
                let body = body.unwrap();
                s.epoch = body["epoch"].as_u64().unwrap();
                s.items.clear();
                for item in body["items"].as_array().unwrap() {
                    let mut item = item.clone();
                    item["updatedAt"] = json!(3);
                    s.items.insert(item["id"].as_str().unwrap().to_owned(), item);
                }
                s.wraps.clear();
                for wrap in body["wraps"].as_array().unwrap() {
                    s.wraps.insert(wrap["device"].as_str().unwrap().to_owned(), wrap.clone());
                }
                ok(json!({}))
            }
            ("GET", ["machines"]) => {
                let machines: Vec<Value> = s
                    .machines
                    .iter()
                    .map(|(id, key)| {
                        let delivered: Vec<Value> = s.deliveries.get(id).cloned().unwrap_or_default().iter().map(|d| json!({"name": d["name"], "revision": d["revision"]})).collect();
                        json!({"id": id, "name": "m", "state": "running", "daemonKey": crate::b64::encode(key), "delivered": delivered})
                    })
                    .collect();
                ok(json!({"machines": machines}))
            }
            ("PUT", ["machines", vm, "delivery"]) => {
                s.deliveries
                    .insert((*vm).to_owned(), body.unwrap()["items"].as_array().unwrap().clone());
                ok(json!({}))
            }
            _ => Ok((404, json!({"error": {"code": "route.not_found", "message": "no"}}))),
        }
    }
}

#[derive(Default)]
struct Store(RefCell<Option<(String, Vec<u8>)>>);

impl DeviceStore for Store {
    fn load(&self) -> Result<Option<(String, Zeroizing<Vec<u8>>)>, String> {
        Ok(self.0.borrow().as_ref().map(|(id, k)| (id.clone(), Zeroizing::new(k.clone()))))
    }
    fn save(&self, id: &str, private_key: &[u8]) -> Result<(), String> {
        *self.0.borrow_mut() = Some((id.to_owned(), private_key.to_vec()));
        Ok(())
    }
}

fn clock() -> u64 {
    thread_local!(static T: RefCell<u64> = const { RefCell::new(1_000) });
    T.with(|t| {
        *t.borrow_mut() += 1;
        *t.borrow()
    })
}

fn vault<'a>(http: &'a Fake<'a>, store: &'a Store, kind: &str) -> Vault<'a, Fake<'a>, Store> {
    Vault {
        http,
        store,
        vault: VaultRef::personal(),
        kind: kind.to_owned(),
        label: kind.to_owned(),
        now_ms: clock,
    }
}

const VM: &str = "vm_abcdefghij0123456789";
const DOTENV: &str = "# a comment\nexport OPENAI_API_KEY=sk-test-openai-123456\nSTRIPE_KEY=\"sk_live_with\\\"quote\"\nPLAIN = spaced value # tail\nnot a line\nMULTI=\"one\ntwo\"\n";

fn machine_open(
    server: &RefCell<Server>,
    daemon: &DeviceKey,
) -> BTreeMap<String, Zeroizing<String>> {
    let items: Vec<Value> = server
        .borrow()
        .deliveries
        .get(VM)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|mut i| {
            i["vault"] = json!("personal");
            i
        })
        .collect();
    let (answered, delivered, refused) =
        machine::parse_answer(&json!({"machine": VM, "items": items})).unwrap();
    assert_eq!(refused, 0);
    let (values, _, applied) = machine::open_all(
        daemon.private_bytes(),
        VM,
        &answered,
        &delivered,
        &machine::State::default(),
    );
    assert!(applied.refused.is_empty(), "{:?}", applied.refused);
    values
}

#[test]
fn mac_imports_phone_joins_machine_gets_values_with_mac_gone() {
    let server = RefCell::new(Server::default());
    let http = Fake(&server);
    let (mac_store, phone_store) = (Store::default(), Store::default());
    let mac = vault(&http, &mac_store, "mac");
    assert_eq!(mac.status().unwrap().state, "off");
    assert_eq!(mac.enroll().unwrap().state, "active");

    let parsed = dotenv::parse(DOTENV);
    assert_eq!(parsed.skipped_lines, vec![5]);
    let names: Vec<&str> = parsed.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["OPENAI_API_KEY", "STRIPE_KEY", "PLAIN", "MULTI"]);
    assert_eq!(parsed.entries[1].value.as_str(), "sk_live_with\"quote");
    assert_eq!(parsed.entries[2].value.as_str(), "spaced value");
    assert_eq!(parsed.entries[3].value.as_str(), "one\ntwo");
    // The person ticks two of the four.
    let picked: Vec<(&str, &Scope, &str)> = parsed
        .entries
        .iter()
        .filter(|e| e.name == "OPENAI_API_KEY" || e.name == "STRIPE_KEY")
        .map(|e| (e.name.as_str(), &Scope::All, e.value.as_str()))
        .collect();
    mac.set_many(&picked).unwrap();
    let only_here = Scope::Machine(VM.to_owned());
    mac.set("OPENAI_API_KEY", &only_here, "sk-machine-specific-999").unwrap();

    let phone = vault(&http, &phone_store, "iphone");
    let joined = phone.enroll().unwrap();
    assert_eq!(joined.state, "pending");
    assert!(phone.sync().is_err(), "a pending device holds no key");
    let wrong = mac.approve("0000 0000");
    assert_eq!(wrong.unwrap_err().code, "vault.no_such_code");
    mac.approve(joined.safety_code.as_deref().unwrap()).unwrap();
    assert_eq!(phone.status().unwrap().state, "active");

    // The Mac is off from here on. A machine is made from the phone.
    let daemon = DeviceKey::generate().unwrap();
    server.borrow_mut().machines.push((VM.to_owned(), daemon.public_bytes().to_vec()));
    let rows = phone.sync().unwrap();
    assert_eq!(rows[0].outcome, "delivered");
    assert_eq!(rows[0].names, ["OPENAI_API_KEY", "STRIPE_KEY"]);
    assert_eq!(phone.sync().unwrap()[0].outcome, "current");

    let values = machine_open(&server, &daemon);
    assert_eq!(values["OPENAI_API_KEY"].as_str(), "sk-machine-specific-999", "machine scope wins");
    assert_eq!(values["STRIPE_KEY"].as_str(), "sk_live_with\"quote");

    let env = machine::render_env("export DELIVERED_BY_MAC='x'\n", &BTreeSet::new(), &values);
    assert!(env.contains("export DELIVERED_BY_MAC='x'\n"));
    assert!(env.contains("export STRIPE_KEY='sk_live_with\"quote'\n"));

    // Nothing the server was sent holds a value.
    for body in &server.borrow().seen {
        for secret in
            ["sk-test-openai-123456", "sk_live_with", "sk-machine-specific-999", "spaced value"]
        {
            assert!(!body.contains(secret), "a value reached the server");
        }
    }
}

#[test]
fn removing_a_device_rotates_and_old_key_opens_nothing_new() {
    let server = RefCell::new(Server::default());
    let http = Fake(&server);
    let (a_store, b_store) = (Store::default(), Store::default());
    let a = vault(&http, &a_store, "mac");
    a.enroll().unwrap();
    a.set("TOKEN_ONE", &Scope::All, "value-one-12345").unwrap();
    let b = vault(&http, &b_store, "cli");
    let code = b.enroll().unwrap().safety_code.unwrap();
    a.approve(&code).unwrap();
    let b_id = b.status().unwrap().device_id.unwrap();
    assert_eq!(a.remove_device(&b_id).unwrap(), 2);
    assert!(b.set("TOKEN_TWO", &Scope::All, "value-two-12345").is_err());
    // A still reads and writes under the new epoch, and the item it re-sealed still delivers.
    a.set("TOKEN_TWO", &Scope::All, "value-two-12345").unwrap();
    let daemon = DeviceKey::generate().unwrap();
    server.borrow_mut().machines.push((VM.to_owned(), daemon.public_bytes().to_vec()));
    a.sync().unwrap();
    let values = machine_open(&server, &daemon);
    assert_eq!(values["TOKEN_ONE"].as_str(), "value-one-12345");
    assert_eq!(values["TOKEN_TWO"].as_str(), "value-two-12345");
}

#[test]
fn a_moved_or_rolled_back_ciphertext_does_not_open() {
    let key = crypto::VaultKey::generate().unwrap();
    let at = crypto::ItemPlace {
        vault: "personal",
        item_id: "i1",
        name: "A",
        scope: "*",
        revision: 5,
        epoch: 1,
    };
    let sealed = crypto::seal_item(&key, &at, b"secret-value").unwrap();
    assert_eq!(crypto::open_item(&key, &at, &sealed).unwrap().as_slice(), b"secret-value");
    for moved in [
        crypto::ItemPlace { name: "B", ..at.clone() },
        crypto::ItemPlace { scope: "repo:a/b", ..at.clone() },
        crypto::ItemPlace { revision: 4, ..at.clone() },
        crypto::ItemPlace { vault: "team:team_x", ..at.clone() },
    ] {
        assert!(crypto::open_item(&key, &moved, &sealed).is_err());
    }
    let daemon = DeviceKey::generate().unwrap();
    let d = crypto::seal_delivery(daemon.public_bytes(), VM, "A", 7, b"v").unwrap();
    assert!(
        crypto::open_delivery(daemon.private_bytes(), "vm_other0000000000000000", "A", 7, &d)
            .is_err()
    );
    assert!(crypto::open_delivery(daemon.private_bytes(), VM, "A", 6, &d).is_err());

    // The machine refuses a lower revision than one it holds.
    let state =
        machine::State { revisions: [("A".to_owned(), 9)].into(), owned: ["A".to_owned()].into() };
    let item = machine::Delivered {
        vault: "personal".into(),
        name: "A".into(),
        revision: 7,
        sealed: Sealed { enc: d.enc, ct: d.ct },
    };
    let (values, next, applied) =
        machine::open_all(daemon.private_bytes(), VM, VM, &[item], &state);
    assert!(values.is_empty());
    assert_eq!(applied.refused, vec![("A".to_owned(), "vault.rollback")]);
    assert_eq!(applied.removed, vec!["A".to_owned()]);
    assert_eq!(next.revisions["A"], 9);
}

#[test]
fn render_env_drops_names_the_vault_no_longer_owns_and_quotes() {
    let previously: BTreeSet<String> = ["OLD".to_owned()].into();
    let values: BTreeMap<String, Zeroizing<String>> =
        [("NEW".to_owned(), Zeroizing::new("it's".to_owned()))].into();
    let out = machine::render_env("export OLD='gone'\nexport KEEP='mac'\n", &previously, &values);
    assert_eq!(
        out.as_str(),
        "export KEEP='mac'\n# cmux vault (end to end encrypted, delivered by cmux host): names below\nexport NEW='it'\\''s'\n"
    );
}

#[test]
fn scopes_and_names() {
    assert_eq!(Scope::parse("repo:Manaflow-AI/cmux"), Some(Scope::Repo("manaflow-ai/cmux".into())));
    assert_eq!(Scope::parse("machine:vm_abc"), None);
    assert_eq!(Scope::parse("repo:../x"), None);
    assert!(crate::valid_name("ANTHROPIC_API_KEY"));
    assert!(!crate::valid_name("CLAUDE_CODE_OAUTH_TOKEN"));
    assert!(!crate::valid_name("PATH"));
    assert!(!crate::valid_name("CMUX_X"));
    assert!(crypto::same_code("1234 5678", "1234-5678"));
    assert!(!crypto::same_code("1234 5678", "1234 567"));
    let entry = &dotenv::parse("A=very-secret-value\n").entries[0];
    assert!(!format!("{entry:?}").contains("very-secret"));
}

#[test]
fn a_vault_emptied_of_devices_takes_a_new_first_device_at_the_next_epoch() {
    let server = RefCell::new(Server::default());
    let http = Fake(&server);
    let (a_store, c_store) = (Store::default(), Store::default());
    let a = vault(&http, &a_store, "cli");
    assert_eq!(a.enroll().unwrap().state, "active");
    a.set("TOKEN_ONE", &Scope::All, "value-one-12345").unwrap();
    assert_eq!(a.remove("TOKEN_ONE", None).unwrap(), 1);
    let a_id = a.status().unwrap().device_id.unwrap();
    // Every device removed through the routes (vault-e2e.ts's reset): the vault keeps epoch 1.
    http.send(
        "DELETE",
        &format!("{}/devices/{a_id}?vault=personal", crate::client::BASE),
        &[],
        None,
    )
    .unwrap();
    let c = vault(&http, &c_store, "cli");
    let status = c.enroll().unwrap();
    assert_eq!(status.state, "active");
    assert_eq!(status.epoch, 2);
    c.set("TOKEN_TWO", &Scope::All, "value-two-12345").unwrap();
    let daemon = DeviceKey::generate().unwrap();
    server.borrow_mut().machines.push((VM.to_owned(), daemon.public_bytes().to_vec()));
    c.sync().unwrap();
    assert_eq!(machine_open(&server, &daemon)["TOKEN_TWO"].as_str(), "value-two-12345");
}
