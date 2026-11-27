//! `IPhoneDevAutoApprove`: in a tagged dev build (`com.cmuxterm.app.debug.<tag>`, DEBUG), the same
//! tag's iPhone app (`dev.cmux.mobile.<tag>`) of the signed-in account pairs without the prompt;
//! a dev iPhone app asking any other Mac build waits quietly (cmux-next-ios/SECURITY.md "Dev auto-approve").

/// The launch variable that keeps the Allow prompt (`1`).
pub const APPROVE_FIRST_KEY: &str = "CMUX_NEXT_IPHONE_APPROVE_FIRST";
/// The bundle id prefix of a tagged dev iPhone app; the rest is its tag's slug.
pub const PHONE_BUNDLE_PREFIX: &str = "dev.cmux.mobile.";
/// The only Mac bundle ids that may auto-approve: tagged dev builds.
pub const MAC_BUNDLE_PREFIX: &str = "com.cmuxterm.app.debug.";

/// The tag of a tagged dev build: its kind is `dev`, its bundle id has the dev prefix and its tag is not empty.
pub fn dev_tag(kind: &str, bundle_id: Option<&str>, tag: Option<&str>) -> Option<String> {
    let bundle_id = bundle_id?;
    if kind != "dev" || !bundle_id.to_lowercase().starts_with(MAC_BUNDLE_PREFIX) {
        return None;
    }
    tag.filter(|tag| !tag.is_empty()).map(str::to_owned)
}

/// This launch's auto-approve tag: a DEBUG binary, no `CMUX_NEXT_IPHONE_APPROVE_FIRST=1`, a tagged dev build.
pub fn auto_approve_tag(
    kind: &str,
    bundle_id: Option<&str>,
    tag: Option<&str>,
    approve_first: Option<&str>,
    debug_build: bool,
) -> Option<String> {
    if !debug_build || approve_first == Some("1") {
        return None;
    }
    dev_tag(kind, bundle_id, tag)
}

/// The dev iPhone app's tag of a request: nil for a machine (`kind` not `phone`), another app or none.
pub fn phone_tag(kind: &str, bundle_id: Option<&str>) -> Option<String> {
    if kind != "phone" {
        return None;
    }
    let bundle_id = bundle_id?.to_lowercase();
    let tag = bundle_id.strip_prefix(PHONE_BUNDLE_PREFIX)?;
    (!tag.is_empty()).then(|| tag.to_owned())
}

/// Whether the request waits without prompt, banner or Dock bounce on a Mac of dev tag `mac_dev_tag`.
pub fn asks_quietly(kind: &str, bundle_id: Option<&str>, mac_dev_tag: Option<&str>) -> bool {
    phone_tag(kind, bundle_id).is_some_and(|phone| Some(phone.as_str()) != mac_dev_tag)
}

/// `IPhoneHostService.devAutoApproves`: the auto-approve of tag `auto_tag` takes the request of the
/// account's own user (`paired_user_id`, the signed-in `account_user_id`) when its phone tag matches.
pub fn approves(
    kind: &str,
    bundle_id: Option<&str>,
    auto_tag: Option<&str>,
    paired_user_id: &str,
    account_user_id: Option<&str>,
) -> bool {
    let (Some(auto_tag), Some(account)) = (auto_tag, account_user_id) else { return false };
    if account.is_empty() || paired_user_id != account {
        return false;
    }
    phone_tag(kind, bundle_id).as_deref() == Some(auto_tag)
}
