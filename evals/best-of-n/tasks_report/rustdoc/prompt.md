# `cargo doc -D warnings` fails on generated code: `[::1]` in a description becomes an intra-doc link

`doc(text, indent)` in `rustdoc.py` turns a schema field's description into a `///` doc comment for our generated
Rust. A description saying `hosts: localhost, [::1], <hex> and \`code\`` came out as
`/// hosts: localhost, [::1], \<hex> and \`code\``: rustdoc reads `[::1]` as an intra-doc link and warns, and CI's
`cargo doc -D warnings` fails.

Descriptions are plain text written by people. Whatever characters one holds, rustdoc should show it exactly as
written.
