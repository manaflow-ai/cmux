use std::borrow::Cow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Locale {
    English,
    Japanese,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticAction {
    SpawnWorker,
    ParseWebSocketUrl,
    BearerHeader,
    ConnectAppServer,
    ConfigureSocket,
    SendInitialized,
    ReadBearerToken,
    DecodeThreadList,
    DecodeThreadRead,
    DecodeThreadMetadata,
    DecodeThreadTurns,
    DecodeAppServerJson,
    EncodeAppServerJson,
    WriteAppServerMessage,
}

impl Locale {
    pub fn detect() -> Self {
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if std::env::var(key)
                .ok()
                .is_some_and(|value| value.to_ascii_lowercase().starts_with("ja"))
            {
                return Self::Japanese;
            }
        }
        Self::English
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Catalog {
    locale: Locale,
}

impl Catalog {
    pub const fn new(locale: Locale) -> Self {
        Self { locale }
    }

    pub const fn title(self) -> &'static str {
        self.pick("cmux tree", "cmux tree")
    }

    pub const fn machines(self) -> &'static str {
        self.pick("machines", "マシン")
    }

    pub const fn conversations(self) -> &'static str {
        self.pick("conversations", "会話")
    }

    pub const fn trajectory(self) -> &'static str {
        self.pick("trajectory", "軌跡")
    }

    pub const fn add_machine(self) -> &'static str {
        self.pick("add machine", "マシンを追加")
    }

    pub const fn no_machines(self) -> &'static str {
        self.pick("Add a Codex app server.", "Codex app server を追加してください。")
    }

    pub const fn no_conversations(self) -> &'static str {
        self.pick("No Codex conversations.", "Codex の会話はありません。")
    }

    pub const fn select_conversation(self) -> &'static str {
        self.pick("Select a conversation.", "会話を選択してください。")
    }

    pub const fn loading(self) -> &'static str {
        self.pick("loading", "読み込み中")
    }

    pub const fn connecting(self) -> &'static str {
        self.pick("connecting", "接続中")
    }

    pub const fn connected(self) -> &'static str {
        self.pick("connected", "接続済み")
    }

    pub const fn disconnected(self) -> &'static str {
        self.pick("disconnected", "未接続")
    }

    pub const fn active(self) -> &'static str {
        self.pick("working", "作業中")
    }

    pub const fn idle(self) -> &'static str {
        self.pick("stopped", "停止")
    }

    pub const fn not_loaded(self) -> &'static str {
        self.pick("stored", "保存済み")
    }

    pub const fn system_error(self) -> &'static str {
        self.pick("error", "エラー")
    }

    pub const fn waiting_approval(self) -> &'static str {
        self.pick("approval", "承認待ち")
    }

    pub const fn waiting_input(self) -> &'static str {
        self.pick("input", "入力待ち")
    }

    pub const fn unnamed(self) -> &'static str {
        self.pick("Untitled conversation", "無題の会話")
    }

    pub const fn add_title(self) -> &'static str {
        self.pick("Add Codex app server", "Codex app server を追加")
    }

    pub const fn machine_name(self) -> &'static str {
        self.pick("Name", "名前")
    }

    pub const fn websocket_url(self) -> &'static str {
        self.pick("WebSocket URL", "WebSocket URL")
    }

    pub const fn token_file(self) -> &'static str {
        self.pick("Bearer token file (optional)", "Bearer token ファイル（任意）")
    }

    pub const fn save(self) -> &'static str {
        self.pick("Save", "保存")
    }

    pub const fn cancel(self) -> &'static str {
        self.pick("Esc cancel", "Esc キャンセル")
    }

    pub const fn invalid_name(self) -> &'static str {
        self.pick("Machine name is required.", "マシン名が必要です。")
    }

    pub const fn invalid_url(self) -> &'static str {
        self.pick(
            "URL must start with ws:// or wss://.",
            "URL は ws:// または wss:// で始めてください。",
        )
    }

    pub const fn config_saved(self) -> &'static str {
        self.pick("Machine saved.", "マシンを保存しました。")
    }

    pub fn app_server_error(self, details: &str) -> String {
        match self.locale {
            Locale::English => format!("Codex app-server error: {details}"),
            Locale::Japanese => format!("Codex app-server エラー: {details}"),
        }
    }

    pub fn config_error(self, details: &str) -> String {
        match self.locale {
            Locale::English => format!("Could not save machine: {details}"),
            Locale::Japanese => format!("マシンを保存できませんでした: {details}"),
        }
    }

    pub fn invalid_config(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("invalid config {path}"),
            Locale::Japanese => format!("設定ファイルが無効です: {path}"),
        }
    }

    pub fn invalid_machine_config(self, name: &str, path: &str) -> String {
        match self.locale {
            Locale::English => format!("invalid machine '{name}' in {path}"),
            Locale::Japanese => format!("{path} のマシン「{name}」が無効です"),
        }
    }

    pub fn read_config(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("read config {path}"),
            Locale::Japanese => format!("設定ファイルを読み取り: {path}"),
        }
    }

    pub fn create_config_directory(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("create config directory {path}"),
            Locale::Japanese => format!("設定ディレクトリを作成: {path}"),
        }
    }

    pub const fn serialize_config(self) -> &'static str {
        self.pick("serialize config", "設定をシリアライズ")
    }

    pub fn write_config(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("write config {path}"),
            Locale::Japanese => format!("設定ファイルを書き込み: {path}"),
        }
    }

    pub fn replace_config(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("replace config {path}"),
            Locale::Japanese => format!("設定ファイルを置換: {path}"),
        }
    }

    pub fn set_config_permissions(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("set config permissions {path}"),
            Locale::Japanese => format!("設定ファイルの権限を設定: {path}"),
        }
    }

    pub fn diagnostic(self, action: DiagnosticAction, target: Option<&str>) -> String {
        let description = match (self.locale, action) {
            (Locale::English, DiagnosticAction::SpawnWorker) => "spawn Codex app-server worker",
            (Locale::English, DiagnosticAction::ParseWebSocketUrl) => "parse WebSocket URL",
            (Locale::English, DiagnosticAction::BearerHeader) => "create bearer token header",
            (Locale::English, DiagnosticAction::ConnectAppServer) => "connect to Codex app-server",
            (Locale::English, DiagnosticAction::ConfigureSocket) => "configure app-server socket",
            (Locale::English, DiagnosticAction::SendInitialized) => "send initialized notification",
            (Locale::English, DiagnosticAction::ReadBearerToken) => "read bearer token",
            (Locale::English, DiagnosticAction::DecodeThreadList) => "decode thread/list response",
            (Locale::English, DiagnosticAction::DecodeThreadRead) => "decode thread/read response",
            (Locale::English, DiagnosticAction::DecodeThreadMetadata) => "decode thread metadata",
            (Locale::English, DiagnosticAction::DecodeThreadTurns) => "decode thread turns",
            (Locale::English, DiagnosticAction::DecodeAppServerJson) => "decode app-server JSON",
            (Locale::English, DiagnosticAction::EncodeAppServerJson) => "encode app-server JSON",
            (Locale::English, DiagnosticAction::WriteAppServerMessage) => {
                "write app-server message"
            }
            (Locale::Japanese, DiagnosticAction::SpawnWorker) => "Codex app-server ワーカーを起動",
            (Locale::Japanese, DiagnosticAction::ParseWebSocketUrl) => "WebSocket URL を解析",
            (Locale::Japanese, DiagnosticAction::BearerHeader) => "Bearer token ヘッダーを作成",
            (Locale::Japanese, DiagnosticAction::ConnectAppServer) => "Codex app-server へ接続",
            (Locale::Japanese, DiagnosticAction::ConfigureSocket) => "app-server ソケットを設定",
            (Locale::Japanese, DiagnosticAction::SendInitialized) => "initialized 通知を送信",
            (Locale::Japanese, DiagnosticAction::ReadBearerToken) => "Bearer token を読み取り",
            (Locale::Japanese, DiagnosticAction::DecodeThreadList) => "thread/list 応答をデコード",
            (Locale::Japanese, DiagnosticAction::DecodeThreadRead) => "thread/read 応答をデコード",
            (Locale::Japanese, DiagnosticAction::DecodeThreadMetadata) => {
                "スレッドのメタデータをデコード"
            }
            (Locale::Japanese, DiagnosticAction::DecodeThreadTurns) => "スレッドのターンをデコード",
            (Locale::Japanese, DiagnosticAction::DecodeAppServerJson) => {
                "app-server JSON をデコード"
            }
            (Locale::Japanese, DiagnosticAction::EncodeAppServerJson) => {
                "app-server JSON をエンコード"
            }
            (Locale::Japanese, DiagnosticAction::WriteAppServerMessage) => {
                "app-server メッセージを書き込み"
            }
        };
        target.map_or_else(|| description.to_string(), |target| format!("{description}: {target}"))
    }

    pub fn empty_bearer_token(self, path: &str) -> String {
        match self.locale {
            Locale::English => format!("bearer token file is empty: {path}"),
            Locale::Japanese => format!("Bearer token ファイルが空です: {path}"),
        }
    }

    pub fn repeated_pagination_cursor(self, method: &str) -> String {
        match self.locale {
            Locale::English => format!("{method} repeated a pagination cursor"),
            Locale::Japanese => format!("{method} が同じページカーソルを返しました"),
        }
    }

    pub fn app_server_response_error(self, code: i64, message: &str) -> String {
        match self.locale {
            Locale::English => format!("app-server {code}: {message}"),
            Locale::Japanese => format!("app-server エラー {code}: {message}"),
        }
    }

    pub fn request_timed_out(self, method: &str) -> String {
        match self.locale {
            Locale::English => format!("{method} timed out"),
            Locale::Japanese => format!("{method} がタイムアウトしました"),
        }
    }

    pub const fn unknown_app_server_error(self) -> &'static str {
        self.pick("unknown app-server error", "不明な app-server エラー")
    }

    pub const fn app_server_closed(self) -> &'static str {
        self.pick("app-server closed the connection", "app-server が接続を閉じました")
    }

    pub const fn connection_closed(self) -> &'static str {
        self.pick("connection closed", "接続が閉じられました")
    }

    pub const fn read_only_observer(self) -> &'static str {
        self.pick("cmux tree is a read-only observer", "cmux tree は読み取り専用のオブザーバーです")
    }

    pub const fn work(self) -> &'static str {
        self.pick("work", "作業")
    }

    pub const fn steps(self) -> &'static str {
        self.pick("steps", "ステップ")
    }

    pub const fn you(self) -> &'static str {
        self.pick("you", "あなた")
    }

    pub const fn codex(self) -> &'static str {
        self.pick("codex", "codex")
    }

    pub const fn turn(self) -> &'static str {
        self.pick("turn", "ターン")
    }

    pub const fn in_progress(self) -> &'static str {
        self.pick("running", "実行中")
    }

    pub const fn completed(self) -> &'static str {
        self.pick("completed", "完了")
    }

    pub const fn failed(self) -> &'static str {
        self.pick("failed", "失敗")
    }

    pub const fn interrupted(self) -> &'static str {
        self.pick("interrupted", "中断")
    }

    pub const fn reasoning(self) -> &'static str {
        self.pick("thinking", "思考")
    }

    pub const fn command(self) -> &'static str {
        self.pick("command", "コマンド")
    }

    pub const fn file_change(self) -> &'static str {
        self.pick("file change", "ファイル変更")
    }

    pub const fn mcp_tool(self) -> &'static str {
        self.pick("MCP tool", "MCP ツール")
    }

    pub const fn dynamic_tool(self) -> &'static str {
        self.pick("tool", "ツール")
    }

    pub const fn collaboration(self) -> &'static str {
        self.pick("subagent", "サブエージェント")
    }

    pub const fn web_search(self) -> &'static str {
        self.pick("web search", "ウェブ検索")
    }

    pub const fn image(self) -> &'static str {
        self.pick("image", "画像")
    }

    pub const fn sleep(self) -> &'static str {
        self.pick("wait", "待機")
    }

    pub const fn plan(self) -> &'static str {
        self.pick("plan", "計画")
    }

    pub const fn review(self) -> &'static str {
        self.pick("review", "レビュー")
    }

    pub const fn compaction(self) -> &'static str {
        self.pick("context compaction", "コンテキスト圧縮")
    }

    pub const fn details(self) -> &'static str {
        self.pick("details", "詳細")
    }

    pub const fn working_directory(self) -> &'static str {
        self.pick("cwd", "作業ディレクトリ")
    }

    pub const fn output(self) -> &'static str {
        self.pick("output", "出力")
    }

    pub const fn arguments(self) -> &'static str {
        self.pick("arguments", "引数")
    }

    pub const fn result(self) -> &'static str {
        self.pick("result", "結果")
    }

    pub const fn changes(self) -> &'static str {
        self.pick("changes", "変更")
    }

    pub const fn error(self) -> &'static str {
        self.pick("error", "エラー")
    }

    pub const fn unknown(self) -> &'static str {
        self.pick("unknown", "不明")
    }

    pub const fn empty(self) -> &'static str {
        self.pick("(empty)", "（空）")
    }

    pub const fn key_help(self) -> &'static str {
        self.pick(
            "tab/h/l columns  j/k move  enter expand  pgup/pgdn scroll  a add  r refresh  q quit",
            "tab/h/l 列  j/k 移動  enter 展開  pgup/pgdn スクロール  a 追加  r 更新  q 終了",
        )
    }

    pub fn status(self, status: &str, flags: &[String]) -> &'static str {
        if status == "active" {
            if flags.iter().any(|flag| flag == "waitingOnApproval") {
                self.waiting_approval()
            } else if flags.iter().any(|flag| flag == "waitingOnUserInput") {
                self.waiting_input()
            } else {
                self.active()
            }
        } else {
            match status {
                "idle" => self.idle(),
                "notLoaded" => self.not_loaded(),
                "systemError" => self.system_error(),
                _ => self.disconnected(),
            }
        }
    }

    pub fn item_label(self, item_type: &str) -> Cow<'static, str> {
        Cow::Borrowed(match item_type {
            "reasoning" => self.reasoning(),
            "commandExecution" => self.command(),
            "fileChange" => self.file_change(),
            "mcpToolCall" => self.mcp_tool(),
            "dynamicToolCall" => self.dynamic_tool(),
            "collabAgentToolCall" | "collabToolCall" | "subAgentActivity" => self.collaboration(),
            "webSearch" => self.web_search(),
            "imageView" | "imageGeneration" => self.image(),
            "sleep" => self.sleep(),
            "plan" => self.plan(),
            "enteredReviewMode" | "exitedReviewMode" => self.review(),
            "contextCompaction" => self.compaction(),
            _ => self.details(),
        })
    }

    pub const fn help(self) -> &'static str {
        self.pick(
            "Usage: cmux-tree [--config PATH]\n\nConnects directly to Codex app-server WebSocket endpoints configured in the TUI.",
            "使い方: cmux-tree [--config PATH]\n\nTUI に設定した Codex app-server の WebSocket エンドポイントへ直接接続します。",
        )
    }

    pub const fn interactive_terminal_required(self) -> &'static str {
        self.pick(
            "cmux-tree requires an interactive terminal",
            "cmux-tree には対話型ターミナルが必要です",
        )
    }

    pub const fn config_path_required(self) -> &'static str {
        self.pick("--config requires a path", "--config にはパスが必要です")
    }

    pub const fn utf8_arguments_required(self) -> &'static str {
        self.pick("arguments must be valid UTF-8", "引数は有効な UTF-8 である必要があります")
    }

    pub fn unknown_argument(self, value: &str) -> String {
        match self.locale {
            Locale::English => format!("unknown argument: {value}"),
            Locale::Japanese => format!("不明な引数: {value}"),
        }
    }

    pub fn elapsed(self, seconds: i64) -> String {
        let seconds = seconds.max(0);
        match self.locale {
            Locale::English if seconds < 60 => format!("{seconds}s"),
            Locale::English if seconds < 3_600 => format!("{}m", seconds / 60),
            Locale::English if seconds < 86_400 => format!("{}h", seconds / 3_600),
            Locale::English => format!("{}d", seconds / 86_400),
            Locale::Japanese if seconds < 60 => format!("{seconds}秒"),
            Locale::Japanese if seconds < 3_600 => format!("{}分", seconds / 60),
            Locale::Japanese if seconds < 86_400 => format!("{}時間", seconds / 3_600),
            Locale::Japanese => format!("{}日", seconds / 86_400),
        }
    }

    pub fn duration(self, milliseconds: i64) -> String {
        match self.locale {
            Locale::English if milliseconds < 1_000 => format!("{milliseconds}ms"),
            Locale::English if milliseconds < 60_000 => {
                format!("{:.1}s", milliseconds as f64 / 1_000.0)
            }
            Locale::English => format!("{:.1}m", milliseconds as f64 / 60_000.0),
            Locale::Japanese if milliseconds < 1_000 => format!("{milliseconds}ミリ秒"),
            Locale::Japanese if milliseconds < 60_000 => {
                format!("{:.1}秒", milliseconds as f64 / 1_000.0)
            }
            Locale::Japanese => format!("{:.1}分", milliseconds as f64 / 60_000.0),
        }
    }

    pub const fn create_terminal(self) -> &'static str {
        self.pick("create terminal", "ターミナルを作成")
    }

    pub const fn draw_terminal(self) -> &'static str {
        self.pick("draw cmux tree", "cmux tree を描画")
    }

    pub const fn poll_input(self) -> &'static str {
        self.pick("poll terminal input", "ターミナル入力を待機")
    }

    pub const fn read_input(self) -> &'static str {
        self.pick("read terminal input", "ターミナル入力を読み取り")
    }

    pub const fn enable_raw_mode(self) -> &'static str {
        self.pick("enable raw terminal mode", "ターミナルの raw モードを有効化")
    }

    pub const fn enter_alternate_screen(self) -> &'static str {
        self.pick("enter alternate screen", "代替画面へ切り替え")
    }

    const fn pick(self, english: &'static str, japanese: &'static str) -> &'static str {
        match self.locale {
            Locale::English => english,
            Locale::Japanese => japanese,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn japanese_catalog_localizes_help_and_time_units() {
        let catalog = Catalog::new(Locale::Japanese);

        assert!(catalog.help().contains("使い方"));
        assert_eq!(catalog.elapsed(90), "1分");
        assert_eq!(catalog.duration(1_500), "1.5秒");
    }
}
