from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "skills-updater.py"
SPEC = importlib.util.spec_from_file_location("skills_updater", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)


def make_archive(files: dict[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, content in files.items():
            archive.writestr(f"repo-sha/{name}", content)
    return output.getvalue()


class FakeClient:
    def __init__(self, archives: dict[tuple[str, str], bytes]) -> None:
        self.archives = archives
        self.resolved: list[tuple[str, str]] = []
        self.archives_by_sha: dict[tuple[str, str], bytes] = {}

    def resolve_ref(self, repository: str, ref: str) -> str:
        self.resolved.append((repository, ref))
        marker = len(self.resolved)
        sha = f"{marker:040x}"
        self.archives_by_sha[(repository, sha)] = self.archives[(repository, ref)]
        return sha

    def download_archive(self, repository: str, sha: str, destination: Path) -> None:
        destination.write_bytes(self.archives_by_sha[(repository, sha)])


class FailingClient(FakeClient):
    def resolve_ref(self, repository: str, ref: str) -> str:
        raise updater.UpdaterError("network failure")


class SkillsUpdaterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.skills = self.root / "skills"
        self.skills.mkdir()
        self.config = self.root / "skills-manager" / "skills-updater.json"
        self.lock = self.root / "skills-manager" / "skills-updater.lock.json"
        self.spec = updater.SourceSpec(
            target="example-skill",
            repository="example/repo",
            ref="main",
            source_path="skill",
            include=(),
            license_path="LICENSE",
        )
        self.archive = make_archive(
            {
                "LICENSE": b"license\n",
                "skill/SKILL.md": (
                    b"---\nname: example-skill\ndescription: Test skill.\n---\n"
                ),
                "skill/references/guide.md": b"guide\n",
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_json(self, path: Path, payload: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def write_config_sources(self, sources: dict[str, object]) -> None:
        self.write_json(
            self.config,
            {"schema_version": 1, "sources": sources},
        )

    def config_source(self, **changes: object) -> dict[str, object]:
        result: dict[str, object] = {
            "repository": "example/repo",
            "ref": "main",
            "source_path": "skill",
            "include": [],
            "license_path": "LICENSE",
        }
        result.update(changes)
        return result

    def previous_lock(self, targets: tuple[str, ...]) -> None:
        sources = {
            target: {
                "repository": "example/repo",
                "ref": "main",
                "source_path": "skill",
                "commit": "a" * 40,
                "content_sha256": "b" * 64,
            }
            for target in targets
        }
        self.write_json(
            self.lock,
            {"schema_version": 1, "sources": sources},
        )

    def synchronize(
        self,
        check: bool = False,
        *,
        specs: tuple[updater.SourceSpec, ...] | None = None,
        previous_targets: frozenset[str] = frozenset(),
        client: FakeClient | None = None,
    ) -> bool:
        selected_specs = (self.spec,) if specs is None else specs
        selected_client = client or FakeClient(
            {("example/repo", "main"): self.archive}
        )
        return updater.synchronize(
            self.skills,
            self.lock,
            check,
            specs=selected_specs,
            previous_targets=previous_targets,
            client=selected_client,
        )

    def test_loads_complete_configuration(self) -> None:
        self.write_config_sources(
            {"example-skill": self.config_source(license_path=None)}
        )

        specs = updater.load_config(self.config)

        self.assertEqual(
            specs,
            (
                updater.SourceSpec(
                    target="example-skill",
                    repository="example/repo",
                    ref="main",
                    source_path="skill",
                    include=(),
                    license_path=None,
                ),
            ),
        )

    def test_loads_empty_source_list(self) -> None:
        self.write_config_sources({})

        self.assertEqual(updater.load_config(self.config), ())

    def test_rejects_missing_unknown_and_duplicate_configuration_fields(self) -> None:
        invalid_sources = [
            {"example-skill": {"repository": "example/repo"}},
            {"example-skill": self.config_source(extra="value")},
        ]
        for sources in invalid_sources:
            with self.subTest(sources=sources):
                self.write_config_sources(sources)
                with self.assertRaises(updater.UpdaterError):
                    updater.load_config(self.config)

        self.config.write_text(
            '{"schema_version":1,"sources":{"one":{},"one":{}}}',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(updater.UpdaterError, "duplicate key"):
            updater.load_config(self.config)

    def test_rejects_unsafe_configuration_values(self) -> None:
        invalid = {
            "../escape": self.config_source(),
            ".system": self.config_source(),
            "safe": self.config_source(source_path="../skill"),
            "also-safe": self.config_source(license_path="."),
        }
        for target, source in invalid.items():
            with self.subTest(target=target):
                self.write_config_sources({target: source})
                with self.assertRaises(updater.UpdaterError):
                    updater.load_config(self.config)

    def test_rejects_case_insensitive_target_collision(self) -> None:
        self.write_config_sources(
            {
                "Example": self.config_source(),
                "example": self.config_source(),
            }
        )

        with self.assertRaisesRegex(updater.UpdaterError, "collide"):
            updater.load_config(self.config)

    def test_loads_valid_lock_targets_and_allows_missing_lock(self) -> None:
        self.assertEqual(updater.load_lock_targets(self.lock), frozenset())
        self.previous_lock(("one", "two"))

        self.assertEqual(
            updater.load_lock_targets(self.lock), frozenset({"one", "two"})
        )

    def test_rejects_invalid_lock_before_sync(self) -> None:
        self.write_json(
            self.lock,
            {"schema_version": 1, "sources": {"example": {}}},
        )

        with self.assertRaises(updater.UpdaterError):
            updater.load_lock_targets(self.lock)

        self.assertFalse((self.skills / "example").exists())

    def test_update_replaces_local_content_and_removes_deleted_target(self) -> None:
        target = self.skills / "example-skill"
        target.mkdir()
        (target / "local.txt").write_text("local", encoding="utf-8")
        removed = self.skills / "removed-skill"
        removed.mkdir()
        (removed / "SKILL.md").write_text("old", encoding="utf-8")

        self.assertTrue(
            self.synchronize(previous_targets=frozenset({"removed-skill"}))
        )

        self.assertFalse((target / "local.txt").exists())
        self.assertEqual((target / "LICENSE").read_bytes(), b"license\n")
        self.assertTrue((target / "references" / "guide.md").is_file())
        self.assertFalse(removed.exists())
        self.assertTrue(self.lock.is_file())

    def test_empty_configuration_removes_only_previously_locked_target(self) -> None:
        managed = self.skills / "managed"
        managed.mkdir()
        unmanaged = self.skills / "unmanaged"
        unmanaged.mkdir()

        self.assertTrue(
            self.synchronize(
                specs=(), previous_targets=frozenset({"managed"})
            )
        )

        self.assertFalse(managed.exists())
        self.assertTrue(unmanaged.exists())
        self.assertEqual(updater.load_lock_targets(self.lock), frozenset())

    def test_second_update_is_a_no_op(self) -> None:
        self.assertTrue(self.synchronize())
        before = self.lock.read_bytes()
        cache = self.skills / "example-skill" / "__pycache__"
        cache.mkdir()
        (cache / "helper.cpython-313.pyc").write_bytes(b"generated")

        self.assertFalse(self.synchronize())

        self.assertEqual(self.lock.read_bytes(), before)

    def test_check_reports_addition_and_removal_without_writing(self) -> None:
        removed = self.skills / "removed-skill"
        removed.mkdir()

        self.assertTrue(
            self.synchronize(
                check=True, previous_targets=frozenset({"removed-skill"})
            )
        )

        self.assertFalse((self.skills / "example-skill").exists())
        self.assertTrue(removed.exists())
        self.assertFalse(self.lock.exists())

    def test_same_repository_with_different_refs_uses_distinct_archives(self) -> None:
        first = updater.SourceSpec(
            target="first",
            repository="example/repo",
            ref="first-ref",
            source_path="skill",
            include=(),
            license_path=None,
        )
        second = updater.SourceSpec(
            target="second",
            repository="example/repo",
            ref="second-ref",
            source_path="skill",
            include=(),
            license_path=None,
        )
        client = FakeClient(
            {
                ("example/repo", "first-ref"): make_archive(
                    {"skill/SKILL.md": b"first"}
                ),
                ("example/repo", "second-ref"): make_archive(
                    {"skill/SKILL.md": b"second"}
                ),
            }
        )

        self.assertTrue(self.synchronize(specs=(first, second), client=client))

        self.assertEqual((self.skills / "first" / "SKILL.md").read_bytes(), b"first")
        self.assertEqual(
            (self.skills / "second" / "SKILL.md").read_bytes(), b"second"
        )

    def test_unsafe_archive_is_rejected_without_writing(self) -> None:
        unsafe = io.BytesIO()
        with zipfile.ZipFile(unsafe, "w") as archive:
            archive.writestr("repo-sha/../escape.txt", b"escape")
            archive.writestr("repo-sha/skill/SKILL.md", b"skill")
            archive.writestr("repo-sha/LICENSE", b"license")
        client = FakeClient({("example/repo", "main"): unsafe.getvalue()})

        with self.assertRaises(updater.UpdaterError):
            self.synchronize(client=client)

        self.assertFalse((self.skills / "example-skill").exists())
        self.assertFalse(self.lock.exists())

    def test_network_failure_preserves_existing_targets(self) -> None:
        target = self.skills / "example-skill"
        target.mkdir()
        original = target / "local.txt"
        original.write_text("local", encoding="utf-8")
        removed = self.skills / "removed-skill"
        removed.mkdir()

        with self.assertRaises(updater.UpdaterError):
            self.synchronize(
                previous_targets=frozenset({"removed-skill"}),
                client=FailingClient({}),
            )

        self.assertEqual(original.read_text(encoding="utf-8"), "local")
        self.assertTrue(removed.exists())
        self.assertFalse(self.lock.exists())

    def test_transaction_failure_restores_targets_and_lock(self) -> None:
        first = self.skills / "first"
        second = self.skills / "second"
        first.mkdir()
        second.mkdir()
        (first / "value.txt").write_text("old-first", encoding="utf-8")
        (second / "value.txt").write_text("old-second", encoding="utf-8")
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text("old-lock", encoding="utf-8")
        transaction = self.skills / ".transaction-test"
        staged = transaction / "staged"
        (staged / "first").mkdir(parents=True)
        (staged / "first" / "value.txt").write_text(
            "new-first", encoding="utf-8"
        )

        with self.assertRaises(OSError):
            updater.apply_transaction(
                self.skills,
                staged,
                ["first", "second"],
                [],
                self.lock,
                b"new-lock",
            )

        self.assertEqual(
            (first / "value.txt").read_text(encoding="utf-8"), "old-first"
        )
        self.assertEqual(
            (second / "value.txt").read_text(encoding="utf-8"), "old-second"
        )
        self.assertEqual(self.lock.read_text(encoding="utf-8"), "old-lock")


if __name__ == "__main__":
    unittest.main()
