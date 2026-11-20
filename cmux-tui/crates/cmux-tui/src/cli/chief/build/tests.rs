use super::*;

const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
const JOB: &str = "0123456789abcdef01234567";

fn request(dir: &Path) -> Request {
    Request {
        identity: Identity {
            commit: COMMIT.into(),
            tag: "chief-slice".into(),
            workspace: "chief-test".into(),
        },
        receipt: dir.join("build.json"),
        timeout: 60,
    }
}

fn accepted(request: &Request) {
    std::fs::write(
        &request.receipt,
        json!({
            "id": JOB, "kind": "cmux", "ref": request.identity.commit,
            "workspace": request.identity.workspace,
        })
        .to_string(),
    )
    .unwrap();
}

#[test]
fn chief_build_gate_fails_closed() {
    for value in [
        Value::Null,
        json!({}),
        json!({"key": GATE}),
        json!({"path": ["labs", "previewFeatures"], "value": false}),
        json!({"key": GATE, "value": false}),
        json!({"key": GATE, "value": "true"}),
        json!({"key": "other.setting", "value": true}),
    ] {
        assert!(!enabled(&value), "{value}");
    }
    assert!(enabled(&json!({
        "path": ["labs", "previewFeatures"],
        "exists": true,
        "value": true
    })));
}

#[test]
fn chief_build_requires_exact_identity_and_bounded_wait() {
    let args = [
        "--ref",
        COMMIT,
        "--tag",
        "chief-slice",
        "--workspace",
        "chief-test",
        "--receipt",
        "build.json",
    ]
    .map(str::to_owned)
    .to_vec();
    assert_eq!(Request::parse(&args).unwrap().timeout, 600);
    for (flag, value) in [
        ("--timeout", "0"),
        ("--timeout", "86401"),
        ("--timeout", "forever"),
        ("--production", "true"),
    ] {
        let mut invalid = args.clone();
        invalid.extend([flag.into(), value.into()]);
        assert!(Request::parse(&invalid).is_err());
    }
    let mut invalid = args.clone();
    invalid[1] = "main".into();
    assert!(Request::parse(&invalid).is_err());
    let mut invalid = args;
    invalid.extend(["--tag".into(), "another-tag".into()]);
    assert!(Request::parse(&invalid).is_err());
}

#[test]
fn chief_build_timeout_resumes_same_job_without_another_submission() {
    let dir = tempfile::tempdir().unwrap();
    let request = request(dir.path());
    let mut calls = Vec::new();
    let code = execute(&request, |args, _| {
        calls.push(args.to_vec());
        if args[0] == "build" {
            accepted(&request);
            Ok(0)
        } else {
            Ok(2)
        }
    })
    .unwrap();
    assert_eq!(code, 2);
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0], request.submit_args());
    assert_eq!(calls[1], request.wait_args(JOB));
    calls.clear();
    assert_eq!(
        execute(&request, |args, _| {
            calls.push(args.to_vec());
            Ok(0)
        })
        .unwrap(),
        0
    );
    assert_eq!(calls, vec![request.wait_args(JOB)]);
}

#[test]
fn chief_build_lost_submit_response_never_posts_again() {
    let dir = tempfile::tempdir().unwrap();
    let request = request(dir.path());
    assert_eq!(execute(&request, |_, _| Ok(3)).unwrap(), 3);
    assert!(execute(&request, |_, _| panic!("ambiguous submission must not retry")).is_err());
    // Once the accepted receipt is recovered, the original invocation can wait.
    accepted(&request);
    assert_eq!(
        execute(&request, |args, _| {
            assert_eq!(args[0], "wait");
            Ok(0)
        })
        .unwrap(),
        0
    );
}

#[test]
fn chief_build_pending_or_foreign_receipt_never_submits() {
    for pending in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let request = request(dir.path());
        let path =
            if pending { suffix(&request.receipt, ".pending") } else { request.receipt.clone() };
        std::fs::write(path, "{}").unwrap();
        assert!(
            execute(&request, |_, _| panic!("existing receipt must not be overwritten")).is_err()
        );
    }
}

#[test]
fn chief_build_changed_identity_and_bad_receipt_never_wait() {
    let dir = tempfile::tempdir().unwrap();
    let mut request = request(dir.path());
    assert!(reserve(&request).unwrap());
    accepted(&request);
    request.identity.tag = "different".into();
    assert!(execute(&request, |_, _| panic!("identity mismatch")).is_err());
    request.identity.tag = "chief-slice".into();
    for receipt in [
        json!({}),
        json!({"id": JOB, "kind": "cmux", "ref": "other", "workspace": "chief-test"}),
        json!({"id": "--help", "kind": "cmux", "ref": COMMIT, "workspace": "chief-test"}),
    ] {
        std::fs::write(&request.receipt, receipt.to_string()).unwrap();
        assert!(execute(&request, |_, _| panic!("invalid accepted receipt")).is_err());
    }
}

#[test]
fn chief_build_concurrent_callers_have_one_reservation() {
    let dir = tempfile::tempdir().unwrap();
    let request = request(dir.path());
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let reserve_once = || {
            barrier.wait();
            reserve(&request).is_ok_and(|fresh| fresh)
        };
        let first = scope.spawn(reserve_once);
        let second = scope.spawn(reserve_once);
        assert_ne!(first.join().unwrap(), second.join().unwrap());
    });
}

#[test]
fn chief_build_fleet_failure_keeps_the_original_job() {
    let dir = tempfile::tempdir().unwrap();
    let request = request(dir.path());
    assert!(reserve(&request).unwrap());
    accepted(&request);
    let mut calls = 0;
    assert_eq!(
        execute(&request, |args, limit| {
            calls += 1;
            assert_eq!(args, request.wait_args(JOB));
            assert_eq!(limit, Duration::from_secs(150));
            Ok(1)
        })
        .unwrap(),
        1
    );
    assert_eq!(calls, 1);
    assert_eq!(job_id(&request).unwrap(), JOB);
}

#[test]
fn chief_build_corrupt_reservation_never_submits() {
    let dir = tempfile::tempdir().unwrap();
    let request = request(dir.path());
    std::fs::write(suffix(&request.receipt, ".chief-request.json"), "{\"commit\":").unwrap();
    assert!(execute(&request, |_, _| panic!("partial reservation must not retry")).is_err());
}
