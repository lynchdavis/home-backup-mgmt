"""Read-only FastAPI dashboard for the tourbillon backup system.

See doc/ADR-007-backup-dashboard.md. Phase 1 is deliberately read-only and
unauthenticated (LAN-only) — routes are namespaced under /api and /partials
so Phase 2's write endpoints and auth middleware can be added without
touching these.
"""
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import tourbillon_client as tb

WEB_DIR = Path(__file__).resolve().parent.parent / "web"

app = FastAPI(title="Tourbillon Dashboard")
app.mount("/static", StaticFiles(directory=str(WEB_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(WEB_DIR / "templates"))


def _format_bytes(n) -> str:
    if n is None:
        return "—"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def _format_age_seconds(seconds) -> str:
    if seconds is None:
        return "—"
    seconds = float(seconds)
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.0f}m"
    hours = minutes / 60
    if hours < 24:
        return f"{hours:.1f}h"
    days = hours / 24
    if days < 30:
        return f"{days:.1f}d"
    return f"{days / 30:.1f}mo"


def _format_iso_age(iso_str) -> str:
    if not iso_str:
        return "—"
    try:
        dt = datetime.fromisoformat(str(iso_str).replace("Z", "+00:00"))
    except ValueError:
        return str(iso_str)
    return _format_age_seconds((datetime.now(timezone.utc) - dt).total_seconds())


templates.env.filters["bytes"] = _format_bytes
templates.env.filters["age"] = _format_age_seconds
templates.env.filters["iso_age"] = _format_iso_age


def _fetch(fn):
    """Run a tourbillon_client getter, returning (data, error_message)."""
    try:
        return fn(), None
    except tb.TourbillonError as e:
        return None, str(e)


@app.get("/")
def index(request: Request):
    return templates.TemplateResponse(request, "index.html", {})


@app.get("/api/status")
def api_status():
    data, error = _fetch(tb.get_status)
    if error:
        return JSONResponse({"error": error}, status_code=502)
    return data


@app.get("/api/hosts")
def api_hosts():
    data, error = _fetch(tb.get_hosts)
    if error:
        return JSONResponse({"error": error}, status_code=502)
    return data


@app.get("/api/repos")
def api_repos():
    data, error = _fetch(tb.get_repos)
    if error:
        return JSONResponse({"error": error}, status_code=502)
    return data


@app.get("/partials/status")
def partial_status(request: Request):
    data, error = _fetch(tb.get_status)
    return templates.TemplateResponse(
        request, "partials/status.html", {"data": data, "error": error}
    )


@app.get("/partials/hosts")
def partial_hosts(request: Request):
    rows, error = _fetch(tb.get_hosts)
    return templates.TemplateResponse(
        request, "partials/hosts.html", {"rows": rows, "error": error}
    )


@app.get("/partials/repos")
def partial_repos(request: Request):
    rows, error = _fetch(tb.get_repos)
    return templates.TemplateResponse(
        request, "partials/repos.html", {"rows": rows, "error": error}
    )
