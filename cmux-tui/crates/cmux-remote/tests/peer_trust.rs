#![cfg(unix)]
//! Per-peer trust records and the audit log (multi-machine design, next PR 3).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use cmux_remote::peer_trust::{
    Admission, AuditDecision, AuditEntry, PeerAgent, PeerTrust, PeerTrustBook, RefuseReason,
    TrustTier, append_audit, read_audit,
};

const PEER: &str = "AAAAAAAAAAAAAAAAAAAAAA";
const NOW: u64 = 1_800_000_000;

fn grant(folder: &Path, tier: TrustTier) -> PeerTrust {
    PeerTrust {
        fingerprint: PEER.into(),
        tier,
        folders: vec![folder.to_path_buf()],
        agents: vec![PeerAgent::Claude],
        expires_at_unix: None,
        updated_at_unix: NOW,
    }
}

#[test]
fn a_peer_without_a_record_is_refused() {
    let state = tempfile::tempdir().unwrap();
    let book = PeerTrustBook::load(state.path()).unwrap();
    let cwd = tempfile::tempdir().unwrap();

    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, cwd.path(), NOW),
        Admission::Refuse(RefuseReason::NoGrant)
    );
}

#[test]
fn folders_tier_admits_inside_the_allowlist_and_ask_tier_asks() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    let nested = project.path().join("crates/api");
    fs::create_dir_all(&nested).unwrap();

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(grant(project.path(), TrustTier::Folders)).unwrap();
    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, &nested, NOW),
        Admission::Admit(fs::canonicalize(&nested).unwrap())
    );
    assert_eq!(
        book.admit(PEER, PeerAgent::Codex, &nested, NOW),
        Admission::Refuse(RefuseReason::AgentNotAllowed)
    );

    book.set(grant(project.path(), TrustTier::Ask)).unwrap();
    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, &nested, NOW),
        Admission::Ask(fs::canonicalize(&nested).unwrap())
    );

    book.set(grant(project.path(), TrustTier::None)).unwrap();
    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, &nested, NOW),
        Admission::Refuse(RefuseReason::NoGrant)
    );
}

#[test]
fn a_symlink_out_of_the_allowlist_a_sibling_prefix_and_a_missing_folder_are_refused() {
    let state = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("api");
    let sibling = root.path().join("api-secrets");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(&sibling).unwrap();
    std::os::unix::fs::symlink(&sibling, project.join("escape")).unwrap();

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(grant(&project, TrustTier::Folders)).unwrap();

    for cwd in [project.join("escape"), sibling, project.join("missing")] {
        assert_eq!(
            book.admit(PEER, PeerAgent::Claude, &cwd, NOW),
            Admission::Refuse(RefuseReason::FolderNotAllowed),
            "{}",
            cwd.display()
        );
    }
}

#[test]
fn an_expired_grant_is_refused() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    let mut expiring = grant(project.path(), TrustTier::Folders);
    expiring.expires_at_unix = Some(NOW);

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(expiring).unwrap();

    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, project.path(), NOW),
        Admission::Refuse(RefuseReason::Expired)
    );
}

#[test]
fn grants_reject_the_filesystem_root_relative_folders_and_bad_fingerprints() {
    let state = tempfile::tempdir().unwrap();
    let mut book = PeerTrustBook::load(state.path()).unwrap();

    assert!(book.set(grant(Path::new("/"), TrustTier::Folders)).is_err());
    assert!(book.set(grant(Path::new("src/api"), TrustTier::Folders)).is_err());
    assert!(book.set(grant(Path::new("/src/../etc"), TrustTier::Folders)).is_err());
    let mut bad = grant(state.path(), TrustTier::Folders);
    bad.fingerprint = "../../etc".into();
    assert!(book.set(bad).is_err());
    assert!(book.peers().is_empty());
}

#[test]
fn records_persist_owner_only_and_forget_removes_them() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(grant(project.path(), TrustTier::Folders)).unwrap();
    book.save(state.path()).unwrap();

    let path = state.path().join("peer-trust.json");
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let mut reloaded = PeerTrustBook::load(state.path()).unwrap();
    assert_eq!(reloaded.peers().len(), 1);
    assert!(matches!(
        reloaded.admit(PEER, PeerAgent::Claude, project.path(), NOW),
        Admission::Admit(_)
    ));

    assert!(reloaded.forget(PEER));
    assert!(!reloaded.forget(PEER));
    reloaded.save(state.path()).unwrap();
    assert!(PeerTrustBook::load(state.path()).unwrap().peers().is_empty());
}

#[test]
fn a_trust_file_readable_by_others_is_rejected() {
    let state = tempfile::tempdir().unwrap();
    let path = state.path().join("peer-trust.json");
    fs::write(&path, r#"{"version":1,"peers":[]}"#).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

    assert!(PeerTrustBook::load(state.path()).is_err());
}

fn entry(at_unix: u64, cwd: &Path, decision: AuditDecision) -> AuditEntry {
    AuditEntry {
        at_unix,
        peer: PEER.into(),
        request_id: Some(format!("request-{at_unix}")),
        method: "machine.session.request".into(),
        agent: Some(PeerAgent::Claude),
        cwd: Some(cwd.to_path_buf()),
        truncated: false,
        decision,
    }
}

#[test]
fn the_audit_log_appends_owner_only_and_reads_the_newest_entries() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();

    append_audit(
        state.path(),
        &entry(NOW, project.path(), AuditDecision::Refused(RefuseReason::NoGrant)),
    )
    .unwrap();
    append_audit(state.path(), &entry(NOW + 1, project.path(), AuditDecision::Admitted)).unwrap();

    let path = state.path().join("peer-audit.jsonl");
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let entries = read_audit(state.path(), 10).unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].decision, AuditDecision::Refused(RefuseReason::NoGrant));
    assert_eq!(entries[1].decision, AuditDecision::Admitted);
    assert_eq!(entries[1].request_id.as_deref(), Some("request-1800000001"));
    let newest = read_audit(state.path(), 1).unwrap();
    assert_eq!(newest.len(), 1);
    assert_eq!(newest[0].decision, AuditDecision::Admitted);
}

#[test]
fn an_allowed_folder_later_replaced_by_a_symlink_admits_nothing() {
    let state = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("api");
    let elsewhere = root.path().join("elsewhere");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(elsewhere.join("inner")).unwrap();

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(grant(&project, TrustTier::Folders)).unwrap();
    fs::remove_dir(&project).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &project).unwrap();

    assert_eq!(
        book.admit(PEER, PeerAgent::Claude, &elsewhere.join("inner"), NOW),
        Admission::Refuse(RefuseReason::FolderNotAllowed)
    );
}

#[test]
fn set_stores_the_resolved_folder_and_refuses_missing_folders_and_home_ancestors() {
    let state = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("api");
    fs::create_dir_all(&project).unwrap();
    std::os::unix::fs::symlink(&project, root.path().join("link")).unwrap();

    let mut book = PeerTrustBook::load(state.path()).unwrap();
    book.set(grant(&root.path().join("link"), TrustTier::Folders)).unwrap();
    assert_eq!(book.get(PEER).unwrap().folders, vec![fs::canonicalize(&project).unwrap()]);

    assert!(book.set(grant(&root.path().join("missing"), TrustTier::Folders)).is_err());
    if let Some(parent) = std::env::var_os("HOME").and_then(|home| {
        fs::canonicalize(home).ok().and_then(|home| home.parent().map(Path::to_path_buf))
    }) {
        assert!(book.set(grant(&parent, TrustTier::Folders)).is_err(), "{}", parent.display());
    }
}

#[test]
fn a_symlinked_trust_file_is_refused() {
    let state = tempfile::tempdir().unwrap();
    let real = state.path().join("real.json");
    fs::write(&real, r#"{"version":1,"peers":[]}"#).unwrap();
    fs::set_permissions(&real, fs::Permissions::from_mode(0o600)).unwrap();
    std::os::unix::fs::symlink(&real, state.path().join("peer-trust.json")).unwrap();

    assert!(PeerTrustBook::load(state.path()).is_err());
}

#[test]
fn an_oversized_request_is_still_logged_truncated() {
    let state = tempfile::tempdir().unwrap();
    let long = Path::new("/").join("x".repeat(64 * 1024));

    append_audit(
        state.path(),
        &entry(NOW, &long, AuditDecision::Refused(RefuseReason::FolderNotAllowed)),
    )
    .unwrap();

    let entries = read_audit(state.path(), 10).unwrap();
    assert_eq!(entries.len(), 1);
    assert!(entries[0].truncated);
    assert_eq!(entries[0].decision, AuditDecision::Refused(RefuseReason::FolderNotAllowed));
}

#[test]
fn reading_the_audit_log_skips_corrupt_and_oversized_lines() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    append_audit(state.path(), &entry(NOW, project.path(), AuditDecision::Admitted)).unwrap();
    let path = state.path().join("peer-audit.jsonl");
    let mut garbage = fs::read(&path).unwrap();
    garbage.extend_from_slice(b"not json\n");
    garbage.extend(std::iter::repeat_n(b'x', 1024 * 1024));
    garbage.push(b'\n');
    fs::write(&path, garbage).unwrap();
    append_audit(state.path(), &entry(NOW + 1, project.path(), AuditDecision::Asked)).unwrap();

    let entries = read_audit(state.path(), 1).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].decision, AuditDecision::Asked);
    assert_eq!(read_audit(state.path(), 10).unwrap().len(), 2);
}

#[test]
fn appending_to_an_audit_log_readable_by_others_is_refused() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    let path = state.path().join("peer-audit.jsonl");
    fs::write(&path, b"").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

    assert!(
        append_audit(state.path(), &entry(NOW, project.path(), AuditDecision::Admitted)).is_err()
    );
}

#[test]
fn update_loads_changes_and_saves_under_a_lock() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();

    PeerTrustBook::update(state.path(), |book| book.set(grant(project.path(), TrustTier::Ask)))
        .unwrap();

    assert_eq!(PeerTrustBook::load(state.path()).unwrap().peers().len(), 1);
}
