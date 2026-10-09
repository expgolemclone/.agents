"""Keep consumer-repository skills out of the shared discovery directory."""
from pathlib import Path
import re
import unittest


class CommonSkillScopeTests(unittest.TestCase):
    def test_common_skills_do_not_route_to_one_consumers_rules(self):
        root = Path(__file__).resolve().parents[2]
        skills = list((root / "skills").glob("*/SKILL.md"))
        self.assertTrue(skills)
        for skill in skills:
            text = skill.read_text(encoding="utf-8")
            with self.subTest(skill=skill.parent.name):
                self.assertNotRegex(
                    text,
                    r"RepositoryMapで\s*`expgolemclone/[^\`]+\`\s*を特定",
                    "A repository-specific skill belongs in its owner's skills/.",
                )
