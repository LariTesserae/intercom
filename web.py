#!/usr/bin/env python3
"""Intercom web UI — serves the chat interface and API endpoints.

Reads from the same intercom.db that the MCP server writes to.
Run separately: python3 web.py  (port 8767)
"""

import json
import sqlite3
from pathlib import Path

import uvicorn
from starlette.applications import Starlette
from starlette.responses import JSONResponse, HTMLResponse
from starlette.routing import Route
from starlette.requests import Request

DB_PATH = Path(__file__).parent / "intercom.db"
HTML_PATH = Path(__file__).parent / "index.html"

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'chat',
    content TEXT NOT NULL,
    reply_to INTEGER REFERENCES messages(id),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS presence (
    name TEXT PRIMARY KEY,
    project TEXT,
    status TEXT,
    last_seen TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


def get_db() -> sqlite3.Connection:
    db = sqlite3.connect(str(DB_PATH))
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
    for stmt in SCHEMA.strip().split(";"):
        if stmt.strip():
            db.execute(stmt)
    db.commit()
    return db


def touch_presence(db: sqlite3.Connection, name: str):
    db.execute("""
        INSERT INTO presence (name, last_seen)
        VALUES (?, datetime('now'))
        ON CONFLICT(name) DO UPDATE SET last_seen = datetime('now')
    """, (name,))
    db.commit()


async def index(request: Request):
    html = HTML_PATH.read_text()
    return HTMLResponse(html)


async def api_messages(request: Request):
    since_minutes = int(request.query_params.get("since", 360))
    limit = int(request.query_params.get("limit", 200))
    after_id = request.query_params.get("after")

    db = get_db()

    if after_id:
        rows = db.execute("""
            SELECT * FROM messages WHERE id > ? ORDER BY id LIMIT ?
        """, (int(after_id), limit)).fetchall()
    else:
        rows = db.execute("""
            SELECT * FROM messages
            WHERE created_at >= datetime('now', ?)
            ORDER BY id LIMIT ?
        """, (f"-{since_minutes} minutes", limit)).fetchall()

    messages = [dict(row) for row in rows]
    return JSONResponse(messages)


async def api_presence(request: Request):
    db = get_db()
    rows = db.execute("""
        SELECT * FROM presence
        WHERE last_seen >= datetime('now', '-24 hours')
        ORDER BY last_seen DESC
    """).fetchall()
    return JSONResponse([dict(row) for row in rows])


async def api_post(request: Request):
    body = await request.json()
    name = body.get("name", "").strip()
    message = body.get("message", "").strip()
    msg_type = body.get("type", "chat")
    reply_to = body.get("reply_to")

    if not name or not message:
        return JSONResponse({"error": "name and message required"}, status_code=400)

    db = get_db()
    cursor = db.execute(
        "INSERT INTO messages (sender, type, content, reply_to) VALUES (?, ?, ?, ?)",
        (name, msg_type, message, reply_to)
    )
    msg_id = cursor.lastrowid
    db.commit()

    touch_presence(db, name)

    return JSONResponse({"id": msg_id})


async def api_thread(request: Request):
    msg_id = int(request.path_params["id"])
    db = get_db()
    rows = db.execute("""
        SELECT * FROM messages WHERE id = ? OR reply_to = ? ORDER BY id
    """, (msg_id, msg_id)).fetchall()
    return JSONResponse([dict(row) for row in rows])


routes = [
    Route("/", index),
    Route("/api/messages", api_messages),
    Route("/api/presence", api_presence),
    Route("/api/post", api_post, methods=["POST"]),
    Route("/api/thread/{id:int}", api_thread),
]

app = Starlette(routes=routes)

if __name__ == "__main__":
    print("Intercom web UI: http://localhost:8767")
    uvicorn.run(app, host="0.0.0.0", port=8767, log_level="info")
