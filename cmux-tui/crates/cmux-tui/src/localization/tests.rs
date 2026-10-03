use super::*;

#[test]
fn locale_tags_select_complete_catalogs() {
    assert_eq!(catalog_for_locale("en_US.UTF-8"), &ENGLISH);
    assert_eq!(catalog_for_locale("ja_JP.UTF-8"), &JAPANESE);
    assert_eq!(catalog_for_locale("C"), &ENGLISH);
    assert_eq!(ENGLISH.menu.maximize_pane, "Maximize pane");
    assert_eq!(JAPANESE.menu.maximize_pane, "ペインを最大化");
    assert_eq!(ENGLISH.action_label(Action::NewPaneSmart), "New pane");
    assert_eq!(JAPANESE.action_label(Action::NewPaneSmart), "新しいペイン");
    assert_eq!(ENGLISH.shortcuts.title, "Keyboard shortcuts");
    assert_eq!(JAPANESE.shortcuts.title, "キーボードショートカット");
    assert_eq!(ENGLISH.shortcuts.close_button, "Esc close");
    assert_eq!(JAPANESE.shortcuts.close_button, "Esc 閉じる");
    assert_eq!(ENGLISH.remote_client.known_daemons_empty, "No known daemons.");
    assert_eq!(JAPANESE.remote_client.known_daemons_empty, "登録済みのデーモンはありません。");
    assert_eq!(ENGLISH.remote_client.known_daemon_auth_enrolled, "enrolled");
    assert_eq!(JAPANESE.remote_client.known_daemon_auth_enrolled, "登録済み");
    assert_eq!(ENGLISH.remote_client.known_daemon_auth_carrier, "carrier");
    assert_eq!(JAPANESE.remote_client.known_daemon_auth_carrier, "信頼済み搬送路");
    assert_eq!(
        ENGLISH.remote_client.relay_credentials_require_explicit_route,
        "relay credentials without --relay-route require one explicit relay connection route"
    );
    assert_eq!(
        JAPANESE.remote_client.relay_credentials_require_explicit_route,
        "--relay-route を指定しないリレー認証情報には、明示的なリレー接続ルートを 1 つ指定してください"
    );
    assert_eq!(
        JAPANESE.remote_client.relay_shorthand_requires_relay_route("wss://example.test/"),
        "リレー認証情報の短縮形式には明示的なリレールートが必要です。指定されたルート: wss://example.test/"
    );
    assert_eq!(
        JAPANESE.remote_client.known_daemon_forgotten("fingerprint"),
        "デーモン fingerprint を削除しました。"
    );
    assert_eq!(
        JAPANESE.remote_client.known_daemon_not_known("fingerprint"),
        "デーモン \"fingerprint\" は登録されていません"
    );
    assert_eq!(
        ENGLISH.terminal.deferred_input_destination_changed,
        "Deferred input was discarded because its destination changed"
    );
    assert_eq!(
        JAPANESE.terminal.deferred_input_destination_changed,
        "遅延入力は送信先が変更されたため破棄されました"
    );
    assert_eq!(
        ENGLISH.terminal.deferred_input_queue_full,
        "Input queue byte limit reached while a session change is pending"
    );
    assert_eq!(
        JAPANESE.terminal.deferred_input_queue_full,
        "セッション変更の保留中に入力キューのバイト上限に達しました"
    );
    assert_eq!(ENGLISH.terminal.pty_input_exited, "Terminal exited; input was not sent");
    assert_eq!(
        JAPANESE.terminal.pty_input_exited,
        "ターミナルが終了したため、入力は送信されませんでした"
    );
    assert_eq!(ENGLISH.session.operation_failed, "Session operation failed");
    assert_eq!(
        JAPANESE.session.mux_subscription_recovered,
        "Mux イベントの滞留が上限を超えました。購読を復旧しました"
    );
    assert_eq!(
        JAPANESE.session.mux_subscription_recovery_failed("更新失敗"),
        "Mux イベントの滞留から復旧できませんでした。再試行中のキュー入力を破棄しました: 更新失敗"
    );
    assert_eq!(JAPANESE.session.operation_failed, "セッション操作に失敗しました");
    assert_eq!(
        JAPANESE.attach.filtered_subscription_unavailable,
        "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください"
    );
    assert_eq!(ENGLISH.attach.remote_attach_queue_full, "remote surface attach queue is full");
    assert_eq!(
        JAPANESE.attach.remote_attach_queue_full,
        "リモートサーフェス接続キューがいっぱいです"
    );
    assert_eq!(
        ENGLISH.attach.remote_attach_workers_failed("os detail"),
        "could not start surface attach workers: os detail"
    );
    assert_eq!(
        JAPANESE.attach.remote_attach_workers_failed("os detail"),
        "リモートサーフェス接続ワーカーを開始できませんでした: os detail"
    );
    assert_eq!(
        ENGLISH.attach.unknown_terminal("missing"),
        "unknown terminal \"missing\"; use `cmux terminal list` to list terminal IDs"
    );
    assert_eq!(
        JAPANESE.attach.ambiguous_terminal("000010"),
        "ターミナル参照 \"000010\" は曖昧です。`cmux terminal list` に表示される一意の ID を使用してください"
    );
    assert_eq!(
        JAPANESE.attach.browser_not_terminal("browser"),
        "サーフェス \"browser\" はブラウザであり、ターミナルではありません"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").terminal.keyboard_text_too_large,
        "キーボード入力が 4 MiB の PTY バッファ上限を超えています"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").terminal.clear_history_help,
        "アクティブなプロンプトを保持したまま PTY 履歴を消去します。"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").terminal.clear_history_unsupported,
        "このサーバーでは clear-history を使用できません。cmux-tui サーバーを再起動してください"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_disconnected,
        "マシンプロバイダーから切断されました。再接続しています"
    );
    assert_eq!(catalog_for_locale("en_US.UTF-8").machine_agent.pairing_code, "Pairing code");
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").machine_agent.retrying_message(250),
        "Cloud connection lost; retrying in 250 ms"
    );
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").machine_agent.pairing_code, "ペアリングコード");
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").machine_agent.retrying_message(250),
        "クラウド接続が切断されました。250 ミリ秒後に再接続します"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").machine_agent.migration_failed,
        "Could not reconnect the machine; please try again"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").machine_agent.migration_failed,
        "マシンを再接続できませんでした。もう一度お試しください"
    );
    assert!(
        catalog_for_locale("en_US.UTF-8")
            .machine_agent
            .help
            .contains("share one local cmux session through a remote service")
    );
    assert!(
        catalog_for_locale("ja_JP.UTF-8")
            .machine_agent
            .help
            .contains("ローカルの cmux セッションをリモートサービス経由で共有")
    );
    assert!(!catalog_for_locale("en_US.UTF-8").machine_agent.help.contains("BatchMode"));
    assert!(!catalog_for_locale("ja_JP.UTF-8").machine_agent.help.contains("BatchMode"));
    assert!(
        catalog_for_locale("en_US.UTF-8")
            .machine_agent
            .pairing_code_unavailable
            .contains("interactive terminal")
    );
    assert!(
        catalog_for_locale("ja_JP.UTF-8")
            .machine_agent
            .pairing_code_unavailable
            .contains("対話型端末")
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
        "Invalid --cloud-port value: invalid"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
        "--cloud-port の値が無効です: invalid"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.machine_action_failed,
        "Machine action failed"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.provider_notice_identity_unavailable,
        "Could not prepare the connection. Try again; if the problem persists, restart cmux."
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.provider_connection_already_running,
        "Another connection is already running. Close it and try again."
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.connect_prompt,
        "Host address or pairing code"
    );
    assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.new_machine, "new vm");
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.new_machine, "新規VM");
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.connect_prompt,
        "ホストアドレスまたはペアリングコード"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.connect_host_prompt,
        "SSH host or user@host"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.connect_host_prompt,
        "SSH ホストまたは user@host"
    );
    assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.ssh_hosts, "SSH hosts");
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.ssh_hosts, "SSH ホスト");
    assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.type_to_filter, "type to filter");
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.type_to_filter, "入力して絞り込み");
    assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.other_host, "Add SSH host…");
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.other_host, "SSH ホストを追加…");
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.machine_name_required,
        "Enter a machine name"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_name_required,
        "マシン名を入力してください"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_action_failed,
        "マシン操作に失敗しました"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.provider_notice_identity_unavailable,
        "接続を準備できませんでした。もう一度お試しください。問題が解決しない場合は、cmux を再起動してください。"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.provider_connection_already_running,
        "別の接続がすでに実行中です。終了してから、もう一度お試しください。"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_external_connect_ambiguous,
        "前回の接続処理が完了している可能性があります。プロバイダーを再接続し、同じペアリングコードで再試行してください"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_stale,
        "マシン切り替えの状態が古くなっています"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_catalog_updates_failed,
        "マシンカタログの更新を開始できませんでした"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_worker_stopped,
        "確定前にマシン切り替え処理が停止しました"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_not_ready_to_connect,
        "選択したマシンは接続準備ができていません"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_unsupported,
        "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_invalid,
        "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.confirm_layout_undo,
        "Type CONFIRM to close pane(s) {items}"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.confirm_layout_undo,
        "ペイン {items} を閉じるには CONFIRM と入力"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.layout_nothing_to_undo,
        "元に戻せるレイアウト操作はありません"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.layout_undo_stale,
        "レイアウトが変更されたため、元に戻す操作は適用されませんでした"
    );
    let japanese_layout = &catalog_for_locale("ja_JP.UTF-8").layout;
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").layout.surface_size_release_failed(7, "disconnected"),
        "surface 7 size release failed; retrying on the next layout: disconnected"
    );
    assert_eq!(
        japanese_layout.surface_size_release_failed(7, "切断"),
        "サーフェス 7 のサイズ設定の解放に失敗しました。次回のレイアウト更新時に再試行します: 切断"
    );
    assert_eq!(
        japanese_layout.viewport_width_out_of_range,
        "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください"
    );
    assert_eq!(
        japanese_layout.viewport_width_must_be_finite,
        "--width には有限の数値を指定してください"
    );
    assert_eq!(japanese_layout.viewport_width_must_be_number, "--width には数値を指定してください");
    assert_eq!(japanese_layout.ratio_must_be_number, "--ratio には数値を指定してください");
    assert_eq!(japanese_layout.ratio_must_be_finite, "--ratio には有限の数値を指定してください");
    assert_eq!(
        japanese_layout.pane_without_resizable_column(42),
        "ペイン 42 にはサイズ変更可能なビューポート列がありません"
    );
    assert_eq!(
        japanese_layout.unsupported_server_command("undo-layout"),
        "undo-layout はこのサーバーではサポートされていません"
    );
    assert_eq!(japanese_layout.layout_undo_applied(3, 9), "元に戻しました screen=3 revision=9");
    assert_eq!(
        japanese_layout.layout_undo_confirmation_required(8, "15,16"),
        "確認が必要です: --revision 8 --confirm-close を付けて再実行してください（閉じるペイン: 15,16）"
    );
    assert_eq!(
        japanese_layout.layout_undo_confirmation_flags_together,
        "--revision と --confirm-close は同時に指定してください"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").runtime.renderer_panicked("描画セルが無効"),
        "ターミナル描画処理でパニックが発生しました: 描画セルが無効"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").runtime.host_input_failed("切断"),
        "ホストターミナルの入力に失敗しました: 切断"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").runtime.signal_handlers_failed("権限がありません"),
        "シグナルハンドラーの設定に失敗しました: 権限がありません"
    );
    assert_eq!(
        catalog_for_locale("en_US.UTF-8")
            .runtime
            .terminal_restore_also_failed("event loop failed", "restore failed"),
        "event loop failed; host terminal restoration also failed: restore failed"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8")
            .runtime
            .terminal_restore_also_failed("イベントループ失敗", "復元失敗"),
        "イベントループ失敗; ホストターミナルの復元にも失敗しました: 復元失敗"
    );
}

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
fn option_mode_config_warning_is_localized() {
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").config.invalid_macos_option_as_alt("\"guess\""),
        "cmux-tui: ignoring non-boolean keys.macos_option_as_alt = \"guess\""
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").config.invalid_macos_option_as_alt("\"guess\""),
        "cmux-tui: 真偽値ではない keys.macos_option_as_alt = \"guess\" を無視します"
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
fn browser_control_failures_are_localized_at_the_ui_boundary() {
    assert_eq!(
        catalog_for_locale("en_US.UTF-8")
            .browser
            .control_failed("browser panes are not supported over attach yet"),
        "browser command failed: browser panes are not supported over attach yet"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8")
            .browser
            .control_failed("browser panes are not supported over attach yet"),
        "ブラウザ操作に失敗しました: browser panes are not supported over attach yet"
    );
}

#[test]
fn workspace_port_provider_actions_use_localized_labels() {
    assert_eq!(
        catalog().sidebar.provider_action_label(provider_action_id::LIST_WORKSPACE_PORTS),
        Some(catalog().sidebar.action_list_workspace_ports)
    );
    assert_eq!(
        catalog()
            .sidebar
            .provider_action_field_label(provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC, "port"),
        Some(catalog().sidebar.action_workspace_port)
    );
    assert_eq!(catalog().sidebar.provider_action_label("external.action"), None);
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

#[test]
fn usd_formatting_is_two_decimal_and_grouped() {
    assert_eq!(format_usd(0.0), "$0.00");
    assert_eq!(format_usd(1.234), "$1.23");
    assert_eq!(format_usd(1.235), "$1.24");
    assert_eq!(format_usd(999.999), "$1,000.00");
    assert_eq!(format_usd(1234567.5), "$1,234,567.50");
    assert_eq!(format_usd(-3.0), "$0.00");
    assert_eq!(format_usd(f64::NAN), "$0.00");
    assert_eq!(format_usd(f64::INFINITY), "$0.00");
}

#[test]
fn machine_usage_readout_is_localized() {
    assert_eq!(
        catalog_for_locale("en_US.UTF-8").sidebar.machine_usage_readout(1.23, 30),
        "$1.23 / 30d"
    );
    assert_eq!(
        catalog_for_locale("ja_JP.UTF-8").sidebar.machine_usage_readout(1.23, 30),
        "$1.23 / 30日"
    );
}
