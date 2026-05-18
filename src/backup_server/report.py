from dataclasses import dataclass, field
from enum import Enum


class Status(Enum):
    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"


@dataclass
class StageResult:
    name: str
    status: Status
    detail: str = ""
    sub_results: list["StageResult"] = field(default_factory=list)


def render(results: list[StageResult]) -> str:
    lines = []
    for r in results:
        lines.append(f"[{r.status.value}] {r.name}: {r.detail}")
        for sub in r.sub_results:
            lines.append(f"    [{sub.status.value}] {sub.name}: {sub.detail}")
    return "\n".join(lines)


def overall(results: list[StageResult]) -> Status:
    statuses = {r.status for r in results}
    if Status.FAIL in statuses:
        return Status.FAIL
    if Status.WARN in statuses:
        return Status.WARN
    return Status.PASS
