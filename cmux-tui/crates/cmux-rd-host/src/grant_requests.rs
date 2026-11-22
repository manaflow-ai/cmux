//! The NEXT app's one-shot asks of the Screen Sharing helper, the one bundle that holds this
//! Mac's privacy grants (plans/cmux-next/screen-sharing-helper.md). The app never calls a TCC
//! API itself, so macOS never lists it: the key press of a dictation hand-off (PostEvent) and
//! the Voice Room's screen still (Screen Recording) come from this process instead.
//!
//! Neither mode prompts. A missing grant answers `{"granted":false}` and the app asks for it
//! with `request-permission`, which names the helper. One JSON line on stdout, then exit:
//!
//! - `__post-key CODE FLAGS`: one press (down, up) of virtual key `CODE` with modifier `FLAGS`
//!   (CGEventFlags, only Command, Control, Option and Shift), at the HID level, so the app in
//!   front sees it as typed. Answers `{"granted":true}` once posted.
//! - `__screen-still MAX_WIDTH EXCLUDE_PID OUT`: one picture of the main display without
//!   `EXCLUDE_PID`'s windows (the app's own), at most `MAX_WIDTH` pixels wide, written to the
//!   new file `OUT` as tightly packed RGBA8 (premultiplied sRGB, top row first). Answers
//!   `{"granted":true,"width":W,"height":H}`. `OUT` must not exist: the helper never writes
//!   over a file.

use serde::Serialize;

/// The hidden mode that posts one key press.
pub(crate) const POST_KEY: &str = "__post-key";
/// The hidden mode that takes one screen still.
pub(crate) const SCREEN_STILL: &str = "__screen-still";

/// CGEventFlags bits a hand-off chord may hold: Shift, Control, Option, Command.
const MODIFIER_MASK: u64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000;
/// The largest virtual key code (ANSI keyboards stop at 0x7E).
const MAX_KEY_CODE: u16 = 0x7F;
/// The widest still the Voice Room may ask for.
const MAX_STILL_WIDTH: usize = 8192;

/// One key press `__post-key` posts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct KeyPress {
    pub code: u16,
    pub flags: u64,
}

impl KeyPress {
    /// `CODE FLAGS` in decimal; None for anything else (extra words, a flag that is not a
    /// modifier, a key code past the keyboard's).
    pub(crate) fn parse(args: &[String]) -> Option<Self> {
        let [code, flags] = args else { return None };
        let code: u16 = code.parse().ok().filter(|&c| c <= MAX_KEY_CODE)?;
        let flags: u64 = flags.parse().ok().filter(|&f| f & !MODIFIER_MASK == 0)?;
        Some(Self { code, flags })
    }
}

/// One still `__screen-still` takes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StillRequest {
    pub max_width: usize,
    pub exclude_pid: u32,
    pub out: std::path::PathBuf,
}

impl StillRequest {
    /// `MAX_WIDTH EXCLUDE_PID OUT`; `OUT` must be an absolute path.
    pub(crate) fn parse(args: &[String]) -> Option<Self> {
        let [width, pid, out] = args else { return None };
        let max_width: usize =
            width.parse().ok().filter(|&w| (1..=MAX_STILL_WIDTH).contains(&w))?;
        let exclude_pid: u32 = pid.parse().ok().filter(|&p| p > 0)?;
        let out = std::path::PathBuf::from(out);
        out.is_absolute().then_some(Self { max_width, exclude_pid, out })
    }
}

/// The one line a mode answers.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub(crate) struct Answer {
    pub granted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

impl Answer {
    pub(crate) const NOT_GRANTED: Self = Self { granted: false, width: None, height: None };
    pub(crate) const POSTED: Self = Self { granted: true, width: None, height: None };
}

/// Runs `cmd` (one of the two modes) with its words. 0 once it answered, 1 when it failed,
/// 2 for a usage error.
pub(crate) fn run(cmd: &str, args: &[String]) -> i32 {
    let result = match cmd {
        POST_KEY => match KeyPress::parse(args) {
            Some(press) => post_key(press),
            None => return usage(cmd, "CODE FLAGS"),
        },
        SCREEN_STILL => match StillRequest::parse(args) {
            Some(request) => screen_still(&request),
            None => return usage(cmd, "MAX_WIDTH EXCLUDE_PID /absolute/new/file"),
        },
        _ => return usage(cmd, ""),
    };
    match result.and_then(|answer| write_answer(&mut std::io::stdout().lock(), &answer)) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd {cmd}: {e}");
            1
        }
    }
}

fn usage(cmd: &str, words: &str) -> i32 {
    eprintln!("usage: cmux-rd {cmd} {words}");
    2
}

fn write_answer(output: &mut impl std::io::Write, answer: &Answer) -> crate::Res<()> {
    serde_json::to_writer(&mut *output, answer)?;
    output.write_all(b"\n")?;
    Ok(())
}

fn post_key(press: KeyPress) -> crate::Res<Answer> {
    Ok(if crate::mac::post_key_press(press.code, press.flags)? {
        Answer::POSTED
    } else {
        Answer::NOT_GRANTED
    })
}

fn screen_still(request: &StillRequest) -> crate::Res<Answer> {
    use cmux_computer_use::desktop::DesktopError;
    use std::io::Write;
    let frame = match crate::mac::cu_host::display_still(request.max_width, request.exclude_pid) {
        Ok(frame) => frame,
        Err(DesktopError::PermissionMissing(_)) => return Ok(Answer::NOT_GRANTED),
        Err(e) => return Err(e.to_string().into()),
    };
    let mut file = new_private_file(&request.out)?;
    file.write_all(&frame.rgba)?;
    Ok(Answer { granted: true, width: Some(frame.width), height: Some(frame.height) })
}

/// A file only this user may read, made new (never one that exists, never through a symlink).
fn new_private_file(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn a_key_press_is_a_code_and_modifier_flags() {
        assert_eq!(
            KeyPress::parse(&words("49 524288")),
            Some(KeyPress { code: 49, flags: 0x8_0000 })
        );
        // Control + Option + D.
        assert_eq!(
            KeyPress::parse(&words("2 786432")),
            Some(KeyPress { code: 2, flags: 0xC_0000 })
        );
        assert_eq!(KeyPress::parse(&words("49 0")), Some(KeyPress { code: 49, flags: 0 }));
    }

    #[test]
    fn a_key_press_refuses_anything_but_a_chord() {
        // Caps Lock (0x10000), the Fn bit (0x800000), a key code past the keyboard's, extra words.
        assert_eq!(KeyPress::parse(&words("49 65536")), None);
        assert_eq!(KeyPress::parse(&words("49 8388608")), None);
        assert_eq!(KeyPress::parse(&words("200 0")), None);
        assert_eq!(KeyPress::parse(&words("49")), None);
        assert_eq!(KeyPress::parse(&words("49 0 1")), None);
        assert_eq!(KeyPress::parse(&words("-1 0")), None);
    }

    #[test]
    fn a_still_names_a_width_the_app_and_a_new_absolute_file() {
        assert_eq!(
            StillRequest::parse(&words("1440 512 /tmp/still.rgba")),
            Some(StillRequest { max_width: 1440, exclude_pid: 512, out: "/tmp/still.rgba".into() })
        );
        assert_eq!(StillRequest::parse(&words("1440 512 still.rgba")), None);
        assert_eq!(StillRequest::parse(&words("0 512 /tmp/still.rgba")), None);
        assert_eq!(StillRequest::parse(&words("99999 512 /tmp/still.rgba")), None);
        assert_eq!(StillRequest::parse(&words("1440 0 /tmp/still.rgba")), None);
        assert_eq!(StillRequest::parse(&words("1440 512")), None);
    }

    #[test]
    fn an_answer_is_one_json_line() {
        let mut output = Vec::new();
        write_answer(&mut output, &Answer::NOT_GRANTED).expect("answer");
        assert_eq!(output, b"{\"granted\":false}\n");
        let mut output = Vec::new();
        write_answer(&mut output, &Answer { granted: true, width: Some(1440), height: Some(900) })
            .expect("answer");
        assert_eq!(output, b"{\"granted\":true,\"width\":1440,\"height\":900}\n");
    }

    #[test]
    fn a_bad_ask_is_a_usage_error_that_touches_nothing() {
        assert_eq!(run(POST_KEY, &words("49 65536")), 2);
        assert_eq!(run(SCREEN_STILL, &words("1440 512 relative")), 2);
    }

    #[test]
    fn a_still_never_writes_over_a_file() {
        let dir = std::env::temp_dir().join(format!("cmux-rd-still-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("taken");
        std::fs::write(&path, b"keep").expect("write");
        assert!(new_private_file(&path).is_err());
        assert_eq!(std::fs::read(&path).expect("read"), b"keep");
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }
}
