//! The worktree parts of `cmux git --help` and `cmux workspace --help`, in
//! English and Japanese. Each is a macro, so the scope help constants
//! (`scope_help::GIT_HELP`, `topology_help::WORKSPACE_HELP` and their
//! Japanese forms in `help_ja.rs`) hold it as one literal.

/// The worktree paragraphs of `cmux git --help`, in English.
macro_rules! git_worktree_help_en {
    () => {
        "\
worktree create makes a worktree for a chat at ~/.cmux/worktrees/<project>/<name>
on a new branch cmux/<name> from --base (the current branch by default), and
records the base as branch.<branch>.cmuxBase. --branch <branch> names the branch
instead: a new one is made from --base, and one that exists is checked out as it
is (no --base then). A taken name gets the next free suffix (-2, -3, ...); without
--name it is chat-<random>. Your checkout is left as it is.

worktree apply, run in such a worktree, brings everything it changed since its
recorded base (commits, edits and new files; not submodules) to the main checkout
as uncommitted changes. HEAD and the index stay; it is refused when the main
checkout has changes of its own (or untracked files) at those paths, or when the
work does not apply cleanly there.

worktree remove, run in such a worktree, removes it (with its ignored files), the
branch worktree create made for it (a branch that was there before stays), and the
project folder in ~/.cmux/worktrees once its last worktree is gone. It is refused
while the worktree has uncommitted changes or commits on no other branch or
remote; the refusal names --discard, which removes it anyway and loses them. The
main checkout is never removed. Before it goes, the project's teardown runs.

worktree setup shows the project's worktree recipe (.worktreeinclude,
.cmux/worktree.toml and the saved one) and, in a worktree worktree create made,
its setup: state, port and output (from byte --since).

Paths: cmux prints a worktree as ~/.cmux/worktrees/<project>/<name> (on macOS a
link to ~/.cmux/worktrees.noindex) and takes either spelling, like /tmp and
/private/tmp, as the same folder. A folder it reports, such as main_root, keeps
the spelling you gave: a checkout given as /tmp/... prints as /tmp/... .
"
    };
}

/// The worktree paragraph of `cmux workspace --help`, in English.
macro_rules! workspace_worktree_help_en {
    () => {
        "\
create --worktree <name> makes a git worktree of the repository --repo is in
(default: the current folder) on a new branch cmux/<name> (or on --branch
<branch>: made from --base when new, checked out as it is when it exists), in
~/.cmux/worktrees/<project>/<name>, and a workspace named <name> whose
terminal starts there; --json has the workspace ids and the worktree as
worktree (root is its folder). close --remove-worktree removes that worktree,
the branch create made for it and the empty project folder, then closes the
workspace. With uncommitted or unpushed work it is refused, closing nothing,
and the message names --discard, which removes it anyway and loses that work.
"
    };
}

pub(super) use {git_worktree_help_en, workspace_worktree_help_en};

/// The worktree paragraphs of `cmux git --help`, in Japanese.
macro_rules! git_worktree_help_ja {
    () => {
        "\
worktree create はチャット用のワークツリーを ~/.cmux/worktrees/<project>/<name> に作ります。
ブランチは --base (既定は現在のブランチ) から作る新しいブランチ cmux/<name> で、そのベースを
branch.<branch>.cmuxBase に記録します。--branch <branch> でブランチを指定できます: 新しいブランチは
--base から作り、既にあるブランチはそのままチェックアウトします (このとき --base は指定できません)。
名前が使われているときは次の空いた接尾辞 (-2、-3、...) を付けます。--name がなければ chat-<ランダム> です。
あなたのチェックアウトはそのままです。

worktree apply をそのようなワークツリーで実行すると、記録したベース以降の変更 (コミット、編集、
新しいファイル。サブモジュールは除きます) を、メインのチェックアウトにコミットされていない変更として
持ち込みます。HEAD とインデックスはそのままです。メインのチェックアウトの同じパスに独自の変更
(または追跡されていないファイル) があるとき、または変更がきれいに適用できないときは拒否します。

worktree remove をそのようなワークツリーで実行すると、ワークツリー (無視されたファイルも)、
worktree create がそのために作ったブランチ (前からあったブランチは残ります)、最後のワークツリーが
なくなった ~/.cmux/worktrees のプロジェクトフォルダーを削除します。コミットされていない変更や、
ほかのどのブランチにもリモートにもないコミットがあるときは拒否し、そのメッセージは --discard を
示します。--discard はそれらを失って削除します。メインのチェックアウトは削除しません。削除の前に
プロジェクトの teardown を実行します。

worktree setup はプロジェクトのワークツリーレシピ (.worktreeinclude、.cmux/worktree.toml、保存したもの) と、
worktree create が作ったワークツリーではそのセットアップ (状態、ポート、--since バイト以降の出力) を表示します。

パス: cmux はワークツリーを ~/.cmux/worktrees/<project>/<name> と表示します (macOS では
~/.cmux/worktrees.noindex へのリンクです)。どちらの書き方も、/tmp と /private/tmp と同じように、
同じフォルダーとして受け付けます。main_root など表示するフォルダーは、指定した書き方のままです:
/tmp/... と指定したチェックアウトは /tmp/... と表示します。
"
    };
}

/// The worktree paragraph of `cmux workspace --help`, in Japanese.
macro_rules! workspace_worktree_help_ja {
    () => {
        "\
create --worktree <name> は --repo のあるリポジトリ (既定は現在のフォルダー) の git ワークツリーを
~/.cmux/worktrees/<project>/<name> に新しいブランチ cmux/<name> で作り (--branch <branch> なら
そのブランチ: 新しければ --base から作り、既にあればそのままチェックアウトします)、ターミナルが
そこで始まる <name> という名前のワークスペースを作ります。--json にはワークスペースの ID と、
worktree としてワークツリー (root がそのフォルダー) が入ります。close --remove-worktree は
そのワークツリー、create がそのために作ったブランチ、空になったプロジェクトフォルダーを削除してから
ワークスペースを閉じます。コミットされていない作業やプッシュされていない作業があるときは何も閉じずに
拒否し、そのメッセージは --discard を示します。--discard はその作業を失って削除します。
"
    };
}

pub(super) use {git_worktree_help_ja, workspace_worktree_help_ja};
