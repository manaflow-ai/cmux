use cmux_home_ratatui::cli::help_text;
use cmux_home_ratatui::{load_state, parse_args, render_once_summary};
use std::env;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args = match parse_args(env::args().skip(1)) {
        Ok(args) => args,
        Err(error) => {
            eprintln!("{}", error.message);
            eprintln!("{}", help_text());
            return ExitCode::from(2);
        }
    };

    if args.help {
        print!("{}", help_text());
        return ExitCode::SUCCESS;
    }

    let state = match load_state(args.data.as_deref()) {
        Ok(state) => state,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(1);
        }
    };

    if args.once {
        print!("{}", render_once_summary(&state));
        return ExitCode::SUCCESS;
    }

    match cmux_home_ratatui::ui::run(state) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-home: {error}");
            ExitCode::from(1)
        }
    }
}
