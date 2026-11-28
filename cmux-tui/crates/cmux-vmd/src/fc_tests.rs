use super::*;
use tokio::net::UnixListener;

#[tokio::test]
async fn parses_status_and_body() {
    let dir = std::env::temp_dir().join(format!("cmux-vmd-fc-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("api.sock");
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).unwrap();
    tokio::spawn(async move {
        let (mut s, _) = listener.accept().await.unwrap();
        let mut b = [0u8; 1024];
        let _ = s.read(&mut b).await.unwrap();
        s.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 13\r\n\r\n{\"fault\":\"x\"}")
            .await
            .unwrap();
    });
    let err = call(&sock, "PUT", "/actions", Some(&serde_json::json!({}))).await.unwrap_err();
    assert!(err.to_string().contains("400"), "{err}");
    assert!(err.to_string().contains("fault"), "{err}");
    std::fs::remove_dir_all(&dir).unwrap();
}
