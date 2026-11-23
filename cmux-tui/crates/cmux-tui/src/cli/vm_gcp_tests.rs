use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;

use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn takes_the_provider_out_and_keeps_every_other_word() {
    assert_eq!(take_provider(&words("--name a")).unwrap(), (None, words("--name a")));
    assert_eq!(
        take_provider(&words("--provider freestyle --size small")).unwrap(),
        (Some(Provider::Freestyle), words("--size small"))
    );
    assert_eq!(
        take_provider(&words("--name a --provider=gcp")).unwrap(),
        (Some(Provider::Gcp), words("--name a"))
    );
    // After `--` nothing is an option of ours.
    assert_eq!(
        take_provider(&words("-- --provider gcp")).unwrap(),
        (None, words("-- --provider gcp"))
    );
    assert!(take_provider(&words("--provider aws")).unwrap_err().0.contains("not aws"));
    assert!(take_provider(&words("--provider")).is_err());
    assert!(take_provider(&words("--provider gcp --provider freestyle")).is_err());
}

#[test]
fn a_gcp_create_takes_only_its_own_options() {
    let command =
        parse(&words("--name ci-1 --size large --team team_x --cloud-api=https://api.test"))
            .unwrap();
    assert_eq!(command.name.as_deref(), Some("ci-1"));
    assert_eq!(command.size.as_deref(), Some("large"));
    assert_eq!(command.team.as_deref(), Some("team_x"));
    assert_eq!(command.api.as_deref(), Some("https://api.test"));
    for refused in ["--persistent", "--repo o/n", "--snapshot snap_1", "--wait", "--image i"] {
        let error = parse(&words(refused)).unwrap_err().0;
        assert!(error.contains("not taken with --provider gcp"), "{refused}: {error}");
    }
    assert!(parse(&words("--size huge")).is_err());
    assert!(parse(&words("--name")).is_err());
}

#[test]
fn the_params_ask_for_a_fleet_machine_on_gcp() {
    assert_eq!(
        params(&GcpNew::default()),
        json!({ "size": { "cpu": 4, "memory_mb": 16384, "disk_mb": 65536 }, "kind": "fleet", "provider": "gcp" })
    );
    let sized =
        GcpNew { name: Some(" ci-1 ".into()), size: Some("small".into()), ..GcpNew::default() };
    assert_eq!(
        params(&sized),
        json!({ "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 65536 }, "kind": "fleet", "provider": "gcp", "name": "ci-1" })
    );
}

/// One request to a local fake cmux API: its request line, headers and body, answered with `answer`.
fn serve_once(answer: &'static str) -> (String, std::thread::JoinHandle<(String, String)>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut head = String::new();
        let mut length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap();
            }
            if line == "\r\n" {
                break;
            }
            head.push_str(&line);
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}",
            answer.len()
        )
        .unwrap();
        (head, String::from_utf8(body).unwrap())
    });
    (origin, handle)
}

fn target(api: String) -> super::super::cloud_team_keys::Target {
    super::super::cloud_team_keys::Target {
        api,
        credential: "test-credential".into(),
        team: "team_x".into(),
    }
}

#[test]
fn sends_the_fleet_create_with_its_key_team_and_credential() {
    let (origin, server) = serve_once(
        r#"{"ok":true,"op":"cloud.machine.create","value":{"machine":{"id":"vm_1","transport":"gce"}},"transaction":"t","idempotency_key":"ck_k1234567","replayed":true,"stream":"s","sequence":1}"#,
    );
    let command = GcpNew { name: Some("ci-1".into()), ..GcpNew::default() };
    let value = run(&command, &target(origin), "ck_k1234567").unwrap();
    assert_eq!(value["machine"]["id"], "vm_1");
    assert_eq!(value["replayed"], true);
    let (head, body) = server.join().unwrap();
    let head = head.to_ascii_lowercase();
    assert!(head.starts_with("post /v1/ops "), "{head}");
    assert!(head.contains("authorization: bearer test-credential"), "{head}");
    assert!(head.contains("team_x"), "{head}");
    let body: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(body["op"], "cloud.machine.create");
    assert_eq!(body["idempotency_key"], "ck_k1234567");
    assert_eq!(body["params"]["kind"], "fleet");
    assert_eq!(body["params"]["provider"], "gcp");
    assert_eq!(body["params"]["name"], "ci-1");
}

#[test]
fn a_team_off_the_gce_list_keeps_the_refusal_code() {
    let (origin, server) = serve_once(
        r#"{"ok":false,"op":"cloud.machine.create","error":{"code":"cloud.provider.unavailable","message":"GCP machines are our own capacity: this team is not on CLOUD_GCE_TEAMS","retryable":false},"transaction":"t","idempotency_key":"ck_k1234567","replayed":false,"stream":"s","sequence":1}"#,
    );
    let error = run(&GcpNew::default(), &target(origin), "ck_k1234567").unwrap_err();
    assert_eq!(error.code.as_deref(), Some("cloud.provider.unavailable"));
    server.join().unwrap();
}
