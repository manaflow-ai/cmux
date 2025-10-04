#[cfg(target_os = "linux")]
mod linux_only {
    use std::io::{Read, Write};
    use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener};
    use std::env;
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    use cmux_proxy::workspace_ip_from_name;
    use tokio::time::timeout;
    use tokio::time::sleep;
    use hyper::service::{make_service_fn, service_fn};
    use hyper::{Body, Request, Response, Server};

    async fn ensure_loopback(ip: Ipv4Addr) {
        // Attempt to add the IP to loopback; ignore errors if already present
        let cmd = format!("ip addr add {}/8 dev lo || true", ip);
        let _ = Command::new("sh").arg("-lc").arg(cmd).status();
    }

    async fn start_upstream_http_on_fixed(ip: Ipv4Addr, port: u16, body: &'static str) {
        let make_svc = make_service_fn(move |_conn| {
            let body_text = body;
            async move {
                Ok::<_, std::convert::Infallible>(service_fn(move |_req: Request<Body>| {
                    let body_text = body_text;
                    async move { Ok::<_, std::convert::Infallible>(Response::new(Body::from(body_text))) }
                }))
            }
        });
        let addr: SocketAddr = (IpAddr::V4(ip), port).into();
        let server = Server::bind(&addr).serve(make_svc);
        tokio::spawn(server);
        // tiny delay to ensure listener is up
        sleep(Duration::from_millis(50)).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_ld_preload_connect_rewrite() {
        let ws_ip = workspace_ip_from_name("workspace-1").expect("mapping");
        ensure_loopback(ws_ip).await;

        // Start a plain TCP echo server bound to the workspace IP
        let listener = TcpListener::bind(SocketAddr::from((ws_ip, 0))).expect("bind workspace ip");
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut buf = [0u8; 4];
                if s.read_exact(&mut buf).is_ok() {
                    let _ = s.write_all(&buf);
                }
            }
        });

        // Build LD_PRELOAD path
        let lib_path = format!("{}/ldpreload/libworkspace_net.so", env!("CARGO_MANIFEST_DIR"));
        if !Path::new(&lib_path).exists() {
            // Try to build it if missing
            let status = Command::new("make").arg("-C").arg(format!("{}/ldpreload", env!("CARGO_MANIFEST_DIR"))).status().expect("spawn make");
            assert!(status.success(), "failed to build ldpreload library");
        }

        // Use bash's /dev/tcp to make a TCP connection to 127.0.0.1:port
        // LD_PRELOAD should rewrite to ws_ip:port
        let script = format!(
            "exec 3<>/dev/tcp/127.0.0.1/{}; echo -n ping >&3; dd bs=4 count=1 <&3 status=none",
            addr.port()
        );
        let mut child = Command::new("bash")
            .arg("-lc")
            .arg(script)
            .env("LD_PRELOAD", &lib_path)
            .env("CMUX_WORKSPACE_INTERNAL", "workspace-1")
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn bash");

        let mut out = Vec::new();
        let mut stdout = child.stdout.take().unwrap();
        let read = tokio::task::spawn_blocking(move || stdout.read_to_end(&mut out).map(|_| out));
        let out = timeout(Duration::from_secs(5), read).await.expect("read timeout").expect("read join").expect("read ok");

        let status = child.wait().expect("wait child");
        assert!(status.success(), "child failed");
        assert_eq!(out, b"ping");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_ld_preload_cwd_detection_non_numeric() {
        let ws_name = "workspace-c";
        let ws_ip = workspace_ip_from_name(ws_name).expect("mapping");

        // Ensure loopback route works; ignore failures
        ensure_loopback(ws_ip).await;

        // Start echo server on workspace IP
        let listener = TcpListener::bind(SocketAddr::from((ws_ip, 0))).expect("bind workspace ip");
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut buf = [0u8; 4];
                if s.read_exact(&mut buf).is_ok() {
                    let _ = s.write_all(&buf);
                }
            }
        });

        // Build LD_PRELOAD path
        let lib_path = format!("{}/ldpreload/libworkspace_net.so", env!("CARGO_MANIFEST_DIR"));
        if !Path::new(&lib_path).exists() {
            let status = Command::new("make").arg("-C").arg(format!("{}/ldpreload", env!("CARGO_MANIFEST_DIR"))).status().expect("spawn make");
            assert!(status.success(), "failed to build ldpreload library");
        }

        // Prepare workspace directory and run child with that CWD
        let ws_dir = "/root/workspace-c";
        let _ = std::fs::create_dir_all(ws_dir);

        let script = format!(
            "exec 3<>/dev/tcp/127.0.0.1/{}; echo -n ping >&3; dd bs=4 count=1 <&3 status=none",
            addr.port()
        );
        let mut cmd = Command::new("bash");
        cmd
            .arg("-lc")
            .arg(script)
            .current_dir(ws_dir)
            // No CMUX_WORKSPACE_INTERNAL on purpose; rely on CWD detection
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());

        // If LD_PRELOAD is not globally set to our library, set it for the child
        let need_set = match env::var("LD_PRELOAD") {
            Ok(v) => !v.contains("libworkspace_net.so"),
            Err(_) => true,
        };
        if need_set {
            cmd.env("LD_PRELOAD", &lib_path);
        }
        let mut child = cmd.spawn().expect("spawn bash");

        let mut out = Vec::new();
        let mut stdout = child.stdout.take().unwrap();
        let read = tokio::task::spawn_blocking(move || stdout.read_to_end(&mut out).map(|_| out));
        let out = timeout(Duration::from_secs(5), read).await.expect("read timeout").expect("read join").expect("read ok");

        let status = child.wait().expect("wait child");
        assert!(status.success(), "child failed");
        assert_eq!(out, b"ping");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_ld_preload_curl_workspace_isolation() {
        // Resolve workspace IPs and ensure loopback aliases
        let ws_a = "workspace-a";
        let ws_b = "workspace-b";
        let ip_a = workspace_ip_from_name(ws_a).expect("map a");
        let ip_b = workspace_ip_from_name(ws_b).expect("map b");
        ensure_loopback(ip_a).await;
        ensure_loopback(ip_b).await;

        // Start HTTP server on A:3000 only
        let port = 3000u16;
        start_upstream_http_on_fixed(ip_a, port, "ok-from-A").await;

        // Build LD_PRELOAD path (compile if missing)
        let lib_path = format!("{}/ldpreload/libworkspace_net.so", env!("CARGO_MANIFEST_DIR"));
        if !Path::new(&lib_path).exists() {
            let status = Command::new("make").arg("-C").arg(format!("{}/ldpreload", env!("CARGO_MANIFEST_DIR"))).status().expect("spawn make");
            assert!(status.success(), "failed to build ldpreload library");
        }

        // Create workspace directories for CWD-based detection
        let ws_dir_a = "/root/workspace-a";
        let ws_dir_b = "/root/workspace-b";
        let _ = std::fs::create_dir_all(ws_dir_a);
        let _ = std::fs::create_dir_all(ws_dir_b);

        // Verify curl exists for clearer error if missing
        let curl_ok = Command::new("sh").arg("-lc").arg("command -v curl >/dev/null 2>&1").status().expect("spawn sh").success();
        assert!(curl_ok, "curl binary not found in PATH");

        // A: curl should succeed via LD_PRELOAD routing to A IP
        let url = format!("http://127.0.0.1:{}/hello", port);
        let mut cmd_a = Command::new("bash");
        cmd_a
            .arg("-lc")
            .arg(format!("curl -sS -m 5 {}", url))
            .current_dir(ws_dir_a)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let need_set = match env::var("LD_PRELOAD") {
            Ok(v) => !v.contains("libworkspace_net.so"),
            Err(_) => true,
        };
        if need_set { cmd_a.env("LD_PRELOAD", &lib_path); }
        let mut child_a = cmd_a.spawn().expect("spawn curl A");
        let mut out_a = Vec::new();
        let mut stdout_a = child_a.stdout.take().unwrap();
        let read_a = tokio::task::spawn_blocking(move || stdout_a.read_to_end(&mut out_a).map(|_| out_a));
        let out_a = timeout(Duration::from_secs(10), read_a).await.expect("read A timeout").expect("read A join").expect("read A ok");
        let status_a = child_a.wait().expect("wait curl A");
        assert!(status_a.success(), "curl in workspace-a failed");
        assert_eq!(String::from_utf8_lossy(&out_a), "ok-from-A");

        // B: curl should fail (no server bound on B:3000)
        let mut cmd_b = Command::new("bash");
        cmd_b
            .arg("-lc")
            .arg(format!("curl -sS -m 3 {}", url))
            .current_dir(ws_dir_b)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if need_set { cmd_b.env("LD_PRELOAD", &lib_path); }
        let mut child_b = cmd_b.spawn().expect("spawn curl B");
        let status_b = timeout(Duration::from_secs(10), async { child_b.wait() }).await.expect("wait B timeout").expect("wait B ok");
        assert!(!status_b.success(), "curl from workspace-b unexpectedly succeeded");
    }
}
