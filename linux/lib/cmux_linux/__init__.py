"""Linux GTK/VTE entry point for cmux."""

__all__ = ["main"]


def main() -> int:
    from .app import main as run_app

    return run_app()
