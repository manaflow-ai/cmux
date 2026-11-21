//! Sending through Messages.app: validation, the osascript call shape and error mapping, with
//! a fake runner (no Messages.app, no osascript).

use std::cell::RefCell;

use cmux_imessage::send::{
    CommandOutput, CommandRunner, MAX_TEXT_BYTES, SEND_SCRIPT, SendError, SendRequest,
    osascript_args, send, validate,
};

struct FakeRunner {
    result: std::io::Result<CommandOutput>,
    calls: RefCell<Vec<(String, Vec<String>)>>,
}

impl FakeRunner {
    fn ok() -> Self {
        Self::with(Ok(CommandOutput { success: true, stderr: String::new() }))
    }
    fn failing(stderr: &str) -> Self {
        Self::with(Ok(CommandOutput { success: false, stderr: stderr.to_string() }))
    }
    fn with(result: std::io::Result<CommandOutput>) -> Self {
        Self { result, calls: RefCell::new(Vec::new()) }
    }
}

impl CommandRunner for FakeRunner {
    fn run(&self, program: &str, args: &[String]) -> std::io::Result<CommandOutput> {
        self.calls.borrow_mut().push((program.to_string(), args.to_vec()));
        match &self.result {
            Ok(output) => Ok(output.clone()),
            Err(error) => Err(std::io::Error::new(error.kind(), error.to_string())),
        }
    }
}

fn request(guid: &str, text: &str) -> SendRequest {
    SendRequest { chat_guid: guid.to_string(), text: text.to_string() }
}

#[test]
fn text_reaches_osascript_only_as_an_argument() {
    let hostile = "\" & (do shell script \"touch /tmp/pwned\") & \"\nend tell";
    let args = osascript_args(&request("iMessage;-;+15550001111", hostile));
    let script: Vec<&str> =
        args.iter().skip(1).step_by(2).take(SEND_SCRIPT.len()).map(String::as_str).collect();
    assert_eq!(script, SEND_SCRIPT.to_vec(), "the script is fixed");
    assert!(args.iter().take(SEND_SCRIPT.len() * 2).step_by(2).all(|flag| flag == "-e"));
    assert_eq!(args[args.len() - 2], "iMessage;-;+15550001111");
    assert_eq!(args[args.len() - 1], hostile, "the text is passed verbatim as argv");
    assert!(SEND_SCRIPT.iter().all(|line| !line.contains("shell")));
}

#[test]
fn validation_refuses_empty_long_and_malformed_requests() {
    assert_eq!(validate(&request("iMessage;-;+15550001111", "  \n")), Err(SendError::EmptyText));
    let long = "x".repeat(MAX_TEXT_BYTES + 1);
    assert_eq!(validate(&request("iMessage;-;+15550001111", &long)), Err(SendError::TextTooLong));
    for bad in
        ["", "-e;-;x", "iMessage", "iMessage;x;id", "iMessage;-;", ";-;id", "iMessage;-;a\nb"]
    {
        assert_eq!(
            validate(&request(bad, "hi")).map_err(|e| e.code()),
            Err("invalid_chat"),
            "{bad:?}"
        );
    }
    assert_eq!(validate(&request("iMessage;-;+15550001111", "hi")), Ok(()));
    assert_eq!(validate(&request("iMessage;+;chat123456", "hi")), Ok(()));
    assert_eq!(validate(&request("SMS;-;+15550001111", "hi")), Ok(()));
}

#[test]
fn a_successful_send_runs_osascript_once() {
    let runner = FakeRunner::ok();
    assert_eq!(send(&request("iMessage;+;chat1", "hello"), &runner), Ok(()));
    let calls = runner.calls.borrow();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "osascript");
    assert_eq!(calls[0].1.last().map(String::as_str), Some("hello"));
}

#[test]
fn an_invalid_request_never_runs_osascript() {
    let runner = FakeRunner::ok();
    assert_eq!(send(&request("iMessage;-;+1", ""), &runner), Err(SendError::EmptyText));
    assert!(runner.calls.borrow().is_empty());
}

#[test]
fn osascript_failures_map_to_codes() {
    let denied = "execution error: Not authorized to send Apple events to Messages. (-1743)";
    assert_eq!(
        send(&request("iMessage;-;+1", "hi"), &FakeRunner::failing(denied)).map_err(|e| e.code()),
        Err("not_permitted")
    );
    let missing = "execution error: Messages got an error: Can’t get chat id \"x\". (-1728)";
    assert_eq!(
        send(&request("iMessage;-;+1", "hi"), &FakeRunner::failing(missing)).map_err(|e| e.code()),
        Err("invalid_chat")
    );
    assert_eq!(
        send(&request("iMessage;-;+1", "hi"), &FakeRunner::failing("boom")).map_err(|e| e.code()),
        Err("failed")
    );
    let absent =
        FakeRunner::with(Err(std::io::Error::new(std::io::ErrorKind::NotFound, "no osascript")));
    assert_eq!(send(&request("iMessage;-;+1", "hi"), &absent), Err(SendError::Unsupported));
    let slow = FakeRunner::with(Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "slow")));
    assert_eq!(send(&request("iMessage;-;+1", "hi"), &slow), Err(SendError::TimedOut));
}

#[test]
fn the_terminal_error_code_decides_not_codes_quoted_earlier() {
    let quoted =
        "execution error: Messages got an error: Can’t get chat id \"iMessage;-;(-1743)\". (-1728)";
    assert_eq!(
        send(&request("iMessage;-;(-1743)", "hi"), &FakeRunner::failing(quoted))
            .map_err(|e| e.code()),
        Err("invalid_chat")
    );
    let denied_then_newline =
        "execution error: Not authorized to send Apple events to Messages. (-1743)\n";
    assert_eq!(
        send(&request("iMessage;-;+1", "hi"), &FakeRunner::failing(denied_then_newline))
            .map_err(|e| e.code()),
        Err("not_permitted")
    );
}

#[cfg(unix)]
#[test]
fn system_runner_reads_stderr_past_the_pipe_buffer_without_stalling() {
    use cmux_imessage::send::SystemRunner;
    let started = std::time::Instant::now();
    let args =
        vec!["-c".to_string(), "head -c 300000 /dev/zero | tr '\\0' x >&2; exit 3".to_string()];
    let output = SystemRunner.run("sh", &args).expect("sh runs");
    assert!(!output.success);
    assert_eq!(output.stderr.len(), 300_000);
    assert!(started.elapsed() < std::time::Duration::from_secs(30), "took {:?}", started.elapsed());
}

#[cfg(unix)]
#[test]
fn a_timeout_returns_even_when_a_descendant_holds_stderr() {
    use cmux_imessage::send::TimedRunner;
    let started = std::time::Instant::now();
    let runner = TimedRunner { timeout: std::time::Duration::from_secs(1) };
    let args = vec!["-c".to_string(), "sleep 20 & wait".to_string()];
    let error = runner.run("sh", &args).expect_err("times out");
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(started.elapsed() < std::time::Duration::from_secs(8), "took {:?}", started.elapsed());
}

#[cfg(unix)]
#[test]
fn an_exit_returns_even_when_a_descendant_keeps_stderr_open() {
    use cmux_imessage::send::TimedRunner;
    let started = std::time::Instant::now();
    let runner = TimedRunner { timeout: std::time::Duration::from_secs(60) };
    let args = vec!["-c".to_string(), "echo early >&2; sleep 20 & exit 4".to_string()];
    let output = runner.run("sh", &args).expect("sh runs");
    assert!(!output.success);
    assert!(output.stderr.contains("early"), "stderr so far is kept: {:?}", output.stderr);
    assert!(started.elapsed() < std::time::Duration::from_secs(8), "took {:?}", started.elapsed());
}
