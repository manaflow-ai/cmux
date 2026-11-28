use serde_json::{Value, json};

use super::*;

fn doc(mandatory: Value, recommended: Value) -> Document {
    Document::from_json(&json!({ "mandatory": mandatory, "recommended": recommended }))
}

fn chrome_mandatory() -> Document {
    doc(
        json!({
            "DefaultSearchProviderEnabled": true,
            "DefaultSearchProviderName": "Example Corp Search",
            "DefaultSearchProviderSearchURL": "https://search.example.com/search?q={searchTerms}",
            "DefaultSearchProviderSuggestURL": "https://search.example.com/suggest?q={searchTerms}",
            "NewTabPageLocation": "https://intranet.example.com/start",
            "PasswordManagerEnabled": false,
            "URLBlocklist": ["facebook.com", "example.org/private", "file://*"],
            "URLAllowlist": ["example.org/private/handbook"],
            "ExtensionInstallForcelist": ["aeblfdkhhhdcdjpifhhbdiojplfjncoa;https://clients2.google.com/service/update2/crx", "ppnbnpeolgkicgegkbkbjmhlideopiji"],
            "AuthServerAllowlist": "*.example.com",
        }),
        json!({}),
    )
}

/// Swift `mandatoryChromePoliciesBecomeManagedSettings`.
#[test]
fn mandatory_chrome_policies_become_forced_settings() {
    let (forced, recommended) = managed_values(&chrome_mandatory());
    assert!(recommended.is_empty());
    assert_eq!(forced["browser.searchEngine"], "custom");
    assert_eq!(
        forced["browser.customSearchEngine.search"],
        "https://search.example.com/search?q={searchTerms}"
    );
    assert_eq!(
        forced["browser.customSearchEngine.suggest"],
        "https://search.example.com/suggest?q={searchTerms}"
    );
    assert_eq!(forced["browser.newTabPage"], "https://intranet.example.com/start");
    assert_eq!(forced["browser.passwords.offerToSave"], false);
    assert_eq!(forced["browser.passwords.generate"], false);
    assert_eq!(forced["URLBlocklist"], json!(["facebook.com", "example.org/private", "file://*"]));
    assert_eq!(forced["URLAllowlist"], json!(["example.org/private/handbook"]));
    assert_eq!(forced["ExtensionInstallForcelist"].as_array().map(Vec::len), Some(2));
    // Policies Chromium reads natively are not cmux settings.
    assert!(!forced.contains_key("AuthServerAllowlist"));
}

/// Swift `recommendedChromePoliciesOnlyFillDefaults`.
#[test]
fn recommended_chrome_policies_fill_defaults_only() {
    let document = doc(
        json!({}),
        json!({
            "DefaultSearchProviderSearchURL": "https://search.example.com/search?q={searchTerms}",
            "URLBlocklist": ["x.com"],
        }),
    );
    let (forced, recommended) = managed_values(&document);
    assert!(forced.is_empty());
    assert_eq!(recommended["browser.searchEngine"], "custom");
    assert!(!recommended.contains_key("URLBlocklist"));
}

/// Swift `cmuxDomainsWinOverChrome`: the browser domain over Chrome's, key by key.
#[test]
fn browser_domain_wins_over_chrome_key_by_key() {
    let own = doc(json!({ "URLBlocklist": ["x.com"] }), json!({}));
    let merged = merged(&chrome_mandatory(), &own);
    let (forced, _) = managed_values(&merged);
    assert_eq!(forced["URLBlocklist"], json!(["x.com"]));
    assert_eq!(forced["URLAllowlist"], json!(["example.org/private/handbook"]));
}

/// Swift `organizationCanOptOutOfChromePolicies`.
#[test]
fn forced_opt_out_drops_chrome_domain() {
    let opt_out = doc(json!({ "HonorChromePolicy": false, "URLBlocklist": ["x.com"] }), json!({}));
    let merged = merged(&chrome_mandatory(), &opt_out);
    let (forced, _) = managed_values(&merged);
    assert!(!forced.contains_key("browser.searchEngine"));
    assert_eq!(forced["URLBlocklist"], json!(["x.com"]));
    assert!(!merged.mandatory.contains_key("HonorChromePolicy"));
    assert_eq!(native_policy_domain(&opt_out), None);
    assert_eq!(native_policy_domain(&Document::default()), Some("com.google.Chrome"));
}

/// Swift `unusableSearchPolicyIsIgnored`.
#[test]
fn unusable_search_policy_is_ignored() {
    for search in ["https://search.example.com/?q=", "javascript:alert({searchTerms})"] {
        let document = doc(json!({ "DefaultSearchProviderSearchURL": search }), json!({}));
        assert!(!managed_values(&document).0.contains_key("browser.searchEngine"), "{search}");
    }
    let disabled = doc(
        json!({
            "DefaultSearchProviderEnabled": false,
            "DefaultSearchProviderSearchURL": "https://s.example.com/?q={searchTerms}",
        }),
        json!({}),
    );
    assert!(!managed_values(&disabled).0.contains_key("browser.searchEngine"));
}
