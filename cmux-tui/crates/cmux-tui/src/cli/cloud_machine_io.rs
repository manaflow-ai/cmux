//! `cmux cloud machine-io`: one file operation or command on a Cloud machine. The request, the
//! routes and the answer line are `cmux_cloud_api::machine_io`'s (module docs there); this is
//! only the stdin entry.

use std::io::{Read as _, Write as _};

use cmux_cloud_api::machine_io::{
    Answer, Request, Route, line, now_ms, perform, runtime_and_client, scrub, usage, write_line,
};
use cmux_cloud_api::session::secure_origin;

/// `Some(exit code)` when `args` is `cloud machine-io`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "machine-io" {
        return None;
    }
    let stdout_handle = std::io::stdout();
    let mut buffered = std::io::BufWriter::with_capacity(64 * 1024, stdout_handle.lock());
    let stdout = &mut buffered;
    if !rest.is_empty() {
        let _ = writeln!(
            stdout,
            "{}",
            line(Route::None, &usage("cmux cloud machine-io takes its request as JSON on stdin"))
        );
        return Some(2);
    }
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        let _ = writeln!(stdout, "{}", line(Route::None, &usage("the request could not be read")));
        return Some(2);
    }
    let mut request: Request = match serde_json::from_slice(&input) {
        Ok(request) => request,
        Err(_) => {
            let _ = writeln!(
                stdout,
                "{}",
                line(Route::None, &usage("the request is not a machine-io request"))
            );
            return Some(2);
        }
    };
    drop(input);
    match secure_origin(request.api.trim()) {
        Ok(origin) => request.api = origin,
        Err(message) => {
            let _ = writeln!(stdout, "{}", line(Route::None, &usage(&message)));
            return Some(2);
        }
    }
    request.credential = request.credential.trim().to_owned();
    let (route, answer) = match runtime_and_client() {
        Ok((runtime, client)) => runtime.block_on(perform(&client, &request, now_ms)),
        Err(message) => (Route::Proxy, Answer::error(0, "transport", &message)),
    };
    let mut answer = scrub(answer, &request.credential);
    if write_line(stdout, route, &mut answer).and_then(|()| stdout.flush()).is_err() {
        return Some(1);
    }
    Some(if (200..300).contains(&answer.status) { 0 } else { 1 })
}
