//! `packed_str!` for cmux-embed: reads the file an `include_str!` names,
//! compresses it with zstd at compile time, and expands to a
//! `cmux_embed::PackedStr` holding the compressed bytes. Use it through
//! `cmux_embed::packed_str!`, which documents it.
//!
//! The argument stays an `include_str!` call, which the expansion keeps in an
//! unnamed constant: rustc then records the file as a dependency (an edit of
//! it rebuilds the crate), and scripts/ci/check_cmux_tui_tree_inputs.py still
//! sees the embed. Nothing uses that constant, so its text is not in the
//! binary.

use std::path::PathBuf;

use proc_macro::{Delimiter, Group, Literal, Punct, Spacing, Span, TokenStream, TokenTree};

/// zstd's highest level short of `--ultra`: the catalogs are a few MB, so a
/// build pays well under a second for them, and inflating does not get slower.
const LEVEL: i32 = 19;

/// `packed_str!(include_str!("path"))`, or
/// `packed_str!(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/path")))`.
#[proc_macro]
pub fn packed_str(input: TokenStream) -> TokenStream {
    match expand(input) {
        Ok(tokens) => tokens,
        Err(message) => error(&message),
    }
}

fn expand(input: TokenStream) -> Result<TokenStream, String> {
    let path = embedded_path(input.clone())?;
    let text = std::fs::read_to_string(&path)
        .map_err(|error| format!("packed_str!: cannot read {}: {error}", path.display()))?;
    let packed = zstd::bulk::compress(text.as_bytes(), LEVEL)
        .map_err(|error| format!("packed_str!: cannot compress {}: {error}", path.display()))?;
    // The runtime inflates without a fallible path of its own to report on;
    // prove here, once per build, that these bytes give the text back.
    let unpacked = zstd::bulk::decompress(&packed, text.len())
        .map_err(|error| format!("packed_str!: cannot inflate {}: {error}", path.display()))?;
    if unpacked != text.as_bytes() {
        return Err(format!("packed_str!: {} does not round-trip", path.display()));
    }

    let mut body = TokenStream::new();
    body.extend(tokens("const _: &str ="));
    body.extend(input);
    body.extend(tokens("; ::cmux_embed::PackedStr::__new"));
    let args = TokenStream::from_iter([
        TokenTree::Literal(Literal::byte_string(&packed)),
        TokenTree::Punct(Punct::new(',', Spacing::Alone)),
        TokenTree::Literal(Literal::usize_suffixed(text.len())),
    ]);
    body.extend([TokenTree::Group(Group::new(Delimiter::Parenthesis, args))]);
    Ok(TokenStream::from(TokenTree::Group(Group::new(Delimiter::Brace, body))))
}

/// The file the `include_str!` argument names, resolved as rustc resolves it.
fn embedded_path(input: TokenStream) -> Result<PathBuf, String> {
    // Not the macro call itself: check_cmux_tui_tree_inputs.py would read that as an embed.
    const USAGE: &str = "packed_str! takes one include_str call: of a plain \"path\" literal, or of \
        concat(env(\"CARGO_MANIFEST_DIR\"), \"/path\")";
    let mut trees = input.into_iter();
    let (
        Some(TokenTree::Ident(name)),
        Some(TokenTree::Punct(bang)),
        Some(TokenTree::Group(args)),
        None,
    ) = (trees.next(), trees.next(), trees.next(), trees.next())
    else {
        return Err(USAGE.to_owned());
    };
    if name.to_string() != "include_str"
        || bang.as_char() != '!'
        || args.delimiter() != Delimiter::Parenthesis
    {
        return Err(USAGE.to_owned());
    }
    let args: Vec<TokenTree> = args.stream().into_iter().collect();
    match args.as_slice() {
        // Relative to the file the macro is called in, as include_str! reads it.
        [TokenTree::Literal(literal)] => {
            let relative = string_literal(literal)?;
            let file = literal
                .span()
                .local_file()
                .or_else(|| Span::call_site().local_file())
                .ok_or("packed_str!: the calling source file is unknown")?;
            let dir = file.parent().map(PathBuf::from).unwrap_or_default();
            Ok(dir.join(relative))
        }
        [TokenTree::Ident(concat), TokenTree::Punct(bang), TokenTree::Group(parts)]
            if concat.to_string() == "concat" && bang.as_char() == '!' =>
        {
            let parts: Vec<TokenTree> = parts.stream().into_iter().collect();
            let [
                TokenTree::Ident(env),
                TokenTree::Punct(env_bang),
                TokenTree::Group(var),
                TokenTree::Punct(comma),
                TokenTree::Literal(rest),
            ] = parts.as_slice()
            else {
                return Err(USAGE.to_owned());
            };
            let var: Vec<TokenTree> = var.stream().into_iter().collect();
            let [TokenTree::Literal(var)] = var.as_slice() else {
                return Err(USAGE.to_owned());
            };
            if env.to_string() != "env"
                || env_bang.as_char() != '!'
                || comma.as_char() != ','
                || string_literal(var)? != "CARGO_MANIFEST_DIR"
            {
                return Err(USAGE.to_owned());
            }
            let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
                .map_err(|_| "packed_str!: CARGO_MANIFEST_DIR is not set".to_owned())?;
            Ok(PathBuf::from(format!("{manifest_dir}{}", string_literal(rest)?)))
        }
        _ => Err(USAGE.to_owned()),
    }
}

/// A plain `"..."` literal's text. Escapes and raw strings are refused rather
/// than half-parsed: an embed path needs neither.
fn string_literal(literal: &Literal) -> Result<String, String> {
    let source = literal.to_string();
    source
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .filter(|text| !text.contains('\\'))
        .map(str::to_owned)
        .ok_or_else(|| format!("packed_str!: expected a plain string literal, found {source}"))
}

fn tokens(source: &str) -> TokenStream {
    source.parse().unwrap_or_default()
}

fn error(message: &str) -> TokenStream {
    let mut out = tokens("::core::compile_error!");
    let message = TokenStream::from(TokenTree::Literal(Literal::string(message)));
    out.extend([TokenTree::Group(Group::new(Delimiter::Parenthesis, message))]);
    out
}
