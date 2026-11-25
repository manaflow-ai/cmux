//! `cmux mcp` messages in English and Japanese, like the rest of the CLI
//! (crate::localization picks the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    pub disabled: &'static str,
    pub config_invalid: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n\n  serve  Serve cmux tools to an MCP client on stdin and stdout. On for cmux agent\n         chats; other clients need \"mcp\": {\"enabled\": true} (cmux settings set mcp.enabled true).\n         It offers two tools, cmux_docs and cmux_exec, that search every cmux tool and\n         run scripts that call them; --all-tools offers every tool directly\n  tools  List the tools serve offers and the operations it leaves out",
    disabled: "the MCP server is off; turn it on with `cmux settings set mcp.enabled true` or \"mcp\": {\"enabled\": true} in {path}",
    config_invalid: "the MCP server stays off because the settings file cannot be read: {error}",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n\n  serve  標準入出力で MCP クライアントに cmux のツールを提供します。cmux のエージェント\n         チャットではオンです。ほかのクライアントには \"mcp\": {\"enabled\": true} が必要です (cmux settings set mcp.enabled true)。\n         提供するのは cmux_docs と cmux_exec の 2 つで、すべての cmux ツールを検索し、それらを呼ぶスクリプトを実行します。\n         --all-tools を付けるとすべてのツールを直接提供します\n  tools  serve が提供するツールと、除外する操作を一覧表示",
    disabled: "MCP サーバーはオフです。`cmux settings set mcp.enabled true` を実行するか、{path} に \"mcp\": {\"enabled\": true} を設定してください",
    config_invalid: "設定ファイルを読み取れないため、MCP サーバーはオフのままです: {error}",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
