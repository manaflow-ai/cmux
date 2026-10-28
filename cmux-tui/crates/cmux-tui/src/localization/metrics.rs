//! `metrics` strings of the CLI catalog (English and Japanese): `cmux metrics`
//! (cli/metrics.rs).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MetricsMessages {
    pub usage: &'static str,
    pub unknown_option: &'static str,
    /// The table's first four column titles; the percentile columns are
    /// `P50`, `P95`, `P99` and `MAX` in every language.
    pub column_name: &'static str,
    pub column_unit: &'static str,
    pub column_count: &'static str,
    pub column_mean: &'static str,
    pub not_recording: &'static str,
    pub no_histograms: &'static str,
    /// After the table: `{count}` histograms, the app's `{pid}`.
    pub summary: &'static str,
}

pub(super) const ENGLISH: MetricsMessages = MetricsMessages {
    usage: "usage: cmux metrics [NAME ...] [--json]\n\nThe cmux app's field histograms: every sample recorded since the app started\n(key and input latency, frames, main-thread turns, hangs, memory, daemon\nrequests), as chrome://histograms shows Chrome's. Only histograms with samples\nare listed.\n\n  NAME     keep the histograms whose name contains NAME (repeatable), for\n           example `cmux metrics key.frame daemon.request`\n  --json   print the app's whole reply: each histogram's unit, layout,\n           count, sum, mean, p50, p95, p99, max and non-empty buckets\n\nPercentiles are read from the buckets: each is the upper bound of the bucket\nthat holds it, at most 25% above the true value. A value past a histogram's\nlargest bucket shows as >MAX.\n\nThe app serves this only while its metricsView feature is on\n(CMUX_ENABLE_FEATURES=metricsView when it starts).\n",
    unknown_option: "metrics: unknown option \"{option}\"",
    column_name: "NAME",
    column_unit: "UNIT",
    column_count: "COUNT",
    column_mean: "MEAN",
    not_recording: "The app records no metrics yet.",
    no_histograms: "No histogram with samples matches.",
    summary: "{count} histograms since the app started (pid {pid})",
};

pub(super) const JAPANESE: MetricsMessages = MetricsMessages {
    usage: "使い方: cmux metrics [名前 ...] [--json]\n\ncmux アプリのフィールドヒストグラム: アプリの起動以降に記録したすべての\nサンプル (キーと入力の遅延、フレーム、メインスレッドのターン、ハング、\nメモリ、デーモンへのリクエスト) を、Chrome の chrome://histograms と同じ形で\n表示します。サンプルのあるヒストグラムだけを表示します。\n\n  名前     名前に「名前」を含むヒストグラムだけを表示 (複数指定可)。\n           例: `cmux metrics key.frame daemon.request`\n  --json   アプリの応答全体を表示: 各ヒストグラムの単位、レイアウト、\n           件数、合計、平均、p50、p95、p99、最大値、空でないバケット\n\nパーセンタイルはバケットから読み取ります。値はその値を含むバケットの上限で、\n実際の値より最大 25% 大きくなります。ヒストグラムの最大のバケットを超えた値は\n>最大値 と表示します。\n\nアプリは metricsView 機能がオンのときだけこれに応答します\n(起動時に CMUX_ENABLE_FEATURES=metricsView)。\n",
    unknown_option: "metrics: 不明なオプション \"{option}\" です",
    column_name: "名前",
    column_unit: "単位",
    column_count: "件数",
    column_mean: "平均",
    not_recording: "アプリはまだメトリクスを記録していません。",
    no_histograms: "条件に合う、サンプルのあるヒストグラムはありません。",
    summary: "アプリの起動以降のヒストグラム {count} 件 (pid {pid})",
};
