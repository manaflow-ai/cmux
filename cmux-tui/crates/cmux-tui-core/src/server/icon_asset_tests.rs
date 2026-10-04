//! Wire tests for asset blobs and asset icon values (`icon-assets-v1`,
//! plans/cmux-next/sidebar-sections.md section 9a).

use base64::Engine;

use super::super::*;

const PROFILE: &str = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
const UNKNOWN: &str =
    "image:sha256-0000000000000000000000000000000000000000000000000000000000000000";
const DAY_MS: u64 = 24 * 60 * 60 * 1000;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let mut request = request;
    request["id"] = json!(7);
    let request: Request = serde_json::from_str(&request.to_string())?;
    handle_command(mux, 0, request.cmd, &writer)
}

fn assets_mux() -> Arc<Mux> {
    Mux::new_for_test("icon-assets", crate::SurfaceOptions::default())
}

fn error_code(result: anyhow::Result<Value>) -> String {
    let error = result.expect_err("the command must fail");
    response_error_code(&error).unwrap_or_else(|| format!("no code: {error}"))
}

fn base64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// A PNG signature followed by `seed`, so each seed is a different blob.
fn png(seed: u8) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
    data.extend_from_slice(&[seed; 32]);
    data
}

fn put(mux: &Arc<Mux>, media_type: &str, data: &[u8]) -> anyhow::Result<Value> {
    run(mux, json!({"cmd":"put-blob","media_type":media_type,"data":base64(data)}))
}

fn workspace_icon(mux: &Arc<Mux>, key: &str) -> Value {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"] == json!(key))
        .map(|workspace| workspace["icon"].clone())
        .unwrap()
}

#[test]
fn put_and_get_round_trip_over_the_wire_and_put_is_idempotent() {
    let mux = assets_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "icon-assets-v1")
    );
    let data = png(1);
    let first = put(&mux, "image/png", &data).unwrap();
    let reference = first["ref"].as_str().unwrap().to_string();
    let digest = reference.strip_prefix("blob:sha256-").unwrap().to_string();
    assert_eq!(digest.len(), 64);
    assert_eq!(first["icon"], json!(format!("image:sha256-{digest}")));
    assert_eq!(first["size"], data.len());
    assert_eq!(first["media_type"], "image/png");
    assert_eq!(put(&mux, "image/png", &data).unwrap(), first);
    for name in [reference, format!("image:sha256-{digest}")] {
        let got = run(&mux, json!({"cmd":"get-blob","blob":name})).unwrap();
        assert_eq!(got["data"], json!(base64(&data)));
        assert_eq!(got["media_type"], "image/png");
        assert_eq!(got["size"], data.len());
    }
    let svg = put(&mux, "image/svg+xml", br#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><path d="M0 0h1"/></svg>"#).unwrap();
    assert!(svg["icon"].as_str().unwrap().starts_with("svg:sha256-"));
    let stored = run(&mux, json!({"cmd":"get-blob","blob":svg["ref"]})).unwrap();
    let stored =
        base64::engine::general_purpose::STANDARD.decode(stored["data"].as_str().unwrap()).unwrap();
    assert_eq!(
        String::from_utf8(stored).unwrap(),
        r#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1"/></svg>"#
    );
    let missing = format!("blob:sha256-{}", "1".repeat(64));
    assert_eq!(error_code(run(&mux, json!({"cmd":"get-blob","blob":missing}))), "not_found");
    assert_eq!(
        error_code(run(&mux, json!({"cmd":"get-blob","blob":"blob:md5-00"}))),
        "invalid_params"
    );
}

#[test]
fn put_refuses_bad_media_types_magic_bytes_base64_and_sizes() {
    let mux = assets_mux();
    let jpeg = b"\xff\xd8\xff\xe0 jpeg".to_vec();
    let mut webp = b"RIFF\0\0\0\0WEBPVP8 ".to_vec();
    webp.extend_from_slice(&[0; 8]);
    assert!(put(&mux, "image/jpeg", &jpeg).is_ok());
    assert!(put(&mux, "image/webp", &webp).is_ok());
    for (media_type, data) in [
        ("image/png", jpeg),
        ("image/jpeg", png(2)),
        ("image/webp", b"RIFF\0\0\0\0WAVEfmt ".to_vec()),
        ("image/png", b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>".to_vec()),
        ("image/gif", b"GIF89a".to_vec()),
        ("text/html", b"<html></html>".to_vec()),
    ] {
        assert_eq!(error_code(put(&mux, media_type, &data)), "invalid_params", "{media_type}");
    }
    assert_eq!(
        error_code(run(&mux, json!({"cmd":"put-blob","media_type":"image/png","data":"!!"}))),
        "invalid_params"
    );
    let mut largest = png(3);
    largest.resize(256 * 1024, 0);
    assert!(put(&mux, "image/png", &largest).is_ok());
    largest.push(0);
    assert_eq!(error_code(put(&mux, "image/png", &largest)), "invalid_params");
    let mut svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\">".to_vec();
    svg.resize(64 * 1024 + 1 - 6, b' ');
    svg.extend_from_slice(b"</svg>");
    assert_eq!(svg.len(), 64 * 1024 + 1);
    assert_eq!(error_code(put(&mux, "image/svg+xml", &svg)), "invalid_params");
}

#[test]
fn icon_fields_accept_stored_assets_and_refuse_unknown_or_mismatched_ones() {
    let mux = assets_mux();
    let raster = put(&mux, "image/png", &png(4)).unwrap()["icon"].as_str().unwrap().to_string();
    let svg = put(&mux, "image/svg+xml", br#"<svg xmlns="http://www.w3.org/2000/svg"/>"#).unwrap()
        ["icon"]
        .as_str()
        .unwrap()
        .to_string();
    let swapped = raster.replace("image:", "svg:");
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let set = |icon: &str| {
        run(&mux, json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":icon}))
    };
    for bad in [UNKNOWN, swapped.as_str()] {
        assert_eq!(error_code(set(bad)), "unknown_icon_asset", "{bad}");
    }
    assert!(workspace_icon(&mux, &workspace.key).is_null());
    for malformed in [
        "image:sha256-ABCDEF0000000000000000000000000000000000000000000000000000000000",
        "image:sha256-000",
        "png:sha256-0000000000000000000000000000000000000000000000000000000000000000",
        "image:0000000000000000000000000000000000000000000000000000000000000000",
    ] {
        let error = set(malformed).expect_err(malformed).to_string();
        assert!(error.starts_with("bad request: icon must be"), "{malformed}: {error}");
    }
    assert_eq!(set(&raster).unwrap()["icon"], json!(raster));
    assert_eq!(workspace_icon(&mux, &workspace.key), json!(raster));
    assert_eq!(set(&svg).unwrap()["icon"], json!(svg));

    let created = run(
        &mux,
        json!({"cmd":"new-screen","workspace":workspace.workspace,"screen_name":"logs","icon":UNKNOWN}),
    );
    assert_eq!(error_code(created), "unknown_icon_asset");
    let created = run(
        &mux,
        json!({"cmd":"new-screen","workspace":workspace.workspace,"screen_name":"logs","icon":svg}),
    )
    .unwrap();
    let screen = created["screen"].as_u64().unwrap();
    let screen_meta =
        |icon: &str| run(&mux, json!({"cmd":"set-screen-metadata","screen":screen,"icon":icon}));
    assert_eq!(error_code(screen_meta(UNKNOWN)), "unknown_icon_asset");
    assert_eq!(screen_meta(&raster).unwrap()["icon"], json!(raster));

    let room = |icon: &str| {
        run(&mux, json!({"cmd":"create-profile","profile":"prof_art","name":"Art","icon":icon}))
    };
    assert_eq!(error_code(room(UNKNOWN)), "unknown_icon_asset");
    assert_eq!(room(&svg).unwrap()["profile"]["icon"], json!(svg));
    let renamed = run(&mux, json!({"cmd":"update-profile","profile":"prof_art","icon":UNKNOWN}));
    assert_eq!(error_code(renamed), "unknown_icon_asset");

    let browser = |icon: &str| {
        run(
            &mux,
            json!({"cmd":"create-browser-profile","browser_profile":PROFILE,"name":"Work",
                   "icon":icon}),
        )
    };
    assert_eq!(error_code(browser(UNKNOWN)), "unknown_icon_asset");
    assert_eq!(browser(&raster).unwrap()["browser_profile"]["icon"], json!(raster));
    let updated =
        run(&mux, json!({"cmd":"update-browser-profile","browser_profile":PROFILE,"icon":UNKNOWN}));
    assert_eq!(error_code(updated), "unknown_icon_asset");
}

#[test]
fn the_sweep_keeps_assets_an_icon_names_and_deletes_old_unreferenced_ones() {
    let mux = assets_mux();
    let named = put(&mux, "image/png", &png(5)).unwrap();
    let unnamed = put(&mux, "image/png", &png(6)).unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    run(&mux, json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":named["icon"]}))
        .unwrap();
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    let sweep = |at: u64| mux.workspace_registry.lock().unwrap().sweep_blobs_at(at).unwrap();
    assert_eq!(sweep(now + 6 * DAY_MS), 0);
    assert_eq!(sweep(now + 8 * DAY_MS), 1);
    assert!(run(&mux, json!({"cmd":"get-blob","blob":named["ref"]})).is_ok());
    assert_eq!(error_code(run(&mux, json!({"cmd":"get-blob","blob":unnamed["ref"]}))), "not_found");
    // Clearing the icon makes the asset collectable.
    run(&mux, json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":null})).unwrap();
    assert_eq!(sweep(now + 8 * DAY_MS), 1);
}

#[test]
fn a_create_retry_returns_the_stored_record_after_its_old_icon_was_collected() {
    let mux = assets_mux();
    let icon = put(&mux, "image/png", &png(7)).unwrap()["icon"].as_str().unwrap().to_string();
    let browser = json!({"cmd":"create-browser-profile","browser_profile":PROFILE,"name":"Work",
                         "icon":icon});
    let room = json!({"cmd":"create-profile","profile":"prof_art","name":"Art","icon":icon});
    assert_eq!(run(&mux, browser.clone()).unwrap()["changed"], true);
    assert!(run(&mux, room.clone()).is_ok());
    run(&mux, json!({"cmd":"update-browser-profile","browser_profile":PROFILE,"icon":"star"}))
        .unwrap();
    run(&mux, json!({"cmd":"update-profile","profile":"prof_art","icon":"star"})).unwrap();
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    let swept = mux.workspace_registry.lock().unwrap().sweep_blobs_at(now + 8 * DAY_MS).unwrap();
    assert_eq!(swept, 1);
    // The retries are idempotent: they return the stored records.
    let retried = run(&mux, browser).unwrap();
    assert_eq!(retried["changed"], false);
    assert_eq!(retried["browser_profile"]["icon"], "star");
    assert_eq!(run(&mux, room).unwrap()["profile"]["icon"], "star");
}
