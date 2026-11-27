//! Ported from the app's CloudAccessTokenTests (the rules), ShareInstalls' origin cases and
//! MacInstallStore's key name.

use base64::Engine;

use super::*;

const TEAM: &str = "team_aaaaaaaaaaaaaaaaaaaa";

#[test]
fn a_backend_team_is_team_and_twenty_lowercase_hex() {
    assert!(is_team(TEAM));
    assert!(!is_team("team_AAAAAAAAAAAAAAAAAAAA"));
    assert!(!is_team("personal"));
    assert!(!is_team("team_aaaaaaaaaaaaaaaaaaa"));
}

#[test]
fn the_backend_id_of_a_stack_team_ignores_its_case() {
    let upper = backend_team_id("proj_1", "6F1C2D9E-0000-4000-8000-000000000001");
    assert_eq!(upper, backend_team_id("proj_1", "6f1c2d9e-0000-4000-8000-000000000001"));
    assert!(is_team(&upper));
    assert_ne!(upper, backend_team_id("proj_2", "6f1c2d9e-0000-4000-8000-000000000001"));
}

/// Ids the backend derives (`domains/user.ts`), computed there with sha256 for these inputs (the
/// app's GitHubAppLeaseTests pin the same ones).
const PROJECT: &str = "9790718f-14cd-4f7e-824d-eaf527a82b82";
const STACK_USER: &str = "0b6c2f1e-8d0a-4a51-9a4e-5f3c7d1e2a90";
const STACK_TEAM: &str = "4c1d9e7a-2b3f-4e68-8a0c-6d5e9f1b3a27";
const PERSONAL: &str = "team_249f328cf8ed89fd792e";

#[test]
fn the_backend_derives_user_personal_and_stack_team_ids() {
    // sha256("stack:p:s") starts 02ef07e3bf70025ba891; the Stack user id keeps its case.
    assert_eq!(worker_user_id("p", "s"), "user_02ef07e3bf70025ba891");
    assert_ne!(worker_user_id("p", "S"), worker_user_id("p", "s"));
    assert_eq!(personal_team_id(PROJECT, STACK_USER), PERSONAL);
    assert!(is_team(PERSONAL));
    assert_eq!(backend_team_id(PROJECT, STACK_TEAM), "team_18b8d7083ab4a1e6dd3e");
}

#[test]
fn the_team_header_passes_a_backend_team_and_hashes_a_stack_team() {
    assert_eq!(team_header(PROJECT, PERSONAL), PERSONAL);
    assert_eq!(team_header(PROJECT, STACK_TEAM), "team_18b8d7083ab4a1e6dd3e");
    assert_eq!(team_header(PROJECT, &STACK_TEAM.to_uppercase()), "team_18b8d7083ab4a1e6dd3e");
    // Not quite a backend id (upper case hex): a Stack id, so hashed.
    assert_ne!(team_header(PROJECT, "team_AAAAAAAAAAAAAAAAAAAA"), "team_AAAAAAAAAAAAAAAAAAAA");
}

#[test]
fn the_personal_team_active_mints_for_itself() {
    assert_eq!(mint_team(None, Some(PERSONAL), None, PROJECT), Ok(Some(PERSONAL.to_owned())));
    assert_eq!(mint_team(Some(TEAM), Some(PERSONAL), None, PROJECT), Ok(Some(TEAM.to_owned())));
    // A managed device never acts in the personal team.
    assert_eq!(
        mint_team(None, Some(PERSONAL), Some(STACK_TEAM), PROJECT),
        Err(MintRefusal::Managed)
    );
}

#[test]
fn the_default_is_the_active_team_and_a_managed_device_mints_only_for_its_team() {
    let (project, stack_team, other) =
        ("proj_1", "6F1C2D9E-0000-4000-8000-000000000001", "6f1c2d9e-0000-4000-8000-000000000002");
    let backend = backend_team_id(project, stack_team);
    assert_eq!(mint_team(Some(TEAM), Some(stack_team), None, project), Ok(Some(TEAM.to_owned())));
    assert_eq!(mint_team(None, Some(stack_team), None, project), Ok(Some(backend.clone())));
    assert_eq!(mint_team(None, None, None, project), Ok(None));
    assert_eq!(
        mint_team(None, Some(stack_team), Some(stack_team), project),
        Ok(Some(backend.clone()))
    );
    assert_eq!(
        mint_team(Some(&backend), Some(stack_team), Some(stack_team), project),
        Ok(Some(backend.clone()))
    );
    assert_eq!(
        mint_team(Some(TEAM), Some(stack_team), Some(stack_team), project),
        Err(MintRefusal::Managed)
    );
    assert_eq!(mint_team(None, None, Some(stack_team), project), Err(MintRefusal::Managed));
    assert_eq!(mint_team(None, Some(other), Some(stack_team), project), Err(MintRefusal::Managed));
}

#[test]
fn only_the_services_trouble_is_transient() {
    for code in ["http_503", "http_500", "http_429", "auth.rate_limited"] {
        assert!(is_transient(code), "{code}");
    }
    for code in ["http_403", "auth.forbidden", "http_5", "http_5000", "http_5x3"] {
        assert!(!is_transient(code), "{code}");
    }
}

#[test]
fn claims_are_read_from_the_token() {
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(format!(r#"{{"exp":1900000600,"sub":"user_1","team":"{TEAM}"}}"#));
    let token = format!("eyJhbGciOiJFUzI1NiJ9.{payload}.c2ln");
    assert_eq!(
        claims(&token),
        Claims {
            user: Some("user_1".to_owned()),
            expires_at: Some(1_900_000_600.0),
            team: Some(TEAM.to_owned()),
        }
    );
    // An install token with no team claim names no team, so `cmux auth token` with no asked and
    // no active team answers no_team.
    let personal = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(r#"{"exp":1900000600,"sub":"user_1","team":""}"#);
    assert_eq!(claims(&format!("a.{personal}.c")).team, None);
    assert_eq!(claims("not-a-jwt"), Claims::default());
    let empty =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(r#"{"sub":"","exp":-1,"team":""}"#);
    assert_eq!(claims(&format!("a.{empty}.c")), Claims::default());
}

#[test]
fn a_token_with_an_empty_segment_has_no_claims() {
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(format!(r#"{{"exp":1900000600,"sub":"user_1","team":"{TEAM}"}}"#));
    assert_eq!(claims(&format!("h.{payload}.s")).team.as_deref(), Some(TEAM));
    for token in [
        format!(".{payload}.s"),
        format!("h.{payload}."),
        format!(".{payload}."),
        "h..s".to_owned(),
        "..".to_owned(),
    ] {
        assert_eq!(claims(&token), Claims::default(), "{token}");
    }
}

#[test]
fn each_user_has_their_own_install_key() {
    let key = install_key_account("stack_1");
    assert!(key.starts_with("install-key-") && key.len() == "install-key-".len() + 16, "{key}");
    assert_ne!(key, install_key_account("stack_2"));
    assert_eq!(key, install_key_account("stack_1"));
}

#[test]
fn a_share_install_is_kept_by_its_https_origin() {
    let found = share_origin("https://Cloud-API.cmux.dev/v1/x").expect("origin");
    assert_eq!(found.origin, "https://cloud-api.cmux.dev");
    assert_eq!(found.folder, "install-share-cloud-api.cmux.dev");
    assert_eq!(
        share_origin("https://h.example:8443").map(|o| o.origin).as_deref(),
        Some("https://h.example:8443")
    );
    assert_eq!(share_origin("http://cloud-api.cmux.dev"), None);
    assert_eq!(share_origin("https://"), None);
    assert_eq!(
        share_folder_api("install-share-cloud-api.cmux.dev").as_deref(),
        Some("https://cloud-api.cmux.dev")
    );
    assert_eq!(share_folder_api("install-share-a/b"), None);
    assert_eq!(share_folder_api("other"), None);
}
