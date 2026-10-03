//! Allowlists for the names the link hands to OpenSSH.
//!
//! A destination reaches the user's ssh config, where `%h` or `%r` can end
//! up in a `ProxyCommand` that OpenSSH runs through `sh -c`, and a lookup
//! name ends up in a known-hosts file, where `*`, `?`, `!` and `,` are
//! patterns. So both are allowlists, never blocklists.

/// Longest destination or lookup name accepted.
const MAX_LEN: usize = 255;

/// `user@host`, `host`, or an ssh config alias. User: `[A-Za-z0-9._-]`;
/// host: `[A-Za-z0-9.-]` (not starting with `-` or `.`) or a bracketed
/// IPv6 address.
#[must_use]
pub fn valid_destination(destination: &str) -> bool {
    if destination.is_empty() || destination.len() > MAX_LEN {
        return false;
    }
    let (user, host) = match destination.split_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, destination),
    };
    user.is_none_or(valid_user) && (valid_host(host) || valid_bracketed_ipv6(host))
}

/// A known-hosts lookup name as OpenSSH writes it: `host`, an IPv6
/// address, or `[host]:port`.
#[must_use]
pub fn valid_lookup_host(name: &str) -> bool {
    if name.is_empty() || name.len() > MAX_LEN {
        return false;
    }
    if let Some(rest) = name.strip_prefix('[') {
        let Some((inner, port)) = rest.split_once("]:") else { return false };
        return (valid_host(inner) || valid_ipv6(inner))
            && !port.is_empty()
            && port.len() <= 5
            && port.bytes().all(|byte| byte.is_ascii_digit());
    }
    valid_host(name) || valid_ipv6(name)
}

fn valid_user(user: &str) -> bool {
    !user.is_empty()
        && !user.starts_with('-')
        && user.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with(['-', '.'])
        && host.bytes().all(|byte| byte.is_ascii_alphanumeric() || b".-".contains(&byte))
}

fn valid_ipv6(address: &str) -> bool {
    address.contains(':')
        && address.bytes().all(|byte| byte.is_ascii_hexdigit() || b":.".contains(&byte))
}

fn valid_bracketed_ipv6(host: &str) -> bool {
    host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).is_some_and(valid_ipv6)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destinations_are_allowlisted() {
        for good in ["dev@127.0.0.1", "build-box", "a.b.example.com", "u_1.x@h-2", "dev@[::1]"] {
            assert!(valid_destination(good), "{good:?}");
        }
        for bad in [
            "",
            "-oProxyCommand=x",
            "a b",
            "h;id",
            "h$(id)",
            "h`id`",
            "h|x",
            "h&x",
            "h<x",
            "h>x",
            "h*",
            "h?",
            "h!",
            "h[1]",
            "a@b@c",
            "@h",
            "u@",
            ".hidden",
            "h,i",
            "h%h",
            "u\u{202e}@h",
            "dev@[::1;id]",
        ] {
            assert!(!valid_destination(bad), "{bad:?}");
        }
    }

    #[test]
    fn lookup_hosts_are_allowlisted() {
        for good in ["127.0.0.1", "[127.0.0.1]:2222", "::1", "[::1]:22", "host.example"] {
            assert!(valid_lookup_host(good), "{good:?}");
        }
        for bad in ["*", "h*", "!h", "h,i", "[h]", "[h]:x", "[h]:123456", "|1|abc", "h?"] {
            assert!(!valid_lookup_host(bad), "{bad:?}");
        }
    }
}
