def doc(text, indent=""):
    """Rust doc comment lines for a schema description."""
    if not text:
        return []
    words = " ".join(str(text).split()).replace("`", "\\`").replace("<", "\\<")
    return [f"{indent}/// {words}"]
