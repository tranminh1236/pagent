#!/usr/bin/env python3
"""Tests for read_agent_workflow + /agent-workflow route in kit/web/server.py.

Nguồn RIÊNG với read_workflow (workflow.md log): agent-workflow.md là pseudo-spec
điều phối AI (khối `## Overview`/`## Agents`/… + graph ascii), sống ở
REPORTS/<proj>/agent-workflow.md (pagent ghi tại đây, KHÔNG ở SOURCE/.pagent/knowledge/).
"""
import os, sys, shutil, tempfile, threading, unittest
import http.client
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "kit", "web"))
import server as srv

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "agent-workflow-sample.md")


class ReadAgentWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        srv.REPORTS = os.path.realpath(self.tmp)
        self.proj = "demo"
        os.makedirs(os.path.join(self.tmp, self.proj), exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _put(self, src=FIXTURE):
        shutil.copy(src, os.path.join(self.tmp, self.proj, "agent-workflow.md"))

    def test_missing_file(self):
        r = srv.read_agent_workflow(self.proj)
        self.assertFalse(r["exists"])
        self.assertEqual(r["blocks"], [])
        self.assertEqual(r["content"], "")

    def test_reads_from_reports_not_knowledge(self):
        # File neo REPORTS/<proj>/agent-workflow.md — GIỐNG read_workflow, KHÁC .pagent/knowledge/.
        self._put()
        r = srv.read_agent_workflow(self.proj)
        self.assertTrue(r["exists"])
        self.assertTrue(r["path"].endswith(os.path.join("demo", "agent-workflow.md")))

    def test_parses_blocks_by_heading(self):
        self._put()
        r = srv.read_agent_workflow(self.proj)
        headings = [b["heading"] for b in r["blocks"]]
        self.assertEqual(headings, ["Overview", "Agents / Roles", "Nodes / Steps",
                                    "Edges / Handoffs", "Graph"])
        overview = r["blocks"][0]
        self.assertIn("framework-agnostic", overview["body"])

    def test_keeps_raw_content(self):
        self._put()
        r = srv.read_agent_workflow(self.proj)
        self.assertIn("# Agent Orchestration Workflow — demo", r["content"])

    def test_graph_body_preserves_code_fence(self):
        # Body của ## Graph giữ nguyên fence + ascii (không bị parser workflow.md ép schema).
        self._put()
        r = srv.read_agent_workflow(self.proj)
        graph = next(b for b in r["blocks"] if b["heading"] == "Graph")
        self.assertIn("```", graph["body"])
        self.assertIn("plan --> review", graph["body"])

    def test_empty_file_no_blocks(self):
        # File rỗng / chỉ preamble → không vỡ: exists True, blocks rỗng.
        open(os.path.join(self.tmp, self.proj, "agent-workflow.md"), "w").close()
        r = srv.read_agent_workflow(self.proj)
        self.assertTrue(r["exists"])
        self.assertEqual(r["blocks"], [])

    def test_malformed_no_headings(self):
        # Format lệch (không có `## `) → blocks rỗng nhưng content giữ nguyên, không raise.
        p = os.path.join(self.tmp, self.proj, "agent-workflow.md")
        with open(p, "w") as f:
            f.write("chỉ vài dòng text\nkhông có heading nào\n")
        r = srv.read_agent_workflow(self.proj)
        self.assertTrue(r["exists"])
        self.assertEqual(r["blocks"], [])
        self.assertIn("chỉ vài dòng text", r["content"])

    def test_path_traversal_blocked(self):
        r = srv.read_agent_workflow("../../etc")
        self.assertFalse(r["exists"])
        self.assertEqual(r["blocks"], [])

    def test_absolute_proj_blocked(self):
        # proj tuyệt đối reset os.path.join → path ngoài REPORTS → _safe_join None → exists False.
        r = srv.read_agent_workflow("/etc")
        self.assertFalse(r["exists"])
        self.assertEqual(r["blocks"], [])
        self.assertEqual(r["path"], "")


class AgentWorkflowRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        srv.REPORTS = os.path.realpath(self.tmp)
        os.makedirs(os.path.join(self.tmp, "demo"), exist_ok=True)
        shutil.copy(FIXTURE, os.path.join(self.tmp, "demo", "agent-workflow.md"))
        self.s = ThreadingHTTPServer(("127.0.0.1", 0), srv.H)
        threading.Thread(target=self.s.serve_forever, daemon=True).start()
        self.port = self.s.server_address[1]

    def tearDown(self):
        self.s.shutdown()
        self.s.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        try:
            c.request("GET", path)
            resp = c.getresponse()
            import json
            return resp.status, json.loads(resp.read())
        finally:
            c.close()

    def test_route_returns_blocks(self):
        st, body = self._get("/api/projects/demo/agent-workflow")
        self.assertEqual(st, 200)
        self.assertTrue(body["exists"])
        self.assertEqual(body["blocks"][0]["heading"], "Overview")

    def test_route_does_not_clash_with_workflow(self):
        # /workflow (log cũ) không tồn tại file → exists False, không dính parser agent-workflow.
        st, body = self._get("/api/projects/demo/workflow")
        self.assertEqual(st, 200)
        self.assertFalse(body["exists"])
        self.assertIn("workflows", body)  # schema log cũ giữ nguyên

    def test_route_invalid_project(self):
        st, body = self._get("/api/projects/nope/agent-workflow")
        self.assertEqual(st, 400)


if __name__ == "__main__":
    unittest.main()
