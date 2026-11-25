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
    /// After an invite begin: who confirms this machine (`{inviter}`) and that the words must match.
    pub invite_confirm: &'static str,
    /// The same when the API named nobody.
    pub invite_confirm_anyone: &'static str,
    /// `Paired as NAME` after an invite.
    pub paired_as: &'static str,
    pub invite_unknown: &'static str,
    pub invite_used: &'static str,
    pub invite_voided: &'static str,
}

impl Messages {
    /// A sentence for an invite failure's code (`server.pair.invite_*`), else none.
    pub(crate) fn explain(&self, code: &str) -> Option<&'static str> {
        match code {
            super::invite::UNKNOWN => Some(self.invite_unknown),
            super::invite::USED => Some(self.invite_used),
            super::invite::VOIDED => Some(self.invite_voided),
            "server.pair.invalid_invite" => Some(self.invite_unknown),
            _ => None,
        }
    }
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
            invite_confirm: "{inviter} さんが cmux アプリでこのマシンを確認します。相手の画面の単語と一致することを確かめてください。",
            invite_confirm_anyone: "招待した人が cmux アプリでこのマシンを確認します。相手の画面の単語と一致することを確かめてください。",
            paired_as: "ペアリング完了:",
            invite_unknown: "招待コードの有効期限が切れたか、正しくありません。cmux アプリで新しいコードを作成してください",
            invite_used: "この招待コードは使用済みか、新しいコードに置き換えられました。cmux アプリで新しいコードを作成してください",
            invite_voided: "確認される前に招待が取り消されました(別のマシンが使用したか、新しい招待に置き換えられました)",
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
            invite_confirm: "{inviter} bestätigt diesen Rechner in der cmux-App. Prüfe, dass diese Wörter mit denen auf dem anderen Bildschirm übereinstimmen.",
            invite_confirm_anyone: "Die Person, die die Einladung erstellt hat, bestätigt diesen Rechner in der cmux-App. Prüfe, dass diese Wörter mit denen auf ihrem Bildschirm übereinstimmen.",
            paired_as: "Gekoppelt als",
            invite_unknown: "Der Einladungscode ist abgelaufen oder ungültig; erstelle in der cmux-App einen neuen",
            invite_used: "Der Einladungscode wurde bereits verwendet oder durch einen neueren ersetzt; erstelle in der cmux-App einen neuen",
            invite_voided: "Die Einladung wurde vor der Bestätigung widerrufen (ein anderer Rechner hat sie verwendet oder eine neuere hat sie ersetzt)",
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
            invite_confirm: "{inviter} confirme cette machine dans l’app cmux. Vérifiez que ces mots correspondent à ceux de son écran.",
            invite_confirm_anyone: "La personne qui a créé l’invitation confirme cette machine dans l’app cmux. Vérifiez que ces mots correspondent à ceux de son écran.",
            paired_as: "Associé sous le nom",
            invite_unknown: "Le code d’invitation a expiré ou n’est pas valide ; créez-en un nouveau dans l’app cmux",
            invite_used: "Le code d’invitation a déjà été utilisé ou remplacé par un plus récent ; créez-en un nouveau dans l’app cmux",
            invite_voided: "L’invitation a été annulée avant d’être confirmée (une autre machine l’a utilisée ou une invitation plus récente l’a remplacée)",
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
            invite_confirm: "{inviter} confirma esta máquina en la app cmux. Comprueba que estas palabras coinciden con las de su pantalla.",
            invite_confirm_anyone: "La persona que creó la invitación confirma esta máquina en la app cmux. Comprueba que estas palabras coinciden con las de su pantalla.",
            paired_as: "Vinculado como",
            invite_unknown: "El código de invitación caducó o no es válido; crea uno nuevo en la app cmux",
            invite_used: "El código de invitación ya se usó o lo sustituyó otro más reciente; crea uno nuevo en la app cmux",
            invite_voided: "La invitación se canceló antes de confirmarse (otra máquina la usó o la sustituyó una más reciente)",
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
            invite_confirm: "سيؤكد {inviter} هذا الجهاز في تطبيق cmux. تحقق من تطابق هذه الكلمات مع الكلمات على شاشته.",
            invite_confirm_anyone: "سيؤكد صاحب الدعوة هذا الجهاز في تطبيق cmux. تحقق من تطابق هذه الكلمات مع الكلمات على شاشته.",
            paired_as: "تم الإقران باسم",
            invite_unknown: "انتهت صلاحية رمز الدعوة أو أنه غير صالح؛ أنشئ رمزًا جديدًا في تطبيق cmux",
            invite_used: "استُخدم رمز الدعوة بالفعل أو استُبدل برمز أحدث؛ أنشئ رمزًا جديدًا في تطبيق cmux",
            invite_voided: "أُلغيت الدعوة قبل تأكيدها (استخدمها جهاز آخر أو استُبدلت بدعوة أحدث)",
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
            invite_confirm: "{inviter} 님이 cmux 앱에서 이 기기를 확인합니다. 상대 화면의 단어와 일치하는지 확인하세요.",
            invite_confirm_anyone: "초대를 만든 사람이 cmux 앱에서 이 기기를 확인합니다. 상대 화면의 단어와 일치하는지 확인하세요.",
            paired_as: "페어링됨:",
            invite_unknown: "초대 코드가 만료되었거나 올바르지 않습니다. cmux 앱에서 새 코드를 만드세요",
            invite_used: "초대 코드가 이미 사용되었거나 새 코드로 대체되었습니다. cmux 앱에서 새 코드를 만드세요",
            invite_voided: "확인되기 전에 초대가 취소되었습니다(다른 기기가 사용했거나 새 초대로 대체됨)",
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
                invite_confirm: "{inviter} 會在 cmux App 中確認這台機器。請確認這些詞語與對方螢幕上的相符。",
                invite_confirm_anyone: "建立邀請的人會在 cmux App 中確認這台機器。請確認這些詞語與對方螢幕上的相符。",
                paired_as: "已配對為",
                invite_unknown: "邀請碼已過期或無效；請在 cmux App 中建立新的邀請碼",
                invite_used: "邀請碼已被使用，或已被較新的邀請碼取代；請在 cmux App 中建立新的邀請碼",
                invite_voided: "邀請在確認前已被取消（另一台機器使用了它，或被較新的邀請取代）",
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
            invite_confirm: "{inviter} 将在 cmux 应用中确认这台机器。请确认这些词语与对方屏幕上的一致。",
            invite_confirm_anyone: "创建邀请的人将在 cmux 应用中确认这台机器。请确认这些词语与对方屏幕上的一致。",
            paired_as: "已配对为",
            invite_unknown: "邀请码已过期或无效；请在 cmux 应用中创建新的邀请码",
            invite_used: "邀请码已被使用，或已被更新的邀请码取代；请在 cmux 应用中创建新的邀请码",
            invite_voided: "邀请在确认前已被取消（另一台机器使用了它，或被更新的邀请取代）",
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
            invite_confirm: "{inviter} confirms this machine in the cmux app. Check that these words match the ones on their screen.",
            invite_confirm_anyone: "The person who made the invite confirms this machine in the cmux app. Check that these words match the ones on their screen.",
            paired_as: "Paired as",
            invite_unknown: "The invite code expired or is not valid; make a new one in the cmux app",
            invite_used: "The invite code was already used, or a newer one replaced it; make a new one in the cmux app",
            invite_voided: "The invite was cancelled before it was confirmed (another machine used it, or a newer invite replaced it)",
        },
    }
}
