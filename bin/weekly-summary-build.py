#!/usr/bin/env python3
"""weekly-summary-build.py

Reads `tourbillon status --json` output on stdin, emits a complete
multipart/alternative MIME email on stdout (suitable for piping into
`msmtp`). The HTML version uses real <table> elements with inline
styles (Gmail-safe), color-coded status badges, and small typography.
The text/plain alternative mirrors the structure for readers that
don't render HTML.

Usage (from weekly-summary.sh):
    bin/tourbillon status --json \\
      | bin/weekly-summary-build.py "lynchdavis0@gmail.com" \\
      | msmtp "lynchdavis0@gmail.com"
"""

from __future__ import annotations

import html
import json
import sys
import time
import datetime
from typing import Any

# ── colors / status mapping ────────────────────────────────────────────────
COLOR_OK = "#0a7d20"
COLOR_WARN = "#b8860b"     # amber — "due" / advisory
COLOR_FAIL = "#c01818"
COLOR_TEXT = "#222222"
COLOR_DIM = "#666666"
COLOR_FAINT = "#888888"
COLOR_BORDER = "#e5e5e5"
COLOR_HEAD_BG = "#f3f3f3"
COLOR_ROW_BG = "#fafafa"
# NB: keep all colors as full 6-char hex. badge() appends "1a" (alpha)
# to produce an 8-char rgba — only valid if the base color is 6-char.

STATUS_BADGE_COLOR = {
    "ok": COLOR_OK,
    "due": COLOR_WARN,
    "unreachable": COLOR_WARN,
    "FAILED": COLOR_FAIL,
    "NEVER": COLOR_FAIL,
    "FINISHED": COLOR_OK,
    "RUNNING": COLOR_OK,
    "ERROR": COLOR_FAIL,
    "ONLINE": COLOR_OK,
}


# ── small format helpers ──────────────────────────────────────────────────
def fmt_size(b: int | None) -> str:
    if not b:
        return "—"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def fmt_age(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    if seconds < 60:
        return f"{seconds:.0f}s ago"
    if seconds < 3600:
        return f"{seconds/60:.0f}m ago"
    if seconds < 86400:
        return f"{seconds/3600:.1f}h ago"
    return f"{seconds/86400:.1f}d ago"


def iso_age_seconds(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return time.time() - dt.timestamp()
    except Exception:
        return None


def ms_age_seconds(ms: int | None) -> float | None:
    if not ms:
        return None
    return time.time() - (ms / 1000.0)


# ── HTML primitives ────────────────────────────────────────────────────────
def h(s: Any) -> str:
    return html.escape(str(s)) if s is not None else "—"


def badge(text: str, color: str) -> str:
    return (
        f'<span style="display:inline-block;padding:2px 9px;border-radius:12px;'
        f'background:{color}1a;color:{color};font-size:12px;font-weight:600;'
        f'font-family:ui-monospace,monospace;letter-spacing:.02em;">{h(text)}</span>'
    )


def status_badge(state: str) -> str:
    color = STATUS_BADGE_COLOR.get(state, COLOR_DIM)
    return badge(state, color)


def table_open(headers: list[str]) -> str:
    head_cells = "".join(
        f'<th style="text-align:left;padding:8px 12px;border-bottom:1px solid {COLOR_BORDER};'
        f'font-size:12px;font-weight:600;color:{COLOR_DIM};text-transform:uppercase;letter-spacing:.05em;">'
        f"{h(c)}</th>"
        for c in headers
    )
    return (
        '<table style="border-collapse:collapse;width:100%;'
        f'background:{COLOR_ROW_BG};border:1px solid {COLOR_BORDER};border-radius:6px;'
        'overflow:hidden;margin:8px 0 20px 0;">'
        f'<thead><tr style="background:{COLOR_HEAD_BG};">{head_cells}</tr></thead><tbody>'
    )


def table_close() -> str:
    return "</tbody></table>"


def row(cells: list[str]) -> str:
    cell_html = "".join(
        f'<td style="padding:9px 12px;border-bottom:1px solid {COLOR_BORDER};'
        f'font-size:13px;vertical-align:top;">{c}</td>'
        for c in cells
    )
    return f"<tr>{cell_html}</tr>"


def kv_table(items: list[tuple[str, str]]) -> str:
    rows_html = "".join(
        f'<tr><td style="padding:7px 12px;border-bottom:1px solid {COLOR_BORDER};'
        f'font-size:12px;color:{COLOR_DIM};text-transform:uppercase;letter-spacing:.05em;'
        f'font-weight:600;width:160px;">{h(k)}</td>'
        f'<td style="padding:7px 12px;border-bottom:1px solid {COLOR_BORDER};font-size:13px;">{v}</td></tr>'
        for k, v in items
    )
    return (
        '<table style="border-collapse:collapse;width:100%;'
        f'background:{COLOR_ROW_BG};border:1px solid {COLOR_BORDER};border-radius:6px;'
        'overflow:hidden;margin:8px 0 20px 0;">'
        f"<tbody>{rows_html}</tbody></table>"
    )


def section_heading(title: str) -> str:
    return (
        f'<h3 style="margin:24px 0 4px 0;font-size:16px;font-weight:600;'
        f'color:{COLOR_TEXT};">{h(title)}</h3>'
    )


# ── overall status decision ────────────────────────────────────────────────
def assess_overall(data: dict) -> tuple[str, str, str]:
    """Return (overall_key, badge_text, badge_color)."""
    flags = []

    # Saratoga DR
    sara = data.get("saratoga", {})
    if not sara.get("ok"):
        flags.append(("FAIL", "Saratoga DR API unavailable"))
    else:
        for t in sara.get("tasks", []):
            if t.get("state") in ("ERROR", "FAILED"):
                flags.append(("FAIL", f"Saratoga task {t['name']} in {t['state']}"))
            age_s = ms_age_seconds(t.get("last_ts_ms"))
            if age_s is None or age_s > 26 * 3600:
                flags.append(("FAIL", f"Saratoga task {t['name']} stale ({fmt_age(age_s)})"))

    # Hosts
    hcounts = data.get("hosts", {}).get("counts", {})
    if hcounts.get("FAILED", 0) > 0 or hcounts.get("NEVER", 0) > 0:
        flags.append(("FAIL", f"hosts: {hcounts.get('FAILED', 0)} failed / {hcounts.get('NEVER', 0)} never"))
    if hcounts.get("due", 0) > 0 or hcounts.get("unreachable", 0) > 0:
        flags.append(("WARN", f"hosts: {hcounts.get('due', 0)} due / {hcounts.get('unreachable', 0)} unreachable"))

    # Repos
    rcounts = data.get("repos", {}).get("counts", {})
    if rcounts.get("FAILED", 0) > 0 or rcounts.get("NEVER", 0) > 0:
        flags.append(("FAIL", f"repos: {rcounts.get('FAILED', 0)} failed / {rcounts.get('NEVER', 0)} never"))
    if rcounts.get("due", 0) > 0:
        flags.append(("WARN", f"repos: {rcounts.get('due', 0)} due"))

    # Pool
    pool = data.get("pool", {})
    if pool.get("health") and pool["health"] != "ONLINE":
        flags.append(("FAIL", f"pool {pool.get('pool')} is {pool['health']}"))
    if any(pool.get(k, 0) for k in ("read_errors", "write_errors", "cksum_errors")):
        flags.append(("FAIL", "pool has read/write/checksum errors"))

    # Drive
    drive = data.get("drive", {})
    for k in ("reallocated", "pending", "uncorrectable"):
        if drive.get(k, 0) > 0:
            flags.append(("FAIL", f"drive {k} sector(s): {drive[k]}"))

    if any(f[0] == "FAIL" for f in flags):
        return ("FAIL", "⚠ Attention required", COLOR_FAIL)
    if any(f[0] == "WARN" for f in flags):
        return ("WARN", "⚠ Healthy with caveats", COLOR_WARN)
    return ("OK", "✓ All systems healthy", COLOR_OK)


# ── sections (HTML) ────────────────────────────────────────────────────────
def render_saratoga(data: dict) -> str:
    sara = data.get("saratoga", {})
    if not sara.get("ok"):
        return section_heading("Saratoga DR") + (
            f'<p style="color:{COLOR_FAIL};">unavailable: {h(sara.get("error", "?"))}</p>'
        )
    rows = []
    for t in sara.get("tasks", []):
        age = fmt_age(ms_age_seconds(t.get("last_ts_ms")))
        name_short = (t.get("name") or "").split(" - ", 1)[0]
        rows.append(row([
            f'<code style="font-family:ui-monospace,monospace;">{h(name_short)}</code>',
            status_badge(t.get("state", "?")),
            h(age),
            f'<code style="font-family:ui-monospace,monospace;font-size:12px;color:{COLOR_DIM};">{h(t.get("last_snapshot"))}</code>',
        ]))
    body = (
        table_open(["task", "state", "last sync", "most recent snapshot"])
        + "".join(rows)
        + table_close()
    )
    return section_heading("Saratoga DR") + body


def render_repos(data: dict) -> str:
    r = data.get("repos", {})
    counts = r.get("counts", {})
    by_prov = r.get("by_provider", {})
    parts = []
    parts.append(section_heading(f"Repo mirrors — {r.get('n', 0)} configured"))
    parts.append(kv_table([
        ("ok / due / failed / never",
            f'{badge(counts.get("ok",0), COLOR_OK)} '
            f'{badge(counts.get("due",0), COLOR_WARN if counts.get("due",0) else COLOR_DIM)} '
            f'{badge(counts.get("FAILED",0), COLOR_FAIL if counts.get("FAILED",0) else COLOR_DIM)} '
            f'{badge(counts.get("NEVER",0), COLOR_FAIL if counts.get("NEVER",0) else COLOR_DIM)}'),
        ("total size", h(fmt_size(r.get("total_size", 0)))),
        ("by provider", f"{by_prov.get('github', 0)} github · {by_prov.get('bitbucket', 0)} bitbucket"),
        ("oldest sync", _format_age_tuple(r.get("oldest"))),
        ("newest sync", _format_age_tuple(r.get("newest"))),
    ]))
    return "".join(parts)


def _format_age_tuple(t: list | None) -> str:
    if not t or t[0] is None:
        return "—"
    name, age = t[0], t[1]
    return f'<code style="font-family:ui-monospace,monospace;">{h(name)}</code> &nbsp;<span style="color:{COLOR_DIM};">{h(fmt_age(age))}</span>'


def render_hosts(data: dict) -> str:
    rows_data = data.get("host_rows", [])
    now_ts = time.time()
    parts = [section_heading(f"Host backups — {len(rows_data)} configured")]
    if not rows_data:
        parts.append(f'<p style="color:{COLOR_DIM};">(no hosts configured)</p>')
        return "".join(parts)

    trows = []
    for r in sorted(rows_data, key=lambda x: x.get("name") or ""):
        last_ok = fmt_age(iso_age_seconds(r.get("last_success_at")))
        note = ""
        state = r.get("state", "?")
        if state == "ok":
            interval_s = r.get("interval_s") or 0
            note = f"interval {interval_s/3600:.0f}h"
        elif state == "due":
            age = iso_age_seconds(r.get("last_success_at"))
            overdue = (age or 0) - (r.get("interval_s") or 0)
            note = f"overdue by {fmt_age(overdue)}"
        elif state == "unreachable":
            note = "host currently offline"
        elif state == "FAILED":
            err = r.get("last_error", "") or ""
            note = err[:80]
        elif state == "NEVER":
            note = "never attempted"
        trows.append(row([
            f'<code style="font-family:ui-monospace,monospace;font-weight:600;">{h(r.get("name"))}</code>',
            status_badge(state),
            h(last_ok),
            h(fmt_size(r.get("size", 0))),
            f'<span style="color:{COLOR_DIM};font-size:12px;">{h(note)}</span>',
        ]))
    parts.append(table_open(["host", "state", "last sync", "size", "note"]) + "".join(trows) + table_close())
    return "".join(parts)


def render_pool(data: dict) -> str:
    p = data.get("pool", {})
    nxt = data.get("next_scrub", {}) or {}
    parts = [section_heading(f"Pool — {h(p.get('pool', '?'))}")]
    if "error" in p:
        parts.append(f'<p style="color:{COLOR_FAIL};">unavailable: {h(p["error"])}</p>')
        return "".join(parts)
    re_err = p.get("read_errors", "?")
    we_err = p.get("write_errors", "?")
    ce_err = p.get("cksum_errors", "?")
    err_summary = (
        f'{badge(re_err, COLOR_OK if re_err == 0 else COLOR_FAIL)} read · '
        f'{badge(we_err, COLOR_OK if we_err == 0 else COLOR_FAIL)} write · '
        f'{badge(ce_err, COLOR_OK if ce_err == 0 else COLOR_FAIL)} cksum'
    )
    parts.append(kv_table([
        ("state", status_badge(p.get("health", "?"))),
        ("capacity",
            f'{h(fmt_size(p.get("alloc", 0)))} used / '
            f'{h(fmt_size(p.get("free", 0)))} free '
            f'<span style="color:{COLOR_DIM};">({h(p.get("capacity_pct", "?"))}%)</span>'),
        ("errors", err_summary),
        ("scan", h(p.get("scan", "—"))),
        ("next scrub", f'{h(nxt.get("next", "—"))} <span style="color:{COLOR_DIM};">{h(nxt.get("tz",""))}</span>'),
    ]))
    return "".join(parts)


def render_drive(data: dict) -> str:
    d = data.get("drive", {})
    parts = [section_heading(f"Drive — {h(d.get('device', '/dev/sdb'))}")]
    if "error" in d and not any(k in d for k in ("reallocated", "pending", "uncorrectable")):
        parts.append(f'<p style="color:{COLOR_FAIL};">unavailable: {h(d["error"])}</p>')
        return "".join(parts)
    re_v = d.get("reallocated")
    pe_v = d.get("pending")
    un_v = d.get("uncorrectable")
    parts.append(kv_table([
        ("drive", f'{h(d.get("model"))} <span style="color:{COLOR_DIM};">S/N {h(d.get("serial"))}</span>'),
        ("reallocated", badge(re_v, COLOR_OK if re_v == 0 else COLOR_FAIL)),
        ("pending", badge(pe_v, COLOR_OK if pe_v == 0 else COLOR_FAIL)),
        ("uncorrectable", badge(un_v, COLOR_OK if un_v == 0 else COLOR_FAIL)),
        ("power-on hours", h(d.get("power_on_hours"))),
        ("last test", h(d.get("last_test", "—"))),
    ]))
    return "".join(parts)


# ── plain-text rendering (mirrors HTML structure, no markup) ───────────────
def render_text(data: dict, badge_text: str) -> str:
    lines = []
    lines.append("kodiak weekly backup summary")
    lines.append(datetime.datetime.now().strftime("%A, %B %-d, %Y"))
    lines.append("")
    lines.append(badge_text)
    lines.append("")

    # saratoga
    lines.append("── Saratoga DR ──")
    sara = data.get("saratoga", {})
    if not sara.get("ok"):
        lines.append(f"  unavailable: {sara.get('error','?')}")
    else:
        for t in sara.get("tasks", []):
            name_short = (t.get("name") or "").split(" - ", 1)[0]
            age = fmt_age(ms_age_seconds(t.get("last_ts_ms")))
            lines.append(f"  {name_short:<12}{t.get('state','?'):<11}{age:<14}{t.get('last_snapshot','')}")
    lines.append("")

    # repos
    r = data.get("repos", {})
    counts = r.get("counts", {})
    by_prov = r.get("by_provider", {})
    lines.append(f"── Repo mirrors — {r.get('n',0)} configured ──")
    lines.append(f"  {counts.get('ok',0)} ok | {counts.get('due',0)} due | "
                 f"{counts.get('FAILED',0)} failed | {counts.get('NEVER',0)} never")
    lines.append(f"  {fmt_size(r.get('total_size',0))} across "
                 f"{by_prov.get('github',0)} github + {by_prov.get('bitbucket',0)} bitbucket")
    if r.get("oldest") and r["oldest"][0]:
        lines.append(f"  oldest sync: {r['oldest'][0]}  ({fmt_age(r['oldest'][1])})")
    if r.get("newest") and r["newest"][0]:
        lines.append(f"  newest sync: {r['newest'][0]}  ({fmt_age(r['newest'][1])})")
    lines.append("")

    # hosts
    rows_data = data.get("host_rows", [])
    lines.append(f"── Host backups — {len(rows_data)} configured ──")
    if not rows_data:
        lines.append("  (no hosts configured)")
    else:
        lines.append(f"  {'HOST':<13}{'STATE':<13}{'LAST OK':<11}{'SIZE':>10}")
        for r in sorted(rows_data, key=lambda x: x.get("name") or ""):
            lines.append(f"  {(r.get('name') or ''):<13}{r.get('state','?'):<13}"
                         f"{fmt_age(iso_age_seconds(r.get('last_success_at'))):<11}"
                         f"{fmt_size(r.get('size',0)):>10}")
    lines.append("")

    # pool
    p = data.get("pool", {})
    nxt = data.get("next_scrub", {}) or {}
    lines.append(f"── Pool {p.get('pool','?')} ──")
    if "error" in p:
        lines.append(f"  unavailable: {p['error']}")
    else:
        lines.append(f"  state:    {p.get('health','?')}")
        lines.append(f"  capacity: {fmt_size(p.get('alloc',0))} used / {fmt_size(p.get('free',0))} free  ({p.get('capacity_pct','?')}%)")
        lines.append(f"  errors:   {p.get('read_errors','?')} read / {p.get('write_errors','?')} write / {p.get('cksum_errors','?')} cksum")
        lines.append(f"  scan:     {p.get('scan','—')}")
        lines.append(f"  next scrub: {nxt.get('next','—')} {nxt.get('tz','')}")
    lines.append("")

    # drive
    d = data.get("drive", {})
    lines.append(f"── Drive {d.get('device','/dev/sdb')} ──")
    if "error" in d and not any(k in d for k in ("reallocated", "pending", "uncorrectable")):
        lines.append(f"  unavailable: {d['error']}")
    else:
        lines.append(f"  drive:        {d.get('model','—')} (S/N {d.get('serial','—')})")
        lines.append(f"  reallocated:  {d.get('reallocated','—')}")
        lines.append(f"  pending:      {d.get('pending','—')}")
        lines.append(f"  uncorrectable:{d.get('uncorrectable','—')}")
        lines.append(f"  power-on hrs: {d.get('power_on_hours','—')}")
        lines.append(f"  last test:    {d.get('last_test','—')}")
    lines.append("")

    lines.append("─" * 60)
    lines.append(f"Heartbeat email — generated {datetime.datetime.now().strftime('%Y-%m-%d %H:%M %Z')}.")
    lines.append("If a Sunday goes by without this email, cron + msmtp are down.")
    return "\n".join(lines)


# ── compose the multipart MIME message ────────────────────────────────────
def main() -> int:
    data = json.load(sys.stdin)
    overall, badge_text, badge_color = assess_overall(data)

    today_human = datetime.datetime.now().strftime("%A, %B %-d, %Y")
    today_stamp = datetime.datetime.now().strftime("%Y-%m-%d")
    now_stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M %Z")

    subject = f"kodiak weekly backup summary {today_stamp}"
    if overall == "FAIL":
        subject += " — ATTENTION"
    elif overall == "WARN":
        subject += " — caveats"

    # HTML body
    html_body = (
        '<!DOCTYPE html><html><head><meta charset="UTF-8"></head>'
        f'<body style="font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif;'
        f'color:{COLOR_TEXT};max-width:760px;margin:0 auto;padding:16px;line-height:1.5;">'

        f'<h2 style="margin:0 0 4px 0;">kodiak weekly backup summary</h2>'
        f'<div style="color:{COLOR_DIM};margin-bottom:16px;">{h(today_human)}</div>'

        f'<div style="padding:14px 18px;border-radius:8px;background:{badge_color}11;'
        f'border-left:4px solid {badge_color};margin-bottom:8px;">'
        f'<strong style="color:{badge_color};font-size:17px;">{h(badge_text)}</strong>'
        f'</div>'

        + render_saratoga(data)
        + render_repos(data)
        + render_hosts(data)
        + render_pool(data)
        + render_drive(data)

        + f'<hr style="border:0;border-top:1px solid {COLOR_BORDER};margin:28px 0 12px 0;">'
        + f'<p style="color:{COLOR_FAINT};font-size:12px;margin:0;">'
        + f'Heartbeat email — generated {h(now_stamp)} by '
        + '<code style="font-family:ui-monospace,monospace;">bin/weekly-summary.sh</code>. '
        + 'If a Sunday goes by without this email, the cron + msmtp chain is broken '
        + '(different failure mode from a subsystem alert).</p>'
        + '</body></html>'
    )

    text_body = render_text(data, badge_text)

    # multipart envelope
    boundary = f"kodiak-weekly-{int(time.time())}"
    out = sys.stdout
    out.write(f"Subject: {subject}\r\n")
    out.write("MIME-Version: 1.0\r\n")
    out.write(f"Content-Type: multipart/alternative; boundary=\"{boundary}\"\r\n")
    out.write("\r\n")
    out.write("This is a multi-part message in MIME format.\r\n")
    out.write("\r\n")

    # text/plain
    out.write(f"--{boundary}\r\n")
    out.write("Content-Type: text/plain; charset=UTF-8\r\n")
    out.write("Content-Transfer-Encoding: 8bit\r\n")
    out.write("\r\n")
    out.write(text_body + "\r\n")

    # text/html
    out.write(f"--{boundary}\r\n")
    out.write("Content-Type: text/html; charset=UTF-8\r\n")
    out.write("Content-Transfer-Encoding: 8bit\r\n")
    out.write("\r\n")
    out.write(html_body + "\r\n")

    out.write(f"--{boundary}--\r\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
