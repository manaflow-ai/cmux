use super::*;

fn request(phase: &str) -> Request {
    Request {
        phase: phase.into(),
        preflight: false,
        lease_id: "0123456789abcdef01234567".into(),
        bundle_id: "test.capture".into(),
        configured_bundle_id: Some("test.capture".into()),
        home: "/private/capture".into(),
        storage: StorageNames {
            keychain_service: "current.auth".into(),
            credentials_subpath: vec!["current".into()],
            defaults_key_suffix: None,
        },
        legacy: Some(LegacyStore {
            keychain_service: "legacy.auth".into(),
            credentials_subpath: vec!["legacy".into()],
        }),
        stack_project_id: "staging".into(),
        facts: Vec::new(),
    }
}
fn fact(status: &str) -> Fact {
    Fact { status: status.into(), text: None }
}
fn owned(r: &Request) -> Fact {
    Fact { status: "present".into(), text: Some(format!("{}\n{}", r.lease_id, r.bundle_id)) }
}
fn code(reply: Reply) -> String {
    reply.result.expect("terminal refusal").code
}

#[test]
fn capture_auth_rejects_invalid_binding_before_any_platform_call() {
    let mut r = request("cleanup");
    r.lease_id = "wrong".into();
    assert_eq!(code(next(&r)), "invalid_lease");
    r = request("cleanup");
    r.bundle_id = "another".into();
    assert_eq!(code(next(&r)), "bundle_mismatch");
    r = request("cleanup");
    r.storage.credentials_subpath = vec!["..".into()];
    assert_eq!(code(next(&r)), "invalid_lease");
}

#[test]
fn capture_auth_preflight_never_mutates_or_proves_stores_absent() {
    let mut r = request("cleanup");
    r.preflight = true;
    assert!(matches!(next(&r).action, Some(Action::ReadMarker { .. })));
    r.facts.push(Fact { status: "present".into(), text: Some("other-lease".into()) });
    assert_eq!(code(next(&r)), "ownership_mismatch");
    r.facts = vec![owned(&r)];
    let done = next(&r);
    assert!(done.preflight_complete && done.action.is_none() && done.result.is_none());
    r.preflight = false;
    r.facts = vec![fact("absent")];
    assert_eq!(code(next(&r)), "ownership_missing");
}

#[test]
fn capture_auth_prepare_refuses_existing_store_without_keychain_or_write() {
    let mut r = request("prepare");
    r.facts = vec![fact("absent"), fact("present")];
    assert_eq!(code(next(&r)), "file_store_present");
    r.facts = vec![fact("error")];
    assert_eq!(code(next(&r)), "marker_present");
}

fn pristine(r: &mut Request, actions: &mut Vec<Action>) -> Proof {
    for _ in 0..64 {
        let reply = next(r);
        if let Some(proof) = reply.result {
            return proof;
        }
        let action = reply.action.expect("next platform call");
        let result = match &action {
            Action::ReadMarker { .. }
                if actions.iter().any(|a| matches!(a, Action::WriteMarker { .. })) =>
            {
                owned(r)
            }
            Action::ReadMarker { .. } if r.phase == "cleanup" && actions.is_empty() => owned(r),
            Action::ReadMarker { .. } | Action::ProbeFile { .. } | Action::ReadKeychain { .. } => {
                fact("absent")
            }
            Action::WriteMarker { .. } | Action::RemoveFile { .. } => fact("ok"),
            _ => panic!("pristine stores need no key deletion"),
        };
        actions.push(action);
        r.facts.push(result);
    }
    panic!("capture reducer did not terminate");
}

#[test]
fn capture_auth_covers_current_namespaced_and_stack_legacy_exactly() {
    let mut actions = Vec::new();
    let proof = pristine(&mut request("prepare"), &mut actions);
    assert!(proof.ok && proof.verified_absent && proof.keychain_absent && proof.files_absent);
    let items: Vec<_> = actions
        .iter()
        .filter_map(|a| match a {
            Action::ReadKeychain { service, account, protected } => {
                Some((service.as_str(), account.as_str(), *protected))
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        items,
        vec![
            ("current.auth", "cmux-auth-access-token", true),
            ("current.auth", "cmux-auth-refresh-token", true),
            ("legacy.auth", "cmux-auth-access-token", true),
            ("legacy.auth", "cmux-auth-refresh-token", true),
            ("", "stack-auth-access-staging", false),
            ("", "stack-auth-refresh-staging", false),
        ]
    );
    assert!(
        actions.contains(&Action::ProbeFile {
            path: "/private/capture/current/credentials.json".into()
        })
    );
    assert!(
        actions.contains(&Action::ProbeFile {
            path: "/private/capture/legacy/credentials.json".into()
        })
    );
}

#[test]
fn capture_auth_cleanup_requires_every_readback_before_removing_lease() {
    let mut r = request("cleanup");
    let mut actions = Vec::new();
    let proof = pristine(&mut r, &mut actions);
    assert!(proof.ok);
    assert!(matches!(actions.last(), Some(Action::ReadMarker { .. })));
    // Every failed platform call must refuse completion, including the final
    // absence readback and the second pass over previously absent key items.
    for index in 0..r.facts.len() {
        let mut broken = r.clone();
        broken.facts.truncate(index + 1);
        broken.facts[index] = fact("error");
        let reply = next(&broken);
        assert!(!reply.result.expect("failure must stop immediately").ok, "action {index}");
    }
}

#[test]
fn capture_auth_present_key_is_deleted_then_read_back_before_any_file_delete() {
    let mut r = request("cleanup");
    r.facts = vec![owned(&r), fact("present")];
    assert!(matches!(next(&r).action, Some(Action::RemoveKeychain { .. })));
    r.facts.push(fact("ok"));
    assert!(matches!(next(&r).action, Some(Action::ReadKeychain { .. })));
    r.facts.push(fact("present"));
    assert_eq!(code(next(&r)), "keychain_read_failed");
}
