//! `cargo run -p cmux-git-cache --example git-cache -- serve ...`: the proxy without cmux host
//! (bench/clone-bench.sh).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(i32::from(cmux_git_cache::cli::run(&args)));
}
