//! Domain and publication ops against recorded fixtures
//! (`web/app/api/vm/{domains,publications}`): routes, bodies, origin rules,
//! idempotency and typed errors.

mod common;

use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

const PUB_1: &str = "00000000-0000-4000-8000-000000000001";
const PUB_2: &str = "00000000-0000-4000-8000-000000000002";

fn server(fixtures: &[&str]) -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(fixtures))
}

fn only_call(s: &Server<FakeControlPlane>) -> (&'static str, String, Option<Value>) {
    let calls = &s.control_plane().calls;
    assert_eq!(calls.len(), 1, "{calls:?}");
    (calls[0].method, calls[0].path.clone(), calls[0].body.clone())
}

#[test]
fn domain_list_and_verify() {
    let mut s = server(&["domain-list"]);
    let list = s.handle(&Request::new("cmux.cloud.domain.list", json!({}))).expect("list");
    assert_eq!(only_call(&s), ("GET", "/api/vm/domains".into(), None));
    let domain = &list["domains"][0];
    assert_eq!(domain["hostname"], "example.test");
    assert_eq!(domain["verificationState"], "pending");
    assert_eq!(domain["publications"][0]["id"], PUB_1);
    assert_eq!(domain["dnsInstructions"][0]["recordTypes"], json!(["TXT"]));

    let mut s = server(&["domain-verify"]);
    let verify = Request::new("cmux.cloud.domain.verify", json!({ "domain": "example.test" }))
        .origin(Origin::Mcp)
        .key("d-1");
    let verified = s.handle(&verify).expect("verify is mutate-own: any origin");
    assert_eq!(
        only_call(&s),
        ("POST", "/api/vm/domains/example.test/verify".into(), Some(json!({})))
    );
    assert_eq!(verified["domain"]["verificationState"], "verified");

    let mut s = server(&[]);
    for bad in ["example.test/verify", "a?b=c", "", ".hidden", "ex ample.test"] {
        let verify = Request::new("cloud.domain.verify", json!({ "domain": bad })).key("d-2");
        assert_eq!(s.handle(&verify).unwrap_err().code, "cmux.cloud.invalid_args", "{bad}");
    }
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn publication_list_filters_by_machine() {
    let mut s = server(&["publication-list"]);
    let all = s.handle(&Request::new("cloud.publication.list", json!({}))).expect("list");
    assert_eq!(all["publications"].as_array().map(Vec::len), Some(2));
    let one = s
        .handle(&Request::new("cmux.cloud.publication.list", json!({ "machine": "vm-alpha01" })))
        .expect("list");
    let rows = one["publications"].as_array().expect("rows");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["vmId"], "vm-alpha01");
    assert_eq!(rows[0]["accessMode"], "personal");
    assert_eq!(s.control_plane().count("GET", "/api/vm/publications"), 2);
}

#[test]
fn publication_create_needs_user_and_a_key_and_runs_once_per_key() {
    let args = json!({ "machine": "vm-alpha01", "port": 5173 });
    let mut s = server(&["publication-create"]);
    for origin in [Origin::Mcp, Origin::Agent, Origin::Cli] {
        let create =
            Request::new("cloud.publication.create", args.clone()).origin(origin).key("p-1");
        assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.origin_refused");
    }
    let keyless = Request::new("cloud.publication.create", args.clone()).origin(Origin::User);
    assert_eq!(s.handle(&keyless).unwrap_err().code, "cmux.cloud.idempotency_key_required");
    assert!(s.control_plane().calls.is_empty());

    let create = Request::new("cloud.publication.create", args).origin(Origin::User).key("p-1");
    let made = s.handle(&create).expect("create");
    assert_eq!(
        only_call(&s),
        (
            "POST",
            "/api/vm/publications".into(),
            Some(json!({ "vmId": "vm-alpha01", "port": 5173 }))
        )
    );
    assert_eq!(made["publication"]["hostname"], "brisk-test-label.cmux.sh");
    assert_eq!(s.handle(&create).expect("same-key retry"), made);
    assert_eq!(s.control_plane().calls.len(), 1, "a same-key retry makes one call in total");
    assert!(s.control_plane().calls[0].idempotency_key.is_some(), "the API gets a derived key");
}

#[test]
fn publication_create_passes_access_fields() {
    let args = json!({
        "machine": "vm-alpha01", "port": 5173, "accessMode": "public", "confirmPublic": true,
        "hostname": "app.example.test"
    });
    let mut s = server(&["publication-create"]);
    let create = Request::new("cloud.publication.create", args).origin(Origin::User).key("p-2");
    s.handle(&create).expect("create");
    let body = json!({
        "vmId": "vm-alpha01", "port": 5173, "accessMode": "public", "confirmPublic": true,
        "hostname": "app.example.test"
    });
    assert_eq!(only_call(&s), ("POST", "/api/vm/publications".into(), Some(body)));

    for bad in [
        json!({ "machine": "vm-alpha01", "port": 0 }),
        json!({ "machine": "vm-alpha01", "port": 70000 }),
        json!({ "machine": "vm-alpha01", "port": 80, "accessMode": "world" }),
        json!({ "machine": "vm-alpha01", "port": 80, "hostname": "https://x.test/" }),
        json!({ "port": 80 }),
    ] {
        let mut s = server(&["publication-create"]);
        let create =
            Request::new("cloud.publication.create", bad.clone()).origin(Origin::User).key("p-3");
        assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.invalid_args", "{bad}");
        assert!(s.control_plane().calls.is_empty(), "{bad}");
    }
}

#[test]
fn publication_update_delete_and_verify() {
    let mut s = server(&["publication-update"]);
    let args = json!({ "publication": PUB_2, "accessMode": "personal" });
    let mcp = Request::new("cloud.publication.update", args.clone()).origin(Origin::Mcp).key("u-1");
    assert_eq!(s.handle(&mcp).unwrap_err().code, "cmux.cloud.origin_refused");
    let update = Request::new("cloud.publication.update", args).origin(Origin::User).key("u-1");
    let updated = s.handle(&update).expect("update");
    assert_eq!(
        only_call(&s),
        (
            "PATCH",
            format!("/api/vm/publications/{PUB_2}"),
            Some(json!({ "accessMode": "personal" }))
        )
    );
    assert_eq!(updated["publication"]["routingRevision"], 4);

    let mut s = server(&["publication-delete"]);
    let args = json!({ "publication": PUB_1 });
    let mcp = Request::new("cloud.publication.delete", args.clone()).origin(Origin::Mcp).key("x-1");
    assert_eq!(s.handle(&mcp).unwrap_err().code, "cmux.cloud.origin_refused");
    assert!(s.control_plane().calls.is_empty());
    let delete = Request::new("cloud.publication.delete", args).origin(Origin::User).key("x-1");
    assert_eq!(s.handle(&delete).expect("delete"), json!({ "ok": true }));
    assert_eq!(only_call(&s), ("DELETE", format!("/api/vm/publications/{PUB_1}"), None));

    let mut s = server(&["publication-verify"]);
    let verify = Request::new("cloud.publication.verify", json!({ "publication": PUB_1 }))
        .origin(Origin::Agent)
        .key("v-1");
    let verified = s.handle(&verify).expect("verify is mutate-own");
    assert_eq!(
        only_call(&s),
        ("POST", format!("/api/vm/publications/{PUB_1}/verify"), Some(json!({})))
    );
    assert_eq!(verified["publication"]["state"], "active");
    // A verify reads fresh state every time: no replay of the first answer.
    s.handle(&verify).expect("verify again");
    assert_eq!(s.control_plane().calls.len(), 2);
}

#[test]
fn publication_conflict_is_typed() {
    let mut s = server(&["publication-conflict"]);
    let create =
        Request::new("cloud.publication.create", json!({ "machine": "vm-alpha01", "port": 3000 }))
            .origin(Origin::User)
            .key("c-1");
    let error = s.handle(&create).unwrap_err();
    assert_eq!((error.code, error.status), ("cmux.cloud.conflict", Some(409)));
    assert_eq!(error.upstream_code.as_deref(), Some("vm_publication_conflict"));
}
