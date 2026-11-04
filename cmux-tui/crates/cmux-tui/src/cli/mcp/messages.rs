//! `cmux mcp` messages in English and Japanese, like the rest of the CLI
//! (crate::localization picks the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    pub disabled: &'static str,
    pub config_invalid: &'static str,
    pub connections_usage: &'static str,
    pub key_not_taken: &'static str,
    pub not_found: &'static str,
    pub no_connections: &'static str,
    pub no_tools: &'static str,
    pub audit_empty: &'static str,
    pub verified: &'static str,
    pub unverified: &'static str,
    pub tool_count: &'static str,
    pub removed: &'static str,
    pub opened_auth: &'static str,
    pub opened_key: &'static str,
    pub opened_policy: &'static str,
    pub opened_approve_tools: &'static str,
    pub held_mark: &'static str,
    pub held_count: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n       cmux mcp ls [--json] | cmux mcp tools NAME [--json] | cmux mcp audit [--limit N] [--json]\n       cmux mcp rm NAME | cmux mcp auth NAME | cmux mcp key NAME | cmux mcp policy NAME [TOOL always|ask|never] | cmux mcp approve-tools NAME\n\n  serve   Serve cmux tools to an MCP client on stdin and stdout. On for cmux agent\n          chats; other clients need \"mcp\": {\"enabled\": true} (cmux settings set mcp.enabled true).\n          It offers two tools, cmux_docs and cmux_exec, that search every cmux tool and\n          run scripts that call them; --all-tools offers every tool directly\n  tools   Without NAME: list the tools serve offers and the operations it leaves out\n\n  MCP servers your agents connected (Settings > MCP Servers):\n  ls      List them: name, state, scope, publisher and whether cmux verified it, URL\n  tools NAME  List the tools of one server and each tool's policy\n  audit   Print the newest lines of the MCP audit log (digests only, never values)\n  rm      Remove a server and its key or sign-in\n  auth, key, policy, approve-tools  Change nothing: open Settings > MCP Servers at that server,\n          where you sign in, type a key, set a policy or approve tools that changed (held). An agent can run this CLI, so it never adds access\n          and never takes a key as an argument",
    disabled: "the MCP server is off; turn it on with `cmux settings set mcp.enabled true` or \"mcp\": {\"enabled\": true} in {path}",
    config_invalid: "the MCP server stays off because the settings file cannot be read: {error}",
    connections_usage: "usage: cmux mcp ls | tools NAME | audit [--limit N] | rm NAME | auth NAME | key NAME | policy NAME [TOOL POLICY] | approve-tools NAME (cmux mcp --help)",
    key_not_taken: "cmux mcp key takes only the server's name: the CLI never takes a key. Run cmux mcp key NAME and type the key in Settings > MCP Servers",
    not_found: "no MCP server is named {name} (cmux mcp ls lists them)",
    no_connections: "No MCP servers are connected.",
    no_tools: "This server has no approved tools.",
    audit_empty: "The MCP audit log is empty.",
    verified: "verified",
    unverified: "not verified",
    tool_count: "{count} tools",
    removed: "Removed {name}.",
    opened_auth: "Opened Settings > MCP Servers at {name}. Click Sign In there: the CLI does not sign in.",
    opened_key: "Opened Settings > MCP Servers at {name}. Type the key there: the CLI never takes a key.",
    opened_policy: "Opened Settings > MCP Servers at {name}. Set the tool's policy there: the CLI does not change policies.",
    opened_approve_tools: "Opened Settings > MCP Servers at {name}. Review the changed tools and click Approve Changed Tools there: the CLI does not approve tools.",
    held_mark: "\theld: changed, waits for your approval",
    held_count: "{count} held",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux mcp serve [--all-tools] | cmux mcp tools [--json]\n        cmux mcp ls [--json] | cmux mcp tools 名前 [--json] | cmux mcp audit [--limit N] [--json]\n        cmux mcp rm 名前 | cmux mcp auth 名前 | cmux mcp key 名前 | cmux mcp policy 名前 [ツール always|ask|never] | cmux mcp approve-tools 名前\n\n  serve   標準入出力で MCP クライアントに cmux のツールを提供します。cmux のエージェント\n          チャットではオンです。ほかのクライアントには \"mcp\": {\"enabled\": true} が必要です (cmux settings set mcp.enabled true)。\n          提供するのは cmux_docs と cmux_exec の 2 つで、すべての cmux ツールを検索し、それらを呼ぶスクリプトを実行します。\n          --all-tools を付けるとすべてのツールを直接提供します\n  tools   名前なし: serve が提供するツールと、除外する操作を一覧表示\n\n  エージェントが接続した MCP サーバー (設定 > MCP サーバー):\n  ls      一覧表示: 名前、状態、範囲、発行元と cmux による確認の有無、URL\n  tools 名前  1 つのサーバーのツールと各ツールのポリシーを一覧表示\n  audit   MCP 監査ログの新しい行を表示 (ダイジェストのみ。値は含みません)\n  rm      サーバーと、そのキーまたはサインインを削除\n  auth, key, policy, approve-tools  何も変更しません。そのサーバーの位置で 設定 > MCP サーバー を開きます。\n          サインイン、キーの入力、ポリシーの設定、変更されたツール (保留中) の承認はそこで行います。エージェントもこの CLI を実行できるため、\n          CLI がアクセスを増やすことはなく、キーを引数として受け取ることもありません",
    disabled: "MCP サーバーはオフです。`cmux settings set mcp.enabled true` を実行するか、{path} に \"mcp\": {\"enabled\": true} を設定してください",
    config_invalid: "設定ファイルを読み取れないため、MCP サーバーはオフのままです: {error}",
    connections_usage: "使い方: cmux mcp ls | tools 名前 | audit [--limit N] | rm 名前 | auth 名前 | key 名前 | policy 名前 [ツール ポリシー] | approve-tools 名前 (cmux mcp --help)",
    key_not_taken: "cmux mcp key にはサーバー名だけを指定します。CLI はキーを受け取りません。cmux mcp key 名前 を実行し、設定 > MCP サーバー でキーを入力してください",
    not_found: "{name} という名前の MCP サーバーはありません (cmux mcp ls で一覧表示)",
    no_connections: "接続された MCP サーバーはありません。",
    no_tools: "このサーバーには承認済みのツールがありません。",
    audit_empty: "MCP 監査ログは空です。",
    verified: "確認済み",
    unverified: "未確認",
    tool_count: "ツール {count} 個",
    removed: "{name} を削除しました。",
    opened_auth: "{name} の位置で 設定 > MCP サーバー を開きました。そこで「サインイン」をクリックしてください。CLI はサインインしません。",
    opened_key: "{name} の位置で 設定 > MCP サーバー を開きました。そこでキーを入力してください。CLI はキーを受け取りません。",
    opened_policy: "{name} の位置で 設定 > MCP サーバー を開きました。そこでツールのポリシーを設定してください。CLI はポリシーを変更しません。",
    opened_approve_tools: "{name} の位置で 設定 > MCP サーバー を開きました。変更されたツールを確認し、そこで「変更されたツールを承認」をクリックしてください。CLI はツールを承認しません。",
    held_mark: "\t保留中: 変更あり、承認待ち",
    held_count: "保留中 {count} 個",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
