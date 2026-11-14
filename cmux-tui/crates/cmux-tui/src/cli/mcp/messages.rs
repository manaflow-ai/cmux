//! `cmux mcp` messages in English and Japanese, like the rest of the CLI
//! (crate::localization picks the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    /// Off because the person has not added cmux's tools to their coding
    /// agents (`agents.cmuxMcp` not `on`, no `mcp.enabled`). `{path}`: the
    /// settings file.
    pub disabled: &'static str,
    /// Off because the settings file says `"mcp": {"enabled": false}`, which
    /// wins over `agents.cmuxMcp`. `{path}`: the settings file.
    pub switched_off: &'static str,
    pub config_invalid: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n\n  serve  Serve cmux tools to an MCP client on stdin and stdout. On for cmux agent\n         chats; your own coding agents (Claude Code, Codex) get them once you choose\n         Add to My Agents in Settings > Agents > Add cmux Tools to Your Coding Agents\n         (cmux settings set agents.cmuxMcp on --confirm). It offers two tools, cmux_docs\n         and cmux_exec, that search every cmux tool and run scripts that call them;\n         --all-tools offers every tool directly\n  tools  List the tools serve offers and the operations it leaves out",
    disabled: "cmux's tools are off for your coding agents (agents.cmuxMcp is not \"on\" in {path}). To turn them on, choose Add to My Agents in cmux Settings > Agents > Add cmux Tools to Your Coding Agents, or run `cmux settings set agents.cmuxMcp on --confirm` and approve it in cmux. Then restart this agent or reconnect its cmux MCP server (/mcp in Claude Code).",
    switched_off: "cmux's MCP server is off: {path} sets \"mcp\": {\"enabled\": false}, which keeps cmux's tools from every agent outside cmux's own chats. Remove that setting from the file (or set it to true), then restart this agent or reconnect its cmux MCP server (/mcp in Claude Code).",
    config_invalid: "the MCP server stays off because the settings file cannot be read: {error}",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n\n  serve  標準入出力で MCP クライアントに cmux のツールを提供します。cmux のエージェント\n         チャットではオンです。ご自身のコーディングエージェント (Claude Code、Codex) には、設定 > エージェント >\n         「コーディングエージェントに cmux ツールを追加」で「エージェントに追加」を選ぶと提供されます\n         (cmux settings set agents.cmuxMcp on --confirm)。\n         提供するのは cmux_docs と cmux_exec の 2 つで、すべての cmux ツールを検索し、それらを呼ぶスクリプトを実行します。\n         --all-tools を付けるとすべてのツールを直接提供します\n  tools  serve が提供するツールと、除外する操作を一覧表示",
    disabled: "コーディングエージェントでの cmux のツールはオフです ({path} の agents.cmuxMcp が \"on\" ではありません)。オンにするには、cmux の設定 > エージェント > 「コーディングエージェントに cmux ツールを追加」で「エージェントに追加」を選ぶか、`cmux settings set agents.cmuxMcp on --confirm` を実行して cmux で承認してください。そのあと、このエージェントを再起動するか、cmux の MCP サーバーに再接続してください (Claude Code では /mcp)。",
    switched_off: "cmux の MCP サーバーはオフです: {path} に \"mcp\": {\"enabled\": false} があり、cmux のチャット以外のすべてのエージェントで cmux のツールが使えません。ファイルからこの設定を削除して (または true にして) から、このエージェントを再起動するか、cmux の MCP サーバーに再接続してください (Claude Code では /mcp)。",
    config_invalid: "設定ファイルを読み取れないため、MCP サーバーはオフのままです: {error}",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}

/// Every locale's messages (tests).
#[cfg(test)]
pub(super) fn all() -> [&'static Messages; 2] {
    [&ENGLISH, &JAPANESE]
}
