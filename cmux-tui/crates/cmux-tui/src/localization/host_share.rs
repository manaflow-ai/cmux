//! Host chat consent, in the CLI catalog's English and Japanese locales.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Messages {
    pub no_arguments: &'static str,
    pub arguments: &'static str,
    pub role: &'static str,
    pub grant: &'static str,
    pub confirm: &'static str,
    pub not_approved: &'static str,
    pub agents: &'static str,
}

pub(crate) const ENGLISH: Messages = Messages {
    no_arguments: "takes no positional arguments",
    arguments: "needs a surface and tailnet login",
    role: "role must be member or guest",
    grant: "share needs a consented agents grant",
    confirm: "Shares expire when the daemon restarts. Type yes to confirm:",
    not_approved: "not approved; nothing changed",
    agents: "participate in agent chats shared with you",
};
pub(crate) const JAPANESE: Messages = Messages {
    no_arguments: "位置引数は指定できません",
    arguments: "サーフェスと tailnet ログインを指定してください",
    role: "ロールには member または guest を指定してください",
    grant: "共有するには、同意済みの agents アクセス許可が必要です",
    confirm: "共有はデーモンの再起動で期限切れになります。確認するには yes と入力してください:",
    not_approved: "承認されませんでした。変更はありません",
    agents: "自分と共有されたエージェントチャットに参加する",
};
