//! The reply of a request a work item answers (p02-threads 231). It is sent
//! once: by the item with its value, or, when the item never answers, by
//! its drop with the reason, so a client always gets an answer and never a
//! false one.

use std::marker::PhantomData;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};

/// Why a work item gave no answer of its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Unanswered {
    /// Shutdown refused or dropped the item before it ran.
    ShuttingDown,
    /// The item's body panicked (the daemon's panic hook logged it).
    Panicked,
}

/// Holds a request's `send` until its work item answers.
pub(crate) struct WorkReply<T, F: FnOnce(Result<T, Unanswered>)> {
    send: Option<F>,
    _value: PhantomData<fn(T)>,
}

impl<T, F: FnOnce(Result<T, Unanswered>)> WorkReply<T, F> {
    pub(crate) fn new(send: F) -> Self {
        Self { send: Some(send), _value: PhantomData }
    }

    /// Runs `body` and sends its value. A panic in `body` sends
    /// [`Unanswered::Panicked`] and unwinds on, so the worker counts it.
    pub(crate) fn run(mut self, body: impl FnOnce() -> T) {
        match catch_unwind(AssertUnwindSafe(body)) {
            Ok(value) => self.finish(Ok(value)),
            Err(payload) => {
                self.finish(Err(Unanswered::Panicked));
                resume_unwind(payload);
            }
        }
    }

    fn finish(&mut self, answer: Result<T, Unanswered>) {
        if let Some(send) = self.send.take() {
            send(answer);
        }
    }
}

impl<T, F: FnOnce(Result<T, Unanswered>)> Drop for WorkReply<T, F> {
    /// The item was refused or dropped unrun (or unwound past `run`).
    fn drop(&mut self) {
        let why =
            if std::thread::panicking() { Unanswered::Panicked } else { Unanswered::ShuttingDown };
        self.finish(Err(why));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn answers_once_with_the_value_a_panic_or_the_drop() {
        let (sender, answers) = channel();
        let send = |sender: std::sync::mpsc::Sender<_>| move |answer| sender.send(answer).unwrap();

        WorkReply::new(send(sender.clone())).run(|| 7);
        drop(WorkReply::new(send(sender.clone())));
        let panicked = std::thread::spawn({
            let sender = sender.clone();
            move || WorkReply::new(send(sender)).run(|| -> i32 { panic!("item panics") })
        })
        .join();
        drop(sender);

        assert!(panicked.is_err(), "the panic unwinds on to the worker");
        assert_eq!(
            answers.iter().collect::<Vec<_>>(),
            vec![Ok(7), Err(Unanswered::ShuttingDown), Err(Unanswered::Panicked)]
        );
    }
}
