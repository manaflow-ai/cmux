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
mod tests;
