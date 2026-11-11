//! `cmux agent --help` text in Japanese. The English text is `AGENT_HELP` in
//! `cli.rs`; both describe where `agent start` opens an agent (W6-F).

/// `cmux agent --help` for a Japanese catalog.
pub(super) const AGENT_HELP_JA: &str = "\
使用方法
  cmux agent start NAME [--cmd <launcher>] [--harness H] [--pane <selector>]
                  [--split right|down|left|up] [--cwd DIR] [--no-focus]
                  [--timeout 90s] [--no-wait] [-- ARGS...]
  cmux agent resume NAME [同じオプション]
  cmux agent open <session id> [--name NAME] [--key UUID] [--cwd DIR] [--host HOST] [--group GROUP] [--placement top] [--focus]
  cmux agent open-tab <session id> [--target PANE_OR_TAB] [--host HOST] [--focus]
  cmux agent message <agent> [--from <name>] [--thread <id>] [--] <text...|->
  cmux agent message --reply-to <message-id> [--from <name>] [--] <text...|->
  cmux agent message release <message-id> --recipient <agent> --approve|--decline
  cmux agent message unsend <message-id> [--recipient <agent>]
  cmux agent inbox [<agent>] [--state <state>] [--limit <n>] [--ack]
  cmux agent list [--needs-me] [--state working|blocked|done|idle|unknown|ended]
                  [--terminal <selector>] [--sort needs-me|recent|none] [--limit <n>] [--counts]
                  (done: 未読の通知がある idle。ended: セッションが終了した状態で、
                  以前は --state done が選んでいました。行には name と status が
                  あり、state は status の非推奨の別名です。閉じたターミナルの
                  ended のエージェントは --state ended のときだけ表示されます)
  cmux agent <agent> focus
  cmux agent report --terminal <selector> --state working|blocked|idle|ended|unknown --source <value>
  cmux agent hook install|uninstall|status [provider...]
  cmux agent hook emit --source <agent> --event <native-event> [--terminal <id>]
  cmux agent plugin list
  cmux agent plugin install <git-url> [--name <value>] [--force]
  cmux agent plugin use|update|remove <name-or-id>
  cmux agent plugin use --builtin

agent start はランチャー (--cmd、なければ $CMUX_AGENT_COMMAND、なければ claude。
sr2 claude と codex も使えます) を NAME という名前の新しいタブで起動し、
エージェントがメッセージを受け取れるまで待ちます。--pane か --split の指定が
なければ、最初のエージェントは、あなたのペインと新しいペインの両方がターミナル
40 列以上を保てるときはペインの横の新しい列に、そうでなければペインの下に開きます。
2 つ目以降のエージェントは、そこにあるどのエージェントもターミナル 8 行以上を
保てる間は最後のエージェントの下に開き、保てないときは最後のエージェントの
ペインの新しいタブとして開きます。一度できた列の幅は変わりません。
cmux のターミナルから --session か --socket を使い、--pane がないか
--pane current か --pane caller のときは、あなたのペインがそのセッションに
ある必要があり、ないときは終了コード 2 で終了します (そのときフォーカス中のペインは使いません)。
ID と状態を表示します: ready (終了コード 0)、ダイアログと理由つきの blocked
(Claude のフォルダー信頼の確認など。終了コード 4。cmux は答えません)、
timeout (終了コード 124)、exited (終了コード 1)。NAME は英小文字 1 文字の後に
英小文字、数字、- または _ を 31 文字まで続けたもので、実行中のタブの中で
一意です。ターミナル、タブ、ペインのセレクターが使える場所ならどこでも使えます
(cmux terminal NAME send --text ... --wait idle)。
agent resume NAME は、終了したエージェントを記録されたハーネスのセッション
(claude --resume <id>、codex resume <id>) で同じペインに再び起動します。
そのペインがもうないときは、agent start と同じくあなたのペインの横に開きます。
";
