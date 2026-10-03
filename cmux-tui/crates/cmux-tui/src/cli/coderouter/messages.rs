//! Account-handle strings for `cmux coderouter` and `cmux accounts list`, in
//! English and Japanese like the main catalog (crate::localization).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AccountMessages {
    pub account_email_selector: &'static str,
    pub no_accounts: &'static str,
    pub status_signed_in: &'static str,
    pub status_signed_out: &'static str,
    pub handles_unstable: &'static str,
}

const ENGLISH: AccountMessages = AccountMessages {
    account_email_selector: "select the account by its acct_… handle (cmux coderouter claude list)",
    no_accounts: "no Claude upstream accounts",
    status_signed_in: "signed in",
    status_signed_out: "not signed in",
    handles_unstable: "account handles change after restart: Keychain unavailable",
};

const JAPANESE: AccountMessages = AccountMessages {
    account_email_selector: "アカウントは acct_… ハンドルで選択してください (cmux coderouter claude list)",
    no_accounts: "Claude アップストリームアカウントはありません",
    status_signed_in: "サインイン済み",
    status_signed_out: "サインインしていません",
    handles_unstable: "アカウントのハンドルは再起動後に変わります: キーチェーンを使用できません",
};

/// The strings for the process locale: Japanese exactly when the main
/// catalog is the Japanese one.
pub(crate) fn messages() -> &'static AccountMessages {
    let japanese =
        std::ptr::eq(crate::localization::catalog(), crate::localization::catalog_for_locale("ja"));
    if japanese { &JAPANESE } else { &ENGLISH }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_string_is_translated() {
        assert_ne!(ENGLISH, JAPANESE);
        for (english, japanese) in [
            (ENGLISH.account_email_selector, JAPANESE.account_email_selector),
            (ENGLISH.no_accounts, JAPANESE.no_accounts),
            (ENGLISH.status_signed_in, JAPANESE.status_signed_in),
            (ENGLISH.status_signed_out, JAPANESE.status_signed_out),
            (ENGLISH.handles_unstable, JAPANESE.handles_unstable),
        ] {
            assert!(!japanese.is_empty() && english != japanese, "{english}");
        }
    }
}
