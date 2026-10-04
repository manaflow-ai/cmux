//! The personal blob store: content addressing, limits, the reference sweep
//! and the total cap (`icon-assets-v1`).

use std::path::PathBuf;

use super::super::super::new_uuid_v4;
use super::*;

const DAY_MS: u64 = 24 * 60 * 60 * 1000;
const T0: u64 = 1_800_000_000_000;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-blobs-{label}-{}", new_uuid_v4()))
}

fn open(label: &str) -> (WorkspaceRegistry, PathBuf) {
    let root = temp_root(label);
    (WorkspaceRegistry::open(&root, "blobs").unwrap(), root)
}

/// A PNG signature and `seed`, padded to `len` bytes.
fn png(seed: u32, len: usize) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
    data.extend_from_slice(&seed.to_be_bytes());
    data.resize(len.max(data.len()), 0);
    data
}

fn code(result: anyhow::Result<impl std::fmt::Debug>) -> &'static str {
    let error = result.expect_err("the request must be refused");
    error.downcast_ref::<IconAssetError>().map_or("none", IconAssetError::code)
}

fn digests(registry: &WorkspaceRegistry) -> Vec<String> {
    let mut statement =
        registry.connection.prepare("SELECT digest FROM personal_blobs ORDER BY digest").unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<_, _>>().unwrap()
}

#[test]
fn a_blob_is_addressed_by_the_sha256_of_its_stored_bytes() {
    let (mut registry, _root) = open("address");
    let blob = registry.put_blob_at("image/png", b"\x89PNG\r\n\x1a\nabc", T0).unwrap();
    // sha256 of the 11 stored bytes, computed independently.
    let expected: String =
        Sha256::digest(b"\x89PNG\r\n\x1a\nabc").iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(blob.digest, expected);
    assert_eq!(blob.reference(), format!("blob:sha256-{expected}"));
    assert_eq!(blob.icon(), format!("image:sha256-{expected}"));
    let again = registry.put_blob_at("image/png", b"\x89PNG\r\n\x1a\nabc", T0 + DAY_MS).unwrap();
    assert_eq!(again, blob);
    assert_eq!(digests(&registry), [expected]);
    let touched: i64 = registry
        .connection
        .query_row("SELECT touched_ms FROM personal_blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(touched as u64, T0 + DAY_MS, "a repeated put refreshes the blob's age");
    assert_eq!(registry.get_blob(&blob.reference()).unwrap(), blob);
    assert_eq!(code(registry.get_blob(&format!("svg:sha256-{}", "e".repeat(64)))), "not_found");
}

#[test]
fn raster_types_are_checked_by_magic_bytes_and_size() {
    for (media_type, data) in [
        ("image/png", png(1, 16)),
        ("image/jpeg", b"\xff\xd8\xff\xdb....".to_vec()),
        ("image/webp", b"RIFF\x10\0\0\0WEBPVP8L".to_vec()),
    ] {
        let blob = prepare_blob(media_type, &data).unwrap();
        assert_eq!(blob.media_type.as_str(), media_type);
        assert_eq!(blob.data, data, "raster bytes are stored as given");
    }
    for (media_type, data) in [
        ("image/png", b"\xff\xd8\xff\xdb".to_vec()),
        ("image/jpeg", png(1, 16)),
        ("image/webp", b"RIFF\x10\0\0\0AVI LIST".to_vec()),
        ("image/webp", b"RIFF".to_vec()),
        ("image/png", Vec::new()),
        ("image/bmp", b"BM".to_vec()),
        ("", png(1, 16)),
    ] {
        assert_eq!(code(prepare_blob(media_type, &data)), "invalid_params", "{media_type}");
    }
    assert!(prepare_blob("image/png", &png(2, MAX_RASTER_BYTES)).is_ok());
    assert_eq!(code(prepare_blob("image/png", &png(2, MAX_RASTER_BYTES + 1))), "invalid_params");
}

#[test]
fn an_svg_is_stored_sanitized_and_addressed_by_its_sanitized_bytes() {
    let input = br#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" onload="x()"><path d="M0 0"/></svg>"#;
    let blob = prepare_blob("image/svg+xml", input).unwrap();
    let stored = String::from_utf8(blob.data.clone()).unwrap();
    assert_eq!(stored, r#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>"#);
    assert_eq!(blob.icon(), format!("svg:sha256-{}", blob.digest));
    assert_eq!(prepare_blob("image/svg+xml", stored.as_bytes()).unwrap(), blob);
}

#[test]
fn icon_values_must_name_a_stored_asset_of_the_matching_kind() {
    let (mut registry, _root) = open("require");
    let raster = registry.put_blob_at("image/png", &png(3, 16), T0).unwrap();
    let svg = registry
        .put_blob_at("image/svg+xml", br#"<svg xmlns="http://www.w3.org/2000/svg"/>"#, T0)
        .unwrap();
    for ok in ["terminal", "folder.fill", "🚀", raster.icon().as_str(), svg.icon().as_str()] {
        registry.require_icon_asset(ok).unwrap();
    }
    for unknown in [
        raster.icon().replace("image:", "svg:"),
        svg.icon().replace("svg:", "image:"),
        format!("image:sha256-{}", "0".repeat(64)),
    ] {
        assert_eq!(code(registry.require_icon_asset(&unknown)), "unknown_icon_asset", "{unknown}");
    }
    assert!(registry.require_icon_asset("NOT AN ICON").is_err());
}

#[test]
fn the_sweep_keeps_every_registered_reference_and_deletes_old_unreferenced_blobs() {
    let (mut registry, _root) = open("sweep");
    let blobs: Vec<StoredBlob> =
        (0..8).map(|seed| registry.put_blob_at("image/png", &png(seed, 16), T0).unwrap()).collect();
    let icon = |index: usize| blobs[index].icon();
    let connection = &registry.connection;
    connection
        .execute(
            "INSERT INTO workspace_presentation(workspace_key, icon) VALUES('ws-key', ?1)",
            [icon(0)],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO screen_presentation(screen_id, icon) VALUES('screen_1', ?1)",
            [icon(1)],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO saved_screen_groups(saved_id, name, color, members_json, position, updated_at_ms)
             VALUES('ssg_1', 'Saved', 'red', ?1, 0, 0)",
            [serde_json::json!([{"name":"a","icon":icon(2)}]).to_string()],
        )
        .unwrap();
    connection
        .execute("UPDATE profiles SET icon = ?1 WHERE profile_id = 'default'", [icon(3)])
        .unwrap();
    connection
        .execute(
            "INSERT INTO browser_profiles(browser_profile_id, name, icon, position)
             VALUES('3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d', 'Work', ?1, 1)",
            [icon(4)],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO workspace_status_entries(workspace_id, status_key, text, icon, updated_at_ms, position)
             VALUES('ws_1', 'build', 'ok', ?1, 0, 0)",
            [icon(5)],
        )
        .unwrap();
    assert_eq!(registry.sweep_blobs_at(T0 + 6 * DAY_MS).unwrap(), 0, "young blobs stay");
    assert_eq!(registry.sweep_blobs_at(T0 + 8 * DAY_MS).unwrap(), 2);
    let mut kept: Vec<String> = blobs[..6].iter().map(|blob| blob.digest.clone()).collect();
    kept.sort();
    assert_eq!(digests(&registry), kept);
    for field in ICON_REFERENCE_FIELDS {
        assert!(
            registry
                .connection
                .query_row(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [field.0],
                    |_| Ok(())
                )
                .is_ok(),
            "registered field {field:?} names a real table"
        );
    }
}

#[test]
fn a_put_the_sweep_cannot_make_room_for_is_refused() {
    const MINUTE_MS: u64 = 60 * 1000;
    let (mut registry, _root) = open("cap");
    let count = (MAX_TOTAL_BYTES as usize) / MAX_RASTER_BYTES;
    let mut first = Vec::new();
    for seed in 0..count {
        let blob =
            registry.put_blob_at("image/png", &png(seed as u32, MAX_RASTER_BYTES), T0).unwrap();
        first.push(blob);
    }
    // Blob 1 is named by an icon, so no sweep may take it.
    registry
        .connection
        .execute("UPDATE profiles SET icon = ?1 WHERE profile_id = 'default'", [first[1].icon()])
        .unwrap();
    let extra = png(u32::MAX, 16);
    assert_eq!(
        code(registry.put_blob_at("image/png", &extra, T0 + MINUTE_MS)),
        "asset_store_full",
        "every blob is younger than the full-store grace"
    );
    // An existing blob is still accepted: it takes no space.
    registry.put_blob_at("image/png", &png(0, MAX_RASTER_BYTES), T0 + 15 * MINUTE_MS).unwrap();
    // A full store collects unreferenced blobs older than the short grace.
    let later = T0 + 20 * MINUTE_MS;
    assert_eq!(registry.put_blob_at("image/png", &extra, later).unwrap().data, extra);
    let mut kept = vec![first[0].digest.clone(), first[1].digest.clone()];
    kept.push(prepare_blob("image/png", &extra).unwrap().digest);
    kept.sort();
    assert_eq!(digests(&registry), kept, "the refreshed, the named and the new blob");
}

#[test]
fn opening_the_registry_sweeps_old_unreferenced_blobs() {
    let root = temp_root("open-sweep");
    let now = unix_epoch_ms().unwrap();
    {
        let mut registry = WorkspaceRegistry::open(&root, "blobs").unwrap();
        registry.put_blob_at("image/png", &png(1, 16), now - 8 * DAY_MS).unwrap();
        registry.put_blob_at("image/png", &png(2, 16), now - DAY_MS).unwrap();
        assert_eq!(digests(&registry).len(), 2);
    }
    let registry = WorkspaceRegistry::open(&root, "blobs").unwrap();
    assert_eq!(digests(&registry), [prepare_blob("image/png", &png(2, 16)).unwrap().digest]);
}
