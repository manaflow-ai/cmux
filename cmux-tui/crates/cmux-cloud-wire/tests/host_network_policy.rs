//! Exercise the generated public result, including its strict version discriminator.
use cmux_cloud_wire::{Op, OpVisitor, visit_op};
use serde_json::{Value, json};

struct PolicyTrip(Value);
impl OpVisitor for PolicyTrip {
    type Output = (Value, bool);

    fn visit<O: Op>(self) -> Self::Output {
        let typed: O::Result =
            serde_json::from_value(self.0.clone()).expect("current policy result");
        let back = serde_json::to_value(typed).expect("encode policy result");
        let refused = [json!(0), json!(2), json!("1"), Value::Null].into_iter().all(|version| {
            let mut value = self.0.clone();
            value["schema_version"] = version;
            serde_json::from_value::<O::Result>(value).is_err()
        });
        (back, refused)
    }
}

#[test]
fn host_network_policy_generated_result_keeps_the_schema_version_strict() {
    let value = json!({"schema_version":1,"host":"host_00000000000000000001","team":"team_00000000000000000001",
        "user":"user_00000000000000000001","install":"inst_00000000000000000001",
        "origin":"https://native.example.test","tenant":"native_team","mesh":"mesh_00000000000000000000000000","device":"dev_00000000000000000000000000",
        "wg_public_key":"public-wg","install_public_key":"public-point","authority_version":"a".repeat(64),
        "checked_at":1000,"expires_at":31000,"acl_version":1,"policy_digest":"b".repeat(64),
        "peers":[{"host":"host_00000000000000000002","user":"user_00000000000000000002","install":"inst_00000000000000000002",
            "device":"dev_00000000000000000000000001","wg_public_key":"peer-wg","install_public_key":"peer-point",
            "authority_version":"c".repeat(64),"inbound":[{"protocol":"tcp","port":22}],"outbound":[]}]});
    let (back, refused) = visit_op("host.network.policy", PolicyTrip(value.clone()))
        .expect("the generated client must expose the public policy read");
    assert_eq!(back, value);
    assert!(refused, "unknown or nonnumeric schema versions must be refused");
}
