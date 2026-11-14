use super::*;

fn policy() -> Policy {
    Policy::new(vec![
        Secret::new(
            "GITHUB_TOKEN",
            Zeroizing::new("ghp_real".into()),
            vec![
                HostPattern::parse("api.github.com").unwrap(),
                HostPattern::parse("github.com").unwrap(),
            ],
        ),
        Secret::new(
            "WILD",
            Zeroizing::new("wild-real".into()),
            vec![HostPattern::parse("*.example.com:8443").unwrap()],
        ),
        Secret::new("NOWHERE", Zeroizing::new("nowhere-real".into()), vec![]),
    ])
}

#[test]
fn host_patterns_follow_the_contract() {
    for ok in ["api.github.com", "*.example.com", "a.b:8443", "x1.io", "xn--bcher-kva.example"] {
        assert!(HostPattern::parse(ok).is_some(), "{ok}");
    }
    for bad in [
        "",
        "localhost",
        "API.github.com",
        "https://api.github.com",
        "api.github.com/",
        "api.github.com.",
        "1.2.3.4",
        "*.com",
        "**.example.com",
        "a.*.example.com",
        "user@api.github.com",
        "api.github.com:0",
        "api.github.com:65536",
        "api.github.com:080",
        "api.github.com:",
        "-a.example.com",
        "api.example.com-",
        "[::1]",
    ] {
        assert!(HostPattern::parse(bad).is_none(), "{bad}");
    }
    assert_eq!(HostPattern::parse("*.example.com:8443").unwrap().to_string(), "*.example.com:8443");
    assert_eq!(HostPattern::parse("api.github.com:443").unwrap().to_string(), "api.github.com");
}

#[test]
fn wildcard_matches_subdomains_only_and_ports_are_exact() {
    let p = HostPattern::parse("*.example.com").unwrap();
    assert!(p.matches("a.example.com", 443));
    assert!(p.matches("a.b.example.com", 443));
    assert!(!p.matches("example.com", 443));
    assert!(!p.matches("badexample.com", 443));
    assert!(!p.matches("a.example.com", 8443));
    assert!(!HostPattern::parse("github.com").unwrap().matches("api.github.com", 443));
}

#[test]
fn a_placeholder_is_replaced_only_toward_a_host_its_secret_allows() {
    let p = policy();
    let (out, names) =
        p.substitute_header("Bearer cmux-secret://GITHUB_TOKEN", "api.github.com", 443).unwrap();
    assert_eq!(out.as_str(), "Bearer ghp_real");
    assert_eq!(names, ["GITHUB_TOKEN"]);
    // Another host, another port, or a secret with no hosts: untouched.
    assert!(p.substitute_header("Bearer cmux-secret://GITHUB_TOKEN", "evil.test", 443).is_none());
    assert!(
        p.substitute_header("Bearer cmux-secret://GITHUB_TOKEN", "api.github.com", 8443).is_none()
    );
    assert!(p.substitute_header("cmux-secret://NOWHERE", "api.github.com", 443).is_none());
    // A host one secret allows does not open another secret to it.
    let (out, names) = p
        .substitute_header("cmux-secret://WILD cmux-secret://GITHUB_TOKEN", "a.example.com", 8443)
        .unwrap();
    assert_eq!(out.as_str(), "wild-real cmux-secret://GITHUB_TOKEN");
    assert_eq!(names, ["WILD"]);
}

#[test]
fn names_end_at_the_first_non_name_byte_and_unknown_names_stay() {
    let p = policy();
    let (out, names) = p
            .substitute_text(
                "a=cmux-secret://GITHUB_TOKEN;b=cmux-secret://GITHUB_TOKENX;c=cmux-secret://;d=cmux-secret://GITHUB_TOKEN",
                "github.com",
                443,
            )
            .unwrap();
    assert_eq!(
        out.as_str(),
        "a=ghp_real;b=cmux-secret://GITHUB_TOKENX;c=cmux-secret://;d=ghp_real"
    );
    assert_eq!(names, ["GITHUB_TOKEN"]);
}

#[test]
fn basic_credentials_are_rewritten_inside_the_encoding() {
    let engine = base64::engine::general_purpose::STANDARD;
    let header = format!("Basic {}", engine.encode("x-access-token:cmux-secret://GITHUB_TOKEN"));
    let (out, names) = policy().substitute_header(&header, "github.com", 443).unwrap();
    assert_eq!(out.as_str(), format!("Basic {}", engine.encode("x-access-token:ghp_real")));
    assert_eq!(names, ["GITHUB_TOKEN"]);
    assert!(policy().substitute_header(&header, "evil.test", 443).is_none());
}

#[test]
fn debug_never_shows_a_value() {
    let text = format!("{:?}", policy());
    assert!(text.contains("GITHUB_TOKEN"));
    for value in ["ghp_real", "wild-real", "nowhere-real"] {
        assert!(!text.contains(value), "{text}");
    }
}
