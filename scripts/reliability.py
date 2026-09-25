"""Qualify real Chromium persistence, recovery and daily browsing primitives."""
from pathlib import Path
import json
import os
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
profile = Path(tempfile.mkdtemp(prefix="lume-reliability-"))
binary = root / "dist/Lume.app/Contents/MacOS/Lume"
reports = []

def terminate_group(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)

with (profile / "server.log").open("w") as server_log:
    server = subprocess.Popen(["python3", str(root / "scripts/fixture-server.py"), str(profile / "port")], stdout=server_log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        while not (profile / "port").exists():
            if server.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Fixture server failed to start")
            time.sleep(0.1)
        base_url = "http://127.0.0.1:" + (profile / "port").read_text()
        for phase in ("seed", "restore", "abrupt-seed", "abrupt-restore"):
            report_path = profile / (phase + ".json")
            ready_path = profile / "ready"
            env = dict(os.environ, LUME_PROFILE_DIR=str(profile), LUME_TEST_URL=base_url,
                       LUME_TEST_PHASE=phase, LUME_SMOKE_REPORT=str(report_path), LUME_TEST_READY=str(ready_path))
            with (profile / (phase + ".log")).open("w") as log:
                process = subprocess.Popen([str(binary), "--reliability-test"], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    if phase == "abrupt-seed":
                        deadline = time.monotonic() + 70
                        while not ready_path.exists():
                            if process.poll() is not None or time.monotonic() > deadline:
                                raise RuntimeError("Forced-termination fixture failed to become ready")
                            time.sleep(0.1)
                        terminate_group(process)
                        reports.append({"phase": phase, "passed": True, "checks": ["isolated app process group terminated with SIGKILL"]})
                    else:
                        code = process.wait(timeout=80)
                        report = json.loads(report_path.read_text()) if report_path.exists() else {"passed": False, "phase": phase, "error": "Report missing"}
                        reports.append(report)
                        if code != 0 or not report["passed"]:
                            raise RuntimeError(f"{phase} failed: {report}")
                finally:
                    terminate_group(process)
            time.sleep(0.6)
            print(phase + ": PASS", flush=True)
    finally:
        server.terminate()
        server.wait(timeout=10)
        aggregate = {"passed": len(reports) == 4 and all(r["passed"] for r in reports), "profile": str(profile), "reports": reports}
        (root / ".build/reliability-report.json").write_text(json.dumps(aggregate, indent=2))
        print("Evidence: " + str(profile), flush=True)
