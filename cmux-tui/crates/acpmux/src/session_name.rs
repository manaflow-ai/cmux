//! Session name rules. Names are what people type, so keep them safe for
//! shells, paths, and URLs.

pub fn validate(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 80 {
        return Err("session name must be 1 to 80 characters".into());
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Err("session name may contain letters, digits, '-', '_' and '.'".into());
    }
    if name.starts_with('.') || name.starts_with('-') {
        return Err("session name may not start with '.' or '-'".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate;

    #[test]
    fn accepts_slugs() {
        assert!(validate("backend-review").is_ok());
        assert!(validate("t1.x_y").is_ok());
    }

    #[test]
    fn rejects_bad_names() {
        assert!(validate("").is_err());
        assert!(validate("a b").is_err());
        assert!(validate("-x").is_err());
        assert!(validate("../x").is_err());
    }
}
