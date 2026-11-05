//! `live-code` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LiveCodeMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub apply_needs_patch: &'static str,
    pub apply_pull_request: &'static str,
    pub not_watching: &'static str,
    pub no_answer: &'static str,
}

pub(super) const ENGLISH: LiveCodeMessages = LiveCodeMessages {
    usage: "usage: cmux live-code status|apply PATCH.dylib|undo [--all]|log [--dir DIR] [--json]\n\nRead and repair the live code of a running cmux live code build, through its\nlive folder (never its window), so a patch that wedged the app can still be undone.\n\n  status          What the app has applied, newest first: each patch's commit,\n                  files and functions, and the last error.\n  apply PATCH     Apply a patch dylib (scripts/live-code/patch.py makes one; for a\n                  pull request, scripts/try-pr.sh builds it and calls this).\n  undo            Undo the newest patch. --all: back to the code as built.\n  log [-n N]      The last N lines of the app's live code log (default 40).\n\n  --dir DIR       The live folder. Default: CMUX_LIVE_CODE_DIR, else\n                  ~/Library/Caches/cmux-next/live-code.\n  --timeout S     How long apply and undo wait for the app (default 20 s).\n  --no-wait       Do not wait for the app's answer.\n\nExit 1: the app refused it. 3: no live code app watches the folder.\n4: the app did not answer in time; relaunch it.\n\nSee docs/cmux-next/live-code.md.\n",
    unknown_verb: "unknown live-code verb \"{verb}\"; use status, apply, undo or log",
    apply_needs_patch: "live-code apply needs a patch dylib",
    apply_pull_request: "live-code apply takes a patch dylib; for pull request {pr}, run scripts/try-pr.sh {pr}, which builds its patch and applies it",
    not_watching: "no running cmux live code build watches {dir} (turn on Labs > Live Code in a live code build, or relaunch it)",
    no_answer: "the app did not answer {name} within {seconds} s; it may be stuck: relaunch it",
};

pub(super) const JAPANESE: LiveCodeMessages = LiveCodeMessages {
    usage: "使い方: cmux live-code status|apply パッチ.dylib|undo [--all]|log [--dir フォルダ] [--json]\n\n実行中の cmux ライブコードビルドのライブコードを、ウィンドウではなくライブフォルダ\n経由で確認・修復します。アプリを固まらせたパッチも元に戻せます。\n\n  status          適用済みのパッチ (新しい順): コミット、ファイル、関数数と最後のエラー。\n  apply パッチ    パッチ dylib を適用します (scripts/live-code/patch.py が作成。プル\n                  リクエストは scripts/try-pr.sh がビルドしてこれを呼びます)。\n  undo            最新のパッチを元に戻します。--all: ビルド時のコードに戻します。\n  log [-n N]      アプリのライブコードログの最後の N 行 (既定 40)。\n\n  --dir フォルダ  ライブフォルダ。既定: CMUX_LIVE_CODE_DIR、なければ\n                  ~/Library/Caches/cmux-next/live-code。\n  --timeout 秒    apply と undo がアプリの応答を待つ時間 (既定 20 秒)。\n  --no-wait       アプリの応答を待ちません。\n\n終了コード 1: アプリが拒否。3: フォルダを監視するライブコードアプリがない。\n4: アプリが時間内に応答しない。再起動してください。\n\ndocs/cmux-next/live-code.md を参照。\n",
    unknown_verb: "live-code の動詞「{verb}」は不明です。status、apply、undo、log を使ってください",
    apply_needs_patch: "live-code apply にはパッチ dylib が必要です",
    apply_pull_request: "live-code apply はパッチ dylib を受け取ります。プルリクエスト {pr} には scripts/try-pr.sh {pr} を実行してください (パッチをビルドして適用します)",
    not_watching: "{dir} を監視している実行中の cmux ライブコードビルドがありません (ライブコードビルドで Labs > Live Code をオンにするか、再起動してください)",
    no_answer: "アプリが {seconds} 秒以内に {name} に応答しませんでした。固まっている可能性があります: 再起動してください",
};
