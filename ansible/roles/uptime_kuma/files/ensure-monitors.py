#!/usr/bin/env python3
"""Ensure Uptime Kuma push monitors exist. Managed by Ansible.

Uptime Kuma's HTTP API exposes push heartbeats but not monitor management, so
this script writes the monitor rows directly. It is idempotent and only runs
while the service is stopped (see tasks/monitors.yml).

Usage:
    ensure-monitors.py --check   # exit 0 = in sync, 10 = changes needed
    ensure-monitors.py --apply   # insert/update monitors
"""

import json
import os
import sqlite3
import sys

DB = os.environ.get("KUMA_DB", "/opt/uptime-kuma/data/kuma.db")
CONFIG = os.environ.get("KUMA_MONITORS_CONFIG", "/etc/uptime-kuma/monitors.json")
FIELDS = (
    "type",
    "active",
    "push_token",
    "interval",
    "retry_interval",
    "maxretries",
    "description",
)


def load_config():
    with open(CONFIG, encoding="utf-8") as handle:
        return json.load(handle)


def connect(readonly=False):
    if readonly:
        connection = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=15)
    else:
        connection = sqlite3.connect(DB, timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=15000")
    return connection


def desired_monitor(monitor, user_id):
    return {
        "name": monitor["name"],
        "active": int(monitor.get("active", 1)),
        "user_id": user_id,
        "interval": int(monitor.get("interval", 300)),
        "type": "push",
        "push_token": monitor["token"],
        "maxretries": int(monitor.get("maxretries", 2)),
        "retry_interval": int(monitor.get("retry_interval", 60)),
        "description": monitor.get("description", ""),
    }


def change_needed(connection, monitor):
    row = connection.execute(
        "SELECT * FROM monitor WHERE name = ?", (monitor["name"],)
    ).fetchone()
    if row is None:
        return "insert"
    for field in FIELDS:
        if row[field] != monitor[field]:
            return "update"
    # Also reconcile notification links so a newly added notification starts
    # alerting for existing monitors.
    for notification in connection.execute(
        "SELECT id FROM notification WHERE active = 1"
    ).fetchall():
        linked = connection.execute(
            """
            SELECT 1 FROM monitor_notification
             WHERE monitor_id = ? AND notification_id = ?
            """,
            (row["id"], notification["id"]),
        ).fetchone()
        if linked is None:
            return "update"
    return None


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode not in ("--check", "--apply"):
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2

    monitors = load_config()
    connection = connect(readonly=(mode == "--check"))

    user = connection.execute("SELECT id FROM user ORDER BY id LIMIT 1").fetchone()
    if user is None:
        print("no Uptime Kuma user found", file=sys.stderr)
        return 2

    actions = []
    for monitor in monitors:
        desired = desired_monitor(monitor, user["id"])
        action = change_needed(connection, desired)
        if action:
            actions.append((action, desired))

    if mode == "--check":
        print(json.dumps({"changes": len(actions)}))
        return 10 if actions else 0

    for action, monitor in actions:
        if action == "insert":
            cursor = connection.execute(
                """
                INSERT INTO monitor
                    (name, active, user_id, interval, type, push_token,
                     maxretries, retry_interval, description)
                VALUES
                    (:name, :active, :user_id, :interval, :type, :push_token,
                     :maxretries, :retry_interval, :description)
                """,
                monitor,
            )
            monitor_id = cursor.lastrowid
        else:
            connection.execute(
                """
                UPDATE monitor
                   SET type = :type,
                       active = :active,
                       interval = :interval,
                       push_token = :push_token,
                       maxretries = :maxretries,
                       retry_interval = :retry_interval,
                       description = :description
                 WHERE name = :name
                """,
                monitor,
            )
            monitor_id = connection.execute(
                "SELECT id FROM monitor WHERE name = ?", (monitor["name"],)
            ).fetchone()["id"]

        # Without this link the monitor is visible but never notifies.
        for notification in connection.execute(
            "SELECT id FROM notification WHERE active = 1"
        ).fetchall():
            linked = connection.execute(
                """
                SELECT 1 FROM monitor_notification
                 WHERE monitor_id = ? AND notification_id = ?
                """,
                (monitor_id, notification["id"]),
            ).fetchone()
            if linked is None:
                connection.execute(
                    """
                    INSERT INTO monitor_notification
                        (monitor_id, notification_id)
                    VALUES (?, ?)
                    """,
                    (monitor_id, notification["id"]),
                )

    connection.commit()
    print(json.dumps({"changes": len(actions)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
