//! Every case of `backend/catalog/cloud-vectors.json` round-trips through the
//! generated types: the params decode as the op's params struct, every
//! response body decodes as the op's typed envelope (with the op's error
//! enum), each encodes back to the same JSON, and no part of a vector lands in
//! an `Unknown` variant (the vectors use only declared codes, values and union
//! members). The generated op set equals the catalog's (name, class,
//! idempotency, declared error codes). A newer backend's code, enum value or
//! union member decodes to `Unknown` and encodes back unchanged.

use cmux_cloud_wire::{
    HttpError, Op, OpRequest, OpResponse, OpVisitor, ReadResponse, WireClass, WireError, visit_op,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::fmt::Debug;
use std::path::Path;

fn catalog_file(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../backend/catalog").join(name);
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&raw).expect("catalog JSON")
}

/// JSON equality where numbers compare by value (`1` equals `1.0`).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x == y || x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn round_trip<T: Serialize + DeserializeOwned + Debug>(
    what: &str,
    json: &Value,
) -> Result<(), String> {
    let typed: T =
        serde_json::from_value(json.clone()).map_err(|e| format!("{what}: decode: {e}"))?;
    // Every Unknown variant (error code, string enum, union) is a tuple variant.
    let debug = format!("{typed:?}");
    if debug.contains("Unknown(") {
        return Err(format!("{what}: a part decodes only as Unknown: {debug}"));
    }
    let back = serde_json::to_value(&typed).map_err(|e| format!("{what}: encode: {e}"))?;
    if same(&back, json) {
        Ok(())
    } else {
        Err(format!("{what}: round trip differs\n  wire: {json}\n  back: {back}"))
    }
}

/// Round-trips one vector case through the types of its op.
struct CaseTrip<'a>(&'a Value);

impl OpVisitor for CaseTrip<'_> {
    type Output = Result<usize, String>;

    fn visit<O: Op>(self) -> Self::Output {
        let case = self.0;
        let name = case["name"].as_str().unwrap_or("?");
        if let Some(class) = case["class"].as_str()
            && class != O::CLASS.as_str()
        {
            return Err(format!("{name}: class {class}, catalog {}", O::CLASS.as_str()));
        }
        let params = &case["params"];
        round_trip::<O::Params>(&format!("{name} params"), params)?;

        // The request body is {op, params, idempotency_key?} (conventions.request).
        let typed: O::Params = serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
        let mut request = OpRequest::new::<O>(typed);
        let mut want = json!({ "op": O::NAME, "params": params });
        let key = case.get("idempotency_key").or_else(|| case.get("request_idempotency_key"));
        if let Some(key) = key.and_then(Value::as_str) {
            request = request.with_idempotency_key(key);
            want["idempotency_key"] = json!(key);
        }
        let sent = serde_json::to_value(&request).map_err(|e| e.to_string())?;
        if !same(&sent, &want) {
            return Err(format!("{name}: request {sent}, want {want}"));
        }

        let mut checked = 0;
        for (i, response) in case["responses"].as_array().expect("responses").iter().enumerate() {
            let what = format!("{name} responses[{i}]");
            let status = response["http"]["status"].as_i64().expect("status");
            let path = response["http"]["path"].as_str().expect("path");
            if path != O::CLASS.http_path() {
                return Err(format!("{what}: path {path}, class wants {}", O::CLASS.http_path()));
            }
            let body = &response["body"];
            match (status, O::CLASS) {
                (200, WireClass::Read) => round_trip::<ReadResponse<O::Result>>(&what, body)?,
                (200, WireClass::Mutation) => {
                    round_trip::<OpResponse<O::Result, O::Error>>(&what, body)?;
                }
                _ => round_trip::<HttpError<O::Error>>(&what, body)?,
            }
            checked += 1;
        }
        Ok(checked)
    }
}

#[test]
fn every_vector_case_round_trips_through_the_generated_types() {
    let vectors = catalog_file("cloud-vectors.json");
    let catalog = catalog_file("cloud-operations.json");
    let ops = catalog["operations"].as_object().expect("operations");
    let mut failures = Vec::new();
    let (mut cases, mut responses) = (0, 0);
    for group in ["cases", "backend_only"] {
        for case in vectors[group].as_array().expect(group) {
            let op = case["op"].as_str().expect("op");
            if group == "backend_only" && !ops.contains_key(op) {
                // An internal op (for example cloud.machine.bind): not in the
                // catalog, so not part of the client.
                continue;
            }
            match visit_op(op, CaseTrip(case)) {
                None => failures.push(format!("{}: no generated type for op {op}", case["name"])),
                Some(Err(e)) => failures.push(e),
                Some(Ok(n)) => {
                    cases += 1;
                    responses += n;
                }
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    let total = vectors["cases"].as_array().map_or(0, Vec::len);
    assert!(cases >= total, "round-tripped {cases} cases, the vectors hold {total}");
    assert!(responses > cases, "round-tripped {responses} responses for {cases} cases");
}

/// Checks one op's generated constants against its catalog row.
struct CatalogRow<'a>(&'a str, &'a Value);

impl OpVisitor for CatalogRow<'_> {
    type Output = Vec<String>;

    fn visit<O: Op>(self) -> Self::Output {
        let (name, row) = (self.0, self.1);
        let mut wrong = Vec::new();
        if O::NAME != name {
            wrong.push(format!("{name}: NAME {}", O::NAME));
        }
        if row["class"] != O::CLASS.as_str() {
            wrong.push(format!("{name}: class {} vs {}", row["class"], O::CLASS.as_str()));
        }
        if row["idempotency"] != O::IDEMPOTENCY.as_str() {
            wrong.push(format!(
                "{name}: idempotency {} vs {}",
                row["idempotency"],
                O::IDEMPOTENCY.as_str()
            ));
        }
        let mut declared: Vec<&str> =
            row["errors"].as_array().expect("errors").iter().filter_map(Value::as_str).collect();
        // A row may list a code twice; the generated set holds it once.
        declared.dedup();
        if declared != O::Error::CODES {
            wrong.push(format!("{name}: errors {declared:?} vs {:?}", O::Error::CODES));
        }
        for code in &declared {
            let e = O::Error::from_code(code);
            if e.code() != *code || !e.is_declared() {
                wrong.push(format!("{name}: code {code} maps to {e:?}"));
            }
        }
        let newer = O::Error::from_code("cmux.newer.code");
        if newer.is_declared() || newer.code() != "cmux.newer.code" {
            wrong.push(format!("{name}: an undeclared code maps to {newer:?}"));
        }
        let principals: Vec<&str> = O::PRINCIPALS.iter().map(|p| p.as_str()).collect();
        let want: Vec<&str> = row["principals"]
            .as_array()
            .expect("principals")
            .iter()
            .filter_map(Value::as_str)
            .collect();
        if principals != want {
            wrong.push(format!("{name}: principals {principals:?} vs {want:?}"));
        }
        wrong
    }
}

#[test]
fn the_generated_op_set_is_the_catalog() {
    let catalog = catalog_file("cloud-operations.json");
    let ops = catalog["operations"].as_object().expect("operations");
    let mut wrong = Vec::new();
    for (name, row) in ops {
        match visit_op(name, CatalogRow(name, row)) {
            None => wrong.push(format!("{name}: no generated op")),
            Some(found) => wrong.extend(found),
        }
    }
    assert!(visit_op("cmux.no.such.op", CatalogRow("", &Value::Null)).is_none());
    assert!(wrong.is_empty(), "{} mismatches:\n{}", wrong.len(), wrong.join("\n"));
}

#[test]
fn a_newer_error_code_decodes_as_unknown_and_round_trips() {
    let catalog = catalog_file("cloud-operations.json");
    let op = "cloud.machine.list";
    assert!(catalog["operations"].get(op).is_some(), "{op} left the catalog; pick another op");

    struct Newer;
    impl OpVisitor for Newer {
        type Output = Result<(), String>;
        fn visit<O: Op>(self) -> Self::Output {
            let declared = json!({ "_tag": "Unauthenticated", "code": "auth.unauthenticated", "message": "x" });
            let newer = json!({ "_tag": "Conflict", "code": "cmux.newer.code", "message": "x" });
            let d: HttpError<O::Error> =
                serde_json::from_value(declared).map_err(|e| e.to_string())?;
            let n: HttpError<O::Error> =
                serde_json::from_value(newer.clone()).map_err(|e| e.to_string())?;
            if !d.code.is_declared() || n.code.is_declared() {
                return Err(format!("declared {:?}, newer {:?}", d.code, n.code));
            }
            let back = serde_json::to_value(&n).map_err(|e| e.to_string())?;
            if back != newer {
                return Err(format!("newer code round trip: {back}"));
            }
            Ok(())
        }
    }
    assert_eq!(visit_op(op, Newer), Some(Ok(())));
}

#[test]
fn a_newer_union_member_decodes_as_unknown_and_round_trips() {
    let newer = json!({ "type": "cmux_newer_body", "anything": [1, "two"] });
    let body: cmux_cloud_wire::Body = serde_json::from_value(newer.clone()).expect("decodes");
    assert!(matches!(body, cmux_cloud_wire::Body::Unknown(_)), "{body:?}");
    assert_eq!(serde_json::to_value(&body).expect("encodes"), newer);

    let known = json!({ "type": "steps", "steps": [] });
    let body: cmux_cloud_wire::Body = serde_json::from_value(known.clone()).expect("decodes");
    assert!(matches!(body, cmux_cloud_wire::Body::Steps(_)), "{body:?}");
    assert_eq!(serde_json::to_value(&body).expect("encodes"), known);
}
