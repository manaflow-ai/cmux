use std::sync::OnceLock;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PairingMessages {
    pub title: &'static str,
    pub confirm: &'static str,
    pub peer_prefix: &'static str,
    pub deny: &'static str,
    pub approve: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ForeignViewportMessages {
    pub sized_by_another_client: &'static str,
    pub type_to_take_over: &'static str,
    pub separator: &'static str,
}

impl ForeignViewportMessages {
    pub fn hint(&self, cols: u16, rows: u16) -> String {
        format!(
            "{} ({cols}x{rows}){}{}",
            self.sized_by_another_client, self.separator, self.type_to_take_over
        )
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Catalog {
    pub pairing: PairingMessages,
    pub foreign_viewport: ForeignViewportMessages,
}

static ENGLISH: Catalog = Catalog {
    pairing: PairingMessages {
        title: "Approve browser?",
        confirm: "Confirm this code matches the browser:",
        peer_prefix: "from",
        deny: "[ Deny esc ]",
        approve: "[ Approve enter ]",
    },
    foreign_viewport: ForeignViewportMessages {
        sized_by_another_client: "sized by another client",
        type_to_take_over: "type to take over",
        separator: ", ",
    },
};

static JAPANESE: Catalog = Catalog {
    pairing: PairingMessages {
        title: "ブラウザを承認しますか？",
        confirm: "ブラウザのコードと一致するか確認:",
        peer_prefix: "接続元:",
        deny: "[ 拒否 esc ]",
        approve: "[ 承認 enter ]",
    },
    foreign_viewport: ForeignViewportMessages {
        sized_by_another_client: "別のクライアントがサイズを決定中",
        type_to_take_over: "入力すると引き継ぎます",
        separator: "。",
    },
};

pub(crate) fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<&'static Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| catalog_for_locale(&system_locale()))
}

pub(crate) fn catalog_for_locale(locale: &str) -> &'static Catalog {
    if locale.to_ascii_lowercase().starts_with("ja") { &JAPANESE } else { &ENGLISH }
}

fn system_locale() -> String {
    std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LC_MESSAGES"))
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locale_tags_select_complete_catalogs() {
        assert_eq!(catalog_for_locale("en_US.UTF-8"), &ENGLISH);
        assert_eq!(catalog_for_locale("ja_JP.UTF-8"), &JAPANESE);
        assert_eq!(catalog_for_locale("C"), &ENGLISH);
    }

    #[test]
    fn foreign_viewport_hints_describe_state_without_promising_input_takeover() {
        assert_eq!(
            ENGLISH.foreign_viewport.hint(12, 5),
            "sized by another client (12x5)"
        );
        assert_eq!(
            JAPANESE.foreign_viewport.hint(12, 5),
            "別のクライアントがサイズを決定中 (12x5)"
        );
    }
}
