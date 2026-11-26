def split_title(raw: str) -> tuple:
    """(text, activity) of a terminal title."""
    raise NotImplementedError


def store(stored, title: str) -> tuple:
    """(raw title to store, what to announce or None)."""
    if title == stored:
        return stored, None
    return title, (title, None)


def shown_title(tab: dict) -> tuple:
    """(text, activity) the sidebar shows for a tab."""
    return tab.get("title", ""), None
