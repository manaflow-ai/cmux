use super::*;
use std::cell::RefCell;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

const ACCOUNT: &str = "0123456789abcdef0123456789abcdef";

/// One recorded call: method, path, bearer, body.
type Call = (String, String, String, Option<Value>);

/// Answers Cloudflare calls from a script and records every call.
struct FakeCloudflare {
    calls: RefCell<Vec<Call>>,
    bucket_exists: bool,
    fail_first_bucket_read: RefCell<bool>,
    /// Keys minted so far: the first is `key-id`, the next `key-id2`, and so on.
    keys_minted: RefCell<u32>,
}

impl FakeCloudflare {
    fn new(bucket_exists: bool) -> Self {
        Self {
            calls: RefCell::new(Vec::new()),
            bucket_exists,
            fail_first_bucket_read: RefCell::new(true),
            keys_minted: RefCell::new(0),
        }
    }
    fn paths(&self) -> Vec<String> {
        self.calls.borrow().iter().map(|(m, p, _, _)| format!("{m} {p}")).collect()
    }
}

impl Http for FakeCloudflare {
    fn call(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let path = url.strip_prefix(CLOUDFLARE_API).unwrap().to_owned();
        self.calls.borrow_mut().push((method.into(), path.clone(), bearer.into(), body.cloned()));
        let ok = |result: Value| Ok((200, json!({"success": true, "result": result})));
        let tokens = format!("/accounts/{ACCOUNT}/tokens");
        match (method, path.as_str()) {
            ("GET", p) if p == format!("{tokens}/verify") => ok(json!({"status": "active"})),
            ("GET", p) if p == format!("{tokens}/permission_groups") => ok(json!([
                {"id": "g-admin", "name": R2_ADMIN_WRITE},
                {"id": "g-write", "name": R2_ITEM_WRITE},
                {"id": "g-read", "name": R2_ITEM_READ},
            ])),
            ("POST", p) if p == tokens => {
                let name = body.unwrap()["name"].as_str().unwrap();
                let id = if name.contains("set up") {
                    "setup-id".to_owned()
                } else {
                    let mut minted = self.keys_minted.borrow_mut();
                    *minted += 1;
                    if *minted == 1 { "key-id".to_owned() } else { format!("key-id{minted}") }
                };
                ok(json!({"id": id, "value": format!("{id}-value")}))
            }
            ("DELETE", p) if p.starts_with(&tokens) => ok(json!({})),
            ("GET", p) if p.ends_with("/r2/buckets/handoff") => {
                // A fresh token's first call: not yet propagated.
                if self.fail_first_bucket_read.replace(false) {
                    return Ok((
                        403,
                        json!({"success": false, "errors": [{"code": 10000, "message": "Authentication error"}]}),
                    ));
                }
                if self.bucket_exists {
                    ok(json!({"name": "handoff"}))
                } else {
                    Ok((404, json!({"success": false})))
                }
            }
            ("POST", p) if p.ends_with("/r2/buckets") => ok(json!({"name": "handoff"})),
            ("PUT", p) if p.ends_with("/lifecycle") => ok(json!({})),
            _ => Ok((
                500,
                json!({"success": false, "errors": [{"code": 1, "message": "unexpected"}]}),
            )),
        }
    }
}

#[derive(Default)]
struct FakeSinks {
    put: RefCell<Vec<(Store, String, String)>>,
    saved: RefCell<Vec<(String, String)>>,
    fail_put: bool,
}

impl Sinks for FakeSinks {
    fn provider_token(&self, _: &str) -> Result<Zeroizing<String>, String> {
        Ok(Zeroizing::new("bootstrap".into()))
    }
    fn save_provider_token(&self, account: &str, token: &str) -> Result<(), String> {
        self.saved.borrow_mut().push((account.into(), token.into()));
        Ok(())
    }
    fn read_bootstrap(&self) -> Result<Zeroizing<String>, String> {
        Ok(Zeroizing::new("bootstrap".into()))
    }
    fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String> {
        if self.fail_put {
            return Err("gh refused".into());
        }
        self.put.borrow_mut().push((store.clone(), name.into(), value.into()));
        Ok(())
    }
}

fn connected(dir: &tempfile::TempDir) -> Paths {
    let paths = Paths { audit: dir.path().join("keys.json") };
    run(
        Command::Connect { account: ACCOUNT.into() },
        &paths,
        &FakeCloudflare::new(true),
        &FakeSinks::default(),
        &local::tests::MemoryVault::default(),
    )
    .unwrap();
    paths
}

#[test]
fn mint_parses_the_r2_ask_and_never_takes_a_value() {
    let Command::MintR2(mint) = parse(&words(
        "mint cloudflare-r2 --bucket cmux-ci-handoff --rw --ttl 180d --create-bucket --expire-objects-days 1 --store gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2",
    ))
    .unwrap() else {
        panic!("not a mint")
    };
    assert_eq!(mint.bucket, "cmux-ci-handoff");
    assert!(mint.write && mint.create_bucket);
    assert_eq!(mint.ttl, Duration::from_secs(180 * 86_400));
    assert_eq!(mint.expire_objects_days, Some(1));
    assert_eq!(
        mint.stores,
        vec![Store::GhSecret {
            repo: "manaflow-ai/cmux".into(),
            environment: None,
            prefix: "CI_HANDOFF_R2".into()
        }]
    );
    for bad in [
        "mint cloudflare-r2 --bucket b --rw --store gh-secret:a/b:X", // bucket too short
        "mint cloudflare-r2 --bucket bucket --store gh-secret:a/b:X", // no access
        "mint cloudflare-r2 --bucket bucket --rw --ro --store gh-secret:a/b:X", // both
        "mint cloudflare-r2 --bucket bucket --rw",                    // stored nowhere
        "mint cloudflare-r2 --bucket bucket --rw --ttl 0d --store gh-secret:a/b:X",
        "mint cloudflare-r2 --bucket bucket --rw --ttl 400d --store gh-secret:a/b:X",
        "mint cloudflare-r2 --bucket bucket --rw --store gh-secret:a/b:lower",
        "mint cloudflare-r2 --bucket bucket --rw --store gh-secret:a/b:GITHUB_X",
        "mint cloudflare-r2 --bucket bucket --rw --store keychain:CMUX_X",
        "mint cloudflare-r2 --bucket bucket --rw --store s3:X",
        "connect cloudflare --account nothex",
        "connect cloudflare tok_live_value",
        "revoke",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
    assert_eq!(
        Store::parse("gh-secret:manaflow-ai/cmux@ci-cache-writer:CACHE")
            .unwrap()
            .label("ACCESS_KEY_ID"),
        "gh-secret:manaflow-ai/cmux@ci-cache-writer:CACHE_ACCESS_KEY_ID"
    );
    assert_eq!(
        Store::parse("keychain:Acme/App:R2").unwrap().label("ACCESS_KEY_ID"),
        "keychain:acme/app/R2_ACCESS_KEY_ID"
    );
    assert_eq!(
        Store::parse("vault:CI_R2").unwrap().label("SECRET_ACCESS_KEY"),
        "vault:CI_R2_SECRET_ACCESS_KEY"
    );
    assert!(Store::parse("vault:ci_r2").is_err());
}

#[test]
fn connect_verifies_then_keeps_the_token_in_the_keychain_and_lists_the_provider() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths { audit: dir.path().join("keys.json") };
    let sinks = FakeSinks::default();
    let http = FakeCloudflare::new(true);
    run(
        Command::Connect { account: ACCOUNT.into() },
        &paths,
        &http,
        &sinks,
        &local::tests::MemoryVault::default(),
    )
    .unwrap();
    assert_eq!(
        sinks.saved.borrow().as_slice(),
        &[(format!("cloudflare/{ACCOUNT}"), "bootstrap".to_owned())]
    );
    let audit = std::fs::read_to_string(&paths.audit).unwrap();
    assert!(!audit.contains("bootstrap"), "the audit never holds a value");
    assert!(audit.contains(ACCOUNT));
}

#[test]
fn mint_sets_up_the_bucket_with_a_short_token_then_mints_a_bucket_scoped_key_and_stores_its_s3_pair()
 {
    let dir = tempfile::tempdir().unwrap();
    let paths = connected(&dir);
    let http = FakeCloudflare::new(false);
    let sinks = FakeSinks::default();
    let Command::MintR2(mint) = parse(&words(
        "mint cloudflare-r2 --bucket handoff --rw --create-bucket --expire-objects-days 1 --store gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2",
    ))
    .unwrap() else {
        panic!()
    };
    let answer =
        run(Command::MintR2(mint), &paths, &http, &sinks, &local::tests::MemoryVault::default())
            .unwrap();
    let tokens = format!("/accounts/{ACCOUNT}/tokens");
    let buckets = format!("/accounts/{ACCOUNT}/r2/buckets");
    assert_eq!(
        http.paths(),
        vec![
            format!("GET {tokens}/permission_groups"),
            format!("POST {tokens}"),
            format!("GET {buckets}/handoff"),
            format!("GET {buckets}/handoff"),
            format!("POST {buckets}"),
            format!("PUT {buckets}/handoff/lifecycle"),
            format!("DELETE {tokens}/setup-id"),
            format!("POST {tokens}"),
        ]
    );
    let calls = http.calls.borrow();
    // Bucket work uses the setup token, never the bootstrap; the setup token is account-wide R2 admin.
    assert!(calls[2..6].iter().all(|(_, _, bearer, _)| bearer == "setup-id-value"));
    assert_eq!(
        calls[1].3.as_ref().unwrap()["policies"][0]["permission_groups"][0]["id"],
        "g-admin"
    );
    assert_eq!(
        calls[5].3.as_ref().unwrap()["rules"][0]["deleteObjectsTransition"]["condition"]["maxAge"],
        86_400
    );
    // The stored key is scoped to the one bucket, with item write only, and expires.
    let key = calls[7].3.as_ref().unwrap();
    assert_eq!(
        key["policies"][0]["resources"],
        json!({format!("com.cloudflare.edge.r2.bucket.{ACCOUNT}_default_handoff"): "*"})
    );
    assert_eq!(key["policies"][0]["permission_groups"][0]["id"], "g-write");
    assert!(key["expires_on"].as_str().unwrap().ends_with('Z'));
    let put = sinks.put.borrow();
    let expected_secret: String =
        Sha256::digest(b"key-id-value").iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(put[0].1, "CI_HANDOFF_R2_ACCESS_KEY_ID");
    assert_eq!(put[0].2, "key-id");
    assert_eq!(put[1].1, "CI_HANDOFF_R2_SECRET_ACCESS_KEY");
    assert_eq!(put[1].2, expected_secret);
    assert_eq!(answer["bucket"]["created"], true);
    let audit = std::fs::read_to_string(&paths.audit).unwrap();
    assert!(
        !audit.contains("key-id-value") && !audit.contains(&expected_secret),
        "no value in the audit"
    );
    assert!(audit.contains("gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2_SECRET_ACCESS_KEY"));
}

#[test]
fn a_key_that_cannot_be_stored_is_revoked_and_left_out_of_the_audit() {
    let dir = tempfile::tempdir().unwrap();
    let paths = connected(&dir);
    let http = FakeCloudflare::new(true);
    let sinks = FakeSinks { fail_put: true, ..FakeSinks::default() };
    let Command::MintR2(mint) =
        parse(&words("mint cloudflare-r2 --bucket handoff --ro --store gh-secret:a/b:R2")).unwrap()
    else {
        panic!()
    };
    let error =
        run(Command::MintR2(mint), &paths, &http, &sinks, &local::tests::MemoryVault::default())
            .unwrap_err();
    assert!(error.contains("revoked"), "{error}");
    assert!(http.paths().last().unwrap().ends_with("/tokens/key-id"));
    assert!(!std::fs::read_to_string(&paths.audit).unwrap().contains("key-id"));
}

#[test]
fn revoke_deletes_at_the_provider_and_ls_shows_it() {
    let dir = tempfile::tempdir().unwrap();
    let paths = connected(&dir);
    let http = FakeCloudflare::new(true);
    let Command::MintR2(mint) =
        parse(&words("mint cloudflare-r2 --bucket handoff --ro --store gh-secret:a/b:R2")).unwrap()
    else {
        panic!()
    };
    run(
        Command::MintR2(mint),
        &paths,
        &http,
        &FakeSinks::default(),
        &local::tests::MemoryVault::default(),
    )
    .unwrap();
    let listed = run(
        Command::Ls,
        &paths,
        &http,
        &FakeSinks::default(),
        &local::tests::MemoryVault::default(),
    )
    .unwrap();
    assert_eq!(listed["keys"][0]["state"], "live");
    run(
        Command::Revoke { id: "key-id".into() },
        &paths,
        &http,
        &FakeSinks::default(),
        &local::tests::MemoryVault::default(),
    )
    .unwrap();
    assert_eq!(http.paths().last().unwrap(), &format!("DELETE /accounts/{ACCOUNT}/tokens/key-id"));
    assert_eq!(
        run(
            Command::Ls,
            &paths,
            &http,
            &FakeSinks::default(),
            &local::tests::MemoryVault::default()
        )
        .unwrap()["keys"][0]["state"],
        "revoked"
    );
}

#[test]
fn rotate_mints_the_same_scope_stores_it_under_the_same_names_then_revokes_the_old_key() {
    let dir = tempfile::tempdir().unwrap();
    let paths = connected(&dir);
    let http = FakeCloudflare::new(true);
    let vault = local::tests::MemoryVault::default();
    let Command::MintR2(mint) = parse(&words(
        "mint cloudflare-r2 --bucket handoff --rw --ttl 30d \
         --store gh-secret:a/b@ci:R2 --store keychain:a/b:R2 --store keychain:ALL --store vault:R2",
    ))
    .unwrap() else {
        panic!()
    };
    let first = FakeSinks::default();
    run(Command::MintR2(mint), &paths, &http, &first, &vault).unwrap();

    assert_eq!(
        parse(&words("rotate abc")).unwrap(),
        Command::Rotate { id: "abc".into(), ttl: None }
    );
    assert_eq!(
        parse(&words("rotate abc --ttl 7d")).unwrap(),
        Command::Rotate { id: "abc".into(), ttl: Some(Duration::from_secs(7 * 86_400)) }
    );

    let calls_before = http.calls.borrow().len();
    let second = FakeSinks::default();
    let rotated =
        run(Command::Rotate { id: "key-id".into(), ttl: None }, &paths, &http, &second, &vault)
            .unwrap();
    assert_eq!(rotated["rotated"], "key-id");
    assert_eq!(rotated["revoked"], true);
    assert_eq!(rotated["minted"]["id"], "key-id2");

    // The same scope: one bucket-scoped token with the same access, no bucket setup, the old
    // key's lifetime; then the old key deleted at the provider, after the new one is stored.
    let calls = http.calls.borrow()[calls_before..].to_vec();
    let minted: Vec<&Call> =
        calls.iter().filter(|(m, p, ..)| m == "POST" && p.ends_with("/tokens")).collect();
    assert_eq!(minted.len(), 1, "{calls:?}");
    let body = minted[0].3.as_ref().unwrap();
    assert_eq!(
        body["policies"][0]["resources"],
        json!({format!("com.cloudflare.edge.r2.bucket.{ACCOUNT}_default_handoff"): "*"})
    );
    assert_eq!(body["policies"][0]["permission_groups"], json!([{"id": "g-write"}]));
    assert!(!calls.iter().any(|(_, p, ..)| p.contains("/r2/buckets")));
    assert_eq!(
        calls.last().map(|(m, p, ..)| format!("{m} {p}")).unwrap(),
        format!("DELETE /accounts/{ACCOUNT}/tokens/key-id")
    );

    // The same names, every store, now holding the new key.
    let names = |sinks: &FakeSinks| {
        sinks.put.borrow().iter().map(|(store, name, _)| store.place(name)).collect::<Vec<_>>()
    };
    assert_eq!(names(&second), names(&first));
    assert_eq!(names(&second).len(), 8);
    assert!(
        second
            .put
            .borrow()
            .iter()
            .any(|(_, name, value)| name == "R2_ACCESS_KEY_ID" && value == "key-id2")
    );

    let listed = run(Command::Ls, &paths, &http, &FakeSinks::default(), &vault).unwrap();
    let keys = listed["keys"].as_array().unwrap();
    assert_eq!(keys[0]["id"], "key-id");
    assert_eq!(keys[0]["state"], "revoked");
    assert_eq!(keys[0]["rotated_to"], "key-id2");
    assert_eq!(keys[1]["id"], "key-id2");
    assert_eq!(keys[1]["state"], "live");
    assert_eq!(keys[1]["rotated_from"], "key-id");
    assert_eq!(keys[1]["stores"], keys[0]["stores"]);
    assert_eq!(keys[1]["access"], "rw");
    let life = |k: &Value| {
        k["expires_at_s"].as_u64().unwrap()
            - parse_rfc3339(k["created_at"].as_str().unwrap()).unwrap()
    };
    assert_eq!(life(&keys[1]), 30 * 86_400);

    let missing =
        run(Command::Rotate { id: "nope".into(), ttl: None }, &paths, &http, &second, &vault);
    assert!(missing.unwrap_err().contains("no minted key nope"));
}

#[test]
fn a_store_label_names_its_store_again() {
    for spec in
        ["gh-secret:a/b:R2", "gh-secret:a/b@ci:R2", "keychain:R2", "keychain:a/b:R2", "vault:R2"]
    {
        let store = Store::parse(spec).unwrap();
        assert_eq!(
            Store::from_label(&store.label("ACCESS_KEY_ID"), "ACCESS_KEY_ID"),
            Some(store.clone()),
            "{spec}"
        );
        assert_eq!(
            Store::from_label(&store.label("SECRET_ACCESS_KEY"), "ACCESS_KEY_ID"),
            None,
            "{spec}"
        );
    }
}

#[test]
fn times_are_rfc3339_utc() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(1_794_700_800), "2026-11-15T00:00:00Z");
    assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    for secs in [0, 951_782_400, 1_794_700_800, 1_794_745_199, 4_102_444_800] {
        assert_eq!(parse_rfc3339(&rfc3339(secs)), Some(secs));
    }
    assert_eq!(parse_rfc3339("2026-11-15 00:00:00Z"), None);
    assert_eq!(parse_rfc3339("2026-13-15T00:00:00Z"), None);
}

#[test]
fn a_dev_builds_audit_is_its_own() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| {
            pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| std::ffi::OsString::from(*v))
        }
    };
    let dev: &[(&str, &str)] =
        &[("HOME", "/h"), (AUDIT_OVERRIDE, "/s/builds/dev/config/keys.json")];
    assert_eq!(
        Paths::from_env(env(dev), false).unwrap().audit,
        PathBuf::from("/s/builds/dev/config/keys.json")
    );
    assert_eq!(
        Paths::from_env(env(dev), true).unwrap().audit,
        PathBuf::from("/h/.config").join(cmux_config::NEXT_DIR).join("keys.json")
    );
    assert_eq!(
        Paths::from_env(env(&[("HOME", "/h")]), false).unwrap().audit,
        PathBuf::from("/h/.config").join(cmux_config::NEXT_DIR).join("keys.json")
    );
}

/// The Mac's broker: its Keychain holds a bootstrap whose bytes the test looks for everywhere the
/// key goes.
const MAC_BOOTSTRAP: &str = "cfat_BOOTSTRAP_kept_on_the_mac_0123456789";

struct MacSinks(FakeSinks);

impl Sinks for MacSinks {
    fn provider_token(&self, _: &str) -> Result<Zeroizing<String>, String> {
        Ok(Zeroizing::new(MAC_BOOTSTRAP.into()))
    }
    fn save_provider_token(&self, account: &str, token: &str) -> Result<(), String> {
        self.0.save_provider_token(account, token)
    }
    fn read_bootstrap(&self) -> Result<Zeroizing<String>, String> {
        Ok(Zeroizing::new(MAC_BOOTSTRAP.into()))
    }
    fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String> {
        self.0.put(store, name, value)
    }
}

/// The peer link: what the Linux machine's ask carries and what comes back, recorded byte for byte.
struct Link<'a> {
    mac: &'a Paths,
    http: &'a FakeCloudflare,
    sinks: &'a MacSinks,
    crossed: RefCell<Vec<String>>,
}

impl PeerBroker for Link<'_> {
    fn mint(&self, ask: Value) -> Result<Value, String> {
        self.crossed.borrow_mut().push(ask.to_string());
        // What the Mac's acpmux runs for a peer's ask (keys_relay.rs `MintAsk::argv`).
        let mut words = vec![
            "mint".to_owned(),
            "cloudflare-r2".to_owned(),
            "--bucket".to_owned(),
            ask["bucket"].as_str().unwrap().to_owned(),
            if ask["access"] == "rw" { "--rw" } else { "--ro" }.to_owned(),
            "--ttl".to_owned(),
            ask["ttl"].as_str().unwrap().to_owned(),
        ];
        words.extend(["--reply-to-machine".to_owned(), "lane-vm".to_owned()]);
        let Command::MintR2(mint) = parse(&words).map_err(|e| e.0)? else { panic!("not a mint") };
        let answer = run(
            Command::MintR2(mint),
            self.mac,
            self.http,
            self.sinks,
            &local::tests::MemoryVault::default(),
        )?;
        self.crossed.borrow_mut().push(answer.to_string());
        Ok(answer)
    }
}

#[test]
fn a_linux_machine_gets_a_scoped_key_from_the_macs_broker_and_never_the_bootstrap() {
    let mac_dir = tempfile::tempdir().unwrap();
    let mac = connected(&mac_dir);
    let http = FakeCloudflare::new(true);
    let mac_sinks = MacSinks(FakeSinks::default());
    let link =
        Link { mac: &mac, http: &http, sinks: &mac_sinks, crossed: RefCell::new(Vec::new()) };

    let linux_dir = tempfile::tempdir().unwrap();
    let linux = Paths { audit: linux_dir.path().join("keys.json") };
    let linux_sinks = FakeSinks::default();
    let Command::MintR2(mint) = parse(&words(
        "mint cloudflare-r2 --bucket handoff --ro --ttl 30d --via leo-mac --store vault:CI_R2",
    ))
    .unwrap() else {
        panic!()
    };
    assert_eq!(mint.via.as_deref(), Some("leo-mac"));
    let answer = mint_via(mint, &linux, &link, &linux_sinks).unwrap();

    // The Mac minted with its bootstrap: a read-only key on the one bucket, 30 days.
    let calls = http.calls.borrow();
    let (_, _, bearer, body) =
        calls.iter().find(|(m, p, _, _)| m == "POST" && p.ends_with("/tokens")).unwrap();
    assert_eq!(bearer, MAC_BOOTSTRAP);
    assert_eq!(body.as_ref().unwrap()["policies"][0]["permission_groups"][0]["id"], "g-read");

    // The Linux machine stored the scoped pair in its own vault.
    let expected_secret: String =
        Sha256::digest(b"key-id-value").iter().map(|b| format!("{b:02x}")).collect();
    let put = linux_sinks.put.borrow();
    assert_eq!(put.len(), 2);
    assert_eq!((put[0].1.as_str(), put[0].2.as_str()), ("CI_R2_ACCESS_KEY_ID", "key-id"));
    assert_eq!(
        (put[1].1.as_str(), put[1].2.as_str()),
        ("CI_R2_SECRET_ACCESS_KEY", expected_secret.as_str())
    );
    // The Mac stored nothing of its own; its audit says where the key went.
    assert!(mac_sinks.0.put.borrow().is_empty());
    let mac_audit = std::fs::read_to_string(&mac.audit).unwrap();
    assert!(mac_audit.contains("machine:lane-vm"), "{mac_audit}");

    // The bootstrap's bytes never crossed the link either way, and are nowhere on the Linux machine:
    // not in its answer, its audit or its stores. Nor the raw token value (only its SHA-256 is the
    // S3 secret).
    let crossed = link.crossed.borrow();
    assert_eq!(crossed.len(), 2, "one ask, one answer");
    let linux_audit = std::fs::read_to_string(&linux.audit).unwrap();
    let stored: Vec<String> = put.iter().map(|(_, n, v)| format!("{n}={v}")).collect();
    for (place, text) in [
        ("the ask", crossed[0].clone()),
        ("the answer", crossed[1].clone()),
        ("the Linux reply", answer.to_string()),
        ("the Linux audit", linux_audit.clone()),
        ("the Linux stores", stored.join("\n")),
    ] {
        assert!(!text.contains(MAC_BOOTSTRAP), "the bootstrap reached {place}: {text}");
        assert!(!text.contains("key-id-value"), "the raw token reached {place}: {text}");
    }
    // The pair crossed only in the answer; the Linux reply and audit never show it.
    assert!(crossed[1].contains(&expected_secret));
    assert!(!answer.to_string().contains(&expected_secret));
    assert!(!linux_audit.contains(&expected_secret));
    assert!(
        linux_audit.contains("\"via\":\"leo-mac\"") || linux_audit.contains("\"via\": \"leo-mac\"")
    );
}

#[test]
fn reply_to_machine_takes_no_store_and_via_needs_one() {
    for bad in [
        "mint cloudflare-r2 --bucket handoff --ro --reply-to-machine m --store vault:X",
        "mint cloudflare-r2 --bucket handoff --ro --reply-to-machine m --via n",
        "mint cloudflare-r2 --bucket handoff --ro --via leo-mac",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
    assert!(parse(&words("mint cloudflare-r2 --bucket handoff --ro --reply-to-machine m")).is_ok());
}
