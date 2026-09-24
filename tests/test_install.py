"""Exercise the piped release installer without changing the user's installation."""

import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import select
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ["CODAG_TEST_BINARY"]).resolve()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codag curl test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fixture = self.root / "downloads"
        self.fixture.mkdir()
        self.install_dir = self.root / "installed binaries"
        self.install_dir.mkdir()
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        os_name = "darwin" if sys.platform == "darwin" else "linux"
        arch = "arm64" if platform.machine() in {"arm64", "aarch64"} else "amd64"
        self.archive = self.fixture / f"codag-log-mcp_0.1.0_{os_name}_{arch}.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            archive.add(BINARY, arcname="codag-log-mcp")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.fixture / "checksums.txt").write_text(
            f"{self.digest}  {self.archive.name}\n"
        )
        (self.fixture / "log-latest.txt").write_text("log-v0.1.0\n")
        curl = self.fake_bin / "curl"
        curl.write_text(
            f"#!{sys.executable}\n"
            + """import os, pathlib, shutil, sys
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith('https://'))
with open(os.environ['CODAG_TEST_REQUESTS'], 'a') as stream:
    stream.write(url + '\\n')
source = pathlib.Path(os.environ['CODAG_TEST_DOWNLOADS']) / url.rsplit('/', 1)[-1]
if not source.is_file():
    sys.exit(22)
shutil.copyfile(source, args[args.index('-o') + 1])
"""
        )
        curl.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.fake_bin) + os.pathsep + os.environ["PATH"],
            "CODAG_INSTALL_DIR": str(self.install_dir),
            "CODAG_SKIP_SETUP": "1",
            "CODAG_TEST_DOWNLOADS": str(self.fixture),
            "CODAG_TEST_REQUESTS": str(self.root / "requests.txt"),
        }
        self.env.pop("CODAG_LOG_VERSION", None)
        self.env.pop("CODAG_REQUIRE_ATTESTATION", None)

    def run_installer(self, **changes):
        return subprocess.run(
            ["sh"],
            input=(ROOT / "install-log-engine.sh").read_text(),
            env={**self.env, **changes},
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def test_pipe_downloads_current_log_channel_and_runs(self):
        run = self.run_installer()
        self.assertEqual(run.returncode, 0, run.stderr)
        installed = self.install_dir / "codag-log-mcp"
        self.assertEqual(
            hashlib.sha256(installed.read_bytes()).hexdigest(),
            hashlib.sha256(BINARY.read_bytes()).hexdigest(),
        )
        version = subprocess.check_output([str(installed), "--version"], text=True)
        self.assertIn("codag-log-mcp", version)
        requests = (self.root / "requests.txt").read_text()
        self.assertIn("/main/log-latest.txt", requests)
        self.assertIn("/releases/download/log-v0.1.0/", requests)
        self.assertNotIn("/releases/latest/", requests)
        self.assertNotIn("codag-cli", requests)
        self.assertEqual(self.run_installer().returncode, 0)

    def test_bad_checksum_keeps_existing_installation(self):
        installed = self.install_dir / "codag-log-mcp"
        installed.write_text("keep the old version")
        (self.fixture / "checksums.txt").write_text(
            f"{'0' * 64}  {self.archive.name}\n"
        )
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum mismatch", result.stderr)
        self.assertEqual(installed.read_text(), "keep the old version")

    def test_missing_checksum_fails_before_install(self):
        (self.fixture / "checksums.txt").write_text("")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install_dir / "codag-log-mcp").exists())

    def test_invalid_version_fails_without_download(self):
        result = self.run_installer(CODAG_LOG_VERSION="../../old-cli")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "requests.txt").exists())

    def test_version_pin_skips_mutable_channel(self):
        result = self.run_installer(CODAG_LOG_VERSION="log-v0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("log-latest.txt", (self.root / "requests.txt").read_text())

    def test_download_failure_keeps_existing_binary(self):
        installed = self.install_dir / "codag-log-mcp"
        installed.write_text("old")
        self.archive.unlink()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(installed.read_text(), "old")

    def test_actual_pipe_reads_wizard_answers_from_terminal(self):
        source = self.root / "my logs.csv"
        source.write_text(
            "timestamp,cmdb_id,log_name,value\n1700000000,api,app,timeout\n"
        )
        script = ROOT / "install-log-engine.sh"
        env = {**self.env, "CODAG_SKIP_SETUP": "0"}
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execve(
                "/bin/sh",
                ["sh", "-c", "cat " + shlex.quote(str(script)) + " | sh"],
                env,
            )
        transcript = b""
        try:
            for prompt, answer in [
                (b"Path to CSV/TSV logs", str(source)),
                (b"Client [1]", "4"),
            ]:
                deadline = time.monotonic() + 20
                while prompt not in transcript:
                    if time.monotonic() > deadline:
                        self.fail(
                            f"Missing prompt {prompt!r}: {transcript.decode(errors='replace')}"
                        )
                    if select.select([fd], [], [], 0.1)[0]:
                        transcript += os.read(fd, 65536)
                os.write(fd, (answer + "\n").encode())
            deadline = time.monotonic() + 20
            while True:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    self.assertEqual(
                        os.waitstatus_to_exitcode(status),
                        0,
                        transcript.decode(errors="replace"),
                    )
                    pid = 0
                    break
                if time.monotonic() > deadline:
                    self.fail("Installer did not finish")
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        transcript += os.read(fd, 65536)
                    except OSError:
                        pass
            config = json.loads((self.root / ".codag/mcp.json").read_text())
            self.assertEqual(
                config["mcpServers"]["codag-logs"]["args"][0], str(source.resolve())
            )
        finally:
            if pid:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
