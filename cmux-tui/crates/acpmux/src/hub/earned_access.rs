//! Read-only earned-access preview. No permission decision consumes this projection.
//! Until stable identity and verified landing/refusal history exist, eligibility is unknown.
use serde_json::{Value, json};

/// Current acpmux policy, never a claim that this access was earned. Unknown policies and
/// Ask/DenyAll are not coerced into a ladder rung. Constant work, no history scan or I/O.
pub(super) fn preview(policy: &str) -> Value {
    let current = match policy {
        "review" => "readOnly",
        "approve-reads" => "reads",
        "approve-edits" => "edits",
        "approve-all" => "full",
        "ask" => "ask",
        "deny-all" => "denyAll",
        _ => "unknown",
    };
    json!({ "current": current, "eligibility": "unavailable" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn earned_access_preview_never_claims_earned_permissions() {
        for (policy, current) in [
            ("review", "readOnly"),
            ("approve-reads", "reads"),
            ("approve-edits", "edits"),
            ("approve-all", "full"),
            ("ask", "ask"),
            ("deny-all", "denyAll"),
            ("unknown", "unknown"),
            ("", "unknown"),
        ] {
            assert_eq!(
                preview(policy),
                json!({ "current": current, "eligibility": "unavailable" })
            );
        }
    }

    #[test]
    fn earned_access_preview_uses_effective_daemon_policy_without_mutating_metadata() {
        use crate::config::PermissionPolicy;
        use crate::store::{META_SCHEMA, SessionMeta};
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": "preview", "name": "preview", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        let before = serde_json::to_value(&meta).unwrap();
        let report = super::super::views::enforcement(&meta, Some(PermissionPolicy::ApproveAll));
        assert_eq!(report["policy"], "approve-all");
        assert_eq!(report["accessPreview"]["current"], "full");
        assert_eq!(report["accessPreview"]["eligibility"], "unavailable");
        assert_eq!(serde_json::to_value(&meta).unwrap(), before);
        meta.permission_policy = Some("review".into());
        let report = super::super::views::enforcement(&meta, Some(PermissionPolicy::ApproveAll));
        assert_eq!(report["policy"], "review");
        assert_eq!(report["accessPreview"]["current"], "readOnly");
    }
}
