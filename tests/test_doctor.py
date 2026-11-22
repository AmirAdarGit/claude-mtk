"""Tests for scripts/doctor.sh and the heartbeat every hook writes.

HOME and CLAUDE_CONFIG_DIR point at temp folders, so the real plugin registry,
settings and heartbeats are never read or changed.
"""

import json
import os
import subprocess

from test_hooks import HookCase, ROOT


class DoctorTest(HookCase):
    def setUp(self):
        super().setUp()
        self.claude = os.path.join(self.tmp, "claude")
        os.makedirs(os.path.join(self.claude, "plugins"))
        self.env["CLAUDE_CONFIG_DIR"] = self.claude
        self.beat_dir = os.path.join(self.home, ".mtk", "beat")

    def doctor(self, project=None):
        r = subprocess.run(["sh", os.path.join(ROOT, "scripts", "doctor.sh"), "--dir", project or self.tmp],
                           capture_output=True, env=self.env, timeout=30)
        return r.returncode, r.stdout.decode()

    def plugin_copy(self, version):
        """A fake installed copy of mtk with the given version."""
        path = os.path.join(self.tmp, f"copy-{version}")
        self.write(path, ".claude-plugin/plugin.json", json.dumps({"version": version}))
        self.write(path, "hooks/hooks.json", open(os.path.join(ROOT, "hooks", "hooks.json")).read())
        return path

    def beat(self, name, root):
        os.makedirs(self.beat_dir, exist_ok=True)
        self.write(self.beat_dir, name, os.path.join(root, "hooks", "..") + "\n")

    def source(self, path):
        self.write(self.claude, "plugins/known_marketplaces.json",
                   json.dumps({"mtk": {"source": {"source": "directory", "path": path}}}))

    def settings(self, folder, plugins):
        self.write(folder, "settings.json", json.dumps({"enabledPlugins": plugins}))

    # -- heartbeat ----------------------------------------------------------
    def test_a_hook_leaves_a_heartbeat_with_its_folder(self):
        self.hook("style.sh")
        self.hook("memory.sh", "stop", payload={"cwd": self.tmp})
        for name in ("style.sh-", "memory.sh-stop"):
            with open(os.path.join(self.beat_dir, name)) as f:
                self.assertEqual(os.path.realpath(f.read().strip()), os.path.realpath(ROOT))

    # -- doctor -------------------------------------------------------------
    def test_no_heartbeat_says_unknown(self):
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertIn("no hook has left a heartbeat yet", out)

    def test_running_copy_older_than_source_is_a_warning(self):
        old, new = self.plugin_copy("0.3.1"), self.plugin_copy("0.3.4")
        self.source(new)
        self.beat("memory.sh-start", old)
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertIn("running mtk 0.3.1", out)
        self.assertIn("the source folder has mtk 0.3.4", out)
        self.assertIn("update mtk", out)

    def test_matching_copy_and_ran_hooks_are_ok(self):
        copy = self.plugin_copy("0.3.4")
        self.source(copy)
        for name in ("memory.sh-start", "memory.sh-stop", "style.sh-", "verify-gate.sh-base", "verify-gate.sh-stop"):
            self.beat(name, copy)
        code, out = self.doctor()
        self.assertIn("matches the source folder (mtk 0.3.4)", out)
        self.assertIn("OK    memory.sh start ran", out)
        self.assertIn("OK    verify-gate.sh stop ran", out)
        self.assertIn("INFO  memory.sh precompact has not run yet", out)   # rare: not a warning
        self.assertNotIn("FAIL", out)

    def test_a_wired_hook_that_never_ran_is_a_warning(self):
        copy = self.plugin_copy("0.3.4")
        self.beat("memory.sh-start", copy)
        _, out = self.doctor()
        self.assertIn("WARN  verify-gate.sh stop has not run (Stop)", out)

    def test_broken_plan_json_is_a_failure(self):
        path = self.repo()
        self.write(path, ".mtk/now.md", "# Now\n\nNext: x\n")
        self.write(path, ".mtk/plan.json", "{broken")
        code, out = self.doctor(path)
        self.assertEqual(code, 2)
        self.assertIn("FAIL  .mtk/plan.json is not valid JSON", out)

    def test_ctk_on_in_the_project_is_a_warning_and_off_is_not(self):
        path = self.repo()
        self.settings(self.claude, {"ctk@claude-forge": True})
        _, out = self.doctor(path)
        self.assertIn("ctk@claude-forge is on in this project", out)
        self.settings(os.path.join(path, ".claude"), {"ctk@claude-forge": False})
        _, out = self.doctor(path)
        self.assertNotIn("ctk@claude-forge is on", out)

    def test_doctor_changes_nothing(self):
        path = self.repo()
        before = subprocess.run(["git", "-C", path, "status", "--porcelain"], capture_output=True).stdout
        self.doctor(path)
        after = subprocess.run(["git", "-C", path, "status", "--porcelain"], capture_output=True).stdout
        self.assertEqual(before, after)
