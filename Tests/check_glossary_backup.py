"""Independent common-format check; not a replacement for Windows product testing."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys

LIMIT = 128 * 1024 * 1024


def check(path):
    assert path.stat().st_size <= LIMIT, "compressed size"
    data = path.read_bytes()
    assert len(data) > 48 and data[:16] == b"MyPLaMoGlossary\n", "header"
    with gzip.GzipFile(fileobj=io.BytesIO(data[48:])) as stream:
        payload = stream.read(LIMIT + 1)
    assert len(payload) <= LIMIT, "uncompressed size"
    assert hashlib.sha256(payload).digest() == data[16:48], "digest"
    value = json.loads(payload.decode("utf-8"))
    assert set(value) == {"Version", "Glossaries"}
    assert type(value["Version"]) is int and value["Version"] == 1
    assert type(value["Glossaries"]) is list
    for book in value["Glossaries"]:
        assert set(book) == {"Id", "Name", "Terms"}, "exact common glossary keys"
        assert type(book["Id"]) is str and type(book["Name"]) is str
        assert type(book["Terms"]) is list
        for term in book["Terms"]:
            assert set(term) == {"Source", "Target", "From", "To"}, "no internal term ID"
            assert all(type(item) is str for item in term.values())
    print(f"PASS {path} SHA256={hashlib.sha256(data).hexdigest()}")
    return value


if __name__ == "__main__":
    paths = [Path(item) for item in sys.argv[1:]]
    if not paths:
        paths = [Path(__file__).parent / "Fixtures/windows-glossary-v1.myplamo-glossary"]
    values = [check(path) for path in paths]
    if len(values) == 2:
        assert values[0] == values[1], "Windows/Mac sample content differs"
        print("PASS Windows/Mac sample content equality")
