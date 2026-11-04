//! `cloud_config_*`, `cloud_auth_*` and `cloud_vm_agent_key_*` through the C ABI: the app sends
//! its facts and acts on the answer (cmux-cloud-config holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 13];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn signed_dev_resolves_to_the_development_cloud_with_its_names() {
    let (code, body) = call(
        c"cloud_config_resolve",
        &json!({"bundleId": "com.cmuxterm.app.debug.next", "bundled": {"CMUX_API_BASE_URL": "https://x.invalid"},
                "process": {}, "isDebugBuild": false}),
    );
    assert_eq!(code, OK);
    let configuration = &body["configuration"];
    assert_eq!(
        configuration["backend"],
        json!({"kind": "development", "url": "https://cmux-api-development.debussy.workers.dev"})
    );
    // NEXT Cloud's Worker, never the classic staging web app; sign-in and teams stay on the web app.
    assert_eq!(
        configuration["cloudApiBaseUrl"],
        "https://cmux-api-development.debussy.workers.dev"
    );
    assert_eq!(configuration["apiBaseUrl"], "https://cmux-staging.vercel.app");
    assert_eq!(configuration["linkSource"], "appServer");
    assert_eq!(configuration["callbackScheme"], "cmux-next-dev");
    assert_eq!(configuration["isProductionAuth"], false);
    assert_eq!(
        body["keychainService"],
        "com.cmuxterm.app.debug.next.auth.454ecd03-1db2-4050-845e-4ce5b0cd9895"
    );
    assert_eq!(body["vmApiBaseUrl"], "https://vm-staging.cmux.dev");
    let (_, production) = call(
        c"cloud_config_resolve",
        &json!({"bundleId": "com.cmuxterm.app", "isDebugBuild": false}),
    );
    assert_eq!(production["configuration"]["backend"], json!({"kind": "production"}));
    assert_eq!(production["vmApiBaseUrl"], "https://vm.cmux.dev");
}

#[test]
fn names_and_apis_follow_the_identity_sent() {
    let identity = json!({"bundleId": "com.cmuxterm.app.debug.next", "isDebugBuild": false, "isProductionAuth": true,
                          "stackProjectId": "9790718f-14cd-4f7e-824d-eaf527a82b82"});
    let (code, names) = call(
        c"cloud_config_names",
        &json!({"identity": identity, "defaultsKeys": ["cmux.auth.hasTokens"]}),
    );
    assert_eq!(code, OK);
    assert_eq!(names["keychainService"], "com.cmuxterm.app.debug.next.auth");
    assert_eq!(names["defaultsKeys"]["cmux.auth.hasTokens"], "cmux.auth.hasTokens");
    let debug = json!({"bundleId": "com.cmuxterm.app.debug.walk", "isDebugBuild": true, "isProductionAuth": false, "linkSource": "appServer"});
    let (_, apis) = call(c"cloud_config_apis", &json!({"identity": debug, "environment": {}}));
    assert_eq!(apis["ownerApi"], "https://cmux-api-development.debussy.workers.dev");
    assert_eq!(apis["shareApi"], "https://cmux-api-development.debussy.workers.dev");
    assert_eq!(apis["previewApi"], "https://cmux-platform-development.debussy.workers.dev");
    let (_, accepts) = call(
        c"cloud_config_accepts_share_api",
        &json!({"identity": identity, "api": "https://elsewhere.example"}),
    );
    assert_eq!(accepts["accepts"], false);
    let (_, capture) = call(
        c"cloud_config_capture_build",
        &json!({"bundleId": "com.cmuxterm.app.debug.cap0123456789", "benchHooks": true}),
    );
    assert_eq!(capture["capture"], true);
}

#[test]
fn auth_rules_answer_from_what_the_app_read() {
    let (_, paths) =
        call(c"cloud_auth_credential_paths", &json!({"environment": {}, "home": "/h"}));
    assert_eq!(paths["paths"][0], "/h/.config/cmux/dev-account");
    let (_, decision) =
        call(c"cloud_auth_credentials", &json!({"environment": {}, "home": "/h", "files": {}}));
    assert_eq!(decision, json!({"credentials": null, "refusal": {"kind": "noDeclaredAccount"}}));
    let (_, team) = call(
        c"cloud_auth_team",
        &json!({"requested": "b", "resolved": "a", "available": ["a", "b"], "managed": null}),
    );
    assert_eq!(team, json!({"active": "a", "refusal": "notActive"}));
    let (_, keys) = call(
        c"cloud_auth_launch_keys",
        &json!({"environment": {"CMUX_DEV_AUTH_PROFILE": "agent", "HOME": "/h"}}),
    );
    assert_eq!(keys["keys"], json!({"CMUX_DEV_AUTH_PROFILE": "agent"}));
    let (_, masked) = call(c"cloud_auth_mask", &json!({"email": "leo@example.com"}));
    assert_eq!(masked["masked"], "l***@example.com");
}

#[test]
fn the_agent_key_mint_is_planned_and_read_here() {
    let (code, planned) = call(
        c"cloud_vm_agent_key_request",
        &json!({"backend": {"kind": "production"}, "params": {"ttlSeconds": 3600, "maxVms": 2}}),
    );
    assert_eq!(code, OK);
    assert_eq!(planned["request"]["url"], "https://vm.cmux.dev/v1/agent-keys");
    assert_eq!(planned["request"]["body"]["scopes"], json!(["vm:read", "vm:write", "vm:exec"]));
    let (_, refused) = call(
        c"cloud_vm_agent_key_request",
        &json!({"backend": {"kind": "production"}, "params": {"maxVms": 99}}),
    );
    assert_eq!(refused["refusal"]["code"], "invalid_params");
    let (_, minted) = call(
        c"cloud_vm_agent_key_answer",
        &json!({"status": 201, "body": "{\"key\":\"vmk_s\",\"id\":\"vmk_1\"}", "baseUrl": "https://vm.cmux.dev", "teamId": "t"}),
    );
    assert_eq!(minted["result"]["teamId"], "t");
    let (_, signed_out) = call(
        c"cloud_vm_agent_key_answer",
        &json!({"status": 401, "body": "", "baseUrl": "https://vm.cmux.dev", "teamId": "t"}),
    );
    assert_eq!(signed_out["refusal"]["appText"], "notSignedIn");
}

#[test]
fn an_unknown_op_or_a_bad_request_is_refused() {
    assert_eq!(call(c"cloud_config_nope", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_config_resolve", &json!({"isDebugBuild": "no"})).0, ERR_INVALID);
}
