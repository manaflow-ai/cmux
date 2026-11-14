// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CertificateWarningActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "CertificateWarningActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "browser.certificateWarning.proceed",
        group: GROUP,
        title: t("PageInfoActions", "action.certificateWarning.proceed", "Proceed Past Certificate Warning (Unsafe)"),
        keywords: &["certificate", "warning", "interstitial", "proceed", "unsafe", "tls", "ssl", "visit", "continue"],
        category: "browser",
        symbol: "exclamationmark.triangle",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "action browser-certificate-warning-proceed",
        is_person_only: true,
        ..Action::DEFAULT
    },
    Action {
        id: "browser.certificateWarning.goBack",
        group: GROUP,
        title: t("PageInfoActions", "action.certificateWarning.goBack", "Go Back from Certificate Warning"),
        keywords: &["certificate", "warning", "interstitial", "back", "safety", "tls", "ssl"],
        category: "browser",
        symbol: "chevron.backward",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        requires: &["browserFocused"],
        targets: &["pane"],
        cli_name: "action browser-certificate-warning-go-back",
        ..Action::DEFAULT
    },
];
