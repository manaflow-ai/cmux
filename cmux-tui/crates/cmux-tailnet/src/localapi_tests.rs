use super::LocalApi;

const CHILD: &str = "CMUX_TAILNET_LOCALAPI_NO_ROOTS_CHILD";

/// A host with no CA store (a bare container, some Macs and VMs) still gets a LocalAPI
/// client: it is plain HTTP on loopback. The check runs in a child process so the empty
/// `SSL_CERT_FILE` / `SSL_CERT_DIR` never reach another test.
#[test]
fn the_client_builds_without_any_system_roots() {
    if std::env::var_os(CHILD).is_some() {
        if let Err(error) = LocalApi::new("127.0.0.1:1", "credential") {
            panic!("{}", error.0);
        }
        return;
    }
    let empty = std::env::temp_dir().join(format!("cmux-tailnet-no-roots-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "localapi::tests::the_client_builds_without_any_system_roots"])
        .env(CHILD, "1")
        .env("SSL_CERT_FILE", empty.join("none.pem"))
        .env("SSL_CERT_DIR", &empty)
        .output()
        .unwrap();
    let _ = std::fs::remove_dir(&empty);
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
