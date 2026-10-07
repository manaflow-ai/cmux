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

pub static WORDLIST: LazyLock<[&'static str; 2048]> = LazyLock::new(|| {
    let words: Vec<&'static str> = RAW.lines().collect();
    words.try_into().expect("the word list has exactly 2,048 lines")
});

pub fn word_count() -> usize {
    WORDLIST.len()
}
