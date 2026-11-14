# Notice to PL-acpmux: the relay label leaves out every format character (2026-11-09)

Follow-up to #39722 (owner W5-S; lead request). `cli/send_relay.rs` `hidden_in_a_label` now drops
every character of the Unicode general categories Cc, Cf, Zl and Zp from the sender's name in
`ACPMUX_FROM_LABEL` (crate `unicode-general-category` 1.1, Unicode 16, already in `Cargo.lock`
through `cmux-palette-ranker`; new direct dependency of acpmux). Before, only Cc, U+2028, U+2029
and the bidi controls and marks were dropped, so zero-width characters, the soft hyphen, the byte
order mark and tag characters (U+E0000-U+E007F, which can carry text an agent reads and a person
does not see) stayed. Lead decision on review: it also drops every `Default_Ignorable_Code_Point`
(a checked table of Unicode 16.0.0's DerivedCoreProperties.txt, with its reserved ranges), so
variation selectors and Hangul fillers go too. Removing ZWJ/ZWNJ changes emoji sequences and some
scripts' shaping in labels (accepted). The label is still an unverified claim (W5-M (b) PR 2 adds a verifiable
reply address).
