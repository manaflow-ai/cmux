//! `cas-publish TREE OUT`: lay `TREE` out under `OUT` as `cas/1` objects ([`cmux_cas::publish`]:
//! `m/<manifest>`, `p/<pack>.pack`, `p/<pack>.idx`) and print one JSON line,
//! `{"manifest", "pack", "tree_bytes", "pack_bytes"}`. The web bundle publish workflow runs it on
//! the unpacked bundle archive and uploads `OUT` write-once under `cmux-next-web/cas/`.

use std::path::PathBuf;

fn main() -> cmux_cas::Result<()> {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [tree, out] = args.as_slice() else {
        return Err("usage: cas-publish TREE OUT".into());
    };
    let published = cmux_cas::publish::publish(tree, out)?;
    println!("{}", serde_json::to_string(&published)?);
    Ok(())
}
