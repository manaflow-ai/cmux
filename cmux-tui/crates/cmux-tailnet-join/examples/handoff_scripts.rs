//! Prints one of the handoff's commands or scripts, exactly as `cmux vm tailnet move` sends them,
//! for `testing/handoff-e2e.sh`: `cargo run -p cmux-tailnet-join --example handoff_scripts -- NAME`.
//! Names: prepare, release, adopt, start, read, forget, restore.

use cmux_tailnet_join::{handoff, prepare_command, read_command, start_command};

fn main() {
    let name = std::env::args().nth(1).unwrap_or_default();
    let text = match name.as_str() {
        "prepare" => prepare_command("root"),
        "release" => handoff::release_command(),
        "adopt" => handoff::vm_adopt_script(),
        "start" => start_command(),
        "read" => read_command(),
        "forget" => handoff::forget_command(),
        "restore" => handoff::restore_command(),
        _ => {
            eprintln!("usage: handoff_scripts prepare|release|adopt|start|read|forget|restore");
            std::process::exit(2);
        }
    };
    print!("{text}");
}
