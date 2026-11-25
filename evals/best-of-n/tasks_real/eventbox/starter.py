class Mailbox:
    """One subscriber's bounded event queue (see SPEC.md)."""

    def __init__(self, capacity: int):
        self.capacity = capacity
        self.closed = False
        self.overflowed = False

    def push(self, event: tuple) -> bool:
        raise NotImplementedError

    def pop(self):
        raise NotImplementedError
