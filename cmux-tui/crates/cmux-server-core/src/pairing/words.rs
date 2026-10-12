//! The 2,048-word list for fingerprint words.
//!
//! `bip39-english.txt` is the English word list of BIP-39 ("Mnemonic code for
//! generating deterministic keys", Marek Palatinus, Pavol Rusnak, Aaron
//! Voisine, Sean Bowe; https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt),
//! licensed under the MIT license. File SHA-256:
//! 2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda.
//! The words are unique in their first four letters, which helps when a
//! person reads them aloud.

use std::sync::LazyLock;

const RAW: &str = include_str!("bip39-english.txt");

/// The list has exactly 2,048 lines (a unit test checks it; a short list
/// would leave empty words, never a panic).
pub static WORDLIST: LazyLock<[&'static str; 2048]> = LazyLock::new(|| {
    let mut lines = RAW.lines();
    std::array::from_fn(|_| lines.next().unwrap_or_default())
});

pub fn word_count() -> usize {
    WORDLIST.len()
}
