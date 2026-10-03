//! `pairing` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PairingMessages {
    pub title: &'static str,
    pub confirm: &'static str,
    pub peer_prefix: &'static str,
    pub deny: &'static str,
    pub approve: &'static str,
}

pub(super) const ENGLISH: PairingMessages = PairingMessages {
    title: "Approve browser?",
    confirm: "Confirm this code matches the browser:",
    peer_prefix: "from",
    deny: "[ Deny esc ]",
    approve: "[ Approve enter ]",
};

pub(super) const JAPANESE: PairingMessages = PairingMessages {
    title: "ブラウザを承認しますか？",
    confirm: "ブラウザのコードと一致するか確認:",
    peer_prefix: "接続元:",
    deny: "[ 拒否 esc ]",
    approve: "[ 承認 enter ]",
};
