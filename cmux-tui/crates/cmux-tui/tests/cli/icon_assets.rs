//! Icon assets through a real daemon (`icon-assets-v1`): `put-blob` and
//! `get-blob` over the raw socket, and icon fields that take only a stored
//! asset of the matching kind.
#![cfg(unix)]

use base64::Engine;

use super::*;

const UNKNOWN: &str =
    "image:sha256-0000000000000000000000000000000000000000000000000000000000000000";

fn encode(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// A PNG signature followed by `seed`, so each seed is a different blob.
fn png(seed: u8) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
    data.extend_from_slice(&[seed; 32]);
    data
}

fn put(server: &HeadlessServer, media_type: &str, data: &[u8]) -> Output {
    raw_cli(
        server,
        serde_json::json!({"id": "put", "cmd": "put-blob", "media_type": media_type,
                           "data": encode(data)}),
    )
}

/// The `error_code` of a refused raw command.
fn refused(output: &Output) -> String {
    assert!(!output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
    let error = json_error(output);
    error["code"].as_str().map(str::to_string).unwrap_or_else(|| error.to_string())
}

#[test]
fn icon_assets_round_trip_and_gate_icon_fields_through_a_real_daemon() {
    let server = HeadlessServer::start("icon-assets");
    let identity = raw_json(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "icon-assets-v1"),
        "{identity}"
    );

    // put-blob: content addressed, idempotent, readable by ref or icon value.
    let data = png(1);
    let first = put(&server, "image/png", &data);
    assert_success(&first);
    let first = json_output(&first);
    let reference = first["ref"].as_str().unwrap().to_string();
    let digest = reference.strip_prefix("blob:sha256-").unwrap().to_string();
    let raster = format!("image:sha256-{digest}");
    assert_eq!(first["icon"], serde_json::json!(raster), "{first}");
    assert_eq!(json_output(&put(&server, "image/png", &data)), first);
    for name in [reference.as_str(), raster.as_str()] {
        let got =
            raw_json(&server, serde_json::json!({"id": "get", "cmd": "get-blob", "blob": name}));
        assert_eq!(got["data"], serde_json::json!(encode(&data)), "{got}");
        assert_eq!(got["media_type"], "image/png");
    }

    // An SVG is stored sanitized.
    let svg = put(
        &server,
        "image/svg+xml",
        br#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><path d="M0 0h1"/></svg>"#,
    );
    assert_success(&svg);
    let svg = json_output(&svg);
    let stored =
        raw_json(&server, serde_json::json!({"id": "svg", "cmd": "get-blob", "blob": svg["ref"]}));
    assert_eq!(
        stored["data"],
        serde_json::json!(encode(
            br#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1"></path></svg>"#
        )),
    );

    // Wrong magic bytes, unknown types and missing blobs are refused.
    assert_eq!(refused(&put(&server, "image/jpeg", &png(2))), "invalid_params");
    assert_eq!(refused(&put(&server, "text/html", b"<html></html>")), "invalid_params");
    // An SVG the sanitizer cannot reduce to a plain icon is refused, not stored.
    for bad in [
        &br#"<!DOCTYPE svg [<!ENTITY a "aaaa">]><svg xmlns="http://www.w3.org/2000/svg"><text>&a;</text></svg>"#[..],
        br#"<html xmlns="http://www.w3.org/1999/xhtml"><script>alert(1)</script></html>"#,
        b"not svg at all",
    ] {
        assert_eq!(
            refused(&put(&server, "image/svg+xml", bad)),
            "invalid_params",
            "{}",
            String::from_utf8_lossy(bad)
        );
    }
    let missing = format!("blob:sha256-{}", "1".repeat(64));
    let missing =
        raw_cli(&server, serde_json::json!({"id": "missing", "cmd": "get-blob", "blob": missing}));
    assert_eq!(refused(&missing), "not_found");
    let swapped = raster.replace("image:", "svg:");
    let swapped_get =
        raw_cli(&server, serde_json::json!({"id": "swapped", "cmd": "get-blob", "blob": swapped}));
    assert_eq!(refused(&swapped_get), "not_found");

    // Icon fields take a stored asset of the matching kind only.
    state_cli(&server, None, &["workspace", "create", "--name", "art", "--empty"]);
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "art")
        .and_then(|workspace| workspace["key"].as_str())
        .unwrap_or_else(|| panic!("no art workspace: {tree}"))
        .to_string();
    let set = |icon: &str| {
        raw_cli(
            &server,
            serde_json::json!({"id": "icon", "cmd": "set-workspace-metadata", "key": key,
                               "icon": icon}),
        )
    };
    let unknown_svg = UNKNOWN.replace("image:", "svg:");
    for bad in [UNKNOWN, unknown_svg.as_str(), swapped.as_str()] {
        assert_eq!(refused(&set(bad)), "unknown_icon_asset", "{bad}");
    }
    let svg_icon = svg["icon"].as_str().unwrap().to_string();
    for icon in [raster.as_str(), svg_icon.as_str()] {
        let accepted = set(icon);
        assert_success(&accepted);
        assert_eq!(json_output(&accepted)["icon"], serde_json::json!(icon));
    }
}
