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
}

impl FakeCloudflare {
    fn new(bucket_exists: bool) -> Self {
        Self {
            calls: RefCell::new(Vec::new()),
            bucket_exists,
            fail_first_bucket_read: RefCell::new(true),
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
                let id = if name.contains("set up") { "setup-id" } else { "key-id" };
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
fn times_are_rfc3339_utc() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(1_794_700_800), "2026-11-15T00:00:00Z");
    assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
}
