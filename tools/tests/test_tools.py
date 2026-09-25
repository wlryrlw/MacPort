import json
import subprocess
import sys
import unittest
from pathlib import Path


class ToolSmokeTests(unittest.TestCase):
    def test_fixture_generator_writes_valid_utf8_fixture(self) -> None:
        script = Path(__file__).parents[1] / "generate_lsof_fixture.py"
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, check=True)
        fixture = Path(result.stdout.strip())
        try:
            content = fixture.read_text(encoding="utf-8")
            self.assertIn("PTCP", content)
            self.assertIn("n127.0.0.1:8080", content)
        finally:
            fixture.unlink(missing_ok=True)

    def test_diagnostic_shape_is_json_serializable(self) -> None:
        payload = {"compatibilityState": "ready", "issues": [], "scannerAvailable": True}
        encoded = json.dumps(payload)
        self.assertEqual(json.loads(encoded)["compatibilityState"], "ready")


if __name__ == "__main__":
    unittest.main()

