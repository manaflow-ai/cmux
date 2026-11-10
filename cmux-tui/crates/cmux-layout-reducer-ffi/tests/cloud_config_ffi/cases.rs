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
fn the_configuration_is_made_from_the_runtime_selection() {
    let selection = json!({"name": "dev", "apiOrigin": "https://api.invalid", "authWebOrigin": "https://web.invalid",
        "stackOrigin": "https://stack.invalid", "stackProjectId": "p", "stackClientKey": "k",
        "bundleId": "com.cmuxterm.app.debug.next", "authNamespace": "dev-1", "legacyStorage": false,
        "vmOrigin": "https://ignored.invalid"});
    let (code, body) = call(
        c"cloud_config_from_selection",
        &json!({"selection": selection, "bundled": {}, "process": {}, "isDebugBuild": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["backend"], json!({"kind": "development", "url": "https://api.invalid"}));
    assert_eq!(body["callbackScheme"], "cmux-next-dev");
    assert_eq!(body["storage"]["keychainService"], "com.cmuxterm.app.debug.next.auth.dev-1");
    assert_eq!(body["storage"]["defaultsKeySuffix"], "dev-1");
    assert_eq!(body["namespacedLegacyStore"], Value::Null);
    let (_, names) = call(
        c"cloud_config_storage_names",
        &json!({"bundleId": "com.cmuxterm.app.cloud-unavailable"}),
    );
    assert_eq!(
        names["keychainService"],
        "com.cmuxterm.app.cloud-unavailable.auth.bootstrap-unavailable"
    );
    let (_, url) = call(
        c"cloud_config_sign_in_url",
        &json!({"authWebOrigin": "https://cmux.com", "callbackScheme": "cmux", "state": null}),
    );
    assert!(
        url["url"]
            .as_str()
            .unwrap()
            .starts_with("https://cmux.com/handler/native-sign-in?after_auth_return_to=")
    );
}

#[test]
fn launch_sign_in_and_identity_rules_answer_here() {
    let (_, launch) = call(
        c"cloud_auth_launch_sign_in",
        &json!({"build": {"bundleId": "com.cmuxterm.app.debug.x", "isDebugBuild": true, "isProductionAuth": false},
                "environment": {}, "home": "/h"}),
    );
    assert_eq!(
        launch["signIn"],
        json!({"devAuth": true, "autoLogin": true, "replacesSession": false, "memoryOnly": false})
    );
    assert_eq!(launch["paths"][0], "/h/.config/cmux/dev-account");
    let (_, login) = call(
        c"cloud_auth_launch_login",
        &json!({"signIn": launch["signIn"], "reads": {"environment": {}, "home": "/h", "files": {}}}),
    );
    assert_eq!(login["credentials"], Value::Null);
    assert_eq!(login["allowsEnvironmentAutoLogin"], true);
    assert!(login["refusalLog"].as_str().unwrap().contains("no declared account"));
    let (_, window) = call(
        c"cloud_auth_sign_in_window",
        &json!({"window": "automatic", "defaultBrowser": "com.apple.Safari"}),
    );
    assert_eq!(window["opensDefaultBrowser"], false);
    let (_, scope) = call(
        c"cloud_auth_creation_scope",
        &json!({"previous": [null, null], "current": ["u", null]}),
    );
    assert_eq!(scope["survives"], true);
    let (_, facts) = call(
        c"cloud_auth_seat_facts",
        &json!({"inviteMembers": false, "role": "admin", "members": 2}),
    );
    assert_eq!(facts["canInvite"], true);
    assert_eq!(facts["memberCount"], 2);
    let (_, answer) = call(c"cloud_auth_invite_answer", &json!({"error": "forbidden"}));
    assert_eq!(answer["answer"], "notAllowed");
    let (_, team) = call(
        c"cloud_identity_mint_team",
        &json!({"requested": null, "activeStackTeam": null, "managedStackTeam": "t", "stackProjectId": "p"}),
    );
    assert_eq!(team["refusal"], "managed");
    // The backend's ids (backend `domains/user.ts`, pinned in cmux-cloud-config's identity tests).
    let (project, user) =
        ("9790718f-14cd-4f7e-824d-eaf527a82b82", "0b6c2f1e-8d0a-4a51-9a4e-5f3c7d1e2a90");
    let (_, ids) = call(
        c"cloud_identity_team_ids",
        &json!({"project": project, "stackUser": user, "team": "4c1d9e7a-2b3f-4e68-8a0c-6d5e9f1b3a27"}),
    );
    assert_eq!(ids["personalTeam"], "team_249f328cf8ed89fd792e");
    assert_eq!(ids["teamHeader"], "team_18b8d7083ab4a1e6dd3e");
    assert!(ids["workerUser"].as_str().unwrap().starts_with("user_"));
    let (_, personal) = call(
        c"cloud_identity_team_ids",
        &json!({"project": project, "team": "team_249f328cf8ed89fd792e"}),
    );
    assert_eq!(
        personal,
        json!({"workerUser": null, "personalTeam": null, "teamHeader": "team_249f328cf8ed89fd792e"})
    );
    let (_, team) = call(
        c"cloud_identity_mint_team",
        &json!({"requested": null, "activeStackTeam": "team_249f328cf8ed89fd792e", "managedStackTeam": null, "stackProjectId": project}),
    );
    assert_eq!(team["team"], "team_249f328cf8ed89fd792e");
    let (_, check) =
        call(c"cloud_identity_check", &json!({"team": "personal", "refusalCode": "http_503"}));
    assert_eq!(check, json!({"isTeam": false, "transient": true}));
    let (_, claims) = call(c"cloud_identity_token", &json!({"token": "opaque"}));
    assert_eq!(claims, json!({"user": null, "expiresAt": null, "team": null}));
    // No asked and no active team: the install token's own team is the one to mint for.
    let (_, team) = call(
        c"cloud_identity_mint_team",
        &json!({"requested": null, "activeStackTeam": null, "managedStackTeam": null, "stackProjectId": "p"}),
    );
    assert_eq!(team["team"], Value::Null);
    let (_, own) = call(
        c"cloud_identity_token",
        &json!({"token": "e30.eyJzdWIiOiJ1IiwiZXhwIjoxOTAwMDAwNjAwLCJ0ZWFtIjoidGVhbV9hYWFhYWFhYWFhYWFhYWFhYWFhYSJ9.c2ln"}),
    );
    assert_eq!(own["team"], "team_aaaaaaaaaaaaaaaaaaaa");
    assert_eq!(own["user"], "u");
    let (_, key) = call(c"cloud_identity_install_key", &json!({"user": "u"}));
    assert!(key["account"].as_str().unwrap().starts_with("install-key-"));
    let (_, share) = call(
        c"cloud_identity_share_origin",
        &json!({"url": "https://Cloud-API.cmux.dev/x", "folders": ["install-share-h.example", "x"]}),
    );
    assert_eq!(share["origin"]["origin"], "https://cloud-api.cmux.dev");
    assert_eq!(share["folderApis"], json!(["https://h.example"]));
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
    assert_eq!(team, json!({"active": "a", "refusal": "notActive", "allowed": ["a", "b"]}));
    let (_, rows) = call(
        c"cloud_auth_team_rows",
        &json!({"teams": [{"id": "a", "name": "cmux", "plan": "Team"}, {"id": "p", "name": "Personal"}], "active": "a"}),
    );
    assert_eq!(
        rows,
        json!({"rows": [
            {"id": "a", "title": "cmux", "kind": "team", "active": true, "plan": "team"},
            {"id": "p", "title": "Personal", "kind": "personal", "active": false, "plan": null},
        ]})
    );
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
    assert_eq!(call(c"cloud_config_from_selection", &json!({"isDebugBuild": "no"})).0, ERR_INVALID);
}
