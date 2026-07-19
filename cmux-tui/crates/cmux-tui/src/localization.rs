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
}

impl ForeignViewportMessages {
    pub fn hint(&self, cols: u16, rows: u16) -> String {
        format!("{} ({cols}x{rows})", self.sized_by_another_client)
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
    fn foreign_viewport_hints_are_neutral_and_stack_backed() {
        let english = ENGLISH.foreign_viewport.hint(12, 5).expect("English hint fits inline");
        assert_eq!(english.as_str(), "terminal grid (12x5)");
        assert_eq!(english.inline_capacity(), 64);
        assert_eq!(ENGLISH.foreign_viewport.hint_width(12, 5), 20);

        let japanese = JAPANESE.foreign_viewport.hint(12, 5).expect("Japanese hint fits inline");
        assert_eq!(japanese.as_str(), "端末グリッド (12x5)");
        assert_eq!(japanese.inline_capacity(), 64);
        assert_eq!(JAPANESE.foreign_viewport.hint_width(12, 5), 19);
    }
}
