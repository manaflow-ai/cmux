#![cfg(unix)]
//! Per-peer trust records and the audit log (multi-machine design, next PR 3).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use cmux_remote::peer_trust::{
    Admission, AuditDecision, PeerAgent, PeerTrust, PeerTrustBook, RefuseReason, TrustTier,
    append_audit, read_audit,
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
    assert_eq!(book.admit(PEER, PeerAgent::Claude, &nested, NOW), Admission::Admit);
    assert_eq!(
        book.admit(PEER, PeerAgent::Codex, &nested, NOW),
        Admission::Refuse(RefuseReason::AgentNotAllowed)
    );

    book.set(grant(project.path(), TrustTier::Ask)).unwrap();
    assert_eq!(book.admit(PEER, PeerAgent::Claude, &nested, NOW), Admission::Ask);

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

    for cwd in [project.join("escape"), sibling.clone(), project.join("missing")] {
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
    assert_eq!(reloaded.admit(PEER, PeerAgent::Claude, project.path(), NOW), Admission::Admit);

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

#[test]
fn the_audit_log_appends_owner_only_and_reads_the_newest_entries() {
    let state = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();

    for (offset, decision) in
        [AuditDecision::Refused(RefuseReason::NoGrant), AuditDecision::Admitted]
            .into_iter()
            .enumerate()
    {
        append_audit(
            state.path(),
            NOW + offset as u64,
            PEER,
            "machine.session.request",
            Some(PeerAgent::Claude),
            Some(project.path()),
            decision,
        )
        .unwrap();
    }

    let path = state.path().join("peer-audit.jsonl");
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let entries = read_audit(state.path(), 10).unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].decision, AuditDecision::Refused(RefuseReason::NoGrant));
    assert_eq!(entries[1].decision, AuditDecision::Admitted);
    assert_eq!(entries[1].at_unix, NOW + 1);
    let newest = read_audit(state.path(), 1).unwrap();
    assert_eq!(newest.len(), 1);
    assert_eq!(newest[0].decision, AuditDecision::Admitted);
}
