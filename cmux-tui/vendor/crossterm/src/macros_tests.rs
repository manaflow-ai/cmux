use std::io;
use std::str;

// Helper for execute tests to confirm flush
#[derive(Default, Debug, Clone)]
struct FakeWrite {
    buffer: String,
    flushed: bool,
}

impl io::Write for FakeWrite {
    fn write(&mut self, content: &[u8]) -> io::Result<usize> {
        let content =
            str::from_utf8(content).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        self.buffer.push_str(content);
        self.flushed = false;
        Ok(content.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flushed = true;
        Ok(())
    }
}

#[cfg(not(windows))]
mod unix {
    use std::fmt;

    use super::FakeWrite;
    use crate::command::Command;

    pub struct FakeCommand;

    impl Command for FakeCommand {
        fn write_ansi(&self, f: &mut impl fmt::Write) -> fmt::Result {
            f.write_str("cmd")
        }
    }

    #[test]
    fn test_queue_one() {
        let mut result = FakeWrite::default();
        queue!(&mut result, FakeCommand).unwrap();
        assert_eq!(&result.buffer, "cmd");
        assert!(!result.flushed);
    }

    #[test]
    fn test_queue_many() {
        let mut result = FakeWrite::default();
        queue!(&mut result, FakeCommand, FakeCommand).unwrap();
        assert_eq!(&result.buffer, "cmdcmd");
        assert!(!result.flushed);
    }

    #[test]
    fn test_queue_trailing_comma() {
        let mut result = FakeWrite::default();
        queue!(&mut result, FakeCommand, FakeCommand,).unwrap();
        assert_eq!(&result.buffer, "cmdcmd");
        assert!(!result.flushed);
    }

    #[test]
    fn test_execute_one() {
        let mut result = FakeWrite::default();
        execute!(&mut result, FakeCommand).unwrap();
        assert_eq!(&result.buffer, "cmd");
        assert!(result.flushed);
    }

    #[test]
    fn test_execute_many() {
        let mut result = FakeWrite::default();
        execute!(&mut result, FakeCommand, FakeCommand).unwrap();
        assert_eq!(&result.buffer, "cmdcmd");
        assert!(result.flushed);
    }

    #[test]
    fn test_execute_trailing_comma() {
        let mut result = FakeWrite::default();
        execute!(&mut result, FakeCommand, FakeCommand,).unwrap();
        assert_eq!(&result.buffer, "cmdcmd");
        assert!(result.flushed);
    }
}

#[cfg(windows)]
mod windows {
    use std::fmt;

    use std::cell::RefCell;

    use super::FakeWrite;
    use crate::command::Command;

    // We need to test two different APIs: WinAPI and the write api. We
    // don't know until runtime which we're supporting (via
    // Command::is_ansi_code_supported), so we have to test them both. The
    // CI environment hopefully includes both versions of windows.

    // WindowsEventStream is a place for execute_winapi to push strings,
    // when called.
    type WindowsEventStream = Vec<&'static str>;

    struct FakeCommand<'a> {
        // Need to use a refcell because we want execute_winapi to be able
        // push to the vector, but execute_winapi take &self.
        stream: RefCell<&'a mut WindowsEventStream>,
        value: &'static str,
    }

    impl<'a> FakeCommand<'a> {
        fn new(stream: &'a mut WindowsEventStream, value: &'static str) -> Self {
            Self { value, stream: RefCell::new(stream) }
        }
    }

    impl<'a> Command for FakeCommand<'a> {
        fn write_ansi(&self, f: &mut impl fmt::Write) -> fmt::Result {
            f.write_str(self.value)
        }

        fn execute_winapi(&self) -> std::io::Result<()> {
            self.stream.borrow_mut().push(self.value);
            Ok(())
        }
    }

    // Helper function for running tests against either WinAPI or an
    // io::Write.
    //
    // This function will execute the `test` function, which should
    // queue some commands against the given FakeWrite and
    // WindowsEventStream. It will then test that the correct data sink
    // was populated. It does not currently check is_ansi_code_supported;
    // for now it simply checks that one of the two streams was correctly
    // populated.
    //
    // If the stream was populated, it tests that the two arrays are equal.
    // If the writer was populated, it tests that the contents of the
    // write buffer are equal to the concatenation of `stream_result`.
    fn test_harness(
        stream_result: &[&'static str],
        test: impl FnOnce(&mut FakeWrite, &mut WindowsEventStream) -> std::io::Result<()>,
    ) {
        let mut stream = WindowsEventStream::default();
        let mut writer = FakeWrite::default();

        if let Err(err) = test(&mut writer, &mut stream) {
            panic!("Error returned from test function: {:?}", err);
        }

        // We need this for type inference, for whatever reason.
        const EMPTY_RESULT: [&str; 0] = [];

        // TODO: confirm that the correct sink was used, based on
        // is_ansi_code_supported
        match (writer.buffer.is_empty(), stream.is_empty()) {
            (true, true) if stream_result == EMPTY_RESULT => {}
            (true, true) => panic!(
                "Neither the event stream nor the writer were populated. Expected {:?}",
                stream_result
            ),

            // writer is populated
            (false, true) => {
                // Concat the stream result to find the string result
                let result: String = stream_result.iter().copied().collect();
                assert_eq!(result, writer.buffer);
                assert_eq!(&stream, &EMPTY_RESULT);
            }

            // stream is populated
            (true, false) => {
                assert_eq!(stream, stream_result);
                assert_eq!(writer.buffer, "");
            }

            // Both are populated
            (false, false) => panic!(
                "Both the writer and the event stream were written to.\n\
                     Only one should be used, based on is_ansi_code_supported.\n\
                     stream: {stream:?}\n\
                     writer: {writer:?}",
                stream = stream,
                writer = writer,
            ),
        }
    }

    #[test]
    fn test_queue_one() {
        test_harness(&["cmd1"], |writer, stream| queue!(writer, FakeCommand::new(stream, "cmd1")))
    }

    #[test]
    fn test_queue_some() {
        test_harness(&["cmd1", "cmd2"], |writer, stream| {
            queue!(writer, FakeCommand::new(stream, "cmd1"), FakeCommand::new(stream, "cmd2"),)
        })
    }

    #[test]
    fn test_many_queues() {
        test_harness(&["cmd1", "cmd2", "cmd3"], |writer, stream| {
            queue!(writer, FakeCommand::new(stream, "cmd1"))?;
            queue!(writer, FakeCommand::new(stream, "cmd2"))?;
            queue!(writer, FakeCommand::new(stream, "cmd3"))
        })
    }
}
