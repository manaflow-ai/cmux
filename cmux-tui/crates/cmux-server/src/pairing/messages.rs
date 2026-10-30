//! Copy for the new server pairing flow. Protocol names and error codes stay invariant.

pub(crate) struct Messages {
    pub pair_help: &'static str,
    pub status_help: &'static str,
    pub code: &'static str,
    pub words: &'static str,
    pub approve: &'static str,
    pub paired: &'static str,
    pub unpaired: &'static str,
    pub pending: &'static str,
    pub network_pending: &'static str,
    pub indeterminate: &'static str,
    pub failed: &'static str,
}

pub(crate) fn current() -> Messages {
    let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .into_iter()
        .find_map(|key| std::env::var(key).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    for_locale(&locale)
}

pub(crate) fn for_locale(locale: &str) -> Messages {
    let locale = locale.to_ascii_lowercase().replace('_', "-");
    let lang = locale.split(['-', '.', '@']).next().unwrap_or_default();
    match lang {
        "ja" => Messages {
            pair_help: "cmux アプリでこのサーバーをペアリング",
            status_help: "このサーバーのペアリング状態を表示",
            code: "ペアリングコード:",
            words: "確認用の単語:",
            approve: "cmux アプリの「サーバーを追加」でコードを入力し、単語が一致することを確認して承認してください。",
            paired: "ペアリング済み",
            unpaired: "未ペアリング",
            pending: "承認待ち",
            network_pending: "ネットワーク登録待ち",
            indeterminate: "ペアリング結果を確認できません",
            failed: "サーバーのペアリングに失敗しました",
        },
        "de" => Messages {
            pair_help: "Diesen Server in der cmux-App koppeln",
            status_help: "Kopplungsstatus dieses Servers anzeigen",
            code: "Kopplungscode:",
            words: "Prüfwörter:",
            approve: "In der cmux-App „Server hinzufügen“ wählen, den Code eingeben, die Wörter vergleichen und bestätigen.",
            paired: "Gekoppelt",
            unpaired: "Nicht gekoppelt",
            pending: "Warten auf Bestätigung",
            network_pending: "Warten auf Netzwerkregistrierung",
            indeterminate: "Kopplungsergebnis unbekannt",
            failed: "Serverkopplung fehlgeschlagen",
        },
        "fr" => Messages {
            pair_help: "Associer ce serveur dans l’app cmux",
            status_help: "Afficher l’état d’association de ce serveur",
            code: "Code d’association :",
            words: "Mots de vérification :",
            approve: "Dans l’app cmux, choisissez « Ajouter un serveur », saisissez le code, comparez les mots et approuvez.",
            paired: "Associé",
            unpaired: "Non associé",
            pending: "En attente d’approbation",
            network_pending: "En attente d’inscription au réseau",
            indeterminate: "Résultat de l’association inconnu",
            failed: "Échec de l’association du serveur",
        },
        "es" => Messages {
            pair_help: "Vincular este servidor en la app cmux",
            status_help: "Mostrar el estado de vinculación de este servidor",
            code: "Código de vinculación:",
            words: "Palabras de verificación:",
            approve: "En la app cmux, elige «Añadir servidor», introduce el código, comprueba las palabras y aprueba.",
            paired: "Vinculado",
            unpaired: "Sin vincular",
            pending: "Esperando aprobación",
            network_pending: "Esperando el registro en la red",
            indeterminate: "Resultado de vinculación desconocido",
            failed: "No se pudo vincular el servidor",
        },
        "ar" => Messages {
            pair_help: "إقران هذا الخادم في تطبيق cmux",
            status_help: "عرض حالة إقران هذا الخادم",
            code: "رمز الإقران:",
            words: "كلمات التحقق:",
            approve: "في تطبيق cmux، اختر «إضافة خادم»، وأدخل الرمز، وتحقق من تطابق الكلمات، ثم وافق.",
            paired: "مقترن",
            unpaired: "غير مقترن",
            pending: "بانتظار الموافقة",
            network_pending: "بانتظار التسجيل في الشبكة",
            indeterminate: "نتيجة الإقران غير معروفة",
            failed: "تعذر إقران الخادم",
        },
        "ko" => Messages {
            pair_help: "cmux 앱에서 이 서버 페어링",
            status_help: "이 서버의 페어링 상태 표시",
            code: "페어링 코드:",
            words: "확인 단어:",
            approve: "cmux 앱에서 ‘서버 추가’를 선택하고 코드를 입력한 다음 단어가 일치하는지 확인하고 승인하세요.",
            paired: "페어링됨",
            unpaired: "페어링되지 않음",
            pending: "승인 대기 중",
            network_pending: "네트워크 등록 대기 중",
            indeterminate: "페어링 결과를 확인할 수 없음",
            failed: "서버 페어링에 실패했습니다",
        },
        "zh" if locale.contains("hant")
            || locale.starts_with("zh-tw")
            || locale.starts_with("zh-hk") =>
        {
            Messages {
                pair_help: "在 cmux App 中配對此伺服器",
                status_help: "顯示此伺服器的配對狀態",
                code: "配對碼：",
                words: "驗證詞語：",
                approve: "在 cmux App 中選擇「新增伺服器」，輸入配對碼，確認詞語相符後批准。",
                paired: "已配對",
                unpaired: "尚未配對",
                pending: "等待批准",
                network_pending: "等待網路註冊",
                indeterminate: "配對結果未知",
                failed: "伺服器配對失敗",
            }
        }
        "zh" => Messages {
            pair_help: "在 cmux 应用中配对此服务器",
            status_help: "显示此服务器的配对状态",
            code: "配对码：",
            words: "验证词语：",
            approve: "在 cmux 应用中选择“添加服务器”，输入配对码，确认词语一致后批准。",
            paired: "已配对",
            unpaired: "未配对",
            pending: "等待批准",
            network_pending: "等待网络注册",
            indeterminate: "配对结果未知",
            failed: "服务器配对失败",
        },
        _ => Messages {
            pair_help: "Pair this server in the cmux app",
            status_help: "Show this server’s pairing status",
            code: "Pairing code:",
            words: "Check words:",
            approve: "In the cmux app, choose Add Server, enter the code, check that the words match and approve.",
            paired: "Paired",
            unpaired: "Not paired",
            pending: "Waiting for approval",
            network_pending: "Awaiting network enrollment",
            indeterminate: "Pairing outcome unknown",
            failed: "Server pairing failed",
        },
    }
}
