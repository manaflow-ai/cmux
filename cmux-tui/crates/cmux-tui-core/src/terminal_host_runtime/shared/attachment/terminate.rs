//! Ending a host through its attachment: the unreceipted request, the
//! receipted Terminate (before and after the reader is taken), and the wait
//! for the durable exit receipt.

use super::*;

impl HostAttachment {
    /// Ask the host to end without a receipt: a Terminate with request
    /// id 0, which the host acts on and never acknowledges. The caller
    /// waits for the durable exit receipt instead. A receipted Terminate
    /// would block on its TerminateAck, which the surface's reader thread
    /// delivers only after the terminal output queued ahead of it.
    pub fn request_termination(&self) -> std::io::Result<()> {
        self.send(MessageKind::Terminate, &[])
    }

    pub fn terminate(&mut self) -> anyhow::Result<()> {
        if !self.record.supports_terminate_ack {
            self.send(MessageKind::Terminate, &[])?;
            // The connection is no longer used for commands. A write-half
            // shutdown orders EOF after the complete frame, preventing an
            // immediate Surface drop from discarding a legacy request.
            self.writer.lock().unwrap().shutdown(std::net::Shutdown::Write)?;
            return Ok(());
        }

        if self.reader.is_some() {
            return self.terminate_before_reader_taken();
        }

        let response = self
            .send_control_request(MessageKind::Terminate, MessageKind::TerminateAck, Vec::new())
            .map_err(ClearHistoryFailure::into_error)?;
        anyhow::ensure!(
            response.is_empty(),
            "terminal host returned a malformed terminate receipt"
        );
        Ok(())
    }

    pub(crate) fn terminate_before_reader_taken(&mut self) -> anyhow::Result<()> {
        let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
        anyhow::ensure!(request_id != 0, "terminal host control request id exhausted");
        let mut request = Frame::new(MessageKind::Terminate, Vec::new());
        request.version = self.protocol_version;
        request.request_id = request_id;
        {
            let mut writer = self.writer.lock().unwrap();
            write_frame(&mut *writer, &request).map_err(protocol_io_error)?;
        }

        let protocol_version = self.protocol_version;
        let deadline = Instant::now() + CONTROL_RESPONSE_TIMEOUT;
        let result = (|| -> anyhow::Result<()> {
            let reader = self
                .reader
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
            let previous_timeout =
                reader.read_timeout().context("read terminal-host timeout before termination")?;
            let response = (|| -> anyhow::Result<()> {
                loop {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    anyhow::ensure!(
                        !remaining.is_zero(),
                        "terminal host did not acknowledge termination"
                    );
                    reader
                        .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                        .context("set terminal-host termination timeout")?;
                    let frame = read_frame(reader, MAX_FRAME_PAYLOAD)
                        .map_err(protocol_io_error)?
                        .ok_or_else(|| {
                        anyhow::anyhow!(
                            "terminal host disconnected before acknowledging termination"
                        )
                    })?;
                    anyhow::ensure!(
                        frame.version == protocol_version,
                        "terminal host changed protocol during termination"
                    );
                    if frame.request_id == 0 {
                        continue;
                    }
                    anyhow::ensure!(
                        frame.request_id == request_id
                            && frame.kind == MessageKind::TerminateAck
                            && frame.flags == 0
                            && frame.sequence == 0
                            && frame.payload.is_empty(),
                        "terminal host returned an invalid terminate receipt"
                    );
                    return Ok(());
                }
            })();
            let restored = reader
                .set_read_timeout(previous_timeout)
                .context("restore terminal-host timeout after termination");
            response.and(restored)
        })();
        if result.is_err() {
            self.disconnect();
        }
        result
    }

    pub fn terminate_and_wait_for_exit(&mut self) -> anyhow::Result<TerminalHostExitRecord> {
        let deadline = Instant::now()
            .checked_add(HOST_LAUNCH_ROLLBACK_WAIT)
            .ok_or_else(|| anyhow::anyhow!("terminal-host termination timeout overflow"))?;
        self.terminate().context("send terminal-host termination")?;
        let identity = self.identity();
        let record_path = self.record_path.clone();
        let protocol_version = self.protocol_version;
        let reader = self
            .reader
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
        let previous_timeout =
            reader.read_timeout().context("read terminal-host timeout before termination")?;
        let result = (|| -> anyhow::Result<TerminalHostExitRecord> {
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                anyhow::ensure!(
                    !remaining.is_zero(),
                    "terminal host did not exit before the termination deadline"
                );
                reader
                    .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                    .context("set terminal-host termination timeout")?;
                let frame = match read_frame(reader, MAX_FRAME_PAYLOAD) {
                    Ok(Some(frame)) => frame,
                    Ok(None) | Err(_) => {
                        if let Some((_, record)) = terminal_host_exit_record(&record_path)?
                            && record.terminal_id == identity.terminal_id
                            && record.incarnation == identity.incarnation
                        {
                            return Ok(record);
                        }
                        anyhow::bail!("terminal host disconnected before its exit receipt");
                    }
                };
                anyhow::ensure!(
                    frame.version == protocol_version,
                    "terminal host changed protocol while terminating"
                );
                if frame.kind != MessageKind::Exit {
                    continue;
                }
                anyhow::ensure!(
                    frame.flags == 0 && frame.request_id == 0,
                    "terminal host returned a malformed exit frame"
                );
                let exit = decode_terminal_exit(&frame.payload)?;
                return Ok(TerminalHostExitRecord::new(&identity, exit));
            }
        })();
        let restored = reader
            .set_read_timeout(previous_timeout)
            .context("restore terminal-host timeout after termination");
        match result {
            Ok(record) => {
                restored?;
                Ok(record)
            }
            Err(error) => {
                let _ = restored;
                Err(error)
            }
        }
    }
}
