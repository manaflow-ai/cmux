//! `cloud.firewall.*` over `/api/vm/firewall`: list (`?vmId`, `?vpcId`,
//! `?tunnelId`), get (`?ruleId`), create (`POST`, an allow rule), delete
//! (`DELETE ?ruleId`). Create and delete change which traffic reaches a
//! machine, so the op table lets only origin `user` run them.

use super::network_args as check;
use super::network_models::{FirewallRule, FirewallRuleList};
use crate::api::{CloudError, ControlPlane, Ctx, args, codes, decode_answer};
use serde_json::{Map, Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.firewall.list" => {
            let map = args::object(raw, &["machine", "network", "tunnel"])?;
            let mut query = Vec::new();
            for (field, param) in
                [("machine", "vmId"), ("network", "vpcId"), ("tunnel", "tunnelId")]
            {
                if let Some(value) = check::optional_token(map, field)? {
                    query.push(format!("{param}={value}"));
                }
            }
            let path = if query.is_empty() {
                "/api/vm/firewall".to_owned()
            } else {
                format!("/api/vm/firewall?{}", query.join("&"))
            };
            let list: FirewallRuleList =
                decode_answer(&path, ctx.call("GET", path.clone(), None)?)?;
            Ok(json!(list))
        }
        "cloud.firewall.get" => {
            let rule = check::token(args::object(raw, &["rule"])?, "rule")?;
            let path = format!("/api/vm/firewall?ruleId={rule}");
            let rule: FirewallRule = decode_answer(&path, ctx.call("GET", path.clone(), None)?)?;
            Ok(json!(rule))
        }
        "cloud.firewall.create" => {
            let map = args::object(raw, &["source", "destination", "description"])?;
            let mut body = Map::new();
            body.insert("source".into(), endpoint(map.get("source"), "source")?);
            body.insert("destination".into(), endpoint(map.get("destination"), "destination")?);
            if let Some(text) = args::text(map, "description", 1024)? {
                body.insert("description".into(), json!(text));
            }
            let path = "/api/vm/firewall";
            let rule: FirewallRule =
                decode_answer(path, ctx.call("POST", path.into(), Some(Value::Object(body)))?)?;
            Ok(json!(rule))
        }
        "cloud.firewall.delete" => {
            let rule = check::token(args::object(raw, &["rule"])?, "rule")?;
            ctx.call("DELETE", format!("/api/vm/firewall?ruleId={rule}"), None)?;
            Ok(json!({ "ok": true }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

const ENDPOINT_FIELDS: &[&str] =
    &["vmId", "vpcId", "tunnelId", "cidr", "public", "port", "protocol"];

/// One endpoint, checked like the Cloud API route does: known fields only;
/// exactly one identity (a resource id, a CIDR, or `public: true` alone);
/// `port` needs `protocol`; `icmp` takes no port.
fn endpoint(raw: Option<&Value>, field: &str) -> Result<Value, CloudError> {
    let Some(Value::Object(map)) = raw else {
        return Err(CloudError::invalid(format!("{field} must be an endpoint object")));
    };
    if let Some(extra) = map.keys().find(|k| !ENDPOINT_FIELDS.contains(&k.as_str())) {
        return Err(CloudError::invalid(format!("{field}.{extra} is not an endpoint field")));
    }
    let mut out = Map::new();
    let mut resources = 0;
    for key in ["vmId", "vpcId", "tunnelId"] {
        if let Some(id) = check::optional_token(map, key)? {
            out.insert(key.into(), json!(id));
            resources += 1;
        }
    }
    if let Some(cidr) = map.get("cidr").filter(|v| !v.is_null()) {
        match cidr.as_str() {
            Some(c) if check::is_cidr(c) => out.insert("cidr".into(), json!(c)),
            _ => return Err(CloudError::invalid(format!("{field}.cidr must be a CIDR range"))),
        };
    }
    match check::flag(map, "public")? {
        None => {}
        Some(true) => {
            out.insert("public".into(), json!(true));
        }
        Some(false) => {
            return Err(CloudError::invalid(format!("{field}.public must be true when present")));
        }
    }
    let public = out.contains_key("public");
    if resources > 1 {
        return Err(CloudError::invalid(format!(
            "{field} may name only one of vmId, vpcId, tunnelId"
        )));
    }
    if out.is_empty() {
        return Err(CloudError::invalid(format!(
            "{field} must name a vmId, vpcId, tunnelId, cidr or public: true"
        )));
    }
    if public && out.len() > 1 {
        return Err(CloudError::invalid(format!(
            "{field}.public cannot be combined with another identity"
        )));
    }
    let protocol = check::one_of(map, "protocol", &["tcp", "udp", "icmp"])?;
    let port = args::int(map, "port", 1, 65_535, 1)?;
    match (port, protocol) {
        (Some(_), None) => {
            return Err(CloudError::invalid(format!("{field}.protocol is required with port")));
        }
        (Some(_), Some("icmp")) => {
            return Err(CloudError::invalid(format!("{field}.port cannot be used with icmp")));
        }
        _ => {}
    }
    if let Some(port) = port {
        out.insert("port".into(), json!(port));
    }
    if let Some(protocol) = protocol {
        out.insert("protocol".into(), json!(protocol));
    }
    Ok(Value::Object(out))
}
