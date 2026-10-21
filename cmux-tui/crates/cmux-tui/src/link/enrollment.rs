//! The enrolled-server CLI help, in every supported macOS language.

pub(super) fn help() -> &'static str {
    let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|key| std::env::var(key).ok().filter(|value| !value.is_empty()))
        .unwrap_or_default()
        .replace('-', "_")
        .to_ascii_lowercase();
    let language = locale.split(['_', '.', '@']).next().unwrap_or_default();
    match language {
        "de" => {
            "Vorhandene Identität eines gekoppelten Servers verwenden:\n  init --server-identity FILE [--port PORT]\nDer Schlüssel bleibt in der privaten Registrierungsdatei.\n"
        }
        "fr" => {
            "Utiliser l’identité existante d’un serveur associé :\n  init --server-identity FILE [--port PORT]\nLa clé reste dans le fichier d’inscription privé.\n"
        }
        "es" => {
            "Usar la identidad existente de un servidor vinculado:\n  init --server-identity FILE [--port PORT]\nLa clave permanece en el archivo privado de registro.\n"
        }
        "ar" => {
            "استخدام الهوية الحالية لخادم مقترن:\n  init --server-identity FILE [--port PORT]\nيبقى المفتاح في ملف التسجيل الخاص.\n"
        }
        "ko" => {
            "페어링된 서버의 기존 ID 사용:\n  init --server-identity FILE [--port PORT]\n키는 비공개 등록 파일에 유지됩니다.\n"
        }
        "ja" => {
            "ペアリング済みサーバーの既存の ID を使用:\n  init --server-identity FILE [--port PORT]\n鍵は非公開の登録ファイルに保持されます。\n"
        }
        "zh" if locale.contains("hant") || locale.contains("_tw") || locale.contains("_hk") => {
            "使用已配對伺服器的現有身分：\n  init --server-identity FILE [--port PORT]\n金鑰保留在私有註冊檔案中。\n"
        }
        "zh" => {
            "使用已配对服务器的现有身份：\n  init --server-identity FILE [--port PORT]\n密钥保留在私有注册文件中。\n"
        }
        _ => {
            "Use a paired server’s existing identity:\n  init --server-identity FILE [--port PORT]\nThe key stays in its private enrollment file.\n"
        }
    }
}
