//! Prints the catalog's own palette rows for some queries, best first, as the app ranks them
//! (`tests/support/catalog.rs`).
//!
//!   cargo run -p cmux-palette-eval --example catalog_rank                   # the screen-sharing queries, top 5
//!   cargo run -p cmux-palette-eval --example catalog_rank -- -n 1 "new tab" # any queries, top N

#[path = "../tests/support/catalog.rs"]
mod catalog;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut limit = 5;
    if let Some(at) = args.iter().position(|arg| arg == "-n") {
        limit = args.get(at + 1).and_then(|value| value.parse().ok()).unwrap_or(5);
        args.drain(at..(at + 2).min(args.len()));
    }
    if args.is_empty() {
        args =
            ["share screen", "screen share", "vnc", "remote desktop"].map(str::to_owned).to_vec();
    }
    for query in &args {
        println!("{query:?}");
        for (rank, row) in catalog::ranked_rows(query, true).iter().take(limit).enumerate() {
            println!("  {}. {} ({}) {}", rank + 1, row.title, row.id, row.score);
        }
    }
}
