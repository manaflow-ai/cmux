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
