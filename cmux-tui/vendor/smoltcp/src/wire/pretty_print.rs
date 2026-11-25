/*! Pretty-printing of packet representation.

The `pretty_print` module provides bits and pieces for printing concise,
easily human readable packet listings.

# Example

A packet can be formatted using the `PrettyPrinter` wrapper:

```rust
use smoltcp::wire::*;
let buffer = vec![
    // Ethernet II
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
    0x08, 0x00,
    // IPv4
    0x45, 0x00, 0x00, 0x20,
    0x00, 0x00, 0x40, 0x00,
    0x40, 0x01, 0xd2, 0x79,
    0x11, 0x12, 0x13, 0x14,
    0x21, 0x22, 0x23, 0x24,
    // ICMPv4
    0x08, 0x00, 0x8e, 0xfe,
    0x12, 0x34, 0xab, 0xcd,
    0xaa, 0x00, 0x00, 0xff
];

let result = "\
EthernetII src=11-12-13-14-15-16 dst=01-02-03-04-05-06 type=IPv4\n\
\\ IPv4 src=17.18.19.20 dst=33.34.35.36 proto=ICMP (checksum incorrect)\n \
 \\ ICMPv4 echo request id=4660 seq=43981 len=4\
";

#[cfg(all(feature = "medium-ethernet", feature = "proto-ipv4"))]
assert_eq!(
    result,
    &format!("{}", PrettyPrinter::<EthernetFrame<&'static [u8]>>::new("", &buffer))
);
```
*/

use core::fmt;
use core::marker::PhantomData;

/// Indentation state.
#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct PrettyIndent {
    prefix: &'static str,
    level: usize,
}

impl PrettyIndent {
    /// Create an indentation state. The entire listing will be indented by the width
    /// of `prefix`, and `prefix` will appear at the start of the first line.
    pub fn new(prefix: &'static str) -> PrettyIndent {
        PrettyIndent { prefix, level: 0 }
    }

    /// Increase indentation level.
    pub fn increase(&mut self, f: &mut fmt::Formatter) -> fmt::Result {
        writeln!(f)?;
        self.level += 1;
        Ok(())
    }
}

impl fmt::Display for PrettyIndent {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.level == 0 {
            write!(f, "{}", self.prefix)
        } else {
            write!(f, "{0:1$}{0:2$}\\ ", "", self.prefix.len(), self.level - 1)
        }
    }
}

/// Interface for printing listings.
pub trait PrettyPrint {
    /// Write a concise, formatted representation of a packet contained in the provided
    /// buffer, and any nested packets it may contain.
    ///
    /// `pretty_print` accepts a buffer and not a packet wrapper because the packet might
    /// be truncated, and so it might not be possible to create the packet wrapper.
    fn pretty_print(
        buffer: &dyn AsRef<[u8]>,
        fmt: &mut fmt::Formatter,
        indent: &mut PrettyIndent,
    ) -> fmt::Result;
}

/// Wrapper for using a `PrettyPrint` where a `Display` is expected.
pub struct PrettyPrinter<'a, T: PrettyPrint> {
    prefix: &'static str,
    buffer: &'a dyn AsRef<[u8]>,
    phantom: PhantomData<T>,
}

impl<'a, T: PrettyPrint> PrettyPrinter<'a, T> {
    /// Format the listing with the recorded parameters when Display::fmt is called.
    pub fn new(prefix: &'static str, buffer: &'a dyn AsRef<[u8]>) -> PrettyPrinter<'a, T> {
        PrettyPrinter {
            prefix: prefix,
            buffer: buffer,
            phantom: PhantomData,
        }
    }
}

impl<'a, T: PrettyPrint + AsRef<[u8]>> PrettyPrinter<'a, T> {
    /// Create a `PrettyPrinter` which prints the given object.
    pub fn print(printable: &'a T) -> PrettyPrinter<'a, T> {
        PrettyPrinter {
            prefix: "",
            buffer: printable,
            phantom: PhantomData,
        }
    }
}

impl<'a, T: PrettyPrint> fmt::Display for PrettyPrinter<'a, T> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        T::pretty_print(&self.buffer, f, &mut PrettyIndent::new(self.prefix))
    }
}
