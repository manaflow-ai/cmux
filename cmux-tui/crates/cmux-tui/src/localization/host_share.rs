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
    pub full_access: &'static str,
    pub surface: &'static str,
    pub terminal: &'static str,
    pub restarted: &'static str,
}

pub(crate) const ENGLISH: Messages = Messages {
    no_arguments: "takes no positional arguments",
    arguments: "needs a surface and tailnet login",
    role: "role must be member or guest",
    grant: "share needs a consented agents grant",
    confirm: "Shares expire when the daemon restarts. Type yes to confirm:",
    not_approved: "not approved; nothing changed",
    agents: "participate in agent chats shared with you",
    full_access: "this login has full access (cmux host allow); remove it with cmux host deny before sharing one chat",
    surface: "the surface must be a number (cmux list-workspaces shows it)",
    terminal: "a share must be confirmed by a person at a terminal on this machine",
    restarted: "the session daemon restarted while you confirmed; the surface may be another chat now, so nothing changed",
};
pub(crate) const JAPANESE: Messages = Messages {
    no_arguments: "位置引数は指定できません",
    arguments: "サーフェスと tailnet ログインを指定してください",
    role: "ロールには member または guest を指定してください",
    grant: "共有するには、同意済みの agents アクセス許可が必要です",
    confirm: "共有はデーモンの再起動で期限切れになります。確認するには yes と入力してください:",
    not_approved: "承認されませんでした。変更はありません",
    agents: "自分と共有されたエージェントチャットに参加する",
    full_access: "このログインにはフルアクセスがあります (cmux host allow)。チャットを共有する前に cmux host deny で削除してください",
    surface: "サーフェスは数値で指定してください (cmux list-workspaces で確認できます)",
    terminal: "共有は、このマシンの端末で本人が確認する必要があります",
    restarted: "確認中にセッションデーモンが再起動しました。サーフェスが別のチャットを指している可能性があるため、変更していません",
};
