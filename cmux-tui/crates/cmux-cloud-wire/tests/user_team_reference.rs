use cmux_cloud_wire::UserTeamsListResult;
use serde_json::{Value, json};

fn roundtrip(value: Value) -> Value {
    let listing: UserTeamsListResult = serde_json::from_value(value).unwrap();
    serde_json::to_value(listing).unwrap()
}

#[test]
fn user_team_reference_survives_the_generated_client() {
    // Equal names do not merge the two owner identities or their opaque references.
    let listing = json!({"teams": [
        {"id": "team_aaaaaaaaaaaaaaaaaaaa", "display_name": "Team", "kind": "stack",
         "stack_team": "stack-team-one", "role": "member", "sso_required": false},
        {"id": "team_bbbbbbbbbbbbbbbbbbbb", "display_name": "Team", "kind": "stack",
         "stack_team": "stack-team-two", "role": "admin", "sso_required": true}
    ], "incomplete": false});
    assert_eq!(roundtrip(listing.clone()), listing);
}

#[test]
fn user_team_reference_remains_optional_for_personal_and_older_listings() {
    let listing = json!({"teams": [
        {"id": "team_cccccccccccccccccccc", "display_name": "", "kind": "personal",
         "role": "owner", "sso_required": false},
        {"id": "team_aaaaaaaaaaaaaaaaaaaa", "display_name": "Old team", "kind": "stack",
         "role": "member", "sso_required": false}
    ], "incomplete": true});
    assert_eq!(roundtrip(listing.clone()), listing);
}
