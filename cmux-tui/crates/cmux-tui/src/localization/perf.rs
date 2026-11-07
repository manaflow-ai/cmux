//! `perf` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PerfMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub bad_seconds: &'static str,
    pub bad_interval: &'static str,
    pub no_app: &'static str,
    pub not_an_app: &'static str,
    pub no_process: &'static str,
    pub recording: &'static str,
    pub write_failed: &'static str,
}

pub(super) const ENGLISH: PerfMessages = PerfMessages {
    usage: "usage: cmux perf record [--seconds N] [--out DIR] [--app PATH.app|PID] [--interval-ms MS] [--no-signposts] [--json]\n\nRecord a profile of the running cmux app, on any build (dev, nightly or release), into one\ntrace that https://ui.perfetto.dev opens. Nothing is launched and nothing in the app changes.\n\nIt records, for every process of the app (the app, its browser helpers, the WebKit processes\nof its agent pages, the daemons, terminal hosts and acpmux):\n  CPU (% of one core), wakeups a second (context switches on Linux) and memory, every interval;\n  cmux's signposts (action, key and tab timings; macOS);\n  the agent pages' frames: frame windows, long frames, loads and visibility (macOS).\nNo stack samples: for those use scripts/cmux-next/trace.py or Instruments.\n\n  --seconds N       How long to record, 1 to 600 (default 10). Ctrl-C ends it early;\n                    what was recorded is still written.\n  --out DIR         Where trace.json and summary.json go (default: a new\n                    cmux-perf-<UTC time> folder here).\n  --app PATH|PID    The app to record. Default: the app this cmux is in, else the newest\n                    running cmux app.\n  --interval-ms MS  How often processes are sampled, 50 to 5000 (default 250).\n  --no-signposts    Do not run `log stream`.\n  --json            Print summary.json instead of the summary.\n\nSee plans/cmux-next/trace.md.\n",
    unknown_verb: "unknown perf verb \"{verb}\"; use record",
    bad_seconds: "--seconds takes a whole number from 1 to 600, not \"{value}\"",
    bad_interval: "--interval-ms takes a whole number from 50 to 5000, not \"{value}\"",
    no_app: "no running cmux app found: open cmux, or pass --app PATH.app or --app PID",
    not_an_app: "{path} is not an app bundle (a folder ending in .app)",
    no_process: "no process {pid} is running",
    recording: "recording {seconds} s of {app} (Ctrl-C ends it early)",
    write_failed: "could not write {dir}: {error}",
};

pub(super) const JAPANESE: PerfMessages = PerfMessages {
    usage: "使い方: cmux perf record [--seconds 秒] [--out フォルダ] [--app パス.app|PID] [--interval-ms ミリ秒] [--no-signposts] [--json]\n\n実行中の cmux アプリのプロファイルを、どのビルド (dev、nightly、release) でも記録し、\nhttps://ui.perfetto.dev で開ける 1 つのトレースにします。何も起動せず、アプリにも変更を加えません。\n\nアプリのすべてのプロセス (アプリ本体、ブラウザのヘルパー、エージェントページの WebKit\nプロセス、デーモン、ターミナルホスト、acpmux) について次を記録します:\n  CPU (1 コアに対する %)、1 秒あたりのウェイクアップ (Linux ではコンテキストスイッチ)、メモリ (間隔ごと)\n  cmux のサインポスト (アクション、キー、タブの所要時間。macOS)\n  エージェントページのフレーム: フレームの区間、長いフレーム、読み込み、表示状態 (macOS)\nスタックのサンプルは記録しません。必要なら scripts/cmux-next/trace.py か Instruments を使ってください。\n\n  --seconds 秒        記録する時間。1 から 600 (既定 10)。Ctrl-C で早めに終了でき、\n                      それまでの記録は書き出されます。\n  --out フォルダ      trace.json と summary.json の書き出し先 (既定: ここに新しく作る\n                      cmux-perf-<UTC 時刻> フォルダ)。\n  --app パス|PID      記録するアプリ。既定: この cmux を含むアプリ、なければ最後に起動した\n                      cmux アプリ。\n  --interval-ms ミリ秒  プロセスを測る間隔。50 から 5000 (既定 250)。\n  --no-signposts      `log stream` を実行しません。\n  --json              要約の代わりに summary.json を出力します。\n\nplans/cmux-next/trace.md を参照。\n",
    unknown_verb: "perf の動詞「{verb}」は不明です。record を使ってください",
    bad_seconds: "--seconds には 1 から 600 の整数を指定してください (「{value}」は使えません)",
    bad_interval: "--interval-ms には 50 から 5000 の整数を指定してください (「{value}」は使えません)",
    no_app: "実行中の cmux アプリが見つかりません。cmux を開くか、--app パス.app または --app PID を指定してください",
    not_an_app: "{path} はアプリバンドル (.app で終わるフォルダ) ではありません",
    no_process: "プロセス {pid} は実行されていません",
    recording: "{app} を {seconds} 秒間記録しています (Ctrl-C で早めに終了します)",
    write_failed: "{dir} に書き込めませんでした: {error}",
};
