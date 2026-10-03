//! Unforgeable handle ids: a prefix and 22 random base62 characters
//! (about 131 bits).

const ALPHABET: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const RANDOM_CHARACTERS: usize = 22;

/// Returns `prefix` followed by 22 random base62 characters.
///
/// # Panics
///
/// Panics when the operating system has no random source, because a
/// predictable handle would be a forgeable capability.
#[must_use]
pub fn random_id(prefix: &str) -> String {
    let mut id = String::with_capacity(prefix.len() + RANDOM_CHARACTERS);
    id.push_str(prefix);
    let mut produced = 0;
    while produced < RANDOM_CHARACTERS {
        let mut bytes = [0_u8; 32];
        getrandom::fill(&mut bytes).expect("the operating system random source failed");
        for byte in bytes {
            // 248 = 4 * 62: rejecting the top values keeps every character
            // equally likely.
            if byte < 248 && produced < RANDOM_CHARACTERS {
                id.push(char::from(ALPHABET[usize::from(byte % 62)]));
                produced += 1;
            }
        }
    }
    id
}

/// True when `id` has `prefix` and exactly 22 base62 characters after it.
#[must_use]
pub fn is_well_formed(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix).is_some_and(|rest| {
        rest.len() == RANDOM_CHARACTERS && rest.bytes().all(|byte| byte.is_ascii_alphanumeric())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_ids_are_well_formed_and_distinct() {
        let first = random_id("conn_");
        let second = random_id("conn_");
        assert!(is_well_formed(&first, "conn_"), "{first}");
        assert!(is_well_formed(&second, "conn_"), "{second}");
        assert_ne!(first, second);
        assert!(!is_well_formed(&first, "lst_"));
        assert!(!is_well_formed("conn_short", "conn_"));
        assert!(!is_well_formed("conn_aaaaaaaaaaaaaaaaaaaa/a", "conn_"));
    }
}
