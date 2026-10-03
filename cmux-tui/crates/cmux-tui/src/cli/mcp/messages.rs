//! `cmux mcp` messages in English and Japanese, like the rest of the CLI
//! (crate::localization picks the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    pub disabled: &'static str,
    pub config_invalid: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux mcp serve | cmux mcp tools [--json]\n\n  serve  Serve cmux tools to an MCP client on stdin and stdout. Off unless\n         cmux.json sets \"mcp\": {\"enabled\": true} (cmux settings set mcp.enabled true)\n  tools  List the tools serve offers and the operations it leaves out",
    disabled: "the MCP server is off; turn it on with `cmux settings set mcp.enabled true` or \"mcp\": {\"enabled\": true} in {path}",
    config_invalid: "the MCP server stays off because the settings file cannot be read: {error}",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux mcp serve | cmux mcp tools [--json]\n\n  serve  標準入出力で MCP クライアントに cmux のツールを提供します。cmux.json で\n         \"mcp\": {\"enabled\": true} を設定しない限りオフです (cmux settings set mcp.enabled true)\n  tools  serve が提供するツールと、除外する操作を一覧表示",
    disabled: "MCP サーバーはオフです。`cmux settings set mcp.enabled true` を実行するか、{path} に \"mcp\": {\"enabled\": true} を設定してください",
    config_invalid: "設定ファイルを読み取れないため、MCP サーバーはオフのままです: {error}",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
