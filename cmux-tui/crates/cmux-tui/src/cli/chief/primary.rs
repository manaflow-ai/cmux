//! `cmux chief primary CHIEF`: makes CHIEF the person's primary Chief, the one texts to the cmux
//! line reach (Lawrence 2026-11-02). It runs the app's `home.setPrimaryChief` (CLI name
//! `home primary-chief`), the same path as the Chief settings' Primary row and the `/primary`
//! text: `chief.update {is_default: true}` on the account's Chief record. CHIEF is an id
//! (agent_...) or a name. `cmux chief primary` alone lists the Chiefs (`cmux chief list`).

use super::GlobalArgs;

/// The app action's CLI name.
pub(super) const ACTION: &str = "home primary-chief";

struct Text {
    usage: &'static str,
    unreachable: &'static str,
}

static ENGLISH: Text = Text {
    usage: "usage: cmux chief primary CHIEF\n\n  Makes CHIEF (an id, agent_..., or a name) your primary Chief: texts to the\n  cmux line go to it. The same setting as Chief Settings > Primary Chief and\n  the /primary text. cmux chief list shows your Chiefs.",
    unreachable: "cmux chief primary needs the cmux app running (it sets the Chief on your cmux account)",
};

static JAPANESE: Text = Text {
    usage: "使い方: cmux chief primary CHIEF\n\n  CHIEF (id の agent_... または名前) をメインの Chief にします。cmux の番号への\n  テキストはこの Chief に届きます。Chief 設定の「メインの Chief」と /primary\n  テキストと同じ設定です。cmux chief list で Chief の一覧を表示します。",
    unreachable: "cmux chief primary には cmux アプリの起動が必要です (cmux アカウントの Chief を設定します)",
};

fn text() -> &'static Text {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}

/// What `cmux chief primary ARGS` runs: the action's flags, or `Err(usage)` / `Ok(None)` for help.
pub(super) fn action_args(args: &[String]) -> Result<Option<Vec<String>>, String> {
    let mut chief: Option<String> = None;
    for arg in args {
        match arg.as_str() {
            "-h" | "--help" => return Ok(None),
            other if other.starts_with('-') => return Err(format!("unknown argument {other}")),
            other if chief.is_none() => chief = Some(other.to_owned()),
            other => return Err(format!("cmux chief primary takes one Chief, not also {other}")),
        }
    }
    let chief = chief.ok_or_else(|| {
        "cmux chief primary needs the Chief: an id (agent_...) or its name".to_owned()
    })?;
    Ok(Some(vec!["--chief".into(), chief]))
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let flags = match action_args(args) {
        Ok(Some(flags)) => flags,
        Ok(None) => {
            println!("{}", text().usage);
            return 0;
        }
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", text().usage);
            return 2;
        }
    };
    match super::super::app::run_cli_action(global, ACTION, &flags) {
        Some(code) => code,
        None => {
            eprintln!("cmux: {}", text().unreachable);
            3
        }
    }
}
