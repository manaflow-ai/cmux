#[cfg(target_os = "linux")]
mod linux_preload {
    use std::io::{Read, Write};
    use std::net::{Ipv4Addr, SocketAddr};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    use cmux_proxy::workspace_ip_from_name;
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    async fn ensure_loopback(ip: Ipv4Addr) {
        // Attempt to add the IP to loopback; ignore errors if already present
        let cmd = format!("ip addr add {}/8 dev lo || true", ip);
        let _ = Command::new("sh").arg("-lc").arg(cmd).status();
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
        let need_set = match std::env::var("LD_PRELOAD") {
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
}

