//! `job_notify` strings of the CLI catalog (English and Japanese): the
//! notice title and the agent message a job exit hook posts when the job
//! ends (`cmux workspace|pane run --notify-on-exit --on-exit-send`, `cmux
//! terminal <t> exit-hook add`; state/terminal_exit_hooks.rs in the
//! daemon). The CLI sends its locale's templates; the daemon fills in
//! `{name}`, `{status}` (`exit 3`, `signal 15 (SIGTERM)`: exact and not
//! translated), `{code}`, `{signal}` and `{terminal}`.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct JobNotifyMessages {
    /// The notice title.
    pub title: &'static str,
    /// The agent message.
    pub text: &'static str,
}

pub(super) const ENGLISH: JobNotifyMessages = JobNotifyMessages {
    title: "Job ended: {name}",
    text: "cmux: the job {name} ({terminal}) ended: {status}.",
};

pub(super) const JAPANESE: JobNotifyMessages = JobNotifyMessages {
    title: "ジョブ終了: {name}",
    text: "cmux: ジョブ {name} ({terminal}) が終了しました: {status}。",
};
