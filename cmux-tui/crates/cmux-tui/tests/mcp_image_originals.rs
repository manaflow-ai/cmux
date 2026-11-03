//! Complete images returned by a real upstream MCP process through `cmux_exec`.
#![cfg(unix)]

use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::process::{Command, Stdio};

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

const UPSTREAM: &str = r#"
import base64, json, sys
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    if method == 'initialize':
        result = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'originals', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'images', 'description': 'Return images', 'inputSchema': {'type': 'object'}}]}
    elif method == 'tools/call':
        args = request['params']['arguments']
        content = []
        for index in range(args['count']):
            raw = b'\x89PNG\r\n\x1a\n' + bytes([index % 251]) * (args['bytes'] - 8)
            data = base64.b64encode(raw).decode() if not args.get('invalid') else '!not-base64!'
            content.append({'type': 'image', 'data': data, 'mimeType': 'image/png'})
        result = {'content': content}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
"#;

fn expected(index: usize, size: usize) -> String {
    let mut digest = Sha256::new();
    digest.update(b"\x89PNG\r\n\x1a\n");
    let chunk = vec![u8::try_from(index % 251).unwrap(); 64 << 10];
    let mut remaining = size - 8;
    while remaining != 0 {
        let length = remaining.min(chunk.len());
        digest.update(chunk.get(..length).unwrap());
        remaining -= length;
    }
    format!("{:x}", digest.finalize())
}

fn hash(mut reader: impl std::io::Read) -> (usize, String) {
    let mut buffer = [0u8; 64 << 10];
    let mut digest = Sha256::new();
    let mut size = 0;
    loop {
        let read = reader.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        size += read;
        digest.update(buffer.get(..read).unwrap());
    }
    (size, format!("{:x}", digest.finalize()))
}

struct ResultFiles {
    result: Value,
    root: tempfile::TempDir,
}

fn serve(count: usize, bytes: usize, session: Option<&str>, broken_storage: bool) -> ResultFiles {
    let root = tempfile::tempdir().unwrap();
    let upstream = root.path().join("images.py");
    std::fs::write(&upstream, UPSTREAM).unwrap();
    let config = root.path().join("cmux.json");
    std::fs::write(&config, r#"{"mcp":{"enabled":true}}"#).unwrap();
    let home = root.path().join("state");
    if broken_storage {
        std::fs::write(&home, b"not a directory").unwrap();
    } else {
        std::fs::create_dir(&home).unwrap();
    }
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["mcp", "serve"])
        .env("HOME", root.path())
        .env("ACPMUX_HOME", &home)
        .env("CMUX_NEXT_CONFIG_FILE", config)
        .env(
            "CMUX_MCP_UPSTREAMS",
            json!([{
                "name": "images", "command": "python3", "args": [upstream], "env": {}
            }])
            .to_string(),
        )
        .env_remove("CMUX_MCP_TOOLS")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_MUX_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(session) = session {
        command.env("CMUX_AGENT_SESSION", session);
    }
    let mut child = command.spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    writeln!(input, "{}", json!({"jsonrpc":"2.0", "id":0, "method":"initialize", "params": {
        "protocolVersion":"2025-06-18", "capabilities":{}, "clientInfo":{"name":"image-originals-test", "version":"1"}
    }})).unwrap();
    let script = format!("return await cmux.images_images({{count:{count}, bytes:{bytes}}});");
    writeln!(
        input,
        "{}",
        json!({"jsonrpc":"2.0", "id":1, "method":"tools/call", "params": {
            "name":"cmux_exec", "arguments":{"script":script}
        }})
    )
    .unwrap();
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let result = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|message| message.get("id") == Some(&json!(1)))
        .unwrap_or_else(|| panic!("no result: {}", String::from_utf8_lossy(&output.stderr)))
        .get("result")
        .unwrap()
        .clone();
    ResultFiles { result, root }
}

fn verify(count: usize, size: usize, session: Option<&str>) {
    let ResultFiles { result, root } = serve(count, size, session, false);
    assert_eq!(result.get("isError"), Some(&json!(false)), "{result}");
    let blocks =
        result.pointer("/structuredContent/result/content").and_then(Value::as_array).unwrap();
    assert_eq!(blocks.len(), count, "every original is reachable");
    let final_content = result.get("content").and_then(Value::as_array).unwrap();
    let inline: Vec<_> =
        final_content.iter().filter(|block| block.get("type") == Some(&json!("image"))).collect();
    let links: Vec<_> = final_content
        .iter()
        .filter(|block| block.get("type") == Some(&json!("resource_link")))
        .collect();
    assert!(!links.is_empty(), "the former budget routes originals to files");
    assert_eq!(inline.len() + links.len(), count);
    for (index, block) in blocks.iter().enumerate() {
        let (read, digest) = if let Some(image) = block.get("image").and_then(Value::as_u64) {
            let image = inline.get(usize::try_from(image).unwrap()).unwrap();
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(image.get("data").and_then(Value::as_str).unwrap())
                .unwrap();
            hash(bytes.as_slice())
        } else {
            assert_eq!(block.get("type"), Some(&json!("resource_link")), "{block}");
            let path = url::Url::parse(block.get("uri").and_then(Value::as_str).unwrap())
                .unwrap()
                .to_file_path()
                .unwrap();
            let own = root
                .path()
                .join("state/uploads")
                .join(session.unwrap_or("standalone-mcp"))
                .join("tool-results");
            assert_eq!(path.parent(), Some(own.as_path()));
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
            assert!(links.contains(&block));
            // A new reader can open the returned original after the MCP server has exited.
            hash(std::fs::File::open(path).unwrap())
        };
        assert_eq!(read, size, "image {index}");
        assert_eq!(digest, expected(index, size), "image {index}");
    }
}

#[test]
fn code_mode_keeps_all_64_images_beyond_its_old_16_image_cap() {
    verify(64, 64 << 10, Some("image-count-owner"));
}

#[test]
fn code_mode_keeps_12_mib_of_images_beyond_its_old_8_mib_budget() {
    verify(12, 1 << 20, Some("image-bytes-owner"));
}

#[test]
fn code_mode_keeps_one_12_mib_image_for_a_standalone_mcp_client() {
    verify(1, (12 << 20) + 17, None);
}

#[test]
fn code_mode_reports_storage_failure_after_the_tool_has_run() {
    let ResultFiles { result, .. } = serve(1, 9 << 20, Some("storage-error-owner"), true);
    assert_eq!(result.get("isError"), Some(&json!(true)), "{result}");
    let text = result.to_string();
    assert!(text.contains("image.storage"), "{text}");
    assert!(text.contains("the tool ran"), "{text}");
    assert_eq!(result.pointer("/structuredContent/state"), Some(&json!("partial")));
    assert!(!text.contains("dropped"), "{text}");
}
