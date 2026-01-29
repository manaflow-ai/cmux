#!/usr/bin/env python3
"""
E2E: focusing a panel clears its notification and triggers a flash.

Note: This uses the socket focus command (no assistive access needed).
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def wait_for_notification(client: cmux, surface_id: str, is_read: bool, timeout: float = 2.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        items = client.list_notifications()
        for item in items:
            if item["surface_id"] == surface_id and item["is_read"] == is_read:
                return True
        time.sleep(0.05)
    return False


def surface_id_for_index(client: cmux, index: int) -> str:
    surfaces = client.list_surfaces()
    for entry in surfaces:
        if entry[0] == index:
            return entry[1]
    raise RuntimeError(f"Surface index {index} not found")


def ensure_two_surfaces(client: cmux) -> None:
    surfaces = client.list_surfaces()
    if len(surfaces) < 2:
        client.new_split("right")
        time.sleep(0.2)


def main() -> int:
    try:
        with cmux() as client:
            client.set_app_focus(None)
            ensure_two_surfaces(client)
            client.focus_surface(0)

            surface_id = surface_id_for_index(client, 1)
            client.clear_notifications()
            client.reset_flash_counts()
            initial_flash = client.flash_count(1)

            client.notify_surface(1, "Focus Test", "panel", "body")
            if not wait_for_notification(client, surface_id, is_read=False, timeout=2.0):
                print("FAIL: Notification did not appear as unread")
                return 1

            client.focus_surface(1)
            client.send("x")
            time.sleep(0.2)

            if not wait_for_notification(client, surface_id, is_read=True, timeout=2.0):
                print("FAIL: Notification did not become read after focus")
                return 1

            final_flash = client.flash_count(1)
            if final_flash <= initial_flash:
                print(f"FAIL: Flash count did not increment (before={initial_flash}, after={final_flash})")
                return 1

            print("PASS: Focus clears notification and flashes panel")
            return 0
    except (cmuxError, RuntimeError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
