//! `auth handoff` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AuthHandoffMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub bad_device: &'static str,
    pub code_in_argv: &'static str,
    pub stdin_terminal: &'static str,
    pub stdin_unreadable: &'static str,
    pub stdin_empty: &'static str,
    pub stdin_not_code: &'static str,
    pub bad_answer: &'static str,
    pub signed_in: &'static str,
    pub err_handoff_invalid: &'static str,
    pub err_other_user: &'static str,
    pub err_not_signed_in: &'static str,
    pub err_sso_required: &'static str,
    pub err_rate_limited: &'static str,
    pub err_unavailable: &'static str,
}

pub(super) const ENGLISH: AuthHandoffMessages = AuthHandoffMessages {
    usage: "usage: cmux auth handoff mint [--device NAME] [--json]\n       cmux auth handoff redeem [--device NAME] [--json] < CODE\n\nSign the cmux app on another Mac of yours in to the same account, with no typing\nthere. On the Mac that is signed in, mint a one-time code; send it to the other\nMac over ssh stdin, where redeem hands it to that Mac's running cmux app:\n\n  cmux auth handoff mint --device air-blue --json\n  printf '%s\\n' \"$CODE\" | ssh air-blue cmux auth handoff redeem --json\n\nA code lasts at most two minutes and works once. redeem reads it from stdin only,\nnever from an argument or the environment, and the tokens stay in the app.\nmint prints {code, expiresAt, user, email, device}; redeem prints\n{signedIn, alreadySignedIn, user: {id, email}, device: {name}}.\n\n  --device NAME  The device's name, for the account's audit record.\n\nExit codes: 0 signed in (or minted), 2 bad usage or stdin, 3 the code was spent,\nexpired or wrong (or minting was refused), 4 the app or cmux could not be\nreached, 5 the app is signed in as another account (the code is not spent).\n",
    unknown_verb: "unknown auth handoff verb \"{verb}\"; use mint or redeem (`cmux auth handoff --help`)",
    bad_device: "--device takes a name of at most 64 printable characters",
    code_in_argv: "redeem reads the code from stdin only, never from an argument: printf '%s\\n' \"$CODE\" | cmux auth handoff redeem",
    stdin_terminal: "redeem reads the code from stdin: pipe it in (printf '%s\\n' \"$CODE\" | cmux auth handoff redeem)",
    stdin_unreadable: "could not read the code from stdin",
    stdin_empty: "no code on stdin: pipe in the code `cmux auth handoff mint` printed",
    stdin_not_code: "stdin is not a hand-off code: pipe in exactly the one line `cmux auth handoff mint` printed",
    bad_answer: "the cmux app sent an answer this CLI can't use: compare the two with `cmux version`",
    signed_in: "cmux on this Mac is signed in as {user}",
    err_handoff_invalid: "the hand-off code expired, was used, or is not a code: mint a new one",
    err_other_user: "cmux on this Mac is signed in as another account: sign out there first (the code was not used)",
    err_not_signed_in: "sign in to cmux on this Mac first",
    err_sso_required: "your organization requires sign-in with its SSO on each device",
    err_rate_limited: "too many hand-off codes: try again in a few minutes",
    err_unavailable: "cmux could not be reached: try again in a moment",
};

pub(super) const JAPANESE: AuthHandoffMessages = AuthHandoffMessages {
    usage: "使い方: cmux auth handoff mint [--device 名前] [--json]\n        cmux auth handoff redeem [--device 名前] [--json] < コード\n\nあなたの別の Mac の cmux アプリを、そこで何も入力せずに同じアカウントでサインイン\nさせます。サインイン中の Mac で 1 回限りのコードを発行し、ssh の標準入力で別の Mac\nに送ると、redeem がその Mac で動いている cmux アプリに渡します:\n\n  cmux auth handoff mint --device air-blue --json\n  printf '%s\\n' \"$CODE\" | ssh air-blue cmux auth handoff redeem --json\n\nコードの有効期間は最長 2 分で、1 回だけ使えます。redeem は標準入力からだけ読み、\n引数や環境変数からは読みません。トークンはアプリの中に留まります。\nmint は {code, expiresAt, user, email, device} を、redeem は\n{signedIn, alreadySignedIn, user: {id, email}, device: {name}} を表示します。\n\n  --device 名前  デバイスの名前 (アカウントの監査記録用)。\n\n終了コード: 0 サインイン済み (または発行済み)、2 使い方か標準入力の誤り、3 コードが\n使用済み・期限切れ・不正 (または発行を拒否)、4 アプリか cmux に接続できない、\n5 アプリが別のアカウントでサインイン中 (コードは消費されません)。\n",
    unknown_verb: "auth handoff の動詞「{verb}」は不明です。mint か redeem を使ってください (`cmux auth handoff --help`)",
    bad_device: "--device には 64 文字以内の表示可能な名前を指定してください",
    code_in_argv: "redeem はコードを標準入力からだけ読み、引数からは読みません: printf '%s\\n' \"$CODE\" | cmux auth handoff redeem",
    stdin_terminal: "redeem はコードを標準入力から読みます。パイプで渡してください (printf '%s\\n' \"$CODE\" | cmux auth handoff redeem)",
    stdin_unreadable: "標準入力からコードを読めませんでした",
    stdin_empty: "標準入力にコードがありません。`cmux auth handoff mint` が表示したコードをパイプで渡してください",
    stdin_not_code: "標準入力がハンドオフコードではありません。`cmux auth handoff mint` が表示した 1 行だけを渡してください",
    bad_answer: "cmux アプリの応答をこの CLI が使えません。`cmux version` で両者を比べてください",
    signed_in: "この Mac の cmux は {user} としてサインインしています",
    err_handoff_invalid: "ハンドオフコードが期限切れ・使用済み・不正です。新しいコードを発行してください",
    err_other_user: "この Mac の cmux は別のアカウントでサインインしています。先にサインアウトしてください (コードは使われていません)",
    err_not_signed_in: "先にこの Mac で cmux にサインインしてください",
    err_sso_required: "組織の設定により、各デバイスで SSO によるサインインが必要です",
    err_rate_limited: "ハンドオフコードの発行が多すぎます。数分後にもう一度試してください",
    err_unavailable: "cmux に接続できませんでした。しばらくしてからもう一度試してください",
};
