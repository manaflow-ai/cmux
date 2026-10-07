//! `config` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ConfigMessages {
    pub(super) invalid_macos_option_as_alt: &'static str,
    pub(super) invalid_section: &'static str,
    pub(super) unknown_field: &'static str,
    pub(super) invalid_root: &'static str,
    pub(super) write_durability_warning: &'static str,
}

impl ConfigMessages {
    pub(crate) fn invalid_macos_option_as_alt(&self, value: &str) -> String {
        program(self.invalid_macos_option_as_alt).replace("{value}", value)
    }
    pub(crate) fn invalid_section(&self, value: &str) -> String {
        program(self.invalid_section).replace("{section}", value)
    }
    pub(crate) fn unknown_field(&self, value: &str) -> String {
        program(self.unknown_field).replace("{field}", value)
    }
    pub(crate) fn invalid_root(&self) -> String {
        program(self.invalid_root)
    }
    pub(crate) fn write_durability_warning(&self, error: &str) -> String {
        program(self.write_durability_warning).replace("{error}", error)
    }
}

/// Puts the name this process was run as in place of `{program}`.
fn program(template: &str) -> String {
    template.replace("{program}", &crate::cli::BIN.to_string())
}

pub(super) const ENGLISH: ConfigMessages = ConfigMessages {
    invalid_macos_option_as_alt: "{program}: ignoring non-boolean keys.macos_option_as_alt = {value}",
    invalid_section: "{program}: ignoring invalid config section {section}",
    unknown_field: "{program}: ignoring unknown config field {field}",
    invalid_root: "{program}: ignoring config because the root value is not an object",
    write_durability_warning: "{program}: config write committed, but parent directory durability is unconfirmed: {error}",
};

pub(super) const JAPANESE: ConfigMessages = ConfigMessages {
    invalid_macos_option_as_alt: "{program}: 真偽値ではない keys.macos_option_as_alt = {value} を無視します",
    invalid_section: "{program}: 無効な設定セクション {section} を無視します",
    unknown_field: "{program}: 不明な設定フィールド {field} を無視します",
    invalid_root: "{program}: ルート値がオブジェクトではないため設定を無視します",
    write_durability_warning: "{program}: 設定の書き込みは完了しましたが、親ディレクトリの永続性を確認できません: {error}",
};
