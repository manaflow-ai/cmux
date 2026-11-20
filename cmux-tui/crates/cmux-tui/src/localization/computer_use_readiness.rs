//! Readiness experiment copy in the CLI's English/Japanese catalog.

pub(crate) fn computer_use_readiness_help() -> &'static str {
    if super::catalog().is_japanese() {
        "  cmux computer-use readiness [--machine M]\n    実験機能: ワーカー自身の OS 権限を確認します。Labs の「プレビュー機能を表示」が必要です。\n    対象アプリへのアクセスは許可しません。終了コード 0: 権限あり、1: 未準備または利用不可。"
    } else {
        "  cmux computer-use readiness [--machine M]\n    Experiment: check the worker's own OS grants. Requires Labs > Show Preview Features.\n    Does not authorize target apps. Exit 0: grants ready; 1: not ready or unavailable."
    }
}

pub(crate) fn computer_use_readiness_disabled() -> &'static str {
    if super::catalog().is_japanese() {
        "この実験機能はオフです。設定 > 詳細 > Labs > プレビュー機能を表示をオンにして、もう一度実行してください。"
    } else {
        "This experiment is off. Enable Settings > Advanced > Labs > Show Preview Features, then retry."
    }
}
