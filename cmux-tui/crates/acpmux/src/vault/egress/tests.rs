use super::*;
use zeroize::Zeroizing;

fn given(name: &str, value: &str, proxy: Option<&[&str]>) -> Given {
    Given {
        name: name.to_owned(),
        value: Zeroizing::new(value.to_owned()),
        proxy: proxy.map(|h| h.iter().map(|s| (*s).to_owned()).collect()),
    }
}

fn running() -> Running {
    Running {
        port: 41234,
        node_ca: PathBuf::from("/h/vault-egress/node-extra-ca.pem"),
        bundle: Some(PathBuf::from("/h/vault-egress/ca-bundle.pem")),
    }
}

fn get<'a>(env: &'a [(String, String)], name: &str) -> Option<&'a str> {
    env.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

#[test]
fn proxy_entries_are_placeholders_and_env_entries_are_values() {
    let env = child_env_with(
        vec![
            given("GITHUB_TOKEN", "ghp_secret_value", Some(&["api.github.com"])),
            given("DATABASE_URL", "postgres://u:pw@db/x", None),
        ],
        Some(&running()),
        &|_| None,
    );
    assert_eq!(get(&env, "GITHUB_TOKEN"), Some("cmux-secret://GITHUB_TOKEN"));
    assert_eq!(get(&env, "DATABASE_URL"), Some("postgres://u:pw@db/x"));
    assert_eq!(get(&env, "HTTPS_PROXY"), Some("http://127.0.0.1:41234"));
    assert_eq!(get(&env, "https_proxy"), Some("http://127.0.0.1:41234"));
    assert_eq!(get(&env, "NO_PROXY"), Some("localhost,127.0.0.1,::1,.cmux.internal"));
    assert_eq!(get(&env, "NODE_EXTRA_CA_CERTS"), Some("/h/vault-egress/node-extra-ca.pem"));
    assert_eq!(get(&env, "SSL_CERT_FILE"), Some("/h/vault-egress/ca-bundle.pem"));
    assert!(!env.iter().any(|(_, v)| v.contains("ghp_secret_value")));
}

#[test]
fn no_proxy_entry_means_no_proxy_settings() {
    let env = child_env_with(vec![given("A", "a", None)], Some(&running()), &|_| None);
    assert_eq!(env, vec![("A".to_owned(), "a".to_owned())]);
}

#[test]
fn a_proxy_that_did_not_start_still_withholds_the_value() {
    let env = child_env_with(vec![given("T", "secret", Some(&["x.example.com"]))], None, &|_| None);
    assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
}

#[test]
fn an_existing_https_proxy_is_kept_and_the_value_still_withheld() {
    let inherited = |n: &str| (n == "HTTPS_PROXY").then(|| "http://corp:3128".to_owned());
    let env = child_env_with(
        vec![given("T", "secret", Some(&["x.example.com"]))],
        Some(&running()),
        &inherited,
    );
    assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
}

#[test]
fn no_proxy_keeps_what_the_launch_had() {
    assert_eq!(
        no_proxy(Some(" corp.lan, localhost ,".into())),
        "corp.lan,localhost,127.0.0.1,::1,.cmux.internal"
    );
}

#[test]
fn policy_holds_only_proxy_entries_with_their_valid_hosts() {
    let policy = policy_of(vec![
        given("T", "secret", Some(&["api.github.com", "not a host"])),
        given("E", "env-value", None),
    ]);
    assert_eq!(policy.secrets().len(), 1);
    assert_eq!(policy.secrets()[0].name(), "T");
    assert_eq!(policy.secrets()[0].hosts().len(), 1);
    assert!(policy.intercepts("api.github.com", 443));
}

#[test]
fn trust_files_extend_what_the_launch_trusted() {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().join("base.pem");
    std::fs::write(&base, "-----BEGIN CERTIFICATE-----\nBASE\n-----END CERTIFICATE-----").unwrap();
    let node = dir.path().join("node.pem");
    std::fs::write(&node, "-----BEGIN CERTIFICATE-----\nNODE\n-----END CERTIFICATE-----\n")
        .unwrap();
    let (b, n) = (base.display().to_string(), node.display().to_string());
    let inherited = move |name: &str| match name {
        "SSL_CERT_FILE" => Some(b.clone()),
        "NODE_EXTRA_CA_CERTS" => Some(n.clone()),
        _ => None,
    };
    let ca = "-----BEGIN CERTIFICATE-----\nOURS\n-----END CERTIFICATE-----\n";
    let out = dir.path().join("egress");
    let (node_ca, bundle) = write_trust(&out, ca, &inherited).unwrap();
    let node_text = std::fs::read_to_string(node_ca).unwrap();
    assert!(node_text.contains("NODE") && node_text.ends_with(ca));
    let bundle_text = std::fs::read_to_string(bundle.unwrap()).unwrap();
    assert!(
        bundle_text.starts_with("-----BEGIN CERTIFICATE-----\nBASE") && bundle_text.ends_with(ca)
    );
}
