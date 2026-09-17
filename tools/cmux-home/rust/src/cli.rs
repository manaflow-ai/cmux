use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliArgs {
    pub data: Option<PathBuf>,
    pub once: bool,
    pub help: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError {
    pub message: String,
}

impl CliError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

pub fn parse_args<I, S>(args: I) -> Result<CliArgs, CliError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut data = None;
    let mut once = false;
    let mut help = false;
    let mut iter = args.into_iter().map(Into::into).peekable();

    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--data" => {
                let value = iter
                    .next()
                    .ok_or_else(|| CliError::new("--data requires a JSON path"))?;
                if value.starts_with('-') {
                    return Err(CliError::new("--data requires a JSON path"));
                }
                data = Some(PathBuf::from(value));
            }
            "--once" => once = true,
            "--help" | "-h" => help = true,
            unknown => {
                return Err(CliError::new(format!("unknown argument: {unknown}")));
            }
        }
    }

    Ok(CliArgs { data, once, help })
}

pub fn help_text() -> &'static str {
    "Usage: cmux-home [--data <json>] [--once]\n\n\
     Options:\n\
       --data <json>  Load cmux home state from a JSON file\n\
       --once         Print a deterministic summary and exit without raw TTY mode\n\
       --help, -h     Show this help text\n"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_once_and_data() {
        let args = parse_args(["--data", "state.json", "--once"]).unwrap();

        assert_eq!(args.data, Some(PathBuf::from("state.json")));
        assert!(args.once);
        assert!(!args.help);
    }

    #[test]
    fn reports_missing_data_path() {
        let error = parse_args(["--data"]).unwrap_err();

        assert_eq!(error.message, "--data requires a JSON path");
    }
}
