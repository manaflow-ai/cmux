fn main() -> anyhow::Result<()> {
    acpmux::cli::entry::main(std::env::args_os().skip(1).collect(), Default::default())
}
