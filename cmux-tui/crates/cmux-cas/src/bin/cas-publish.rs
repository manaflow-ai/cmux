//! `cas-publish TREE OUT [BASE]...`: lay `TREE` out under `OUT` as `cas/1` objects
//! ([`cmux_cas::publish`]: `m/<manifest>`, `p/<pack>.pack`, `p/<pack>.idx`) and print one JSON
//! line, `{"manifest", "pack", "tree_bytes", "pack_bytes"}`. With `BASE` trees (the web updates
//! published before, which apps hold), it also writes a `zstd --patch-from` patch per changed
//! file and their list under `OUT/d/` ([`cmux_cas::patch`]) and adds `patches`, `patch_bytes`. The web bundle publish workflow runs it on
//! the unpacked bundle archive and uploads `OUT` write-once under `cmux-next-web/cas/`.

use std::path::PathBuf;

fn main() -> cmux_cas::Result<()> {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [tree, out, bases @ ..] = args.as_slice() else {
        return Err("usage: cas-publish TREE OUT [BASE]...".into());
    };
    let bases: Vec<&std::path::Path> = bases.iter().map(PathBuf::as_path).collect();
    let published = cmux_cas::publish::publish_with_bases(tree, &bases, out)?;
    println!("{}", serde_json::to_string(&published)?);
    Ok(())
}
