"""Generate deterministic lsof -F samples for parser tests."""

from pathlib import Path


FIXTURE = """p1234
cpython3
u501
f3
PTCP
n127.0.0.1:8080
TST=LISTEN
f4
PTCP6
n[::1]:8080->[::1]:51432
TST=ESTABLISHED
"""


def main() -> None:
    output = Path(__file__).with_name("lsof_sample.txt")
    output.write_text(FIXTURE, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()

