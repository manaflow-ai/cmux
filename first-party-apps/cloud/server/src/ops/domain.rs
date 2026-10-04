//! `cloud.domain.*` and `cloud.publication.*` over `/api/vm/domains` and
//! `/api/vm/publications`. A publication makes a port of a machine reachable
//! on a host name, so create, update (it can make one public) and delete run
//! only for origin `user`; the verify ops only re-check DNS and certificate
//! state and are mutate-own.

use super::network_args as check;
use super::network_models::{DomainAnswer, DomainList, PublicationAnswer, PublicationList};
use crate::api::{CloudError, ControlPlane, Ctx, args, codes, decode_answer};
use serde_json::{Map, Value, json};

const ACCESS_MODES: &[&str] = &["personal", "team", "public"];

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.domain.list" => {
            args::object(raw, &[])?;
            let path = "/api/vm/domains";
            let list: DomainList = decode_answer(path, ctx.call("GET", path.into(), None)?)?;
            Ok(json!(list))
        }
        "cloud.domain.verify" => {
            let domain = check::host_ref(args::object(raw, &["domain"])?, "domain")?;
            let path = format!("/api/vm/domains/{domain}/verify");
            let answer: DomainAnswer =
                decode_answer(&path, ctx.call("POST", path.clone(), Some(json!({})))?)?;
            Ok(json!(answer))
        }
        "cloud.publication.list" => {
            let map = args::object(raw, &["machine"])?;
            let machine = match map.get("machine") {
                None | Some(Value::Null) => None,
                Some(_) => Some(args::id(map, "machine")?),
            };
            let path = "/api/vm/publications";
            let mut list: PublicationList =
                decode_answer(path, ctx.call("GET", path.into(), None)?)?;
            if let Some(machine) = machine {
                list.publications.retain(|p| p.vm_id == machine);
            }
            Ok(json!(list))
        }
        "cloud.publication.create" => create(ctx, raw),
        "cloud.publication.update" => {
            let map = args::object(raw, &["publication", "accessMode", "teamId", "confirmPublic"])?;
            let id = check::host_ref(map, "publication")?;
            let mut body = Map::new();
            let mode = check::one_of(map, "accessMode", ACCESS_MODES)?
                .ok_or_else(|| CloudError::invalid("accessMode is required"))?;
            body.insert("accessMode".into(), json!(mode));
            access_fields(map, &mut body)?;
            let path = format!("/api/vm/publications/{id}");
            let answer: PublicationAnswer =
                decode_answer(&path, ctx.call("PATCH", path.clone(), Some(Value::Object(body)))?)?;
            Ok(json!(answer))
        }
        "cloud.publication.delete" => {
            let id = check::host_ref(args::object(raw, &["publication"])?, "publication")?;
            ctx.call("DELETE", format!("/api/vm/publications/{id}"), None)?;
            Ok(json!({ "ok": true }))
        }
        "cloud.publication.verify" => {
            let id = check::host_ref(args::object(raw, &["publication"])?, "publication")?;
            let path = format!("/api/vm/publications/{id}/verify");
            let answer: PublicationAnswer =
                decode_answer(&path, ctx.call("POST", path.clone(), Some(json!({})))?)?;
            Ok(json!(answer))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

fn create<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(
        raw,
        &["machine", "port", "accessMode", "hostname", "teamId", "confirmPublic"],
    )?;
    let mut body = Map::new();
    body.insert("vmId".into(), json!(args::id(map, "machine")?));
    let port = args::int(map, "port", 1, 65_535, 1)?
        .ok_or_else(|| CloudError::invalid("port is required"))?;
    body.insert("port".into(), json!(port));
    if let Some(mode) = check::one_of(map, "accessMode", ACCESS_MODES)? {
        body.insert("accessMode".into(), json!(mode));
    }
    match map.get("hostname") {
        None | Some(Value::Null) => {}
        Some(Value::String(h)) if check::is_hostname(h) => {
            body.insert("hostname".into(), json!(h));
        }
        Some(_) => {
            return Err(CloudError::invalid(
                "hostname must be one DNS host name without scheme, port, path or wildcard",
            ));
        }
    }
    access_fields(map, &mut body)?;
    let path = "/api/vm/publications";
    let answer: PublicationAnswer =
        decode_answer(path, ctx.call("POST", path.into(), Some(Value::Object(body)))?)?;
    Ok(json!(answer))
}

/// `teamId` and `confirmPublic`, passed on as given. The Cloud API refuses
/// a public mode without `confirmPublic: true`; only a person reaches these
/// ops (origin `user`), so the flag records that person's confirmation.
fn access_fields(
    map: &Map<String, Value>,
    body: &mut Map<String, Value>,
) -> Result<(), CloudError> {
    if let Some(team) = check::optional_token(map, "teamId")? {
        body.insert("teamId".into(), json!(team));
    }
    if let Some(confirm) = check::flag(map, "confirmPublic")? {
        body.insert("confirmPublic".into(), json!(confirm));
    }
    Ok(())
}
