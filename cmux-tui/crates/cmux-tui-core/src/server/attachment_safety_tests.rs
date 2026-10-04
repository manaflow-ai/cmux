//! RED tests for the six conditions the protocol owner set on
//! `home-attachments-v1` (plans/cmux-next/home-messaging.md 10.2,
//! "Owner conditions"): staging cleanup and expiry, byte reservation (C1),
//! the icon to attachment upgrade (C2), local-only transports (C3), no
//! staged path (C4), blob paths only from a stored digest (C5) and a commit
//! over an existing digest file (C6). They compile against today's daemon
//! and fail at run time; each test names its failure today.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use super::*;

const MINUTE: Duration = Duration::from_secs(60);

/// A daemon with a state directory on disk (the blob files live there).
fn persistent_mux(label: &str) -> (Arc<Mux>, u64, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-attach-{label}-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(label, crate::SurfaceOptions::default(), &root).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client, root)
}

/// The session state directory: the directory of the registry database.
fn state_dir(mux: &Arc<Mux>) -> PathBuf {
    let registry = mux.workspace_registry.lock().unwrap();
    let database = registry.connection.path().expect("a persistent registry has a path");
    Path::new(database).parent().unwrap().to_path_buf()
}

fn staging_dir(mux: &Arc<Mux>) -> PathBuf {
    state_dir(mux).join("blobs").join("staging")
}

fn digest_path(mux: &Arc<Mux>, digest: &str) -> PathBuf {
    state_dir(mux).join("blobs").join("sha256").join(&digest[..2]).join(digest)
}

fn staged_files(mux: &Arc<Mux>) -> Vec<PathBuf> {
    match std::fs::read_dir(staging_dir(mux)) {
        Ok(entries) => entries.map(|entry| entry.unwrap().path()).collect(),
        Err(_) => Vec::new(),
    }
}

/// Make a staging file look idle for `age` (the idle clock is its mtime).
fn age_file(path: &Path, age: Duration) {
    let file = std::fs::File::options().write(true).open(path).unwrap();
    file.set_modified(SystemTime::now() - age).unwrap();
}

fn chunk(
    mux: &Arc<Mux>,
    client: u64,
    upload: &Value,
    offset: usize,
    data: &[u8],
) -> anyhow::Result<Value> {
    run(
        mux,
        client,
        json!({"cmd":"blob-upload-chunk","upload":upload,"offset":offset,"data":base64(data)}),
    )
}

/// A unique fake digest; begin never needs the bytes.
fn fake_digest(index: usize) -> String {
    sha256_hex(format!("reservation-{index}").as_bytes())
}

fn png(seed: u8) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n".to_vec();
    data.extend_from_slice(&[seed; 64]);
    data
}

fn row(mux: &Arc<Mux>, digest: &str) -> Option<(String, String, bool)> {
    let registry = mux.workspace_registry.lock().unwrap();
    registry
        .connection
        .query_row(
            "SELECT purpose, storage, data IS NULL FROM personal_blobs WHERE digest = ?1",
            [digest],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .ok()
}

/// RED today: `blob-upload-begin` is not a command. The rule: the daemon
/// empties its staging directory at start, so an upload of the previous run
/// and any stray file are gone, and the old upload id is unknown.
#[test]
fn the_daemon_empties_the_staging_directory_at_start() {
    let (mux, client, root) = persistent_mux("staging-start");
    let data = zip(40, 2 * MIB);
    let begun = begin(&mux, client, "application/zip", &sha256_hex(&data), data.len())
        .expect("RED today: blob-upload-begin is not a daemon command");
    chunk(&mux, client, &begun["upload"], 0, &data[..MIB]).unwrap();
    std::fs::write(staging_dir(&mux).join("upl_stray"), b"left by a crash").unwrap();
    assert!(!staged_files(&mux).is_empty());
    drop(mux);

    let mux =
        Mux::open_persistent("staging-start", crate::SurfaceOptions::default(), &root).unwrap();
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    assert!(staged_files(&mux).is_empty(), "start empties staging: {:?}", staged_files(&mux));
    let stale = chunk(&mux, client, &begun["upload"], MIB, &data[MIB..]);
    assert_eq!(error_code(stale), "upload_not_found");
}

/// RED today: no upload command. The rule: an upload with no chunk for 15
/// minutes expires with its staged bytes and its reservation (the idle
/// clock is the staging file's mtime; begin, chunk and commit run the
/// expiry pass).
#[test]
fn an_abandoned_upload_expires_with_its_staged_bytes() {
    let (mux, client, _root) = persistent_mux("staging-expiry");
    let data = zip(41, 2 * MIB);
    let begun = begin(&mux, client, "application/zip", &sha256_hex(&data), data.len())
        .expect("RED today: blob-upload-begin is not a daemon command");
    chunk(&mux, client, &begun["upload"], 0, &data[..MIB]).unwrap();
    let staged = staging_dir(&mux).join(begun["upload"].as_str().unwrap());
    assert!(staged.is_file(), "begin stages under blobs/staging/<upload>");
    age_file(&staged, 16 * MINUTE);

    let other = zip(42, 1000);
    begin(&mux, client, "application/zip", &sha256_hex(&other), other.len()).unwrap();
    assert!(!staged.exists(), "the expiry pass deletes the staged bytes");
    let late = chunk(&mux, client, &begun["upload"], MIB, &data[MIB..]);
    assert_eq!(error_code(late), "upload_not_found");
}

/// RED today: no upload command. C1: begin RESERVES `byte_count` against
/// the store total (10 GB) and the 1 GB disk floor, so open uploads can
/// never promise more than the store holds; nothing is written to reserve.
/// Commit, expiry and connection close release the reservation. Eight open
/// uploads per connection is a second limit (`too_many_uploads`).
/// UNTESTED here: the disk floor alone (it depends on the host disk); it
/// refuses through the same `blob_store_full` path.
#[test]
fn begin_reserves_bytes_and_close_commit_or_expiry_release_them() {
    let (mux, _, _root) = persistent_mux("reservation");
    let mut clients = Vec::new();
    let mut held = Vec::new();
    let mut refused = None;
    'fill: for _ in 0..13 {
        let client = mux.control_clients.register(ClientTransport::Unix, writer());
        clients.push(client);
        for _ in 0..8 {
            let index = held.len();
            match begin(&mux, client, "application/zip", &fake_digest(index), 100_000_000) {
                Ok(begun) => held.push((client, begun["upload"].clone())),
                Err(error) => {
                    refused = Some((index, response_error_code(&error)));
                    break 'fill;
                }
            }
        }
    }
    let (index, code) = refused.expect("RED today: the begins fail before any reservation");
    assert_eq!(code.as_deref(), Some("blob_store_full"));
    assert!(index <= 100, "100 x 100 MB fills the 10 GB total; refused at {index}");
    let staged: u64 = staged_files(&mux).iter().map(|path| path.metadata().unwrap().len()).sum();
    assert_eq!(staged, 0, "a reservation writes no bytes");

    // Closing a connection releases its reservations.
    let next = mux.control_clients.register(ClientTransport::Unix, writer());
    let (closed, _) = held[0].clone();
    disconnect_client(&mux, closed, false);
    begin(&mux, next, "application/zip", &fake_digest(1000), 100_000_000)
        .expect("a closed connection's reservation is free again");
    assert_eq!(
        error_code(begin(&mux, next, "application/zip", &fake_digest(1001), 100_000_000)),
        "blob_store_full"
    );

    // Expiry releases a reservation.
    let (_, idle) = held.iter().find(|(client, _)| *client != closed).unwrap().clone();
    age_file(&staging_dir(&mux).join(idle.as_str().unwrap()), 16 * MINUTE);
    begin(&mux, next, "application/zip", &fake_digest(1002), 100_000_000)
        .expect("an expired upload's reservation is free again");
}

/// RED today: no upload command. C1's second limit.
#[test]
fn a_connection_holds_at_most_eight_open_uploads() {
    let (mux, client) = attachment_mux();
    for index in 0..8 {
        begin(&mux, client, "application/zip", &fake_digest(index), 1000)
            .expect("RED today: blob-upload-begin is not a daemon command");
    }
    let ninth = begin(&mux, client, "application/zip", &fake_digest(8), 1000);
    assert_eq!(error_code(ninth), "too_many_uploads");
    // Another connection has its own eight.
    let other = mux.control_clients.register(ClientTransport::Unix, writer());
    begin(&mux, other, "application/zip", &fake_digest(9), 1000).unwrap();
}

/// RED today: no upload command. C2: an attachment upload of bytes stored
/// as an inline icon upgrades the row (file written first, then the row:
/// purpose `attachment`, storage `file`, data NULL). The upgrade never
/// shortens the row's life: an icon reference keeps it, and an unreferenced
/// upgraded row keeps the longer icon grace (7 days, not 24 hours).
#[test]
fn an_icon_upgraded_to_an_attachment_keeps_its_icon_life() {
    let (mux, client, _root) = persistent_mux("upgrade");
    let named = png(43);
    let loose = png(44);
    let icon =
        run(&mux, client, json!({"cmd":"put-blob","media_type":"image/png","data":base64(&named)}))
            .unwrap()["icon"]
            .clone();
    run(&mux, client, json!({"cmd":"put-blob","media_type":"image/png","data":base64(&loose)}))
        .unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    run(&mux, client, json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":icon}))
        .unwrap();

    for data in [&named, &loose] {
        let digest = sha256_hex(data);
        let again = begin(&mux, client, "image/png", &digest, data.len())
            .expect("RED today: blob-upload-begin is not a daemon command");
        assert_eq!(again["exists"], json!(true), "the bytes are stored; nothing moves");
        assert_eq!(row(&mux, &digest), Some(("attachment".into(), "file".into(), true)));
        assert_eq!(std::fs::read(digest_path(&mux, &digest)).unwrap(), *data);
        assert_eq!(download(&mux, client, &json!(format!("blob:sha256-{digest}"))), *data);
    }

    let sweep = |at: u64| mux.workspace_registry.lock().unwrap().sweep_blobs_at(at).unwrap();
    assert_eq!(sweep(now_ms() + 2 * DAY_MS), 0, "the icon grace (7 days) wins over 24 hours");
    assert_eq!(sweep(now_ms() + 8 * DAY_MS), 1, "only the unreferenced upgrade goes");
    assert!(row(&mux, &sha256_hex(&named)).is_some(), "an icon reference keeps the row");
    assert!(digest_path(&mux, &sha256_hex(&named)).is_file());
    assert!(!digest_path(&mux, &sha256_hex(&loose)).exists(), "the sweep unlinks the file");
}

/// RED today: the upload verbs do not exist (no code) and `get-blob` serves
/// any transport. C3: the upload verbs and `get-blob` need a trusted local
/// connection; websocket and remote (forwarded `cmux link`) connections are
/// `forbidden`, for icons too.
#[test]
fn upload_and_get_blob_are_forbidden_off_a_trusted_local_connection() {
    let (mux, client) = attachment_mux();
    let icon = png(45);
    let stored =
        run(&mux, client, json!({"cmd":"put-blob","media_type":"image/png","data":base64(&icon)}))
            .unwrap();
    let data = zip(46, 1000);
    for transport in [ClientTransport::WebSocket, ClientTransport::Remote] {
        let outsider = mux.control_clients.register(transport, writer());
        let requests = [
            json!({"cmd":"blob-upload-begin","purpose":"attachment","media_type":"application/zip",
                   "sha256":sha256_hex(&data),"byte_count":data.len()}),
            json!({"cmd":"blob-upload-chunk","upload":"upl_x","offset":0,"data":base64(&data)}),
            json!({"cmd":"blob-upload-commit","upload":"upl_x"}),
            json!({"cmd":"get-blob","blob":stored["ref"]}),
            json!({"cmd":"get-blob","blob":stored["ref"],"offset":0,"length":10}),
        ];
        for request in requests {
            assert_eq!(error_code(run(&mux, outsider, request.clone())), "forbidden", "{request}");
        }
    }
}

/// RED today: no upload command. C4: an upload never hands out or takes a
/// path. The staged mode is deferred (`mode` other than absent is
/// `invalid_params`), a `path` or `staged_path` field is `invalid_params`,
/// and no reply carries `staged_path`. No gesture token is needed (none of
/// these requests carry one), so a page bridge can upload and read.
#[test]
fn an_upload_never_names_a_path() {
    let (mux, client) = attachment_mux();
    let data = zip(47, 1000);
    let sha = sha256_hex(&data);
    let base = json!({"cmd":"blob-upload-begin","purpose":"attachment",
                      "media_type":"application/zip","sha256":sha,"byte_count":data.len()});
    for (field, value) in
        [("mode", json!("staged")), ("path", json!("/etc/hosts")), ("staged_path", json!("/tmp/x"))]
    {
        let mut request = base.clone();
        request[field] = value;
        assert_eq!(error_code(run(&mux, client, request)), "invalid_params", "{field}");
    }
    let begun =
        run(&mux, client, base).expect("RED today: blob-upload-begin is not a daemon command");
    let sent = chunk(&mux, client, &begun["upload"], 0, &data).unwrap();
    let stored =
        run(&mux, client, json!({"cmd":"blob-upload-commit","upload":begun["upload"]})).unwrap();
    let read = run(&mux, client, json!({"cmd":"get-blob","blob":stored["ref"]})).unwrap();
    for reply in [&begun, &sent, &stored, &read] {
        assert!(reply.get("staged_path").is_none() && reply.get("path").is_none(), "{reply}");
    }
}

/// RED today: no upload command. C5: a file path comes only from a
/// validated 64-lowercase-hex digest of an EXISTING row. Traversal, wrong
/// lengths, upper case, an upload id, and a valid digest with a file but no
/// row are refused, and no planted file is ever served.
#[test]
fn get_blob_serves_files_only_for_stored_rows() {
    let (mux, client, _root) = persistent_mux("paths");
    let data = zip(48, 3000);
    upload(&mux, client, "application/zip", &data);
    let open = begin(&mux, client, "application/zip", &sha256_hex(&zip(49, 10)), 10).unwrap();
    let upload_id = open["upload"].as_str().unwrap().to_string();

    let planted = sha256_hex(b"planted");
    let path = digest_path(&mux, &planted);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, b"SECRET planted bytes").unwrap();
    std::fs::write(staging_dir(&mux).join(&upload_id), b"SECRET staged bytes").unwrap();

    let hex = sha256_hex(&data);
    let refs = [
        format!("blob:sha256-../../{}", &hex[6..]),
        format!("blob:sha256-{}", &hex[..63]),
        format!("blob:sha256-{hex}0"),
        format!("blob:sha256-{}", hex.to_uppercase()),
        format!("blob:sha256-{upload_id}"),
        upload_id,
        format!("blob:sha256-{planted}"),
        format!("blob:sha256-{}/../{}", &hex[..2], &hex[3..]),
    ];
    for reference in refs {
        let result = run(&mux, client, json!({"cmd":"get-blob","blob":reference,"offset":0}));
        let code = error_code(result);
        assert!(code == "not_found" || code == "invalid_params", "{reference}: {code}");
    }
    assert_eq!(download(&mux, client, &json!(format!("blob:sha256-{hex}"))), data);
}

/// RED today: no upload command. C6: a commit over an existing digest file
/// (a crash left it without a row, or a process changed it) never trusts
/// it: the daemon verifies its hash or renames the staged copy over it
/// atomically. Either way the stored file holds the uploaded bytes.
#[test]
fn a_commit_over_an_existing_digest_file_stores_the_uploaded_bytes() {
    let (mux, client, _root) = persistent_mux("overwrite");
    let data = zip(50, MIB + 11);
    let digest = sha256_hex(&data);
    let path = digest_path(&mux, &digest);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, b"stale bytes with the right name").unwrap();

    let stored = upload(&mux, client, "application/zip", &data);
    assert_eq!(std::fs::read(&path).unwrap(), data, "the digest file holds the uploaded bytes");
    assert_eq!(download(&mux, client, &stored["ref"]), data);
}
