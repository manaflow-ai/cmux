use std::collections::BTreeMap;

#[test]
fn a_remote_launch_probe_gets_no_local_overlay() {
    let overlay = |own: &BTreeMap<String, String>| {
        let mut env = own.clone();
        env.insert("VAULT_SECRET".into(), "local".into());
        env
    };
    let remote = BTreeMap::from([
        (crate::agent::REMOTE_ENV_POLICY_KEY.to_owned(), "1".to_owned()),
        ("OWN".to_owned(), "x".to_owned()),
    ]);
    let base = || {
        BTreeMap::from([
            ("HOME".to_owned(), "/home/u".to_owned()),
            ("SHELL".to_owned(), "/bin/zsh".to_owned()),
            ("OWN".to_owned(), "base".to_owned()),
        ])
    };
    let env = super::probe_env(&remote, base, overlay);
    assert_eq!(
        env,
        BTreeMap::from([
            ("HOME".to_owned(), "/home/u".to_owned()),
            ("OWN".to_owned(), "x".to_owned()),
            ("SHELL".to_owned(), "/bin/zsh".to_owned()),
        ]),
        "the fixed remote base (so ~/.gitconfig is seen), the launch's own env over it"
    );
    let local = BTreeMap::from([("OWN".to_owned(), "x".to_owned())]);
    let env = super::probe_env(&local, base, overlay);
    assert!(env.contains_key("VAULT_SECRET"));
    assert!(!env.contains_key("SHELL"), "a local launch takes its env from `local`");

    // The real remote base carries HOME when the daemon has one.
    if std::env::var_os("HOME").is_some() {
        assert!(super::remote_base().contains_key("HOME"));
    }
}
