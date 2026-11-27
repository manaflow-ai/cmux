//! `cmux-window-rules::onboarding` over the JSON channel (ops
//! `onboarding_*`): the onboarding tool window's footer and Import from
//! Browser's selection rules. The app keeps the window, the detection, the
//! Keychain and the Touch ID sheet, sends the facts and runs the answer.

use cmux_window_rules::onboarding;
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    // `onboarding_first_run_*` is the narrower `onboarding_first_run` module's.
    operation.starts_with(b"onboarding_") && !operation.starts_with(b"onboarding_first_run_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Kinds {
    #[serde(default)]
    password_store: bool,
    #[serde(default)]
    preset: Vec<onboarding::ImportKind>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Browsers {
    #[serde(default)]
    browsers: Vec<String>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The tool window's footer: the primary button, Skip, Back.
        b"onboarding_footer" => {
            serde_json::to_value(onboarding::footer(&read(request)?)).map_err(|_| ERR_INVALID)?
        }
        // Import from Browser's selection rules for the step's facts.
        b"onboarding_import" => {
            let facts: onboarding::ImportFacts = read(request)?;
            json!({
                "canEditSelection": facts.phase.can_edit_selection(),
                "canStart": facts.can_start(),
                "offersPasswordCsv": facts.offers_password_csv(),
                "explainerProgress": facts.phase.explainer_progress(),
            })
        }
        // The kinds offered, checked at first, and checked by a preset.
        b"onboarding_kinds" => {
            let request: Kinds = read(request)?;
            json!({
                "choices": onboarding::kind_choices(request.password_store),
                "defaults": onboarding::default_kinds(),
                "preset": onboarding::preset_kinds(&request.preset, request.password_store),
            })
        }
        // The detected browsers in list order (indices): Edge first.
        b"onboarding_edge_first" => {
            json!({ "order": onboarding::edge_first(&read::<Browsers>(request)?.browsers) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
