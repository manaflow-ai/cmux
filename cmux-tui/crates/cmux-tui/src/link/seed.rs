//! `cmux link seed plan --local FOLDER --bundle OUT [--base SHA]`: plans a
//! `git-seed-v1` seed of a git working copy with a GitHub remote and
//! writes its bundle ([`plan`]). Not wired into `start-chat` yet.
//!
//! Output: one JSON line on stdout. A plan is `{"ok":true,"params":{...},
//! "skipped":[{"path","why"}],"submodules":[{"path","commit"}],
//! "bases":[...],"bundle_bytes":N,"unchanged":false}`, exit 0. A folder that takes the
//! streamed copy instead is `{"ok":false,"code":CODE,"why":TEXT}`, exit 1
//! ([`plan::FallbackCode`]). Bad usage exits 64.

mod git;
mod github;
pub(crate) mod plan;
mod secrets;
#[cfg(test)]
mod tests;

use std::path::PathBuf;

use serde_json::json;

const USAGE: &str = "usage: cmux link seed plan --local FOLDER --bundle OUT [--base SHA]";

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), None | Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return if args.is_empty() { 64 } else { 0 };
    }
    let Some((local, bundle, base)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let planned = match &base {
        Some(base) => plan::plan_with_base(&local, &bundle, base),
        None => plan::plan(&local, &bundle),
    };
    match planned {
        Ok(planned) => {
            let mut line = serde_json::to_value(&planned).unwrap_or_else(|_| json!({}));
            if let Some(object) = line.as_object_mut() {
                object.insert("ok".into(), json!(true));
            }
            println!("{line}");
            0
        }
        Err(fallback) => {
            println!(
                "{}",
                json!({ "ok": false, "code": fallback.code.as_str(), "why": fallback.why })
            );
            1
        }
    }
}

fn parse(args: &[String]) -> Option<(PathBuf, PathBuf, Option<String>)> {
    let (action, rest) = args.split_first()?;
    if action != "plan" {
        return None;
    }
    let (mut local, mut bundle, mut base) = (None, None, None);
    let mut rest = rest.iter();
    while let Some(flag) = rest.next() {
        let value = rest.next()?;
        match flag.as_str() {
            "--local" => local = Some(PathBuf::from(value)),
            "--bundle" => bundle = Some(PathBuf::from(value)),
            "--base" => base = Some(value.clone()),
            _ => return None,
        }
    }
    Some((local?, bundle?, base))
}

#[cfg(test)]
mod cli_tests {
    use super::parse;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| (*arg).to_string()).collect()
    }

    #[test]
    fn parses_plan_flags() {
        let (local, bundle, base) =
            parse(&args(&["plan", "--local", "/a", "--bundle", "/b", "--base", "abc"])).unwrap();
        assert_eq!(local.to_str(), Some("/a"));
        assert_eq!(bundle.to_str(), Some("/b"));
        assert_eq!(base.as_deref(), Some("abc"));
        assert!(parse(&args(&["plan", "--local", "/a"])).is_none());
        assert!(parse(&args(&["plan", "--local", "/a", "--bundle"])).is_none());
        assert!(parse(&args(&["push", "--local", "/a", "--bundle", "/b"])).is_none());
        assert!(parse(&args(&["plan", "--local", "/a", "--bundle", "/b", "--x", "y"])).is_none());
    }
}
