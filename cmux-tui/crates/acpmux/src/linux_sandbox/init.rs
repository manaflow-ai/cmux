//! The hidden Linux sandbox initializer, staged before runtime construction.
//! The implementation is intentionally absent in this red-first commit.

#![allow(dead_code)]

use std::ffi::OsString;

pub(crate) fn main(_args: Vec<OsString>) -> ! {
    eprintln!("remote sandbox init unavailable");
    std::process::exit(125)
}
