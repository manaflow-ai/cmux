//! Systematic Reed-Solomon erasure code over GF(2^8) with a Cauchy parity
//! matrix. Any `k` of the `k + m` shards of a frame rebuild its `k` data
//! shards, because every square submatrix of `[I; C]` with a Cauchy `C` is
//! invertible. Blocks are small (one frame, at most 255 shards), so plain
//! table multiplication is fast enough and needs no dependency.

/// Most shards (data plus parity) in one block.
pub const MAX_SHARDS: usize = 255;

struct Tables {
    exp: [u8; 512],
    log: [u8; 256],
}

const fn tables() -> Tables {
    let mut exp = [0u8; 512];
    let mut log = [0u8; 256];
    let mut x: u16 = 1;
    let mut i = 0;
    while i < 255 {
        exp[i] = x as u8;
        log[x as usize] = i as u8;
        x <<= 1;
        if x & 0x100 != 0 {
            x ^= 0x11d;
        }
        i += 1;
    }
    let mut j = 255;
    while j < 512 {
        exp[j] = exp[j - 255];
        j += 1;
    }
    Tables { exp, log }
}

static T: Tables = tables();

fn mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        return 0;
    }
    T.exp[T.log[a as usize] as usize + T.log[b as usize] as usize]
}

fn inv(a: u8) -> u8 {
    debug_assert!(a != 0);
    T.exp[255 - T.log[a as usize] as usize]
}

/// Cauchy coefficient of parity row `i` (of `m`) for data column `j`.
fn cauchy(i: usize, j: usize, m: usize) -> u8 {
    // x_i = i, y_j = m + j; all distinct while m + k <= 256, so x_i ^ y_j != 0.
    inv((i as u8) ^ ((m + j) as u8))
}

/// Why a block cannot be encoded or rebuilt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FecError {
    /// More than [`MAX_SHARDS`] shards, or no data shard.
    BlockSize,
    /// Shards of one block have different lengths.
    ShardLength,
    /// Fewer than `k` shards are present.
    TooFewShards,
}

/// Computes `m` parity shards for equally long data shards.
pub fn encode(data: &[&[u8]], m: usize) -> Result<Vec<Vec<u8>>, FecError> {
    let k = data.len();
    if k == 0 || k + m > MAX_SHARDS {
        return Err(FecError::BlockSize);
    }
    let len = data[0].len();
    if data.iter().any(|d| d.len() != len) {
        return Err(FecError::ShardLength);
    }
    let mut parity = vec![vec![0u8; len]; m];
    for (i, out) in parity.iter_mut().enumerate() {
        for (j, shard) in data.iter().enumerate() {
            let c = cauchy(i, j, m);
            for (o, &b) in out.iter_mut().zip(shard.iter()) {
                *o ^= mul(c, b);
            }
        }
    }
    Ok(parity)
}

/// Rebuilds missing data shards in place. `shards` holds `k` data shards
/// followed by `m` parity shards; `None` marks a lost shard. On success every
/// data shard is `Some`.
pub fn reconstruct(shards: &mut [Option<Vec<u8>>], k: usize) -> Result<(), FecError> {
    let n = shards.len();
    if k == 0 || k > n || n > MAX_SHARDS {
        return Err(FecError::BlockSize);
    }
    if shards[..k].iter().all(Option::is_some) {
        return Ok(());
    }
    let m = n - k;
    let present: Vec<usize> = (0..n).filter(|&i| shards[i].is_some()).take(k).collect();
    if present.len() < k {
        return Err(FecError::TooFewShards);
    }
    let len = shards[present[0]].as_ref().map_or(0, Vec::len);
    if present.iter().any(|&i| shards[i].as_ref().map_or(0, Vec::len) != len) {
        return Err(FecError::ShardLength);
    }
    // Rows of the generator matrix for the present shards.
    let mut matrix: Vec<Vec<u8>> = present
        .iter()
        .map(|&row| {
            (0..k)
                .map(|j| if row < k { u8::from(row == j) } else { cauchy(row - k, j, m) })
                .collect()
        })
        .collect();
    let decode = invert(&mut matrix, k).ok_or(FecError::TooFewShards)?;
    let inputs: Vec<Vec<u8>> = present.iter().map(|&i| shards[i].clone().unwrap_or_default()).collect();
    for j in 0..k {
        if shards[j].is_some() {
            continue;
        }
        let mut out = vec![0u8; len];
        for (r, input) in inputs.iter().enumerate() {
            let c = decode[j][r];
            if c == 0 {
                continue;
            }
            for (o, &b) in out.iter_mut().zip(input.iter()) {
                *o ^= mul(c, b);
            }
        }
        shards[j] = Some(out);
    }
    Ok(())
}

/// Gauss-Jordan inversion of a `k x k` matrix over GF(2^8).
fn invert(matrix: &mut [Vec<u8>], k: usize) -> Option<Vec<Vec<u8>>> {
    let mut out: Vec<Vec<u8>> = (0..k).map(|i| (0..k).map(|j| u8::from(i == j)).collect()).collect();
    for col in 0..k {
        let pivot = (col..k).find(|&r| matrix[r][col] != 0)?;
        matrix.swap(col, pivot);
        out.swap(col, pivot);
        let scale = inv(matrix[col][col]);
        for j in 0..k {
            matrix[col][j] = mul(matrix[col][j], scale);
            out[col][j] = mul(out[col][j], scale);
        }
        for r in 0..k {
            if r == col || matrix[r][col] == 0 {
                continue;
            }
            let f = matrix[r][col];
            for j in 0..k {
                let a = mul(f, matrix[col][j]);
                matrix[r][j] ^= a;
                let b = mul(f, out[col][j]);
                out[r][j] ^= b;
            }
        }
    }
    Some(out)
}
