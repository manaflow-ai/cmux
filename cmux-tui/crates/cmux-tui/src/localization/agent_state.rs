//! `agent_state` strings of the CLI catalog (English and Japanese): the help
//! and human output of `cmux agent explain` (cli/agent_explain.rs) and of
//! `cmux terminal wait --any|--all` (cli/status/agents_wait.rs). `{}` is
//! replaced at the call site, in order. The JSON output keeps its stable
//! English ids (states, decisions, error codes); only these texts change.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AgentStateMessages {
    /// `cmux agent explain --help`.
    pub explain_help: &'static str,
    /// `cmux terminal wait --help`.
    pub wait_help: &'static str,
    /// `agent start` / `terminal wait --until ready` timed out waiting for the
    /// agent's own session-start report. `{waited}`: a duration; `{who}`: the
    /// agent or terminal.
    pub session_not_reported: &'static str,
    /// Row label: the agent's state now.
    pub state: &'static str,
    /// Row label: the record that set the state.
    pub cause: &'static str,
    /// Row label: the state before.
    pub before: &'static str,
    /// Row label: the screen's last observation.
    pub screen: &'static str,
    /// Row label: the screen text a record carried.
    pub screen_text: &'static str,
    /// Row label: what lists show (the shared status) when it differs.
    pub shown_as: &'static str,
    /// `{}`: a duration such as 12s.
    pub for_duration: &'static str,
    /// `{}`: a duration such as 12s.
    pub ago: &'static str,
    /// `{}`: a journal sequence.
    pub journal: &'static str,
    /// `{}`: the source word (hook, plugin, socket, program_status).
    pub source: &'static str,
    /// `{}`: a hook's native event (Stop, PermissionRequest).
    pub hook_event: &'static str,
    /// `{}`: a tool name.
    pub tool: &'static str,
    /// `{}`: a screen rule id.
    pub rule: &'static str,
    /// `{}`: manifest version, `{}`: its source (bundled, remote).
    pub manifest: &'static str,
    /// The screen matched no rule, so the known agent counts as idle.
    pub basis_idle_fallback: &'static str,
    /// The screen read idle, but output moved within the last moments.
    pub basis_output_activity: &'static str,
    /// The agent's process appeared; the screen was not read yet.
    pub basis_process_identity: &'static str,
    /// The agent's process left the terminal.
    pub basis_process_exit: &'static str,
    /// `{}`: the program (OSC 7501 app).
    pub program_status: &'static str,
    pub decision_hook: &'static str,
    pub decision_hook_report: &'static str,
    pub decision_socket_report: &'static str,
    pub decision_screen: &'static str,
    pub decision_screen_after_stale_hook: &'static str,
    pub decision_screen_cleared_hook_blocker: &'static str,
    pub decision_screen_ended_hook_turn: &'static str,
    pub decision_screen_legacy: &'static str,
    pub decision_program_status_cleared_hook_blocker: &'static str,
    /// The cause's record left the journal (retention).
    pub record_gone: &'static str,
    /// The daemon kept no cause (a state set before this version).
    pub no_cause: &'static str,
    /// `done` while the roster says idle: an unread notification.
    pub done_unseen: &'static str,
    /// The screen saw something else than the state, and lost.
    pub screen_ignored: &'static str,
}

pub(super) const ENGLISH: AgentStateMessages = AgentStateMessages {
    explain_help: "\
USAGE
  cmux agent explain <terminal|name> [--json]
  cmux agent <terminal|name> explain [--json]

Says why cmux holds the agent's state: the state and since when, the record
that set it (a hook event with its name and time, or a screen rule with its
id, manifest version and the screen text it matched), how the daemon took it
(hook, screen, a socket report, or the screen over a hook dialog that no hook
closed), the state before and when it changed, and the screen's last
observation when a fresher hook kept its own state. The screen text comes from
the journal record itself; a record that left the journal says so.
--json prints the same data (exit 0); no agent in the terminal is
agent.not_found (exit 1).
",
    session_not_reported: "the agent did not report that it is ready (its SessionStart hook) within {waited}; its input box alone does not count, because the agent takes no message before that report. Read its screen with cmux terminal {who} screen read",
    wait_help: "\
USAGE
  cmux terminal <selector> wait --until idle|prompt|ready [--timeout D]
  cmux terminal wait --any <t1,t2,...> [--until idle,blocked,done] [--timeout D]
  cmux terminal wait --all <t1,t2,...> [--until idle,blocked,done] [--timeout D]

--any returns when the first listed agent shows one of the --until states;
--all when every listed agent does. A target is a terminal, tab or agent
name; --until takes idle, blocked, done, working or ended, as a comma list or
repeated (default idle,blocked,done). idle also matches done (a finished turn
nobody has viewed). An agent whose hooks report a session start (Claude Code)
shows starting, not idle, until that report comes: its input box is drawn
before it takes a message. A wait that already holds returns at once. The result
names the terminal that matched, its state and every listed agent's state.
It waits on the session's event stream (no polling). A passed --timeout is
wait.timeout (exit 124); agents that ended so the wait can never hold are
wait.agent_ended (exit 1).
",
    state: "state",
    cause: "why",
    before: "before",
    screen: "screen",
    screen_text: "screen text",
    shown_as: "shown as",
    for_duration: "for {}",
    ago: "{} ago",
    journal: "journal {}",
    source: "source {}",
    hook_event: "hook event {}",
    tool: "tool {}",
    rule: "rule {}",
    manifest: "manifest {} ({})",
    basis_idle_fallback: "no rule matched: a known agent at rest counts as idle",
    basis_output_activity: "the screen reads idle, but output moved just now",
    basis_process_identity: "the agent's process appeared; the screen was not read yet",
    basis_process_exit: "the agent's process left the terminal",
    program_status: "the program's own status report (OSC 7501, {})",
    decision_hook: "taken from a hook (hooks win over the screen)",
    decision_hook_report: "a hook-source report (agent report)",
    decision_socket_report: "a socket report (agent report)",
    decision_screen: "taken from the screen (no hook owns this terminal)",
    decision_screen_after_stale_hook: "taken from the screen: the hooks were quiet for 30 s",
    decision_screen_cleared_hook_blocker: "the screen showed the hook's dialog gone (no hook says so)",
    decision_screen_ended_hook_turn: "the screen showed the turn end with no hook (Esc, a lost Stop)",
    decision_screen_legacy: "the old in-core screen detector",
    decision_program_status_cleared_hook_blocker: "the program said its dialog is gone (no hook says so)",
    record_gone: "its journal record is gone (retention)",
    no_cause: "not recorded: the state was set before this daemon version",
    done_unseen: "done: the turn ended and nobody viewed the tab (viewing it makes it idle)",
    screen_ignored: "not taken: a fresh hook owns the state",
};

pub(super) const JAPANESE: AgentStateMessages = AgentStateMessages {
    explain_help: "\
使い方
  cmux agent explain <terminal|name> [--json]
  cmux agent <terminal|name> explain [--json]

cmux がエージェントの状態をそう判断した理由を表示します。現在の状態とその開始時刻、
状態を決めた記録 (名前と時刻付きのフックイベント、またはルール ID・マニフェストの
バージョン・一致した画面テキスト付きの画面ルール)、デーモンの採用の仕方 (フック、
画面、ソケット報告、またはフックが閉じなかったダイアログを画面が閉じた場合)、
直前の状態と変化した時刻、そして新しいフックが状態を保った場合の画面の最新観測を
示します。画面テキストはジャーナル記録そのものから読みます。記録がジャーナルから
消えた場合はそう表示します。
--json は同じ内容を JSON で出力します (終了コード 0)。端末にエージェントがない場合は
agent.not_found (終了コード 1) です。
",
    session_not_reported: "エージェントが {waited} 以内に準備完了を報告しませんでした (SessionStart フック)。その報告の前はメッセージを受け付けないため、入力欄が見えるだけでは準備完了とみなしません。cmux terminal {who} screen read で画面を確認してください",
    wait_help: "\
使い方
  cmux terminal <selector> wait --until idle|prompt|ready [--timeout D]
  cmux terminal wait --any <t1,t2,...> [--until idle,blocked,done] [--timeout D]
  cmux terminal wait --all <t1,t2,...> [--until idle,blocked,done] [--timeout D]

--any は、列挙したエージェントのどれかが --until の状態になった時点で戻ります。
--all はすべてがそうなった時点で戻ります。対象には端末、タブ、エージェント名を
指定できます。--until には idle、blocked、done、working、ended をカンマ区切りまたは
繰り返しで指定します (既定値 idle,blocked,done)。idle は done (誰も見ていない完了した
ターン) にも一致します。フックでセッション開始を報告するエージェント (Claude Code) は、
その報告が来るまで idle ではなく starting と表示されます (入力欄はメッセージを
受け付ける前に表示されるため)。すでに条件を満たしていればすぐに戻ります。結果には一致した
端末とその状態、列挙した全エージェントの状態が含まれます。待機はセッションの
イベントストリームで行います (ポーリングしません)。--timeout を過ぎると wait.timeout
(終了コード 124)、エージェントが終了して条件を満たせなくなった場合は
wait.agent_ended (終了コード 1) です。
",
    state: "状態",
    cause: "理由",
    before: "直前",
    screen: "画面",
    screen_text: "画面テキスト",
    shown_as: "表示",
    for_duration: "{}間",
    ago: "{}前",
    journal: "ジャーナル {}",
    source: "情報源 {}",
    hook_event: "フックイベント {}",
    tool: "ツール {}",
    rule: "ルール {}",
    manifest: "マニフェスト {} ({})",
    basis_idle_fallback: "一致するルールなし: 既知のエージェントが休止中なので idle とみなします",
    basis_output_activity: "画面は idle ですが、直前に出力がありました",
    basis_process_identity: "エージェントのプロセスが現れました。画面はまだ読んでいません",
    basis_process_exit: "エージェントのプロセスが端末からいなくなりました",
    program_status: "プログラム自身の状態報告 (OSC 7501、{})",
    decision_hook: "フックから採用 (フックは画面より優先)",
    decision_hook_report: "フック由来の報告 (agent report)",
    decision_socket_report: "ソケット報告 (agent report)",
    decision_screen: "画面から採用 (この端末を所有するフックはありません)",
    decision_screen_after_stale_hook: "画面から採用: フックが 30 秒間報告しませんでした",
    decision_screen_cleared_hook_blocker: "フックのダイアログが消えたことを画面が示しました (フックは報告しません)",
    decision_screen_ended_hook_turn: "フックなしでターンが終わったことを画面が示しました (Esc、失われた Stop)",
    decision_screen_legacy: "旧来のコア内蔵画面検出",
    decision_program_status_cleared_hook_blocker: "プログラムがダイアログの終了を報告しました (フックは報告しません)",
    record_gone: "ジャーナル記録はもうありません (保持期間切れ)",
    no_cause: "記録なし: この状態はこのデーモンのバージョンより前に設定されました",
    done_unseen: "done: ターンが終わり、まだ誰もタブを見ていません (見ると idle になります)",
    screen_ignored: "不採用: 新しいフックが状態を所有しています",
};
