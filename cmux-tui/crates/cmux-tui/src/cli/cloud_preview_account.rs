//! Private app bridge: credentials arrive on stdin, never argv or diagnostics.
//! Both the native Share action and the guest use cmux-host's preview flow.

use std::io::{Read as _, Write as _};
use std::time::{Duration, Instant};

use cmux_host::cloud::preview::{PreviewAsk, answer};
use cmux_host::cloud::sender::Answer;
use serde::Deserialize;
use serde_json::{Value, json};

const LIMIT: u64 = 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    api: String,
    credential: String,
    team: String,
    machine: String,
    ask: PreviewAsk,
    app_version: Option<String>,
}

fn decode(bytes: &[u8]) -> Result<Request, ()> {
    let mut request: Request = serde_json::from_slice(bytes).map_err(|_| ())?;
    request.api = super::cloud_client_session::secure_origin(&request.api).map_err(|_| ())?;
    if !super::cloud_client_session::valid_machine(&request.machine)
        || request.credential.is_empty()
        || request.team.is_empty()
        || request.team.len() > 128
        || !request.team.bytes().all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
        || request.ask.validate().is_err()
    {
        return Err(());
    }
    Ok(request)
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    if !args.starts_with(&["cloud".to_owned(), "preview-account".to_owned()]) {
        return None;
    }
    let mut input = Vec::new();
    let result = if args.len() != 2
        || std::io::stdin().take(LIMIT + 1).read_to_end(&mut input).is_err()
        || input.len() > LIMIT as usize
    {
        None
    } else {
        decode(&input).ok().and_then(|request| run(&request).ok())
    };
    let value = result.unwrap_or_else(|| {
        json!({"ok":false,"error":{
            "code":"preview.account_unavailable",
            "message":"The account preview request could not be completed. Run cmux cloud preview url with the machine target to check its connection."
        }})
    });
    let code = if value["ok"] == true { 0 } else { 1 };
    let _ = writeln!(std::io::stdout().lock(), "{value}");
    Some(code)
}

fn run(request: &Request) -> Result<Value, ()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime =
        tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|_| ())?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| ())?;
    // Aggregate budget across refresh and mutation, inside the app's 35s subprocess deadline.
    let until = Instant::now() + Duration::from_secs(30);
    Ok(answer(&request.ask, &request.machine, &request.team, |method, path, body| {
        let Some(remaining) = until.checked_duration_since(Instant::now()) else {
            return Answer::Transport;
        };
        let Ok(method) = reqwest::Method::from_bytes(method.as_bytes()) else {
            return Answer::Transport;
        };
        let task = async {
            let mut response = client
                .request(method, format!("{}{path}", request.api))
                .bearer_auth(&request.credential)
                .header("x-cmux-team", &request.team)
                .header("X-Cmux-Client", "cmux-mac")
                .header("X-Cmux-App-Version", request.app_version.as_deref().unwrap_or("cmux-next"))
                .json(body)
                .send()
                .await
                .map_err(|_| ())?;
            let status = response.status().as_u16();
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
                if bytes.len().saturating_add(chunk.len()) > LIMIT as usize {
                    return Err(());
                }
                bytes.extend_from_slice(&chunk);
            }
            let body = serde_json::from_slice(&bytes).map_err(|_| ())?;
            Ok::<_, ()>(Answer::Http { status, body })
        };
        runtime
            .block_on(async { tokio::time::timeout(remaining, task).await })
            .ok()
            .and_then(Result::ok)
            .unwrap_or(Answer::Transport)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Value {
        json!({"api":"https://platform.standin.invalid", "credential":"private-bearer", "team":"team_one",
            "machine":"vm_01234567890123456789", "ask":{"operation":"share","port":3000,"audience":"link"}})
    }

    #[test]
    fn preview_account_accepts_only_a_secure_origin_and_explicit_identity() {
        assert!(decode(request().to_string().as_bytes()).is_ok());
        for (key, value) in [
            ("api", "http://platform.standin.invalid"),
            ("api", "https://user:secret@platform.standin.invalid"),
            ("api", "https://platform.standin.invalid/path"),
            ("machine", "../other"),
            ("credential", ""),
            ("team", ""),
            ("team", "team/other"),
        ] {
            let mut bad = request();
            bad[key] = json!(value);
            assert!(decode(bad.to_string().as_bytes()).is_err(), "{key}");
        }
        let mut bad = request();
        bad["token_in_argv"] = json!(true);
        assert!(decode(bad.to_string().as_bytes()).is_err());
    }

    #[test]
    fn preview_account_transport_keeps_account_headers_and_returns_a_plain_address() {
        use std::io::{BufRead as _, BufReader};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut headers = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                headers.push_str(&line);
            }
            let lowered = headers.to_ascii_lowercase();
            assert!(
                headers.starts_with(
                    "POST /v1/cloud/machines/vm_01234567890123456789/previews/refresh "
                )
            );
            assert!(lowered.contains("authorization: bearer private-bearer\r\n"));
            assert!(lowered.contains("x-cmux-team: team_one\r\n"));
            assert!(lowered.contains("x-cmux-client: cmux-mac\r\n"));
            assert!(!lowered.contains("x-stack-refresh-token"));
            let body = json!({"machine":"vm_01234567890123456789","previews":[{
                "port":3000,"origin":"https://plain.preview.invalid", "url":"https://plain.preview.invalid/auth?token=owner-secret"
            }],"listening":[3000],"unavailable":[]}).to_string();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        });
        let mut input = request();
        input["api"] = json!(format!("http://{address}"));
        input["ask"] = json!({"operation":"list"});
        let reply = run(&decode(input.to_string().as_bytes()).unwrap()).unwrap();
        server.join().unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["value"]["previews"][0]["url"], "https://plain.preview.invalid");
        assert!(!reply.to_string().contains("owner-secret"));
        assert!(!reply.to_string().contains("private-bearer"));
    }
}
