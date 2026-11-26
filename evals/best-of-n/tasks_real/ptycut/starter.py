CAPACITY = 1022
ESC = 0x1B


def cut(buffer: bytes, room: int, capacity: int = CAPACITY):
    """How many leading bytes of `buffer` to write into `room` free bytes now, or None to wait."""
    if len(buffer) <= room:
        return len(buffer)
    return room
