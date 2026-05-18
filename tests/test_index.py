from backup_server.index import BackupRecord, HostIndex, append_backup, load, save


def _sample_record(date: str = "2026-05-17") -> BackupRecord:
    return BackupRecord(
        date=date,
        duration_sec=4821,
        bytes_transferred=184_293_847_562,
        shares={"photography": "ok", "videos": "ok"},
        log_path="/kodiak00/data-00/backups/logs/2026-05-17.log",
        rsync_exit=0,
    )


def test_load_missing_returns_none(tmp_path):
    assert load("nope", tmp_path) is None


def test_save_then_load_roundtrip(tmp_path):
    idx = HostIndex(
        host="saratoga",
        private_ip="192.168.0.60",
        lan_ip="192.168.1.60",
        backups=[_sample_record()],
    )
    save(idx, tmp_path)
    assert load("saratoga", tmp_path) == idx


def test_save_creates_index_dir(tmp_path):
    nested = tmp_path / "deep" / "nest"
    save(HostIndex(host="x"), nested)
    assert (nested / "x.json").exists()


def test_save_leaves_no_tmp_file(tmp_path):
    save(HostIndex(host="x"), tmp_path)
    assert list(tmp_path.glob(".*.tmp")) == []
    assert list(tmp_path.glob("*.tmp")) == []


def test_append_creates_fresh_index(tmp_path):
    append_backup("newhost", tmp_path, _sample_record())
    loaded = load("newhost", tmp_path)
    assert loaded is not None
    assert loaded.host == "newhost"
    assert len(loaded.backups) == 1


def test_append_extends_existing(tmp_path):
    save(HostIndex(host="saratoga", private_ip="192.168.0.60"), tmp_path)
    append_backup("saratoga", tmp_path, _sample_record("2026-05-17"))
    append_backup("saratoga", tmp_path, _sample_record("2026-05-24"))
    loaded = load("saratoga", tmp_path)
    assert loaded is not None
    assert loaded.private_ip == "192.168.0.60"
    assert [b.date for b in loaded.backups] == ["2026-05-17", "2026-05-24"]


def test_load_tolerates_unknown_top_level_keys(tmp_path):
    """Forward compat: extra fields in the JSON shouldn't break loads."""
    save(HostIndex(host="saratoga"), tmp_path)
    path = tmp_path / "saratoga.json"
    raw = path.read_text().rstrip("}\n") + ', "future_field": 42}\n'
    path.write_text(raw)
    loaded = load("saratoga", tmp_path)
    assert loaded is not None and loaded.host == "saratoga"
