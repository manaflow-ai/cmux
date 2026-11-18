//! The locale an app host starts with (`init.locale`, `cmux.locale`): the
//! person's full BCP-47 tag (`en-US`, `de-CH`, `zh-Hans-CN`), so a widget can
//! pick units, date order and first weekday from the region, not only the
//! language. Read once per daemon: the locale environment (`LC_ALL`,
//! `LC_MESSAGES`, `LANG`), then on macOS the system setting (`AppleLocale`,
//! which carries a region override as `@rg=`). `en` when nothing says more.

use std::sync::OnceLock;

/// The tag when nothing names the person's locale.
const FALLBACK: &str = "en";

/// The person's locale as a BCP-47 tag, read once.
pub(super) fn current() -> &'static str {
    static CURRENT: OnceLock<String> = OnceLock::new();
    CURRENT.get_or_init(|| {
        let env =
            ["LC_ALL", "LC_MESSAGES", "LANG"].into_iter().map(|name| std::env::var(name).ok());
        env.chain(std::iter::once_with(system_locale))
            .flatten()
            .find_map(|raw| bcp47(&raw))
            .unwrap_or_else(|| FALLBACK.to_string())
    })
}

/// The macOS system locale (`defaults read -g AppleLocale`, e.g.
/// `en_US` or `en_US@rg=gbzzzz`); `None` elsewhere or when unset.
fn system_locale() -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = cmux_process::Command::new("/usr/bin/defaults")
        .args(["read", "-g", "AppleLocale"])
        .stdin(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// A POSIX or Apple locale (`en_US.UTF-8`, `zh_Hans_CN`, `en_US@rg=gbzzzz`,
/// `de-CH`) as a BCP-47 tag (`en-US`, `zh-Hans-CN`, `en-US-u-rg-gbzzzz`).
/// `None` for the C/POSIX locale and anything that is not a locale.
pub(super) fn bcp47(raw: &str) -> Option<String> {
    let (base, modifiers) = raw.split_once('@').unwrap_or((raw, ""));
    let base = base.split('.').next().unwrap_or_default();
    let mut parts = base.split(['_', '-']).filter(|p| !p.is_empty());
    let language = parts.next()?;
    let alpha = |s: &str| s.chars().all(|c| c.is_ascii_alphabetic());
    if !(2..=3).contains(&language.len()) || !alpha(language) {
        return None;
    }
    let mut tag = language.to_ascii_lowercase();
    for part in parts {
        let subtag = match part.len() {
            4 if alpha(part) => {
                let (first, rest) = part.split_at(1);
                format!("{}{}", first.to_ascii_uppercase(), rest.to_ascii_lowercase())
            }
            2 if alpha(part) => part.to_ascii_uppercase(),
            3 if part.chars().all(|c| c.is_ascii_digit()) => part.to_string(),
            _ => return None,
        };
        tag.push('-');
        tag.push_str(&subtag);
    }
    // Apple's region override (Language & Region > Region differs from the
    // language's region): the Unicode extension says the same thing.
    let region_override = modifiers.split(';').find_map(|m| m.strip_prefix("rg="));
    if let Some(rg) =
        region_override.filter(|rg| rg.len() == 6 && rg.chars().all(|c| c.is_ascii_alphanumeric()))
    {
        tag.push_str("-u-rg-");
        tag.push_str(&rg.to_ascii_lowercase());
    }
    Some(tag)
}

#[cfg(test)]
mod tests {
    use super::bcp47;

    #[test]
    fn posix_and_apple_locales_become_full_bcp47_tags() {
        for (raw, tag) in [
            ("en_US.UTF-8", Some("en-US")),
            ("en_US", Some("en-US")),
            ("de_CH.UTF-8@euro", Some("de-CH")),
            ("zh_Hans_CN", Some("zh-Hans-CN")),
            ("es_419", Some("es-419")),
            ("en-GB", Some("en-GB")),
            ("en_US@rg=gbzzzz", Some("en-US-u-rg-gbzzzz")),
            ("fr", Some("fr")),
            ("C", None),
            ("POSIX", None),
            ("C.UTF-8", None),
            ("", None),
        ] {
            assert_eq!(bcp47(raw).as_deref(), tag, "{raw}");
        }
    }
}
