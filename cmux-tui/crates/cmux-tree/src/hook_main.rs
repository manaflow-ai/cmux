mod launch_hook;
#[allow(dead_code)]
mod localization;

use std::process::ExitCode;

use crate::localization::{Catalog, Locale};

fn main() -> ExitCode {
    let catalog = Catalog::new(Locale::detect());
    match launch_hook::run(std::env::args_os().skip(1).collect(), catalog) {
        Ok(exit_code) => exit_code,
        Err(error) => {
            eprintln!("{}: {error:#}", catalog.error());
            ExitCode::FAILURE
        }
    }
}
