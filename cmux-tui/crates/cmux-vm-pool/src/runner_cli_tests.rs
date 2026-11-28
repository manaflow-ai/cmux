use super::{Args, freestyle_client, jit_client, wait_news};

fn env_of(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
    move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
}

#[test]
fn wait_news_names_each_change_once() {
    assert_eq!(wait_news(false, false, true, false), Some("online, waiting for a job"));
    assert_eq!(wait_news(true, false, true, true), Some("took a job"));
    assert_eq!(wait_news(false, false, true, true), Some("took a job"));
    assert_eq!(wait_news(true, true, true, false), Some("job finished"));
    assert_eq!(wait_news(true, false, true, false), None);
    assert_eq!(wait_news(true, true, true, true), None);
    assert_eq!(wait_news(false, false, false, false), None);
}

#[test]
fn a_named_freestyle_api_url_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let env = env_of(&[
        ("FREESTYLE_API_KEY", "key"),
        ("FREESTYLE_API_URL", "https://runner-freestyle-named-test.org"),
    ]);
    assert!(freestyle_client(&env).is_ok());
    assert!(cmux_egress::check("runner-freestyle-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-runner-freestyle-test.org", "test").is_err());
}

#[test]
fn a_named_github_api_url_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let env = env_of(&[
        ("GITHUB_TOKEN", "token"),
        ("GITHUB_API_URL", "https://runner-github-named-test.org/api/v3"),
    ]);
    assert!(jit_client(&Args::default(), &env).is_ok());
    assert!(cmux_egress::check("runner-github-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-runner-github-test.org", "test").is_err());
}
