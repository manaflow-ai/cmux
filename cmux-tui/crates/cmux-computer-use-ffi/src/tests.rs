use super::*;

#[test]
fn parses_requests_with_remote_origin() {
    let (ctx, name, args) = parse_request(&json!({
        "name": "click", "arguments": {"x": 1}, "session": "s", "label": "Codex",
        "call_id": "c", "origin": {"kind": "remote", "machine": "mini", "same_account": true}
    }))
    .unwrap();
    assert_eq!(name, "click");
    assert_eq!(args["x"], 1);
    assert_eq!(ctx.origin, OriginKind::Remote { machine: "mini".into(), same_account: true });
    assert!(parse_request(&json!({})).is_err());
}

#[cfg(unix)]
#[test]
fn serve_and_stop_through_the_c_abi() {
    use std::io::{BufRead, BufReader, Write};
    let desktop: Arc<dyn cmux_computer_use::Desktop> =
        Arc::new(cmux_computer_use::desktop::fake::FakeDesktop::standard());
    let engine = Box::into_raw(Box::new(CmuxCuEngine {
        engine: Arc::new(Engine::new(EngineParts::new(desktop))),
    }));
    let dir = format!("/tmp/cuffi{}", std::process::id());
    let path = format!("{dir}/s.sock");
    let secret = "ab".repeat(32);
    let mut error = CmuxCuBuffer::empty();
    // SAFETY: valid pointers for the call.
    let server = unsafe {
        cmux_cu_serve(engine, path.as_ptr(), path.len(), secret.as_ptr(), secret.len(), &mut error)
    };
    assert!(!server.is_null());
    let mut stream = std::os::unix::net::UnixStream::connect(&path).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    writeln!(stream, "{}", json!({"secret": secret})).unwrap();
    writeln!(stream, "{}", json!({"id": 1, "method": "status"})).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");
    line.clear();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("\"mode\":\"fullAccess\""), "{line}");
    // SAFETY: from cmux_cu_serve / create.
    unsafe {
        cmux_cu_serve_stop(server);
        cmux_cu_engine_destroy(engine);
    }
    assert!(!std::path::Path::new(&path).exists());
    // A short secret is refused.
    let short = "ab";
    let engine = Box::into_raw(Box::new(CmuxCuEngine {
        engine: Arc::new(Engine::new(EngineParts::new(Arc::new(
            cmux_computer_use::desktop::fake::FakeDesktop::standard(),
        )))),
    }));
    // SAFETY: valid pointers for the call.
    let server = unsafe {
        cmux_cu_serve(engine, path.as_ptr(), path.len(), short.as_ptr(), short.len(), &mut error)
    };
    assert!(server.is_null() && !error.data.is_null());
    // SAFETY: from the library.
    unsafe {
        cmux_cu_buffer_free(error);
        cmux_cu_engine_destroy(engine);
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn stop_and_resume_through_the_c_abi() {
    let desktop: Arc<dyn cmux_computer_use::Desktop> =
        Arc::new(cmux_computer_use::desktop::fake::FakeDesktop::standard());
    let inner = Arc::new(Engine::new(EngineParts::new(desktop)));
    let engine = Box::into_raw(Box::new(CmuxCuEngine { engine: Arc::clone(&inner) }));
    let call = |action: &str, session: &str| {
        let label = "Claude";
        // SAFETY: valid pointers for the call; engine from Box::into_raw.
        unsafe {
            cmux_cu_engine_session(
                engine,
                action.as_ptr(),
                action.len(),
                session.as_ptr(),
                session.len(),
                label.as_ptr(),
                label.len(),
            )
        }
    };
    assert_eq!(call("stop", "s1"), 0);
    assert_eq!(call("stop", "s1"), 2);
    assert!(inner.is_stopped("s1"));
    assert_eq!(call("resume", "s1"), 0);
    assert_eq!(call("resume", "s1"), 2);
    assert!(!inner.is_stopped("s1"));
    assert_eq!(call("pause", "s1"), 1);
    assert_eq!(call("stop", ""), 1);
    // SAFETY: from Box::into_raw.
    unsafe { cmux_cu_engine_destroy(engine) };
}

#[test]
fn buffers_round_trip() {
    let b = cmux_cu_tools_list();
    // SAFETY: from the library.
    let s = unsafe { std::str::from_utf8(std::slice::from_raw_parts(b.data, b.len)) }
        .unwrap()
        .to_string();
    assert!(s.contains("\"screenshot\""));
    // SAFETY: from the library.
    unsafe { cmux_cu_buffer_free(b) };
}
