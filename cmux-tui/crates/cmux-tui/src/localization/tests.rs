use super::*;

#[test]
fn remote_recovery_messages_are_localized() {
    let english = &catalog_for_locale("en_US.UTF-8").remote;
    let japanese = &catalog_for_locale("ja_JP.UTF-8").remote;

    assert!(english.remote_stop_help.contains("USAGE"));
    assert!(japanese.remote_stop_help.contains("使用方法"));
    assert!(english.remote_stop_help.contains("cmux daemon stop"));
    assert!(japanese.remote_stop_help.contains("cmux daemon stop"));
    assert!(english.embedded_daemon_stop_refused.contains("SSH"));
    assert!(japanese.embedded_daemon_stop_refused.contains("SSH"));
    assert_eq!(
        english.remote_stop_unknown_option("--unknown"),
        "unknown option \"--unknown\" for cmux remote stop"
    );
    assert_eq!(
        japanese.remote_stop_unknown_option("--unknown"),
        "cmux remote stop の不明なオプションです: \"--unknown\""
    );
    assert_eq!(
        english.invalid_runtime_metadata("/tmp/runtime.json"),
        "remote daemon runtime metadata is invalid; verify that no cmux-tui process remains, then rerun cmux remote stop with --acknowledge-legacy-finalization (/tmp/runtime.json)"
    );
    assert_eq!(
        japanese.invalid_runtime_metadata("/tmp/runtime.json"),
        "リモートデーモンのランタイムメタデータが無効です。cmux-tui プロセスが残っていないことを確認してから、cmux remote stop を --acknowledge-legacy-finalization 付きで再実行してください（/tmp/runtime.json）"
    );
    assert_eq!(
        english.lifecycle_fence_version_unsupported(7),
        "remote daemon lifecycle fence version 7 is unsupported"
    );
    assert_eq!(
        japanese.lifecycle_fence_version_unsupported(7),
        "リモートデーモンのライフサイクルフェンスバージョン 7 はサポートされていません"
    );
    assert_eq!(
        english.refuse_active_socket("failed finalization", "/tmp/admin.sock"),
        "refusing to acknowledge failed finalization while daemon socket /tmp/admin.sock is active"
    );
    assert_eq!(
        japanese.refuse_active_socket("失敗した終了処理", "/tmp/admin.sock"),
        "デーモンソケット /tmp/admin.sock が有効なため、失敗した終了処理を確認済みとして扱えません"
    );
}

#[test]
fn deferred_input_discard_status_is_catalog_backed() {
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").terminal.deferred_input_destination_changed,
        "Deferred input was discarded because its destination changed"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").terminal.deferred_input_destination_changed,
        "遅延入力は送信先が変更されたため破棄されました"
    );
}

#[test]
fn deferred_input_overflow_status_is_catalog_backed() {
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").terminal.deferred_input_queue_full,
        "Input queue byte limit reached while a session change is pending"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").terminal.deferred_input_queue_full,
        "セッション変更の保留中に入力キューのバイト上限に達しました"
    );
}

#[test]
fn browser_recovery_failures_are_localized_at_the_ui_boundary() {
    let cases = [
        (
            "browser resize recovery failed; reload to retry",
            "browser failed: browser resize recovery failed; reload to retry",
            "ブラウザのサイズ変更を復旧できませんでした。再読み込みして再試行してください",
        ),
        (
            "could not verify new page pixels: capture timed out; reload to retry",
            "browser failed: could not verify new page pixels: capture timed out; reload to retry",
            "新しいページの表示を確認できませんでした: capture timed out。再読み込みして再試行してください",
        ),
        (
            "could not verify updated page pixels: capture timed out; reload to retry",
            "browser failed: could not verify updated page pixels: capture timed out; reload to retry",
            "更新後のページ表示を確認できませんでした: capture timed out。再読み込みして再試行してください",
        ),
    ];

    for (error, english, japanese) in cases {
        let status = cmux_tui_core::BrowserStatus::Failed(error.to_string());
        let failure = status.failure().expect("failed status");
        assert_eq!(catalog_for_locale("en_US.UTF-8").browser.failure_message(failure), english);
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").browser.failure_message(failure), japanese);
    }
}

#[test]
fn foreign_viewport_hints_are_neutral_and_stack_backed() {
    let english = ENGLISH.foreign_viewport.hint(12, 5).expect("English hint fits inline");
    assert_eq!(english.as_str(), "terminal grid (12x5)");
    assert_eq!(english.bytes.len(), 64);
    assert_eq!(ENGLISH.foreign_viewport.hint_width(12, 5), 20);

    let japanese = JAPANESE.foreign_viewport.hint(12, 5).expect("Japanese hint fits inline");
    assert_eq!(japanese.as_str(), "端末グリッド (12x5)");
    assert_eq!(japanese.bytes.len(), 64);
    assert_eq!(JAPANESE.foreign_viewport.hint_width(12, 5), 19);
}
