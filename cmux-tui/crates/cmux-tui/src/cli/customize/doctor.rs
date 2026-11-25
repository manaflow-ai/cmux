//! `cmux customize doctor`: what changes your customization in a way you
//! may not expect (cmux-customize `library::doctor`), and its fixes. The
//! app's notice runs `doctor --announce` and its Settings card the rest, so
//! a person, the app and an agent read the same findings.

use cmux_customize::Customize;
use cmux_customize::library::doctor::{self, FixKind, Level, Report};
use cmux_customize::library::expire::Expiry;
use serde_json::json;

use super::Failure;
use super::render::Answer;

pub(super) const USAGE: &str =
    "customize doctor [--announce] | fix ID off|remove|restore | dismiss ID | recover";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    /// With `announce`: also record every finding as said, and name the new ones.
    Report {
        announce: bool,
    },
    Fix {
        id: String,
        kind: FixKind,
    },
    Dismiss {
        id: String,
    },
    /// Back to a setup that loads: every code layer and hand overlay off, and
    /// the newest generation whose files all load made live.
    Recover,
}

pub(super) fn parse(rest: &[String]) -> Result<Request, String> {
    let id = |word: &String| {
        if word.is_empty() || word.starts_with('-') {
            Err(format!("a finding id, like broken:themes/night.json; {USAGE}"))
        } else {
            Ok(word.clone())
        }
    };
    match rest {
        [] => Ok(Request::Report { announce: false }),
        [flag] if flag == "--announce" => Ok(Request::Report { announce: true }),
        [verb, finding, kind] if verb == "fix" => Ok(Request::Fix {
            id: id(finding)?,
            kind: doctor::fix_kind(kind)
                .ok_or_else(|| format!("a fix is off, remove or restore, got {kind:?}; {USAGE}"))?,
        }),
        [verb, finding] if verb == "dismiss" => Ok(Request::Dismiss { id: id(finding)? }),
        [verb] if verb == "recover" => Ok(Request::Recover),
        _ => Err(USAGE.to_owned()),
    }
}

pub(super) fn execute(
    customize: &Customize,
    request: Request,
    origin: &str,
    now_ms: u64,
) -> Result<Answer, Failure> {
    let expiry = Expiry { now_ms, app_abi: super::app_web_abi(None), ended: Default::default() };
    Ok(match request {
        Request::Report { announce } => {
            let report = if announce {
                customize.doctor_announce(&expiry)?
            } else {
                customize.doctor(&expiry)
            };
            Answer::Library { human: report_lines(&report), json: json!({ "doctor": report }) }
        }
        Request::Fix { id, kind } => {
            let fixed = customize.doctor_fix(&id, kind, &expiry, origin)?;
            let report = customize.doctor(&expiry);
            Answer::Library {
                human: format!("{}\n", fixed.said),
                json: json!({ "fixed": fixed, "doctor": report }),
            }
        }
        Request::Dismiss { id } => {
            let report = customize.doctor_dismiss(&id, &expiry)?;
            Answer::Library {
                human: format!("{id} is hidden until it changes\n"),
                json: json!({ "doctor": report }),
            }
        }
        Request::Recover => {
            let recovery = customize.doctor_recover(&expiry, origin)?;
            let report = customize.doctor(&expiry);
            Answer::Library {
                human: recovery.said.iter().map(|line| format!("{line}\n")).collect(),
                json: json!({ "recovered": recovery, "doctor": report }),
            }
        }
    })
}

/// One block per finding: the title, where, what it changes, and the
/// command for each fix.
fn report_lines(report: &Report) -> String {
    let shown: Vec<_> = report.findings.iter().filter(|finding| !finding.dismissed).collect();
    if shown.is_empty() {
        return "Nothing changes your customization unexpectedly.\n".to_owned();
    }
    let mut out = format!("{}\n", report.line.as_deref().unwrap_or("Nothing is broken."));
    for finding in shown {
        let mark = if finding.level == Level::Warning { "!" } else { "-" };
        out.push_str(&format!("\n{mark} {}  [{}]\n", finding.title, finding.id));
        out.push_str(&format!("  {}\n", finding.place));
        out.push_str(&format!("  {}\n", finding.detail));
        for fix in &finding.fixes {
            match fix.kind {
                FixKind::Open => {
                    if let Some(path) = &finding.path {
                        out.push_str(&format!("  open:   {path}\n"));
                    }
                }
                FixKind::Off => {
                    out.push_str(&format!("  off:    cmux customize doctor fix {} off\n", finding.id));
                }
                FixKind::Remove => out.push_str(&format!(
                    "  remove: cmux customize doctor fix {} remove   (kept in the doctor's removed folder)\n",
                    finding.id
                )),
                FixKind::Restore => out.push_str(&format!(
                    "  restore: cmux customize doctor fix {} restore   (its last version that loaded)\n",
                    finding.id
                )),
            }
        }
    }
    let hidden = report.findings.iter().filter(|finding| finding.dismissed).count();
    if hidden > 0 {
        out.push_str(&format!("\n{hidden} dismissed (shown again when they change)\n"));
    }
    if let Some(plan) = &report.recover {
        out.push_str(&format!("\n{}\n  cmux customize doctor recover\n", plan.said));
    }
    out
}
