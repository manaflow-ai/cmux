def doc(text, indent=""):
    """Rust doc comment lines for a schema description."""
    if not text:
        return []
    words = " ".join(str(text).split())
    if not words:
        return []
    for ch in ("\\", "`", "<", "[", "]"):
        words = words.replace(ch, "\\" + ch)
    return [f"{indent}/// {words}"]
