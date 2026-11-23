"""Tests for scripts/memcheck.sh.

memcheck checks the hard facts in the draft .mtk/ lines (hashes, mtk/* branches,
repo paths, plan step ids) against git. Each test builds a temp git repo with
planted right and wrong facts, runs the script, and reads its output lines:

    <LABEL> <kind> <token> — <reason> | <file>: <line start>

Run: python3 -m unittest discover -s tests -p test_memcheck.py
"""

import json
import os
import re
import subprocess
import time
import unittest

from test_hooks import HookCase, ROOT

SCRIPT = os.path.join(ROOT, "scripts", "memcheck.sh")
PLAN3 = {"steps": [{"id": i, "step": f"step {i}", "done": False} for i in (1, 2, 3)]}


class MemcheckTest(HookCase):
    def setUp(self):
        super().setUp()
        r = self.r = self.repo()
        # src/a.py stays, src/old.py is committed and then removed.
        self.write(r, "src/a.py", "a\n")
        self.write(r, "src/old.py", "old\n")
        self.commit(r, "add src")
        self.git(r, "rm", "-q", "src/old.py")
        self.commit(r, "remove old")
        # a branch that is only named in a commit message
        self.git(r, "commit", "--allow-empty", "-q", "-m", "Merge branch 'mtk/merged-gone' into main")
        self.git(r, "branch", "mtk/real")
        # committed memory, with a wrong fact on a line that will not change
        self.write(r, ".mtk/plan.json", json.dumps(PLAN3))
        self.write(r, ".mtk/now.md", "# Now\n\nOld claim: see `src/stale-nope.py`\n")
        self.commit(r, "memory")
        self.good = subprocess.run(["git", "-C", r, "rev-parse", "HEAD"], capture_output=True).stdout.decode().strip()

    # -- helpers ------------------------------------------------------------
    def draft(self, text, name="now.md"):
        """Add uncommitted lines to a .mtk/ file."""
        full = os.path.join(self.r, ".mtk", name)
        with open(full, "a") as f:
            f.write(text)

    def run_check(self, *args, cwd=None):
        t = time.monotonic()
        p = subprocess.run(["sh", SCRIPT, *args], capture_output=True, env=self.env,
                           cwd=cwd or self.r, timeout=30)
        self.elapsed = time.monotonic() - t
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        return p.stdout.decode(encoding="utf-8")

    def has(self, out, label, kind, token):
        return any(l.startswith(f"{label} {kind} {token} ") for l in out.splitlines())

    def any_line(self, out, kind, token):
        for l in out.splitlines():
            m = re.match(r"(WRONG|NOT FOUND|OLD|OK) (\S+) (\S+) ", l)
            if m and (m.group(2), m.group(3)) == (kind, token):
                return True
        return False

    # -- hash ---------------------------------------------------------------
    def test_hash_ok_and_wrong(self):
        self.draft(f"Commit {self.good[:10]} is done; 1234abc was claimed.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "hash", self.good[:10]), out)
        self.assertTrue(self.has(out, "WRONG", "hash", "1234abc"), out)

    def test_words_are_not_hashes(self):
        self.draft("We added deadbeef and facade here.\n")
        out = self.run_check()
        self.assertNotIn("deadbeef", out)
        self.assertNotIn("facade", out)
        self.assertNotIn("added", out)

    # -- branch -------------------------------------------------------------
    def test_branch_three_states(self):
        self.draft("Branches: mtk/real, mtk/merged-gone, and mtk/never.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "branch", "mtk/real"), out)
        self.assertTrue(self.has(out, "OLD", "branch", "mtk/merged-gone"), out)
        self.assertTrue(self.has(out, "NOT FOUND", "branch", "mtk/never"), out)

    # -- path ---------------------------------------------------------------
    def test_path_three_states(self):
        self.draft("Files: `src/a.py`, `src/old.py`, `src/nope.py`.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "path", "src/a.py"), out)
        self.assertTrue(self.has(out, "OLD", "path", "src/old.py"), out)
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/nope.py"), out)

    def test_path_line_number_suffix_is_stripped(self):
        self.draft("See `src/a.py:12` now.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "path", "src/a.py"), out)

    def test_bare_word_without_slash_is_skipped(self):
        self.draft("The nothere.py file and bare/nothere.py both.\n")
        out = self.run_check()
        self.assertFalse(self.any_line(out, "path", "nothere.py"), out)
        self.assertTrue(self.has(out, "NOT FOUND", "path", "bare/nothere.py"), out)

    def test_backticked_name_needs_an_allowed_extension(self):
        self.draft("See `nothere.py` and `thing.xyz` and `speaker.name`.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "NOT FOUND", "path", "nothere.py"), out)
        self.assertFalse(self.any_line(out, "path", "thing.xyz"), out)
        self.assertFalse(self.any_line(out, "path", "speaker.name"), out)

    def test_slash_token_needs_extension_or_existing_first_segment(self):
        self.draft("Dirs `src/gone-dir` and `nodir/gone-dir` and `src/` here.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/gone-dir"), out)
        self.assertFalse(self.any_line(out, "path", "nodir/gone-dir"), out)
        self.assertTrue(self.has(out, "OK", "path", "src"), out)

    def test_noise_tokens_give_no_result(self):
        self.draft("Words sed/cut and 5/6 and 429/5xx and speaker.name and .md here;"
                   " also `sed/cut` `5/6` `speaker.name` `.md` `segments[].text`"
                   " and implementer/reviewer.\n")
        out = self.run_check()
        self.assertEqual(out.strip(), "memcheck: no facts to check")

    def test_skipped_paths_give_no_result(self):
        self.draft("Skip `~/.claude/x.md` and <encoded-path>/a.md and `<encoded-path>/b.md`"
                   " and /abs/c.md and $HOME/d.md and `src/*.py` and https://example.com/e.md"
                   " and version 0.3.12.\n")
        out = self.run_check()
        self.assertIn("no facts to check", out)
        for bit in ("x.md", "a.md", "b.md", "c.md", "d.md", "*.py", "e.md", "0.3.12"):
            self.assertNotIn(bit, out)

    # -- plan ids -----------------------------------------------------------
    def test_plan_ids(self):
        self.draft("Next is step 2 and later step 19, also [3] and [20].\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "plan", "step 2"), out)
        self.assertTrue(self.has(out, "WRONG", "plan", "step 19"), out)
        self.assertTrue(self.has(out, "OK", "plan", "step 3"), out)
        self.assertTrue(self.has(out, "WRONG", "plan", "step 20"), out)

    def test_plan_id_range(self):
        self.draft("Done in steps 2-4.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "OK", "plan", "step 2"), out)
        self.assertTrue(self.has(out, "WRONG", "plan", "step 4"), out)

    def test_missing_plan_json_skips_plan_ids(self):
        os.remove(os.path.join(self.r, ".mtk", "plan.json"))
        self.draft("Next is step 19.\n")
        out = self.run_check()
        self.assertFalse(self.any_line(out, "plan", "step 19"), out)

    # -- which lines are read -----------------------------------------------
    def test_default_reads_only_added_lines(self):
        self.draft("Added line with `src/nope.py`.\n")
        out = self.run_check()
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/nope.py"), out)
        self.assertFalse(self.any_line(out, "path", "src/stale-nope.py"), out)

    def test_all_reads_whole_files(self):
        self.draft("Added line with `src/nope.py`.\n")
        out = self.run_check("--all")
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/nope.py"), out)
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/stale-nope.py"), out)

    def test_untracked_new_mtk_file_counts_as_added(self):
        self.draft("Wrong hash 7654321 here.\n", name="log.md")   # log.md is not in HEAD
        out = self.run_check()
        self.assertTrue(self.has(out, "WRONG", "hash", "7654321"), out)

    def test_no_changes_means_no_facts(self):
        out = self.run_check()
        self.assertEqual(out.strip(), "memcheck: no facts to check")

    def test_dir_flag_and_other_cwd(self):
        self.draft("Wrong `src/nope.py`.\n")
        out = self.run_check("--dir", self.r, cwd=self.tmp)
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/nope.py"), out)

    def test_linked_worktree_reads_the_main_folder(self):
        wt = os.path.join(self.tmp, "wt")
        self.git(self.r, "worktree", "add", "-q", "-b", "side", wt)
        self.draft("Wrong `src/nope.py`.\n")           # drafted in the main folder
        out = self.run_check(cwd=wt)
        self.assertTrue(self.has(out, "NOT FOUND", "path", "src/nope.py"), out)

    # -- output shape -------------------------------------------------------
    def test_order_line_format_and_summary(self):
        self.draft("`src/a.py` `src/old.py` `src/nope.py`\n")
        out = self.run_check()
        lines = out.splitlines()
        labels = [re.match(r"(WRONG|NOT FOUND|OLD|OK) ", l).group(1) for l in lines[:-1]]
        self.assertEqual(labels, ["NOT FOUND", "OLD", "OK"], out)
        self.assertIn(" — ", lines[0])
        self.assertIn(" | .mtk/now.md: ", lines[0])
        self.assertEqual(lines[-1], "memcheck: 0 wrong, 1 not found, 1 old, 1 ok")

    def test_same_fact_twice_is_reported_once(self):
        self.draft("`src/nope.py` again `src/nope.py`\nand `src/nope.py`\n")
        out = self.run_check()
        self.assertEqual(sum(l.startswith("NOT FOUND path src/nope.py ") for l in out.splitlines()), 1, out)

    # -- always exit 0, limits ----------------------------------------------
    def test_not_a_git_repo(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        out = self.run_check(cwd=plain)
        self.assertEqual(out.strip(), "memcheck: not a git repo")

    def test_many_facts_are_capped_and_fast(self):
        self.draft("".join(f"Claim {1000000 + i} ok, `src/missing{i}.py`, mtk/nope{i}.\n" for i in range(300)))
        out = self.run_check()
        self.assertLessEqual(len(out), 4000, len(out))
        self.assertLess(self.elapsed, 1.0)
        self.assertRegex(out, r"\.\.\. \d+ more")
        self.assertRegex(out.splitlines()[-1], r"^memcheck: 300 wrong, 600 not found, 0 old, 0 ok$")

    def test_normal_run_is_fast(self):
        self.draft("`src/a.py` mtk/real step 2 " + self.good[:8] + "\n")
        self.run_check()
        self.assertLess(self.elapsed, 1.0)


class HandoffCommandTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, "commands", "handoff.md")) as f:
            self.text = f.read()

    def test_check_step_comes_before_asking_the_user(self):
        self.assertIn("mtk:memory-checker", self.text)
        self.assertLess(self.text.index("mtk:memory-checker"), self.text.index("AskUserQuestion"))

    def test_sections_are_numbered_in_order(self):
        heads = re.findall(r"^## (\d+)\. (.+)$", self.text, flags=re.M)
        self.assertEqual([n for n, _ in heads], ["1", "2", "3", "4", "5"])
        self.assertTrue(heads[2][1].startswith("Check"), heads)
        self.assertTrue(heads[3][1].startswith("Ask the user"), heads)
