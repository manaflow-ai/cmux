//! Help for the Chief build experiment in the CLI's supported locales.

pub(crate) const ENGLISH_HELP: &str = "usage: cmux chief build --ref SHA --tag TAG --workspace ID --receipt FILE [--timeout SECONDS]\n\n\
  Labs experiment: submit one exact cmux commit to cmux-ci, then wait on its job.\n\
  Enable Settings > Advanced > Labs > Show Preview Features first.\n\
  SHA is a full lowercase 40-character commit; ID is a PR URL or durable workspace.\n\
  Repeat the same command and receipt to resume waiting, never to resubmit.\n\
  --timeout bounds each wait (default 600 seconds, maximum 86400).\n\
  FILE is the fleet submission receipt; FILE.terminal.json is the latest wait receipt.\n\
  An ambiguous submission requires reconciliation with cmux-ci status.\n\
  A successful build is not test proof. Fleet output and exit codes are preserved.";

pub(crate) const JAPANESE_HELP: &str = "使い方: cmux chief build --ref SHA --tag TAG --workspace ID --receipt FILE [--timeout SECONDS]\n\n\
  Labs の実験機能: 指定したコミットを cmux-ci に送信し、そのジョブを待ちます。\n\
  設定 > 詳細 > Labs でプレビュー機能を有効にしてください。\n\
  SHA は小文字の40文字のコミット ID、ID は PR の URL または永続的なワークスペース ID です。\n\
  タイムアウト後は同じコマンドとレシートで待機を再開します。ビルドを再送信しません。\n\
  --timeout は待機時間です (既定600秒、最大86400秒)。\n\
  FILE は送信レシート、FILE.terminal.json は最新の待機レシートです。\n\
  送信結果が不明な場合は cmux-ci status で確認してください。\n\
  ビルド成功はテストの証明ではありません。fleet の出力と終了コードを保持します。";

pub(crate) fn help() -> &'static str {
    if std::ptr::eq(super::catalog(), super::catalog_for_locale("ja")) {
        JAPANESE_HELP
    } else {
        ENGLISH_HELP
    }
}

/// The CLI currently selects English or Japanese. Preserve diagnostic placeholders.
pub(crate) fn text(english: &'static str) -> &'static str {
    if !std::ptr::eq(super::catalog(), super::catalog_for_locale("ja")) {
        return english;
    }
    match english {
        "--ref must be a full lowercase 40-character commit SHA" => {
            "--ref には小文字40文字の完全なコミット SHA が必要です"
        }
        "--timeout must be between 1 and 86400 seconds" => {
            "--timeout は1〜86400秒で指定してください"
        }
        "Chief build is off. Enable Settings > Advanced > Labs > Show Preview Features." => {
            "Chief のビルドは無効です。設定 > 詳細 > Labs でプレビュー機能を有効にしてください。"
        }
        "This receipt belongs to a different commit, tag or workspace." => {
            "このレシートは別のコミット、タグ、またはワークスペースのものです。"
        }
        "Fleet receipt does not match this cmux commit and workspace; reconcile before continuing." => {
            "fleet のレシートがこのコミットとワークスペースに一致しません。続行する前に確認してください。"
        }
        "Fleet receipt has no valid job ID; do not resubmit." => {
            "fleet のレシートに有効なジョブ ID がありません。再送信しないでください。"
        }
        "cmux-ci helper timed out; the fleet job is unchanged. Reconcile the receipt before retrying." => {
            "cmux-ci がタイムアウトしました。fleet のジョブは変更されていません。再試行前にレシートを確認してください。"
        }
        "unknown argument {key}" => "不明な引数: {key}",
        "{key} needs a value" => "{key} には値が必要です",
        "duplicate argument {key}" => "引数が重複しています: {key}",
        "missing {key}" => "{key} がありません",
        "{} exceeds the receipt size limit" => "{} はレシートのサイズ上限を超えています",
        "Submission state is uncertain at {}. Reconcile with cmux-ci status; do not resubmit or remove receipts." => {
            "{} の送信状態は不明です。cmux-ci status で確認してください。再送信やレシートの削除はしないでください。"
        }
        "{}: {e}; no submission made" => "{}: {e}; 送信されていません",
        "cmux: submission did not complete; reconcile {} with cmux-ci status before retrying" => {
            "cmux: 送信が完了していません。再試行前に cmux-ci status で {} を確認してください"
        }
        "cmux: waiting on fleet job {job}; repeat this command to resume. A build is not test proof." => {
            "cmux: fleet のジョブ {job} を待機中です。同じコマンドで再開できます。ビルドはテストの証明ではありません。"
        }
        "cannot start cmux-ci: {e}; reconcile the saved request before retrying" => {
            "cmux-ci を起動できません: {e}; 再試行前に保存されたリクエストを確認してください"
        }
        "cmux-ci wait failed: {error}; reconcile the receipt before retrying" => {
            "cmux-ci の待機に失敗しました: {error}; 再試行前にレシートを確認してください"
        }
        _ => english,
    }
}
