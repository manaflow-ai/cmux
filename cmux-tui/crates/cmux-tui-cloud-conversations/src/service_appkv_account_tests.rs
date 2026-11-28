use super::*;
use base64::Engine as _;

/// Records each POST and answers a write's revision.
#[derive(Default)]
struct Recording {
    posted: Mutex<Vec<String>>,
}

impl CloudBackend for Recording {
    fn post(
        &self,
        url: &str,
        _: Option<&str>,
        _: Option<&str>,
        _: &Value,
    ) -> Result<HttpReply, TransportError> {
        self.posted.lock().unwrap().push(url.to_string());
        Ok(HttpReply { status: 200, body: json!({"ok": true, "value": {"revision": 1}}) })
    }
    fn connect(
        &self,
        _: &str,
        _: Option<&str>,
        _: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        Err(ConnectError::Unavailable("offline".into()))
    }
}

fn sign_in(service: &CloudConversations, account: &str) {
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(json!({ "sub": account }).to_string());
    let params: SessionParams = serde_json::from_value(json!({
        "api_base_url": "https://api.cmux.test",
        "access_token": format!("e30.{claims}.sig"),
        "expires_at": 4_102_444_800_000_u64,
    }))
    .unwrap();
    service.set_session(params).unwrap();
    assert_eq!(service.lease_account().as_deref(), Some(account));
}

/// A write queued for one account never goes out on another account's
/// lease (a sign-in between the sender's check and its send).
#[test]
fn an_appkv_write_never_goes_out_on_another_accounts_lease() {
    let backend = Arc::new(Recording::default());
    let options = ServiceOptions {
        api_origins: vec!["https://api.cmux.test".into()],
        ..ServiceOptions::default()
    };
    let service = CloudConversations::with_options(backend.clone(), options);
    sign_in(&service, "user_2");
    let sent = service.appkv_op("user_1", "cmux/todo", "k", Some(&json!(1)), "idem-1");
    assert!(matches!(sent, Err(CloudError::Unavailable(_))), "{sent:?}");
    assert!(backend.posted.lock().unwrap().is_empty(), "user_1's write went out as user_2");
    service.appkv_op("user_2", "cmux/todo", "k", Some(&json!(1)), "idem-2").unwrap();
    assert_eq!(backend.posted.lock().unwrap().len(), 1);
}
