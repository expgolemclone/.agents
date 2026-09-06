#!/usr/bin/env python3
"""Synchronize JSON-configured Codex skills with their GitHub sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
from typing import BinaryIO, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile


API_ROOT = "https://api.github.com"
ARCHIVE_ROOT = "https://codeload.github.com"
USER_AGENT = "codex-skills-updater/1"
CONFIG_SCHEMA_VERSION = 1
LOCK_SCHEMA_VERSION = 1
TARGET_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?"
    r"/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\Z"
)
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
CONFIG_FIELDS = frozenset(
    {"repository", "ref", "source_path", "include", "license_path"}
)
LOCK_FIELDS = frozenset(
    {"repository", "ref", "source_path", "commit", "content_sha256"}
)


@dataclass(frozen=True)
class SourceSpec:
    target: str
    repository: str
    ref: str
    source_path: str
    include: tuple[str, ...]
    license_path: str | None


class UpdaterError(RuntimeError):
    pass


class GitHubClient:
    def _open(self, url: str, timeout: int) -> BinaryIO:
        request = Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": USER_AGENT,
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            return urlopen(request, timeout=timeout)
        except HTTPError as exc:
            raise UpdaterError(f"GitHub returned HTTP {exc.code} for {url}") from exc
        except URLError as exc:
            raise UpdaterError(
                f"Could not reach GitHub for {url}: {exc.reason}"
            ) from exc

    def resolve_ref(self, repository: str, ref: str) -> str:
        url = f"{API_ROOT}/repos/{repository}/commits/{quote(ref, safe='')}"
        with self._open(url, timeout=30) as response:
            try:
                payload = json.load(response)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise UpdaterError(
                    f"GitHub returned invalid JSON for {repository}@{ref}"
                ) from exc
        sha = payload.get("sha")
        if not isinstance(sha, str) or COMMIT_PATTERN.fullmatch(sha) is None:
            raise UpdaterError(
                f"GitHub did not return a commit SHA for {repository}@{ref}"
            )
        return sha

    def download_archive(self, repository: str, sha: str, destination: Path) -> None:
        url = f"{ARCHIVE_ROOT}/{repository}/zip/{sha}"
        with self._open(url, timeout=120) as response, destination.open("wb") as output:
            shutil.copyfileobj(response, output)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise UpdaterError(f"JSON contains a duplicate key: {key}")
        result[key] = value
    return result


def _read_json_object(path: Path, description: str) -> dict[str, object]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle, object_pairs_hook=_unique_object)
    except UpdaterError:
        raise
    except FileNotFoundError as exc:
        raise UpdaterError(f"{description} does not exist: {path}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UpdaterError(f"{description} is not valid UTF-8 JSON: {path}") from exc
    if not isinstance(payload, dict):
        raise UpdaterError(f"{description} root must be an object: {path}")
    return payload


def _require_exact_fields(
    payload: dict[str, object], expected: frozenset[str], location: str
) -> None:
    actual = set(payload)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    details: list[str] = []
    if missing:
        details.append(f"missing {', '.join(missing)}")
    if unknown:
        details.append(f"unknown {', '.join(unknown)}")
    if details:
        raise UpdaterError(f"Invalid fields at {location}: {'; '.join(details)}")


def _validate_target(value: object, location: str) -> str:
    if not isinstance(value, str) or TARGET_PATTERN.fullmatch(value) is None:
        raise UpdaterError(f"{location} must be a direct skill directory name")
    if value in (".", "..", ".system"):
        raise UpdaterError(f"{location} is reserved: {value}")
    return value


def _validate_repository(value: object, location: str) -> str:
    if not isinstance(value, str) or REPOSITORY_PATTERN.fullmatch(value) is None:
        raise UpdaterError(f"{location} must use the owner/repository form")
    owner, repository = value.split("/", 1)
    if owner in (".", "..") or repository in (".", ".."):
        raise UpdaterError(f"{location} contains a reserved path component")
    return value


def _validate_ref(value: object, location: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise UpdaterError(f"{location} must be a non-empty Git ref")
    return value


def _validate_posix_path(
    value: object, location: str, *, allow_empty: bool
) -> str:
    if not isinstance(value, str):
        raise UpdaterError(f"{location} must be a string")
    if not value and allow_empty:
        return value
    if not value or "\\" in value:
        raise UpdaterError(f"{location} must be a relative POSIX path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in ("", ".", "..") for part in path.parts)
        or path.as_posix() != value
    ):
        raise UpdaterError(f"{location} must be a normalized relative POSIX path")
    return value


def _validate_include(value: object, location: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise UpdaterError(f"{location} must be an array")
    result: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        entry = _validate_posix_path(
            item, f"{location}[{index}]", allow_empty=False
        )
        if len(PurePosixPath(entry).parts) != 1:
            raise UpdaterError(f"{location}[{index}] must name a top-level entry")
        if entry in seen:
            raise UpdaterError(f"{location} contains a duplicate entry: {entry}")
        seen.add(entry)
        result.append(entry)
    return tuple(result)


def load_config(config_path: Path) -> tuple[SourceSpec, ...]:
    payload = _read_json_object(config_path, "Configuration")
    _require_exact_fields(
        payload, frozenset({"schema_version", "sources"}), "configuration root"
    )
    version = payload["schema_version"]
    if isinstance(version, bool) or version != CONFIG_SCHEMA_VERSION:
        raise UpdaterError(
            f"configuration schema_version must be {CONFIG_SCHEMA_VERSION}"
        )
    sources = payload["sources"]
    if not isinstance(sources, dict):
        raise UpdaterError("configuration sources must be an object")

    specs: list[SourceSpec] = []
    casefolded_targets: dict[str, str] = {}
    for raw_target, raw_source in sources.items():
        target = _validate_target(raw_target, f"sources key {raw_target!r}")
        folded = target.casefold()
        existing = casefolded_targets.get(folded)
        if existing is not None:
            raise UpdaterError(
                "configuration targets collide on this filesystem: "
                f"{existing}, {target}"
            )
        casefolded_targets[folded] = target
        if not isinstance(raw_source, dict):
            raise UpdaterError(f"sources.{target} must be an object")
        _require_exact_fields(raw_source, CONFIG_FIELDS, f"sources.{target}")
        raw_license = raw_source["license_path"]
        license_path = (
            None
            if raw_license is None
            else _validate_posix_path(
                raw_license, f"sources.{target}.license_path", allow_empty=False
            )
        )
        specs.append(
            SourceSpec(
                target=target,
                repository=_validate_repository(
                    raw_source["repository"], f"sources.{target}.repository"
                ),
                ref=_validate_ref(raw_source["ref"], f"sources.{target}.ref"),
                source_path=_validate_posix_path(
                    raw_source["source_path"],
                    f"sources.{target}.source_path",
                    allow_empty=True,
                ),
                include=_validate_include(
                    raw_source["include"], f"sources.{target}.include"
                ),
                license_path=license_path,
            )
        )
    return tuple(specs)


def load_lock_targets(lock_path: Path) -> frozenset[str]:
    if not lock_path.exists():
        return frozenset()
    payload = _read_json_object(lock_path, "Lock file")
    _require_exact_fields(
        payload, frozenset({"schema_version", "sources"}), "lock root"
    )
    version = payload["schema_version"]
    if isinstance(version, bool) or version != LOCK_SCHEMA_VERSION:
        raise UpdaterError(f"lock schema_version must be {LOCK_SCHEMA_VERSION}")
    sources = payload["sources"]
    if not isinstance(sources, dict):
        raise UpdaterError("lock sources must be an object")

    targets: set[str] = set()
    casefolded_targets: dict[str, str] = {}
    for raw_target, raw_source in sources.items():
        target = _validate_target(raw_target, f"lock sources key {raw_target!r}")
        folded = target.casefold()
        existing = casefolded_targets.get(folded)
        if existing is not None:
            raise UpdaterError(
                f"lock targets collide on this filesystem: {existing}, {target}"
            )
        casefolded_targets[folded] = target
        if not isinstance(raw_source, dict):
            raise UpdaterError(f"lock sources.{target} must be an object")
        _require_exact_fields(raw_source, LOCK_FIELDS, f"lock sources.{target}")
        _validate_repository(
            raw_source["repository"], f"lock sources.{target}.repository"
        )
        _validate_ref(raw_source["ref"], f"lock sources.{target}.ref")
        _validate_posix_path(
            raw_source["source_path"],
            f"lock sources.{target}.source_path",
            allow_empty=True,
        )
        commit = raw_source["commit"]
        if not isinstance(commit, str) or COMMIT_PATTERN.fullmatch(commit) is None:
            raise UpdaterError(f"lock sources.{target}.commit must be a commit SHA")
        digest = raw_source["content_sha256"]
        if not isinstance(digest, str) or DIGEST_PATTERN.fullmatch(digest) is None:
            raise UpdaterError(
                f"lock sources.{target}.content_sha256 must be a SHA-256 digest"
            )
        targets.add(target)
    return frozenset(targets)


def _safe_archive_parts(name: str) -> tuple[str, ...]:
    if "\\" in name:
        raise UpdaterError(f"Archive contains a backslash path: {name}")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise UpdaterError(f"Archive contains an unsafe path: {name}")
    return tuple(part for part in path.parts if part not in ("", "."))


def _archive_root(archive: zipfile.ZipFile) -> str:
    roots: set[str] = set()
    for member in archive.infolist():
        parts = _safe_archive_parts(member.filename)
        if parts:
            roots.add(parts[0])
    if len(roots) != 1:
        raise UpdaterError("GitHub archive must contain exactly one root directory")
    return roots.pop()


def _is_symlink(member: zipfile.ZipInfo) -> bool:
    mode = member.external_attr >> 16
    return stat.S_ISLNK(mode)


def _matches_include(relative: tuple[str, ...], include: tuple[str, ...]) -> bool:
    if not include:
        return True
    return bool(relative) and relative[0] in include


def _copy_member(
    archive: zipfile.ZipFile, member: zipfile.ZipInfo, destination: Path
) -> None:
    if _is_symlink(member):
        raise UpdaterError(
            f"Archive contains an unsupported symlink: {member.filename}"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    if member.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        return
    with archive.open(member) as source, destination.open("wb") as output:
        shutil.copyfileobj(source, output)
    mode = member.external_attr >> 16
    if mode & 0o111:
        destination.chmod(destination.stat().st_mode | 0o111)


def materialize_source(archive_path: Path, spec: SourceSpec, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    copied_files = 0
    with zipfile.ZipFile(archive_path) as archive:
        root = _archive_root(archive)
        prefix = (
            (root, *PurePosixPath(spec.source_path).parts)
            if spec.source_path
            else (root,)
        )
        for member in archive.infolist():
            parts = _safe_archive_parts(member.filename)
            if len(parts) <= len(prefix) or parts[: len(prefix)] != prefix:
                continue
            relative = parts[len(prefix) :]
            if not _matches_include(relative, spec.include):
                continue
            _copy_member(archive, member, destination.joinpath(*relative))
            if not member.is_dir():
                copied_files += 1

        if spec.license_path is not None:
            license_parts = (root, *PurePosixPath(spec.license_path).parts)
            license_member = next(
                (
                    member
                    for member in archive.infolist()
                    if _safe_archive_parts(member.filename) == license_parts
                    and not member.is_dir()
                ),
                None,
            )
            if license_member is None:
                raise UpdaterError(
                    f"{spec.repository} does not contain {spec.license_path}"
                )
            _copy_member(archive, license_member, destination / "LICENSE")

    if copied_files == 0:
        raise UpdaterError(f"No files found for {spec.repository}:{spec.source_path}")
    if not (destination / "SKILL.md").is_file():
        raise UpdaterError(f"{spec.target} does not contain SKILL.md")


def tree_digest(root: Path) -> str | None:
    if not root.is_dir():
        return None
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda value: value.as_posix()):
        relative = path.relative_to(root)
        if "__pycache__" in relative.parts or path.suffix in (".pyc", ".pyo"):
            continue
        if path.is_symlink():
            digest.update(b"L\0")
            digest.update(relative.as_posix().encode("utf-8"))
            digest.update(b"\0")
            digest.update(os.readlink(path).encode("utf-8"))
            digest.update(b"\0")
        elif path.is_file():
            digest.update(b"F\0")
            digest.update(relative.as_posix().encode("utf-8"))
            digest.update(b"\0")
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def lock_payload(
    specs: Iterable[SourceSpec],
    commits: dict[tuple[str, str], str],
    staged: Path,
) -> dict[str, object]:
    sources: dict[str, object] = {}
    for spec in specs:
        digest = tree_digest(staged / spec.target)
        if digest is None:
            raise UpdaterError(f"Staged target is missing: {spec.target}")
        sources[spec.target] = {
            "repository": spec.repository,
            "ref": spec.ref,
            "source_path": spec.source_path,
            "commit": commits[(spec.repository, spec.ref)],
            "content_sha256": digest,
        }
    return {"schema_version": LOCK_SCHEMA_VERSION, "sources": sources}


def encode_lock(payload: dict[str, object]) -> bytes:
    return (
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def _lock_matches(lock_path: Path, desired: bytes) -> bool:
    return lock_path.is_file() and lock_path.read_bytes() == desired


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def apply_transaction(
    skills_dir: Path,
    staged: Path,
    changed_targets: list[str],
    removed_targets: list[str],
    lock_path: Path,
    desired_lock: bytes,
) -> None:
    transaction = staged.parent
    backup = transaction / "backup"
    backup.mkdir()
    installed: list[Path] = []
    backed_up: list[tuple[Path, Path]] = []
    lock_backup = transaction / "lock.backup"
    lock_installed = False

    try:
        for name in (*changed_targets, *removed_targets):
            target = skills_dir / name
            if target.exists() or target.is_symlink():
                saved = backup / name
                target.replace(saved)
                backed_up.append((target, saved))

        for name in changed_targets:
            target = skills_dir / name
            (staged / name).replace(target)
            installed.append(target)

        lock_path.parent.mkdir(parents=True, exist_ok=True)
        if lock_path.exists():
            lock_path.replace(lock_backup)
        temporary_lock = transaction / "lock.new"
        temporary_lock.write_bytes(desired_lock)
        os.replace(temporary_lock, lock_path)
        lock_installed = True
    except Exception:
        if lock_installed and lock_path.exists():
            lock_path.unlink()
        if lock_backup.exists():
            lock_backup.replace(lock_path)
        for target in reversed(installed):
            _remove_path(target)
        for target, saved in reversed(backed_up):
            saved.replace(target)
        raise


def synchronize(
    skills_dir: Path,
    lock_path: Path,
    check: bool,
    *,
    specs: tuple[SourceSpec, ...],
    previous_targets: frozenset[str],
    client: GitHubClient | None = None,
) -> bool:
    client = client or GitHubClient()
    skills_dir = skills_dir.resolve()
    if not skills_dir.is_dir():
        raise UpdaterError(f"Skills directory does not exist: {skills_dir}")

    configured_targets = frozenset(spec.target for spec in specs)
    removed_targets = sorted(previous_targets - configured_targets)
    repositories = sorted({(spec.repository, spec.ref) for spec in specs})
    commits: dict[tuple[str, str], str] = {}
    with tempfile.TemporaryDirectory(
        prefix=".skills-updater-", dir=skills_dir
    ) as temporary:
        transaction = Path(temporary)
        archives = transaction / "archives"
        staged = transaction / "staged"
        archives.mkdir()
        staged.mkdir()

        archive_by_source: dict[tuple[str, str], Path] = {}
        for index, (repository, ref) in enumerate(repositories):
            sha = client.resolve_ref(repository, ref)
            commits[(repository, ref)] = sha
            archive_path = archives / f"{index}.zip"
            client.download_archive(repository, sha, archive_path)
            archive_by_source[(repository, ref)] = archive_path
            print(f"source {repository}@{ref} {sha}")

        for spec in specs:
            materialize_source(
                archive_by_source[(spec.repository, spec.ref)],
                spec,
                staged / spec.target,
            )

        payload = lock_payload(specs, commits, staged)
        desired_lock = encode_lock(payload)
        changed_targets = [
            spec.target
            for spec in specs
            if tree_digest(skills_dir / spec.target)
            != tree_digest(staged / spec.target)
        ]
        lock_changed = not _lock_matches(lock_path, desired_lock)
        update_available = bool(changed_targets or removed_targets or lock_changed)

        for spec in specs:
            status_text = "update" if spec.target in changed_targets else "current"
            print(f"{status_text} {spec.target}")
        for name in removed_targets:
            print(f"remove {name}")

        if check or not update_available:
            return update_available

        apply_transaction(
            skills_dir,
            staged,
            changed_targets,
            removed_targets,
            lock_path,
            desired_lock,
        )
        return True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether updates are available without changing files",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    script_dir = Path(__file__).resolve().parent
    config_path = script_dir / "skills-updater.json"
    lock_path = script_dir / "skills-updater.lock.json"
    skills_dir = script_dir.parent / "skills"
    try:
        specs = load_config(config_path)
        previous_targets = load_lock_targets(lock_path)
        changed = synchronize(
            skills_dir,
            lock_path,
            args.check,
            specs=specs,
            previous_targets=previous_targets,
        )
    except (OSError, UpdaterError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check and changed:
        return 1
    if changed:
        print("skills updated")
    else:
        print("all skills are current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
