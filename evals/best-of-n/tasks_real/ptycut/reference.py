CAPACITY = 1022
ESC = 0x1B


def cut(buffer: bytes, room: int, capacity: int = CAPACITY):
    """How many leading bytes of `buffer` to write into `room` free bytes now, or None to wait."""
    if len(buffer) <= room:
        return len(buffer)
    last = buffer.rfind(b"\x1b", 1, room + 1)
    if last >= 1:
        return last
    if buffer[0] == ESC:
        nxt = buffer.find(b"\x1b", 1)
        sequence = len(buffer) if nxt < 0 else nxt
        if sequence <= capacity or room == 0:
            return None
    if room == 0:
        return None
    if buffer[room - 1] == ESC:
        return room - 1 if room > 1 else None
    return room
