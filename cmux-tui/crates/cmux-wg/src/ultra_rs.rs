//! Systematic Reed-Solomon erasure coding over GF(2^8), for ultra mode's `rs`
//! parity (see [`crate::ultra`]).
//!
//! A group's members are shards: a member's 2-byte big-endian length, then
//! its ciphertext, padded with zeros to the longest member. Parity `j` is
//! `sum_i c(j, i) * shard_i`, with the Cauchy coefficients
//! `c(j, i) = 1 / (x_j + y_i)`, `x_j = 32 + j` and `y_i = i`. Every square
//! submatrix of a Cauchy matrix is invertible, so any `n` parities rebuild any
//! `n` lost members, whichever they are. The coefficients depend only on the
//! parity's and the member's positions, so a group closed early (fewer
//! members than K) needs nothing extra on the wire.
//!
//! The length part of each parity shard is 2 bytes and rides in the parity
//! header, so a parity datagram is no longer than its longest member.

use std::sync::OnceLock;

/// Members in one group, at most (the `y` values are `0..MAX_MEMBERS`).
pub(crate) const MAX_MEMBERS: usize = 32;
/// Parities for one group, at most (the `x` values are `32..32 + 16`).
pub(crate) const MAX_PARITIES: usize = 16;

/// `a * b` in GF(2^8) with the polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D).
const fn mul_slow(mut a: u8, mut b: u8) -> u8 {
    let mut product = 0u8;
    while b != 0 {
        if b & 1 != 0 {
            product ^= a;
        }
        let carry = a & 0x80;
        a <<= 1;
        if carry != 0 {
            a ^= 0x1D;
        }
        b >>= 1;
    }
    product
}

/// `1 / a` (`a^254`); 0 for 0, which no caller passes.
const fn inv(a: u8) -> u8 {
    let mut result = 1u8;
    let mut base = a;
    let mut exponent = 254u8;
    while exponent != 0 {
        if exponent & 1 != 0 {
            result = mul_slow(result, base);
        }
        base = mul_slow(base, base);
        exponent >>= 1;
    }
    result
}

/// The multiplication table, one row per left operand: 64 KiB, built once.
fn table() -> &'static [[u8; 256]] {
    static TABLE: OnceLock<Vec<[u8; 256]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        (0..=255u8)
            .map(|a| {
                let mut row = [0u8; 256];
                for (b, slot) in (0..=255u8).zip(row.iter_mut()) {
                    *slot = mul_slow(a, b);
                }
                row
            })
            .collect()
    })
}

fn mul(a: u8, b: u8) -> u8 {
    table().get(usize::from(a)).and_then(|row| row.get(usize::from(b))).copied().unwrap_or(0)
}

/// `out += c * src`, byte by byte over the shorter of the two.
fn mul_add(out: &mut [u8], c: u8, src: &[u8]) {
    let Some(row) = table().get(usize::from(c)).filter(|_| c != 0) else { return };
    for (slot, byte) in out.iter_mut().zip(src) {
        *slot ^= row.get(usize::from(*byte)).copied().unwrap_or(0);
    }
}

fn x(parity: usize) -> u8 {
    u8::try_from(MAX_MEMBERS + parity).unwrap_or(u8::MAX)
}

fn y(member: usize) -> u8 {
    u8::try_from(member).unwrap_or(u8::MAX)
}

/// The coefficient of member `member` in parity `parity`.
fn coefficient(parity: usize, member: usize) -> u8 {
    inv(x(parity) ^ y(member))
}

fn length_bytes(ciphertext: &[u8]) -> [u8; 2] {
    u16::try_from(ciphertext.len()).unwrap_or(u16::MAX).to_be_bytes()
}

/// Parity `parity` of `members`: its 2-byte length code and its body, as
/// long as the longest member. `None` when the group is out of range.
pub(crate) fn encode(parity: usize, members: &[Vec<u8>]) -> Option<([u8; 2], Vec<u8>)> {
    if parity >= MAX_PARITIES || members.len() > MAX_MEMBERS {
        return None;
    }
    let longest = members.iter().map(Vec::len).max().unwrap_or(0);
    let mut code = [0u8; 2];
    let mut body = vec![0u8; longest];
    for (member, ciphertext) in members.iter().enumerate() {
        let c = coefficient(parity, member);
        mul_add(&mut code, c, &length_bytes(ciphertext));
        mul_add(&mut body, c, ciphertext);
    }
    Some((code, body))
}

/// One received parity of a group.
pub(crate) struct Shard<'a> {
    pub(crate) parity: usize,
    pub(crate) code: [u8; 2],
    pub(crate) body: &'a [u8],
}

/// The ciphertexts of the `missing` members (positions in the group), in
/// that order, from `received` members (position, ciphertext) and exactly
/// `missing.len()` parities of distinct positions. `None` when the inputs do
/// not fit together (a received member longer than the parity, a length
/// that does not fit): the parity was not for these members.
pub(crate) fn decode(
    parities: &[Shard<'_>],
    received: &[(usize, &[u8])],
    missing: &[usize],
) -> Option<Vec<Vec<u8>>> {
    if parities.len() != missing.len()
        || missing.is_empty()
        || parities.iter().any(|shard| shard.parity >= MAX_PARITIES)
        || missing
            .iter()
            .chain(received.iter().map(|(member, _)| member))
            .any(|m| *m >= MAX_MEMBERS)
    {
        return None;
    }
    // Two equal positions would make the matrix singular.
    let distinct = |mut values: Vec<usize>| {
        let len = values.len();
        values.sort_unstable();
        values.dedup();
        values.len() == len
    };
    if !distinct(parities.iter().map(|shard| shard.parity).collect())
        || !distinct(
            missing.iter().chain(received.iter().map(|(member, _)| member)).copied().collect(),
        )
    {
        return None;
    }
    let longest = parities.iter().map(|shard| shard.body.len()).min()?;
    if received.iter().any(|(_, ciphertext)| ciphertext.len() > longest) {
        return None;
    }
    // What each parity holds of the missing members alone: the parity minus
    // the received members' share.
    let residuals: Vec<Vec<u8>> = parities
        .iter()
        .map(|shard| {
            let mut residual = Vec::with_capacity(2 + longest);
            residual.extend_from_slice(&shard.code);
            residual.extend_from_slice(shard.body.get(..longest).unwrap_or_default());
            for (member, ciphertext) in received {
                let c = coefficient(shard.parity, *member);
                mul_add(&mut residual, c, &length_bytes(ciphertext));
                mul_add(residual.get_mut(2..).unwrap_or_default(), c, ciphertext);
            }
            residual
        })
        .collect();
    let xs: Vec<u8> = parities.iter().map(|shard| x(shard.parity)).collect();
    let ys: Vec<u8> = missing.iter().map(|member| y(*member)).collect();
    let mut rebuilt = Vec::with_capacity(missing.len());
    for (a, y_a) in ys.iter().enumerate() {
        let mut shard = vec![0u8; 2 + longest];
        for (b, (x_b, residual)) in xs.iter().zip(&residuals).enumerate() {
            mul_add(&mut shard, inverse_entry(&xs, &ys, a, b, *x_b, *y_a), residual);
        }
        let length = usize::from(u16::from_be_bytes([*shard.first()?, *shard.get(1)?]));
        rebuilt.push(shard.get(2..2 + length)?.to_vec());
    }
    Some(rebuilt)
}

/// Entry (a, b) of the inverse of the Cauchy matrix `1 / (xs[r] + ys[c])`:
/// `(x_b + y_a) * A_b(y_a) * B_a(x_b)`, with `A_b` and `B_a` the Lagrange
/// polynomials of `xs` at `b` and of `ys` at `a`. Subtraction is addition in
/// GF(2^8).
fn inverse_entry(xs: &[u8], ys: &[u8], a: usize, b: usize, x_b: u8, y_a: u8) -> u8 {
    let others = |values: &[u8], skip: usize, at: u8| {
        values
            .iter()
            .enumerate()
            .filter(|(k, _)| *k != skip)
            .fold(1u8, |product, (_, value)| mul(product, at ^ value))
    };
    let a_b = mul(others(xs, b, y_a), inv(others(xs, b, x_b)));
    let b_a = mul(others(ys, a, x_b), inv(others(ys, a, y_a)));
    mul(x_b ^ y_a, mul(a_b, b_a))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_arithmetic_is_a_field() {
        for a in 1..=255u8 {
            assert_eq!(mul(a, inv(a)), 1, "{a} times its inverse");
            assert_eq!(mul(a, 1), a);
            assert_eq!(mul(a, 0), 0);
        }
        assert_eq!(mul(0x80, 2), 0x1D, "the reduction polynomial is 0x11D");
    }

    fn members(lengths: &[usize]) -> Vec<Vec<u8>> {
        lengths
            .iter()
            .enumerate()
            .map(|(i, len)| (0..*len).map(|t| (t * 31 + i * 7 + 1) as u8).collect())
            .collect()
    }

    /// Every way to lose up to 4 of 8 members of mixed lengths, rebuilt from
    /// every choice of that many of 4 parities.
    #[test]
    fn any_n_parities_rebuild_any_n_lost_members() {
        let sent = members(&[40, 1400, 16, 77, 1200, 300, 17, 999]);
        let parities: Vec<([u8; 2], Vec<u8>)> = (0..4).map(|j| encode(j, &sent).unwrap()).collect();
        for lost in 1u32..(1 << 8) {
            let missing: Vec<usize> = (0..8).filter(|i| lost & (1 << i) != 0).collect();
            if missing.len() > 4 {
                continue;
            }
            let received: Vec<(usize, &[u8])> =
                (0..8).filter(|i| lost & (1 << i) == 0).map(|i| (i, sent[i].as_slice())).collect();
            for chosen in 0u32..16 {
                if chosen.count_ones() as usize != missing.len() {
                    continue;
                }
                let shards: Vec<Shard<'_>> = (0..4)
                    .filter(|j| chosen & (1 << j) != 0)
                    .map(|j| Shard { parity: j, code: parities[j].0, body: &parities[j].1 })
                    .collect();
                let rebuilt = decode(&shards, &received, &missing).unwrap();
                let expected: Vec<Vec<u8>> = missing.iter().map(|i| sent[*i].clone()).collect();
                assert_eq!(rebuilt, expected, "lost {missing:?} parities {chosen:b}");
            }
        }
    }

    #[test]
    fn the_largest_group_rebuilds_its_largest_loss() {
        let sent = members(&[100; MAX_MEMBERS]);
        let missing: Vec<usize> = (0..MAX_PARITIES).map(|i| i * 2).collect();
        let parities: Vec<_> = (0..MAX_PARITIES).map(|j| encode(j, &sent).unwrap()).collect();
        let received: Vec<(usize, &[u8])> = (0..MAX_MEMBERS)
            .filter(|i| !missing.contains(i))
            .map(|i| (i, sent[i].as_slice()))
            .collect();
        let shards: Vec<Shard<'_>> = parities
            .iter()
            .enumerate()
            .map(|(j, (code, body))| Shard { parity: j, code: *code, body })
            .collect();
        let rebuilt = decode(&shards, &received, &missing).unwrap();
        assert!(rebuilt.iter().zip(&missing).all(|(r, i)| *r == sent[*i]));
    }

    #[test]
    fn out_of_range_or_mismatched_inputs_rebuild_nothing() {
        let sent = members(&[50, 60]);
        assert!(encode(MAX_PARITIES, &sent).is_none());
        let (code, body) = encode(0, &sent).unwrap();
        let shard = Shard { parity: 0, code, body: &body };
        assert!(decode(&[], &[], &[0]).is_none(), "no parity");
        let long = vec![0u8; 61];
        assert!(decode(&[shard], &[(1, &long)], &[0]).is_none(), "a member longer than the parity");
    }
}
