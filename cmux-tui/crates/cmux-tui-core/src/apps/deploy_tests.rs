use super::*;

#[test]
fn targets_parse_and_refuse_option_like_hosts() {
    assert_eq!(
        Target::parse("self-hosted:ops@build-01.corp").unwrap(),
        Target::SelfHosted { host: "ops@build-01.corp".into() }
    );
    assert_eq!(
        Target::parse("cloud-vm:m_123").unwrap(),
        Target::CloudVm { machine: "m_123".into() }
    );
    for bad in
        ["self-hosted:-oProxyCommand=x", "self-hosted:a b", "cloud-vm:", "nowhere", "local:x"]
    {
        assert!(Target::parse(bad).is_err(), "{bad}");
    }
    assert_eq!(String::from(Target::parse("self-hosted:h").unwrap()), "self-hosted:h");
}

#[test]
fn server_spec_refuses_shell_characters() {
    let manifest = |image: &str, health: &str| json!({"deploy": {"server": {"kind": "container", "image": image, "port": 80, "health": health}}});
    let spec =
        ServerSpec::from_manifest(&manifest("docker.io/traefik/whoami:v1.10", "/health")).unwrap();
    assert_eq!(spec.port, 80);
    assert!(ServerSpec::from_manifest(&manifest("busybox; rm -rf /", "/health")).is_err());
    assert!(ServerSpec::from_manifest(&manifest("busybox", "/$(id)")).is_err());
}

#[test]
fn the_runner_binds_privately_and_prints_the_url() {
    let spec = ServerSpec {
        image: "docker.io/traefik/whoami:v1.10".into(),
        port: 80,
        health: "/health".into(),
    };
    let script = deploy_script("manaflow-ai/hello-deploy", &spec);
    assert!(script.contains("--name cmux-app-manaflow_ai.hello_deploy"), "{script}");
    assert!(script.contains("-p \"$bind::80\""), "never every interface: {script}");
    assert!(script.contains("tailscale ip -4"), "{script}");
    assert!(
        script.contains("sudo -n docker info"),
        "a closed docker group falls back to sudo -n: {script}"
    );
    assert_eq!(
        parse_url("noise\ncmux-deploy-url=http://100.64.0.9:49153/\n"),
        Some("http://100.64.0.9:49153/".into())
    );
    assert_eq!(parse_url("nothing"), None);
    assert!(
        stop_script("manaflow-ai/hello-deploy").contains("rm -f cmux-app-manaflow_ai.hello_deploy")
    );
}

#[test]
fn team_vm_has_no_runner_yet() {
    assert!(shell_for(&Target::TeamVm { team: "t".into() }).is_err());
    assert!(shell_for(&Target::SelfHosted { host: "h".into() }).is_ok());
}
