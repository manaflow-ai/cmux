// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, PR_NUMBER).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

/// The sign-in/session phase a deadline applies to. Used as the stable label
/// in timeout diagnostics so a stuck-at-sign-in report names the exact phase.
enum AuthPhase: String, Sendable, Hashable {
    case sendCode = "send_code"
    case verifyCode = "verify_code"
    case passwordSignIn = "password_sign_in"
    case oauth = "oauth"
    case accessToken = "access_token"
    case forceRefreshAccessToken = "force_refresh_access_token"
    case fetchUser = "fetch_user"
    case validateSession = "validate_session"
    case listTeams = "list_teams"
    case teamSelection = "team_selection"
    case teamManagement = "team_management"
    case postSignIn = "post_sign_in"
    case accountDeletion = "account_deletion"
    case pushRegistrationSession = "push_registration_session"
    case pushUnregistrationSession = "push_unregistration_session"
}
