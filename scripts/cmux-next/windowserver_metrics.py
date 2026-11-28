"""Small, platform-independent helpers for WindowServer process measurements."""


def parse_process_time(value: str) -> float:
    """Parse the formats emitted by macOS ps -o time into CPU seconds.

    ps uses SS.ss, MM:SS.ss, HH:MM:SS.ss and, after a process has
    run for a day, DD-HH:MM:SS.ss. Keeping the day component separate is
    essential: folding it into the running clock total and then multiplying
    the total by 60 for each field overcounts it.
    """
    if not value:
        raise ValueError("empty process time")
    if "-" in value:
        day_text, value = value.split("-", 1)
        if not day_text.isdigit():
            raise ValueError(f"invalid day component: {day_text!r}")
        total = int(day_text) * 86400.0
    else:
        total = 0.0
    fields = value.split(":")
    if not 1 <= len(fields) <= 3 or any(not field for field in fields):
        raise ValueError(f"invalid process time: {value!r}")
    try:
        seconds = [float(field) for field in fields]
    except ValueError as error:
        raise ValueError(f"invalid process time: {value!r}") from error
    multipliers = (1.0, 60.0, 3600.0)
    total += sum(seconds[-index - 1] * multipliers[index] for index in range(len(seconds)))
    return total
