//! `auth` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AuthTokenMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub no_token: &'static str,
    pub whoami_usage: &'static str,
    pub whoami_signed_in: &'static str,
    pub whoami_no_team: &'static str,
    pub whoami_signed_out: &'static str,
}

pub(super) const ENGLISH: AuthTokenMessages = AuthTokenMessages {
    usage: "usage: cmux auth token [--team TEAM] [--json]\n\nPrint a short-lived cmux access token from the cmux app's signed-in session,\nfor the cmux platform API and hosted MCP outside the app:\n\n  export CMUX_TOKEN=$(cmux auth token)\n  curl -H \"Authorization: Bearer $CMUX_TOKEN\" https://<platform>/v1/machines\n\nThe token is good for about ten minutes and has no refresh token: ask again\nwhen it expires. It acts for your account and one team, and can never run\ncommands on a machine. Sign in in the cmux app first.\n\n  --team TEAM   The team (team_ and 20 hex digits). Default: the app's team.\n  --json        Also print token_type, team, user, expires_at, expires_in and\n                api_origin (the cmux API that issued it).\n\nSee docs/cmux-next/auth-token.md.\n",
    unknown_verb: "unknown auth verb \"{verb}\"; use token",
    no_token: "the cmux app answered auth.token without a token",
    whoami_usage: "usage: cmux whoami [--json]\n\nSay who the cmux app is signed in as: your cmux user and team.\nSign in with `cmux login`, sign out with `cmux logout`.\n",
    whoami_signed_in: "Signed in to cmux as user {user}, team {team}",
    whoami_no_team: "Signed in to cmux, with no team chosen: choose one in the cmux app",
    whoami_signed_out: "Not signed in to cmux. Run `cmux login`.",
};

pub(super) const JAPANESE: AuthTokenMessages = AuthTokenMessages {
    usage: "使い方: cmux auth token [--team チーム] [--json]\n\ncmux アプリのサインイン中のセッションから、短時間だけ有効な cmux アクセス\nトークンを表示します。アプリの外から cmux プラットフォーム API とホスト型 MCP\nを使うためのものです:\n\n  export CMUX_TOKEN=$(cmux auth token)\n  curl -H \"Authorization: Bearer $CMUX_TOKEN\" https://<platform>/v1/machines\n\nトークンの有効期間は約 10 分で、リフレッシュトークンはありません。期限が切れたら\nもう一度実行してください。あなたのアカウントと 1 つのチームとして動作し、マシン上で\nコマンドを実行することはできません。先に cmux アプリでサインインしてください。\n\n  --team チーム  チーム (team_ と 16 進数 20 桁)。既定はアプリのチーム。\n  --json         token_type、team、user、expires_at、expires_in と api_origin\n                 (発行した cmux API) も表示します。\n\ndocs/cmux-next/auth-token.md を参照。\n",
    unknown_verb: "auth の動詞「{verb}」は不明です。token を使ってください",
    no_token: "cmux アプリの auth.token の応答にトークンがありません",
    whoami_usage: "使い方: cmux whoami [--json]\n\ncmux アプリがどのアカウントでサインインしているか (cmux ユーザーとチーム) を表示します。\nサインインは `cmux login`、サインアウトは `cmux logout` です。\n",
    whoami_signed_in: "cmux にユーザー {user}、チーム {team} としてサインインしています",
    whoami_no_team: "cmux にサインインしていますが、チームが選ばれていません。cmux アプリで選んでください",
    whoami_signed_out: "cmux にサインインしていません。`cmux login` を実行してください。",
};
