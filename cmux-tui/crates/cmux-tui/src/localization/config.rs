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
        self.invalid_macos_option_as_alt.replace("{value}", value)
    }
    pub(crate) fn invalid_section(&self, value: &str) -> String {
        self.invalid_section.replace("{section}", value)
    }
    pub(crate) fn unknown_field(&self, value: &str) -> String {
        self.unknown_field.replace("{field}", value)
    }
    pub(crate) fn invalid_root(&self) -> &'static str {
        self.invalid_root
    }
    pub(crate) fn write_durability_warning(&self, error: &str) -> String {
        self.write_durability_warning.replace("{error}", error)
    }
}

pub(super) const ENGLISH: ConfigMessages = ConfigMessages {
    invalid_macos_option_as_alt: "cmux-tui: ignoring non-boolean keys.macos_option_as_alt = {value}",
    invalid_section: "cmux-tui: ignoring invalid config section {section}",
    unknown_field: "cmux-tui: ignoring unknown config field {field}",
    invalid_root: "cmux-tui: ignoring config because the root value is not an object",
    write_durability_warning: "cmux-tui: config write committed, but parent directory durability is unconfirmed: {error}",
};

pub(super) const JAPANESE: ConfigMessages = ConfigMessages {
    invalid_macos_option_as_alt: "cmux-tui: 真偽値ではない keys.macos_option_as_alt = {value} を無視します",
    invalid_section: "cmux-tui: 無効な設定セクション {section} を無視します",
    unknown_field: "cmux-tui: 不明な設定フィールド {field} を無視します",
    invalid_root: "cmux-tui: ルート値がオブジェクトではないため設定を無視します",
    write_durability_warning: "cmux-tui: 設定の書き込みは完了しましたが、親ディレクトリの永続性を確認できません: {error}",
};
