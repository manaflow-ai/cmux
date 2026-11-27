//! App command messages in English and Japanese (crate::localization picks
//! the language from the locale).

pub(super) struct Messages {
    pub app_usage: &'static str,
    pub usage: &'static str,
    pub see_help: &'static str,
    pub args_value: &'static str,
    pub unknown_flag: &'static str,
    pub missing_value: &'static str,
    pub bad_value: &'static str,
    pub extra_word: &'static str,
    pub missing_required: &'static str,
}

static ENGLISH: Messages = Messages {
    app_usage: "{title} ({app}): cmux {name} <command> [args]\n\nCommands:",
    usage: "usage:",
    see_help: "`cmux {name}` lists its commands",
    args_value: "--args takes a JSON object",
    unknown_flag: "--{flag} is not an argument of this command",
    missing_value: "--{flag} needs a value",
    bad_value: "--{flag} does not take {value}",
    extra_word: "{word} is not an argument of this command",
    missing_required: "missing {flags}",
};

static JAPANESE: Messages = Messages {
    app_usage: "{title} ({app}): cmux {name} <コマンド> [引数]\n\nコマンド:",
    usage: "使い方:",
    see_help: "`cmux {name}` でコマンドの一覧を表示します",
    args_value: "--args には JSON オブジェクトを指定してください",
    unknown_flag: "--{flag} はこのコマンドの引数ではありません",
    missing_value: "--{flag} には値が必要です",
    bad_value: "--{flag} に {value} は指定できません",
    extra_word: "{word} はこのコマンドの引数ではありません",
    missing_required: "{flags} が必要です",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
