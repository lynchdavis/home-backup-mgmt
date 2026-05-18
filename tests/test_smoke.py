from backup_server import __version__
from backup_server.cli import build_parser
from backup_server.report import StageResult, Status, overall


def test_version_present():
    assert __version__


def test_parser_accepts_host():
    args = build_parser().parse_args(["saratoga"])
    assert args.host == "saratoga"
    assert args.execute is False


def test_overall_fail_dominates():
    assert overall([
        StageResult("a", Status.PASS),
        StageResult("b", Status.WARN),
        StageResult("c", Status.FAIL),
    ]) == Status.FAIL


def test_overall_warn_over_pass():
    assert overall([
        StageResult("a", Status.PASS),
        StageResult("b", Status.WARN),
    ]) == Status.WARN
