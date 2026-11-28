//! `machine_agent` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MachineAgentMessages {
    pub help: &'static str,
    pub usage: &'static str,
    pub pairing_code: &'static str,
    pub registered: &'static str,
    pub retrying: &'static str,
    pub migration_failed: &'static str,
    pub pairing_code_unavailable: &'static str,
    pub runtime_failed: &'static str,
    pub invalid_session: &'static str,
    pub identity_unavailable: &'static str,
    pub registration_already_running: &'static str,
    pub cloud_configuration_invalid: &'static str,
    pub argument_needs_value: &'static str,
    pub invalid_cloud_port: &'static str,
    pub cloud_port_cannot_be_zero: &'static str,
    pub unknown_argument: &'static str,
}

impl MachineAgentMessages {
    pub(crate) fn retrying_message(&self, milliseconds: u128) -> String {
        self.retrying.replace("{milliseconds}", &milliseconds.to_string())
    }

    pub(crate) fn argument_needs_value_message(&self, argument: &str) -> String {
        self.argument_needs_value.replace("{argument}", argument)
    }

    pub(crate) fn invalid_cloud_port_message(&self, value: &str) -> String {
        self.invalid_cloud_port.replace("{value}", value)
    }

    pub(crate) fn unknown_argument_message(&self, argument: &str) -> String {
        self.unknown_argument.replace("{argument}", argument)
    }
}

pub(super) const ENGLISH: MachineAgentMessages = MachineAgentMessages {
    help: "\
cmux machine-agent - share one local cmux session through a remote service

USAGE:
  cmux machine-agent [OPTIONS]

OPTIONS:
  --session <name>         Local cmux session (default: main)
  --socket <path>          Explicit local cmux control socket
  --state <path>           Private machine identity file
  --cloud-host <host>      SSH registration host (default: cmux.cloud)
  --cloud-user <user>      SSH user
  --cloud-port <port>      SSH port
  --cloud-identity <path>  SSH identity file
  -h, --help               Show this help

The agent opens one outbound connection. It never opens a public listener or
edits shell files. Authenticate with the configured host before retrying.
",
    usage: "cmux machine-agent       Share one local session through the configured host",
    pairing_code: "Pairing code",
    registered: "Sharing local cmux session",
    retrying: "Cloud connection lost; retrying in {milliseconds} ms",
    migration_failed: "Could not reconnect the machine; please try again",
    pairing_code_unavailable: "Pairing code could not be displayed securely. Run this command from an interactive terminal and retry",
    runtime_failed: "The machine agent could not start or continue; check its configuration",
    invalid_session: "The session name is invalid; use a short name without spaces or control characters",
    identity_unavailable: "The private machine identity is unavailable; check that --state points to a private writable file",
    registration_already_running: "A machine agent is already sharing this session; stop it before starting another",
    cloud_configuration_invalid: "The cloud connection settings are invalid; check the host, user, port, and identity file",
    argument_needs_value: "Option {argument} needs a value",
    invalid_cloud_port: "Invalid --cloud-port value: {value}",
    cloud_port_cannot_be_zero: "--cloud-port cannot be zero",
    unknown_argument: "Unknown machine-agent argument: {argument}",
};

pub(super) const JAPANESE: MachineAgentMessages = MachineAgentMessages {
    help: "\
cmux machine-agent - ローカルの cmux セッションをリモートサービス経由で共有

使用方法:
  cmux machine-agent [オプション]

オプション:
  --session <name>         ローカル cmux セッション（既定: main）
  --socket <path>          ローカル cmux 制御ソケットを指定
  --state <path>           非公開のマシン ID ファイル
  --cloud-host <host>      SSH 登録ホスト（既定: cmux.cloud）
  --cloud-user <user>      SSH ユーザー
  --cloud-port <port>      SSH ポート
  --cloud-identity <path>  SSH ID ファイル
  -h, --help               このヘルプを表示

エージェントは外向きの接続を 1 つ開きます。公開リスナーを開いたり、シェルファイル
を編集したりしません。再試行する前に、設定したホストで認証してください。
",
    usage: "cmux machine-agent       設定したホスト経由でローカルセッションを共有",
    pairing_code: "ペアリングコード",
    registered: "ローカル cmux セッションを共有中",
    retrying: "クラウド接続が切断されました。{milliseconds} ミリ秒後に再接続します",
    migration_failed: "マシンを再接続できませんでした。もう一度お試しください",
    pairing_code_unavailable: "ペアリングコードを安全に表示できませんでした。対話型端末でこのコマンドを実行して再試行してください",
    runtime_failed: "machine-agent を開始または続行できませんでした。設定を確認してください",
    invalid_session: "セッション名が無効です。空白や制御文字を含まない短い名前を使用してください",
    identity_unavailable: "非公開のマシン ID を使用できません。--state が非公開で書き込み可能なファイルを指していることを確認してください",
    registration_already_running: "このセッションは別の machine-agent が共有中です。停止してからもう一度開始してください",
    cloud_configuration_invalid: "クラウド接続設定が無効です。ホスト、ユーザー、ポート、ID ファイルを確認してください",
    argument_needs_value: "オプション {argument} には値が必要です",
    invalid_cloud_port: "--cloud-port の値が無効です: {value}",
    cloud_port_cannot_be_zero: "--cloud-port に 0 は指定できません",
    unknown_argument: "不明な machine-agent 引数です: {argument}",
};
