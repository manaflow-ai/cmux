//! `cloud.environment.*` (plans/cmux-next/cloud-environments-DESIGN.md): the server checks the args,
//! forwards each op to the CloudDO op of the same name, projects the machine a boot made, and keeps
//! build, boot and delete to a person (origin `user`).

mod wire_common;

use cmux_cloud::{Origin, Request, Server};
use serde_json::{Value, json};
use wire_common::{WireFake, vm};

const ENV: &str = "env_00000000000000000001";

fn environment(status: &str) -> Value {
    json!({ "id": ENV, "name": "web", "repo": "manaflow-ai/cmux", "setup_script": "bun install", "env": [],
        "creator": "user_1", "status": status, "snapshot": null, "last_build": null, "created_at": 1, "revision": "3" })
}

fn mutation(op: &str, args: Value, key: &str) -> Request {
    Request::new(op, args).key(key).origin(Origin::User)
}

#[test]
fn environments_forward_to_clouddo_and_a_boot_projects_its_machine() {
    let mut fake = WireFake::load();
    fake.answer(
        "cloud.environment.list",
        json!({}),
        None,
        json!({ "environments": [environment("ready")] }),
    );
    let set = json!({ "name": "web", "repo": "manaflow-ai/cmux", "setup_script": "bun install" });
    fake.answer(
        "cloud.environment.set",
        set.clone(),
        Some("key-env-set"),
        json!({ "environment": environment("unbuilt") }),
    );
    fake.answer(
        "cloud.environment.build",
        json!({ "environment": ENV }),
        Some("key-env-build"),
        json!({ "environment": environment("building"), "built": true }),
    );
    let machine = json!({ "id": vm(9), "team": "team_1", "creator": "user_1", "name": null, "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
        "status": "provisioning", "image": { "id": "img", "daemon_version": null }, "host": null, "classic": false, "created_at": 1,
        "last_active_at": null, "idle_policy": { "idle_seconds": 1800 }, "error": null, "revision": "4" });
    let size = json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 });
    fake.answer(
        "cloud.environment.boot",
        json!({ "environment": ENV, "size": size }),
        Some("key-env-boot"),
        json!({ "machine": machine, "boot": "snapshot" }),
    );
    fake.answer(
        "cloud.environment.delete",
        json!({ "environment": ENV }),
        Some("key-env-delete"),
        json!({ "deleted": true }),
    );
    let mut s = Server::new(fake);

    let list = s.handle(&Request::new("cloud.environment.list", json!({})));
    assert_eq!(list.map(|v| v["environments"][0]["status"].clone()), Ok(json!("ready")));
    let created = s.handle(&mutation("cloud.environment.set", set, "key-env-set"));
    assert_eq!(created.map(|v| v["environment"]["id"].clone()), Ok(json!(ENV)));
    let built = s.handle(&mutation(
        "cloud.environment.build",
        json!({ "environment": ENV }),
        "key-env-build",
    ));
    assert_eq!(built.map(|v| v["built"].clone()), Ok(json!(true)));
    let booted = s.handle(&mutation(
        "cloud.environment.boot",
        json!({ "environment": ENV, "size": size }),
        "key-env-boot",
    ));
    assert_eq!(booted.map(|v| v["boot"].clone()), Ok(json!("snapshot")));
    assert!(s.projection().get(&vm(9)).is_some(), "the booted machine is projected");
    let deleted = s.handle(&mutation(
        "cloud.environment.delete",
        json!({ "environment": ENV }),
        "key-env-delete",
    ));
    assert_eq!(deleted, Ok(json!({ "deleted": true })));
}

#[test]
fn build_boot_and_delete_need_a_person_and_args_are_checked() {
    let mut s = Server::new(WireFake::load());
    for op in ["cloud.environment.build", "cloud.environment.boot", "cloud.environment.delete"] {
        let out = s.handle(
            &Request::new(op, json!({ "environment": ENV })).key("k").origin(Origin::Script),
        );
        assert_eq!(out.map_err(|e| e.code), Err("cmux.cloud.origin_refused"), "{op}");
    }
    let bad =
        s.handle(&mutation("cloud.environment.set", json!({ "name": "x", "colour": "red" }), "k2"));
    assert_eq!(bad.map_err(|e| e.code), Err("cmux.cloud.invalid_args"));
    let no_id = s.handle(&mutation("cloud.environment.build", json!({}), "k3"));
    assert_eq!(no_id.map_err(|e| e.code), Err("cmux.cloud.invalid_args"));
}
