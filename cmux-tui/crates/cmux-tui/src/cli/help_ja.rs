//! `cmux git --help` and `cmux workspace --help` in Japanese, for a Japanese
//! locale. The command lines are the English help's own (`git_usage_lines!`,
//! `workspace_usage_lines!`): commands are typed as they are.

use super::scope_help::git_usage_lines;
use super::topology_help::workspace_usage_lines;
use super::worktree_help::{git_worktree_help_ja, workspace_worktree_help_ja};

pub(super) const GIT_HELP_JA: &str = concat!(
    "使い方\n",
    git_usage_lines!(),
    "対象 (TARGET)
  --path <path>          リポジトリ内のファイルまたはフォルダー
  --workspace <selector> ワークスペースの現在のターミナルの作業フォルダー
  --screen <selector>    スクリーンの現在のターミナルの作業フォルダー
  --pane <selector>      ペインの現在のターミナルの作業フォルダー
  --tab <selector>       タブのターミナルの作業フォルダー
  --terminal <selector>  ターミナルの作業フォルダー
  どれも指定しないときは、現在のフォルダーです。

スコープ (--scope)
  uncommitted  HEAD に対する作業ツリー。追跡されていないファイルも含みます (既定)
  unstaged     インデックスに対する作業ツリー。追跡されていないファイルも含みます
  staged       HEAD に対するインデックス
  committed    最初の親に対する HEAD
  branch       ベースブランチとのマージベースに対する作業ツリー。追跡されていない
               ファイルも含みます
  commits      --base とのマージベースに対する --head (プルリクエストの変更)。どちらも
               リポジトリに既にある完全なコミット ID です。何もフェッチしません

status はブランチ、アップストリーム、それより何コミット先か後か、ベースブランチ
(worktree create がそのブランチに記録したもの、なければ origin の既定のブランチ、
なければ main か master)、リンクされたワークツリーではそのメインのチェックアウトを
表示します。diff は変更された各ファイルの状態と行数を表示します。--patch を付けると、
各ファイルのパッチを最初の @@ 行から、--max-patch-bytes (既定 262144) で切って加えます。
一覧にするのは最大 --max-files 個 (500) で、残りは数だけを示します。返答の next_path を
--after-path に渡すと次のページを表示します。--patch と 1 つのファイルパスでは、
--patch-offset でそのファイルのパッチ全体をバイト位置 (0 から) からページごとに読めます。
後のページを読むときは、最初のページの revision を --patch-revision に渡します。パスは
リポジトリのルートからの相対パスで、そのまま (パターンとしてではなく) 扱います。

branches はローカルブランチ、次にリモート追跡ブランチを、新しいコミットの順に一覧に
します: それぞれの ref とコミット、ローカルブランチではそのアップストリームと、それより
何コミット先か後か。表示するのは最大 --limit 個 (200、最大 1000) です。ブランチの diff
が比べられるベースも提案します: worktree create がそのブランチに記録したベース、origin の
既定のブランチ (なければ main か master)、HEAD のブランチのアップストリームの順です。

files は対象フォルダーの下で、パスにクエリの文字がその順に入っているファイルを、よく
合うものから一覧にします (大文字と小文字は区別せず、空白は無視します): 追跡されている
ファイルと、無視されていない追跡されていないファイルです。表示するのは最大 --limit 個
(50、最大 200) で、探したフォルダーからの相対パスです。

list (または ls) は対象フォルダーのすぐ下の項目を、ファイルエクスプローラーと同じように
一覧にします: フォルダーが先、次にファイルで、名前の順です。git がその場所かその下に
ファイルを知っているとき (追跡されているか、追跡されていなくて無視されていないとき)
に表示します。サブモジュールはフォルダーです。表示するのは最大 --limit 個 (2000、
最大 5000) です。

checkpoint create は HEAD、インデックス、作業ツリーを変えずに、インデックス、追跡されて
いる作業ツリーのファイル、指定した追跡されていないファイル (またはその対象になるすべて)
を refs/cmux/checkpoints/ の下に保存します。無視されたファイル、認証情報らしいファイル、
大きすぎるファイルは飛ばして報告します。同じ --idempotency-key をもう一度使うと最初の
結果を返します。get --key でそれを取り出せます。チェックポイントはピン留めしないと 7 日で
消えます。handoff: か restore: で始まるピンは cmux のものです。checkpoint diff は、ある
チェックポイントから後のチェックポイントまで、または <to> がないときは現在の作業ツリー
までに変わったものを、diff と同じ形で一覧にします。

コミットとプッシュ (commit と push) は、あなたのターミナルと同じように、あなたのフック、
ID、認証情報で git を実行しますが、何も尋ねず、120 秒で止まります。commit は指定した
パスを、--all ならすべての追跡されている変更を (--include-untracked なら追跡されていない
ファイルも)、それ以外はインデックスをそのままコミットします。push はブランチのコミットを
同じ名前のブランチに、強制せずにプッシュし、アップストリームがなければ設定します。
--expected-head は、読んだ後に HEAD が動いていたら拒否します。

",
    git_worktree_help_ja!(),
    "
comments は diff ページのレビューコメントで、セッションホストがワークツリーのルート
(--root、既定は現在のフォルダー。diff ページと同じく、ワークツリーの一番上のフォルダーを
指定します) ごとに保存します。list はそれを表示します。save はコメントのオブジェクト
(filePath、side、startLine、endLine、message など) を加えるか、その id の保存済みの
コメントを置き換えます。createdAt と updatedAt はセッションホストが設定します。delete は
指定したコメントを削除します。--versions-json は id を、読んだときの updatedAt に対応させ
ます。それより後に編集されたコメントは残ります。
"
);

pub(super) const WORKSPACE_HELP_JA: &str = concat!(
    "使い方\n",
    workspace_usage_lines!(),
    "
",
    workspace_worktree_help_ja!(),
    "\
close に --others、--to-right、--to-left、--all を付けると、選んだワークスペースの兄弟
(セッションのワークスペース。ホームは除きます) を 1 つの閉じたグループとして閉じます:
`cmux closed reopen` 1 回ですべて戻ります。screen、pane、tab の close でも同じフラグが、
スクリーン、ペイン、タブのバーで働きます。
open-url は http(s) のリンクをワークスペースの右側で開きます (セレクターがなければホーム
ワークスペース): 最後にそこに表示したブラウザータブで開き、なければブラウザータブを
開きます。エージェントチャットのドックでは開かず、フォーカスは動かしません。
入れ子のペインは split --right と --down に対応します。セレクターがないとき、status、
progress、log は cmux のターミナルの中では呼び出し元のワークスペースを、それ以外では
現在のワークスペースを対象にします。レベル: info、progress、success、warning、error。
ダッシュで始まるテキストは -- の後に置きます。--ephemeral はシークレットのワークスペースを
作り、セッションは次の起動時にそれを閉じます。--top は workspaces.newPlacement に関係
なく、新しいワークスペースをサイドバーの先頭 (Home の下) に置きます。move --index <n> は
ワークスペースを list の n 番目 (サイドバーの順) とセッションの順に動かします。セクション
とグループは変わりません。ワークスペースのグループとルームは個人のもので、この Mac の
ホームセッションにあります。--remote はリモートのグループを作ります: <host> (~/.ssh/config
の別名、Tailscale の名前、または user@host) に接続し、その新しいワークスペースはそこで
動きます。--parent は <group> の中にグループを作ります。グループとルームは ID か正確な
名前で指定します。list --name <name> は名前がちょうど <name> のワークスペースを残します。
list --cwd <path> は <path> かその中のフォルダーにターミナルがあるものを残します (現在の
フォルダーからの相対パス。リンクを解決した形でも比べます)。両方を付けると両方に合う行を
残します。合うものがなければ空の一覧で終了コード 0 なので、`list --name api --json` は
`name:api` のセレクターがあいまいと判断するワークスペースをすべて見つけます。
list --order session はセッションのワークスペースの順 (動かしたものがなければ作った順) を
返します。list --order personal は cmux アプリのサイドバーの順を返します: グループに入って
いないワークスペースと、各グループのワークスペースをグループが表示される位置に並べます。
--order がないとき、セッションにサイドバーのドキュメントがあれば、list はどの呼び出し元にも
サイドバーの順を返します。ドキュメントがなければ、アプリの文脈 (アプリのターミナルや、
アプリ自身のデーモンを指定した Chief) ではサイドバーの順を、それ以外ではセッションの順を
返します。アプリの snapshot.get の windows[].workspaces は各ウィンドウが表示する順を一覧に
します。cmux アプリのセッションでは、list は接続している各 Cloud マシンのワークスペースも
この Mac のものの後に返します。それらは origin cloud で、machine_id (cloud new-workspace が
返す vm-… の ID)、machine_name、target vm:<id> が付きます。--machine <vm-…|vm:vm-…|name>
は 1 台の Cloud マシンのものを一覧にします。--top-index はグループを、その配置インデックスの
ワークスペースのすぐ前に置きます。--clear-top-index はグループに入っていないすべての
ワークスペースの後に置きます。--icon はグループのアイコン (絵文字 1 つ、SF Symbol の名前、
または保存済みの image:sha256-<hex> か svg:sha256-<hex> のアセット) を設定し、
--clear-icon は外します。--pinned true はグループを保存して、そのワークスペースが閉じても
残します。false はピン留めを外します。

セレクター (<selector>)
  <selector> は ID (ws_…、pane_…、tab_…、term_…)、一意な ID の先頭 (pane_3f0a、16 進 4 桁
  以上)、16 進 32 桁そのもの (ターミナルでは run が表示するホストの terminal_id、タブや
  ペインの ID も)、caller、current、focused (人が見ているもの)、または正確な名前です。ID や
  コマンドの語に見える名前には name: を前に付けます。
  caller はこのコマンドが動いているもの、つまりそれを始めた cmux のターミナルかエージェント
  チャットです (`cmux identify` が報告します)。current は、cmux が呼び出し元を知っていれば
  それと同じもの、知らなければフォーカスされているものです (cmux の外のシェルや、別の
  セッションを指定した --socket/--session では caller は拒否されます。呼び出し元自身の
  セッションを指定した --session では caller はそのままです)。
"
);
