//! Part of `Hub`; see `hub/mod.rs`. The "did you mean" hint for a `-m`
//! head that names a model, not a harness.

use super::*;

impl Hub {
    /// "did you mean codex/gpt-5.5": a `-m` head that is no harness may be a
    /// bare model id, or `HEAD/MODEL` may be a full id such as
    /// `opencode-go/deepseek-v4-flash`.
    pub(super) fn with_model_hint(
        &self,
        cfg: &crate::config::Config,
        head: &str,
        model: Option<&str>,
        err: String,
    ) -> String {
        let spec = match model {
            Some(m) => format!("{head}/{m}"),
            None => head.to_owned(),
        };
        let known = self.known_models.lock().unwrap();
        let mut hits: Vec<String> = Vec::new();
        for (name, p) in &cfg.harnesses {
            let mut ids: Vec<String> = p.models.iter().map(|m| m.id().to_owned()).collect();
            match p.kind {
                crate::config::HarnessKind::ClaudeStdio => {
                    ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.to_string()))
                }
                crate::config::HarnessKind::Acp => {
                    ids.extend(known.get(name).into_iter().flatten().map(|(id, _)| id.clone()))
                }
                crate::config::HarnessKind::Terminal => {}
            }
            if ids.contains(&spec)
                || (p.kind == crate::config::HarnessKind::ClaudeStdio && spec.starts_with("claude"))
            {
                hits.push(format!("{name}/{spec}"));
            }
        }
        if hits.is_empty() {
            err
        } else {
            format!("{err}. {spec:?} is a model id: write {}", hits.join(" or "))
        }
    }
}
