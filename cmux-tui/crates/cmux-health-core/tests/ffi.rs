//! The C ABI the macOS app calls (src/ffi.rs, include/cmux_health.h): a page
//! hang and its recovery through `cmux_health_call` in JSON, the snapshot's
//! camelCase fields, and the error codes.

use cmux_health_core::ffi::*;
use serde_json::{Value, json};
use std::ffi::CString;

struct Model(*mut CmuxHealth);

impl Drop for Model {
    fn drop(&mut self) {
        // SAFETY: from `cmux_health_new`, freed once.
        unsafe { cmux_health_free(self.0) };
    }
}

impl Model {
    fn new() -> Self {
        Self(cmux_health_new())
    }

    fn raw(&self, op: &str, body: &[u8]) -> Result<Value, i32> {
        let op = CString::new(op).expect("op");
        let mut out = CmuxHealthBytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: valid pointers for the call.
        let code =
            unsafe { cmux_health_call(self.0, op.as_ptr(), body.as_ptr(), body.len(), &mut out) };
        if code != CMUX_HEALTH_OK {
            return Err(code);
        }
        // SAFETY: a reply buffer of `len` bytes from the library.
        let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
        let value = serde_json::from_slice(bytes).expect("JSON reply");
        // SAFETY: freed once.
        unsafe { cmux_health_bytes_free(out) };
        Ok(value)
    }

    fn call(&self, op: &str, request: Value) -> Value {
        self.raw(op, &serde_json::to_vec(&request).expect("request")).expect(op)
    }
}

#[test]
fn a_page_hang_round_trips_through_the_c_abi() {
    assert_eq!(cmux_health_abi_version(), CMUX_HEALTH_ABI_VERSION);
    let m = Model::new();
    let id = "page:42";
    let reply =
        m.call("register", json!({"id": id, "kind": "page", "label": "Agent chat", "nowMs": 0}));
    assert_eq!(reply, json!({"nextTickMs": 5000}));
    assert_eq!(m.call("beat", json!({"id": id, "nowMs": 0.0})), json!({"nextTickMs": 5000}));
    assert_eq!(m.call("tick", json!({"nowMs": 5000})), json!({"actions": [], "nextTickMs": 10000}));
    assert_eq!(
        m.call("tick", json!({"nowMs": 10000})),
        json!({
            "actions": [{"id": id, "kind": "page", "action": "reloadPage", "attempt": 1}],
            "nextTickMs": 12000
        })
    );
    let snap = m.call("snapshot", json!({}));
    assert_eq!(snap["worst"], "repairing");
    assert_eq!(
        snap["parts"][0],
        json!({
            "id": id, "kind": "page", "label": "Agent chat",
            "state": "repairing", "sinceMs": 10000,
            "detail": "Not answering for 10 s. Reloading it (attempt 1 of 3); your draft is kept.",
            "action": "reloadPage", "attempt": 1, "maxAttempts": 3, "nextAtMs": 12000,
            "canRepair": true
        })
    );
    assert_eq!(snap["receipts"][0]["outcome"], "started");
    assert_eq!(snap["receipts"][0]["atMs"], 10000);
    assert_eq!(snap["pending"], json!([]));
    assert_eq!(snap["pendingMore"], 0);

    m.call("repairResult", json!({"id": id, "action": "reloadPage", "ok": true, "nowMs": 10500}));
    assert_eq!(m.call("snapshot", json!({}))["parts"][0]["state"], "repairing");
    assert_eq!(m.call("beat", json!({"id": id, "nowMs": 11000})), json!({"nextTickMs": 16000}));
    // Swift sends `null` for an absent pid or value.
    let loaded = json!({"id": id, "event": "loaded", "nowMs": 11000, "pid": null, "value": null});
    assert_eq!(m.call("event", loaded), json!({"nextTickMs": 16000}));
    let snap = m.call("snapshot", json!({}));
    assert_eq!((snap["worst"].clone(), snap["parts"].clone()), (json!("healthy"), json!([])));
    assert_eq!(snap["receipts"][0]["outcome"], "ok");

    m.call("pending", json!({"id": "intent:1", "label": "Close Background task", "nowMs": 11000}));
    let snap = m.call("snapshot", json!({}));
    assert_eq!(
        snap["pending"],
        json!([{"id": "intent:1", "label": "Close Background task", "sinceMs": 11000}])
    );
    m.call("pendingDone", json!({"id": "intent:1", "ok": true, "nowMs": 12000}));
    assert_eq!(m.call("snapshot", json!({}))["pending"], json!([]));

    assert_eq!(m.call("inject", json!({"id": id, "fault": "hang"})), json!({"ok": true}));
    assert_eq!(
        m.call("visibility", json!({"id": id, "visible": false, "nowMs": 12000})),
        json!({"nextTickMs": null})
    );
    assert_eq!(
        m.call("repairNow", json!({"id": id, "nowMs": 12000})),
        json!({"actions": [], "nextTickMs": null})
    );
    assert_eq!(m.call("unregister", json!({"id": id})), json!({"nextTickMs": null}));
}

#[test]
fn bad_calls_get_their_codes() {
    let m = Model::new();
    assert_eq!(m.raw("nope", b"{}"), Err(CMUX_HEALTH_ERR_UNKNOWN_OP));
    assert_eq!(m.raw("beat", b"[1]"), Err(CMUX_HEALTH_ERR_INVALID));
    assert_eq!(m.raw("beat", b"{\"id\": \"x\"}"), Err(CMUX_HEALTH_ERR_INVALID));
    assert_eq!(
        m.raw("register", b"{\"id\": \"x\", \"kind\": \"toaster\"}"),
        Err(CMUX_HEALTH_ERR_INVALID)
    );
    // An empty request is `{}`.
    assert_eq!(
        m.raw("snapshot", b""),
        Ok(json!({
            "worst": "healthy", "parts": [], "receipts": [], "pending": [], "pendingMore": 0
        }))
    );
    let op = CString::new("snapshot").expect("op");
    let mut out = CmuxHealthBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: a null handle is refused before any use.
    let code = unsafe {
        cmux_health_call(std::ptr::null_mut(), op.as_ptr(), std::ptr::null(), 0, &mut out)
    };
    assert_eq!(code, CMUX_HEALTH_ERR_NULL);
    // SAFETY: null is ignored.
    unsafe { cmux_health_free(std::ptr::null_mut()) };
}
