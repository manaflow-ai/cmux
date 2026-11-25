use super::*;

const CLONE: &str = "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux";
const INSTALLED: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";

fn signed(path: &Path) -> Option<Identity> {
    Some(Identity {
        team: "ABCDEFGHIJ".into(),
        identifier: if path.file_name()? == "acpmux" {
            "acpmux"
        } else {
            "com.cmuxterm.app.nightly"
        }
        .into(),
    })
}

#[test]
fn sign_clone_matching_valid_signatures_resolve_to_installed_executable() {
    assert_eq!(resolve(Path::new(CLONE), signed), Some(PathBuf::from(INSTALLED)));
}

#[test]
fn sign_clone_missing_or_mismatching_signature_at_every_level_is_refused() {
    let paths = [
        "/Applications/cmux NIGHTLY.app",
        "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle",
        INSTALLED,
        CLONE,
    ];
    for target in paths {
        assert_eq!(
            resolve(Path::new(CLONE), |path| if path == Path::new(target) {
                None
            } else {
                signed(path)
            }),
            None,
            "missing/invalid signature: {target}"
        );
        for change_team in [false, true] {
            assert_eq!(
                resolve(Path::new(CLONE), |path| {
                    let mut identity = signed(path)?;
                    if path == Path::new(target) {
                        if change_team {
                            identity.team = "OTHERTEAM1".into();
                        } else {
                            identity.identifier = "other.app".into();
                        }
                    }
                    Some(identity)
                }),
                None,
                "mismatching signature: {target}"
            );
        }
    }
}

#[test]
fn sign_clone_plain_temp_runner_and_unrelated_shapes_never_read_signatures() {
    for path in [
        "/tmp/acpmux",
        "/tmp/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
        "/tmp/code_sign_clone.fake/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
        "/runner/actions-runner-1/_work/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.a/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
        "/tmp/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.a/cmux NIGHTLY.app.bundle/Contents/../acpmux",
    ] {
        assert_eq!(resolve(Path::new(path), |_| panic!("untrusted shape: {path}")), None);
    }
}
