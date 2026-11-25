//! Trigger authority is a build choice, never a caller or process environment override.
//! Release binaries accept production only. Debug acceptance builds must explicitly
//! select their environment at compile time; an unspecified build uses production.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Authority {
    Production,
    Staging,
    Development,
}

pub(crate) fn configured() -> Result<Authority, &'static str> {
    select(option_env!("CMUX_TRIGGER_PLATFORM_ENV"), cfg!(debug_assertions))
}

fn select(environment: Option<&str>, development_build: bool) -> Result<Authority, &'static str> {
    let authority = match environment {
        None | Some("production") => Authority::Production,
        Some("staging") => Authority::Staging,
        Some("development") => Authority::Development,
        _ => return Err("invalid trigger authority build configuration"),
    };
    if !development_build && authority != Authority::Production {
        return Err("non-production trigger authority is unavailable in release builds");
    }
    Ok(authority)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_policy_refuses_every_non_production_authority() {
        for environment in ["development", "staging", "", "https://attacker.invalid"] {
            assert!(select(Some(environment), false).is_err());
        }
        assert_eq!(select(None, false), Ok(Authority::Production));
        assert_eq!(select(Some("production"), false), Ok(Authority::Production));
    }

    #[test]
    fn debug_build_requires_explicit_non_production_choice() {
        assert_eq!(select(None, true), Ok(Authority::Production));
        assert_eq!(select(Some("development"), true), Ok(Authority::Development));
        assert_eq!(select(Some("staging"), true), Ok(Authority::Staging));
        assert!(select(Some("https://attacker.invalid"), true).is_err());
    }

    // This module also compiles alone with rustc --test -C debug-assertions=no,
    // letting CI exercise the actual release branch with a development build
    // configuration without compiling a second optimized application.
    #[test]
    #[cfg(not(debug_assertions))]
    fn compiled_release_refuses_development_configuration() {
        if matches!(option_env!("CMUX_TRIGGER_PLATFORM_ENV"), Some("development" | "staging")) {
            assert!(configured().is_err());
        } else {
            assert_eq!(configured(), Ok(Authority::Production));
        }
    }
}
