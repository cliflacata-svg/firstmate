#!/usr/bin/env bash
# tests/fm-console.test.sh - loopback console auth, owner integration, and cache.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import sys
from http.server import ThreadingHTTPServer

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("fm_console", root / "bin/fm-console.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="fm-console-test-", dir=root) as temp:
    home = Path(temp) / "home"
    (home / "config").mkdir(parents=True)
    (home / "state").mkdir()
    (home / "data" / "task-report-fixture").mkdir(parents=True)
    (home / "data" / "captain.md").write_text("# Captain\nPrefers a concise, direct answer style.\n")
    (home / "data" / "learnings.md").write_text("# Learnings\nGeneral operational notes.\n")
    (home / "data" / "task-report-fixture" / "report.md").write_text("# Report\nUnrelated content about deployments.\n")
    (home / "data" / "secret-notes.md").write_text("Not curated: contains answer too but must never be searched.\n")
    secret_file = home / "config/console-operator-secret"
    try:
        module.read_secret(home)
        raise AssertionError("absent secret must fail closed")
    except ValueError:
        pass
    secret_file.write_text("a" * 40 + "\n")
    secret_file.chmod(0o600)
    secret = module.read_secret(home)
    secret_file.chmod(0o644)
    try:
        module.read_secret(home)
        raise AssertionError("readable secret must fail closed")
    except ValueError:
        pass
    secret_file.chmod(0o600)

    relpaths = module.curated_relpaths(home)
    assert set(relpaths) == {"captain.md", "learnings.md", "task-report-fixture/report.md"}, relpaths
    matches = module.search_curated(home, "what is the captain's answer style")
    assert matches and matches[0]["file"] == "captain.md", matches
    assert all(match["file"] != "secret-notes.md" for match in matches), "leaked a non-allowlisted file"
    assert module.resolve_artifact(home, "../../../etc/passwd") is None
    assert module.resolve_artifact(home, "secret-notes.md") is None, "non-allowlisted file must not resolve"
    assert module.read_curated_through(home) == ""
    try:
        module.write_curated_through(home, "not-a-cursor")
        raise AssertionError("a malformed cursor must be refused")
    except ValueError:
        pass
    print("pass: curated_relpaths, search_curated, and artifact confinement (module level)")

    fixture = {
        "schema": "fm-bearings.v1", "generated": "2026-09-21T12:00:00Z",
        "in_flight": [{"id": "task-1", "name": "Build UI", "state": "working", "repo": "firstmate", "doing": "Editing /secret/file"}],
        "decisions_open": [{"id": "decision-1", "summary": "Approve direction", "owner": "(main)"}],
        "gates": [], "landed": [], "secondmates": [{"id": "remote", "state": "unknown", "freshness": "stale", "reason": "unreadable"}],
        "omitted": [{"surface": "in_flight showing 20 of 25", "reveal": "inspect /secret/file"}],
        "actions": [{"watch": "rm -rf /secret"}], "paths": [{"worktree": "/secret/file"}],
    }
    (home / "fixture.json").write_text(json.dumps(fixture))
    snapshot = Path(temp) / "snapshot.sh"
    snapshot.write_text('#!/usr/bin/env bash\nprintf "x\\n" >> "$FM_HOME/calls"\nsleep 0.25\ncat "$FM_HOME/fixture.json"\n')
    snapshot.chmod(0o700)
    ready = json.dumps({"schema": "fm-primary-ready.v1", "observed_at": "2026-09-21T12:00:00Z",
                        "lock": {"state": "unknown", "pid": None}, "wake_consumer": {"state": "unknown"},
                        "posture": {"state": "present"}, "can_receive": "unknown"})
    inbox = Path(temp) / "inbox.sh"
    inbox.write_text('#!/usr/bin/env bash\nif [ "$1" = ready ]; then\n  printf \'%s\\n\' ' + "'" + ready + "'" + '\nelse\n  exec ' + str(root / "bin/fm-inbox.sh") + ' "$@"\nfi\n')
    inbox.chmod(0o700)
    service = module.ConsoleService(home, secret, snapshot_bin=snapshot, inbox_bin=inbox)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    server.daemon_threads = True
    server.service = service
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_port
    auth = "Basic " + base64.b64encode(("operator:" + secret).encode()).decode()

    def request(method, path, payload=None, authorized=True, extras=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        headers = {"Host": f"127.0.0.1:{port}"}
        if authorized: headers["Authorization"] = auth
        if extras: headers.update(extras)
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        result = (response.status, json.loads(raw) if response.getheader("Content-Type", "").startswith("application/json") and raw else raw)
        conn.close()
        return result

    try:
        for path in ("/", "/app.css", "/app.js", "/api/session", "/api/fleet", "/api/ready", "/api/receipts", "/api/events", "/artifact/foo", "/unknown"):
            assert request("GET", path, authorized=False)[0] == 401, path
        assert request("POST", "/api/order", "{}", authorized=False)[0] == 401
        assert request("HEAD", "/", authorized=False)[0] == 401
        assert request("OPTIONS", "/api/order", authorized=False)[0] == 401
        bad_auth = "Basic " + base64.b64encode("operator:pässword".encode()).decode()
        assert request("GET", "/", extras={"Authorization": bad_auth})[0] == 401
        assert request("GET", "/api/session", extras={"Origin": "https://evil.example"})[0] == 403
        assert request("GET", "/api/session", extras={"Host": "evil.example"})[0] == 403
        assert request("GET", "/api/ready")[1]["can_receive"] == "unknown"
        csrf = request("GET", "/api/session")[1]["csrf"]
        order = json.dumps({"request_id": "browser-1", "text": "line one\nline two"})
        post_headers = {"Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json", "X-Console-CSRF": csrf}
        assert request("POST", "/api/order", order, extras={"Origin": post_headers["Origin"], "Content-Type": "application/json"})[0] == 403
        assert request("POST", "/api/order", order, extras={**post_headers, "Origin": "https://evil.example"})[0] == 403
        assert request("POST", "/api/order", json.dumps({"request_id": ".unsafe", "text": "hi"}), extras=post_headers)[0] == 400
        first_status, first = request("POST", "/api/order", order, extras=post_headers)
        retry_status, retry = request("POST", "/api/order", order, extras=post_headers)
        assert first_status == retry_status == 202
        assert first["outcome"] == "created" and retry["outcome"] == "replay"
        assert first["id"] == retry["id"] and first["saved"] and first["pending"]
        assert first["readiness"]["can_receive"] == "unknown"
        notes = list((home / "state/inbox").glob("*.note"))
        assert len(notes) == 1 and "line one\nline two" in notes[0].read_text()
        assert (home / "state/.wake-queue").read_text().count("inbox:") == 1
        receipts = request("GET", "/api/receipts?after=")[1]
        assert len(receipts["pending"]) == 1 and receipts["pending"][0]["announced"] is True
        assert "path" not in json.dumps(receipts)
        assert request("GET", "/api/receipts?after=bad")[0] == 400
        module.subprocess.run([str(root / "bin/fm-inbox.sh"), "reply", first["id"], "Answer from primary"],
                              env=service.env(), check=True, capture_output=True)
        receipts = request("GET", "/api/receipts?after=")[1]
        assert receipts["replies"][0]["body"] == "Answer from primary"
        reply_cursor = receipts["replies"][0]["cursor"]
        assert receipts["curated_through"] == ""
        assert receipts["replies"][0]["curated"] is False
        excerpt = receipts["replies"][0]["excerpt"]
        assert excerpt["file"] == "captain.md", excerpt
        assert excerpt["artifact"] == "captain.md"
        assert "answer" in excerpt["excerpt"].lower()
        assert "secret-notes.md" not in json.dumps(receipts), "leaked a non-allowlisted file into an answer"
        artifact = request("GET", "/artifact/" + excerpt["artifact"])[1]
        assert artifact["file"] == "captain.md" and "answer" in artifact["content"].lower()
        windowed = request("GET", f"/artifact/{excerpt['artifact']}?line={excerpt['line']}")[1]
        assert windowed["line"] == excerpt["line"]
        assert request("GET", "/artifact/does-not-exist")[0] == 404
        assert request("GET", "/artifact/secret-notes.md")[0] == 404, "non-allowlisted file must not be servable"
        assert request("GET", "/artifact/" + excerpt["artifact"] + "?line=0")[0] == 400
        assert request("GET", "/artifact/" + excerpt["artifact"] + "?line=abc")[0] == 400
        assert request("GET", "/artifact/" + excerpt["artifact"] + "?line=1&extra=1")[0] == 400
        module.write_curated_through(home, reply_cursor)
        receipts = request("GET", "/api/receipts?after=")[1]
        assert receipts["curated_through"] == reply_cursor
        assert receipts["replies"][0]["curated"] is True
        assert request("GET", "/api/receipts?after=" + receipts["reply_cursor"])[1]["replies"] == []
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: request("GET", "/api/fleet"), range(8)))
        assert all(status == 200 for status, _ in results)
        assert (home / "calls").read_text().count("x") == 1, "concurrent polls must share one collector"
        time.sleep(0.35)
        _, fleet = request("GET", "/api/fleet")
        assert fleet["snapshot"]["omitted"] == ["in_flight showing 20 of 25"]
        assert fleet["snapshot"]["secondmates"][0]["freshness"] == "stale"
        assert fleet["observed_at"] == "2026-09-21T12:00:00Z"
        assert "actions" not in json.dumps(fleet) and "/secret" not in json.dumps(fleet)
        assert (home / "calls").read_text().count("x") == 1, "cache hits must not start another observation"
        time.sleep(0.35)
        assert (home / "calls").read_text().count("x") == 1, "no viewers means no new collection"
        assert "Quick ask" in request("GET", "/")[1].decode()
        print("pass: auth, CSRF, unknown readiness, request replay, replies, source-linked excerpts, "
              "the confined artifact route, the curation cursor, omissions, serialized collection")
    finally:
        server.shutdown()
        server.server_close()
PY
node --check "$ROOT/web/console/app.js"
node - "$ROOT/web/console/app.js" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
function makeElement() {
  return {
    className: "", textContent: "", hidden: false, dataset: {}, children: [],
    append(...kids) { this.children.push(...kids); },
    replaceChildren(...kids) { this.children = kids; },
    addEventListener() {},
  };
}
const elements = new Map();
const document = {
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, makeElement());
    return elements.get(id);
  },
  createElement() { return makeElement(); },
};
const context = vm.createContext({
  document,
  assert,
  fetch: () => Promise.reject(new Error("fixture offline")),
});
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), context);
vm.runInContext('renderReady({can_receive:"unknown",observed_at:"2026-09-21T12:00:00Z",lock:"unknown",wake_consumer:"unknown",posture:"present"})', context);
assert.match(elements.get("readiness").textContent, /readiness unknown/i);
assert.match(elements.get("order-readiness").textContent, /may remain pending/i);
assert.doesNotMatch(elements.get("order-readiness").textContent, /refus/i);

vm.runInContext(`
  const block = excerptBlock({file: "captain.md", line: 3, excerpt: "the excerpt text", artifact: "captain.md", id_match: false});
  assert.equal(block.className, "excerpt");
  const head = block.children.find(child => child.className === "excerpt-head");
  const source = head.children.find(child => child.className === "excerpt-source");
  assert.equal(source.textContent, "captain.md:3");
  const body = block.children.find(child => child.className === "excerpt-body");
  assert.equal(body.textContent, "the excerpt text");
`, context);

vm.runInContext(`
  replies.set("000000000001", {id: "a", at: "2026-09-21T12:00:00Z", body: "hi", cursor: "000000000001", curated: false});
  renderCuration();
`, context);
assert.match(elements.get("curation-status").textContent, /not yet folded/i);
assert.equal(elements.get("curation-status").hidden, false);

vm.runInContext(`
  replies.get("000000000001").curated = true;
  renderCuration();
`, context);
assert.match(elements.get("curation-status").textContent, /folded into curated memory/i);

console.log("pass: browser rendering keeps readiness unknown distinct from refusal, "
  + "renders a source-linked excerpt, and reflects the curation cursor");
JS
