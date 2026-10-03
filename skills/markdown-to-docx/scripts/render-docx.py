#!/usr/bin/env python3
"""Render one DOCX to per-page PNGs behind a narrow JSON CLI."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from zipfile import BadZipFile, ZipFile

try:
    import fitz
except ImportError as error:
    raise SystemExit("PyMuPDF is required to render DOCX pages.") from error


RENDER_DPI = 144
LIBREOFFICE_TIMEOUT_SECONDS = 120


def resolve_libreoffice() -> Path:
    if sys.platform == "win32":
        program_files = os.environ.get("ProgramFiles")
        if not program_files:
            raise RuntimeError("ProgramFiles is not defined.")
        executable = Path(program_files) / "LibreOffice" / "program" / "soffice.exe"
    elif sys.platform == "darwin":
        executable = Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    elif sys.platform.startswith("linux"):
        discovered = shutil.which("soffice")
        if not discovered:
            raise RuntimeError("LibreOffice soffice is not on PATH.")
        executable = Path(discovered)
    else:
        raise RuntimeError(f"Unsupported platform: {sys.platform}")

    if not executable.is_file():
        raise RuntimeError(f"LibreOffice executable does not exist: {executable}")
    return executable


def validate_docx(input_path: str) -> Path:
    path = Path(input_path).expanduser().resolve()
    if path.suffix.lower() != ".docx":
        raise ValueError(f"DOCX input must use the .docx extension: {path}")
    if not path.is_file():
        raise FileNotFoundError(f"DOCX input does not exist or is not a file: {path}")

    try:
        with ZipFile(path) as package:
            if "word/document.xml" not in package.namelist():
                raise ValueError(f"DOCX package is missing word/document.xml: {path}")
            corrupt_entry = package.testzip()
            if corrupt_entry:
                raise ValueError(f"DOCX package contains a corrupt entry: {corrupt_entry}")
    except BadZipFile as error:
        raise ValueError(f"DOCX input is not a valid ZIP package: {path}") from error

    return path


def convert_to_pdf(docx_path: Path, conversion_directory: Path, profile: Path) -> Path:
    executable = resolve_libreoffice()
    command = [
        str(executable),
        "--headless",
        "--norestore",
        "--nodefault",
        "--nofirststartwizard",
        f"-env:UserInstallation={profile.as_uri()}",
        "--convert-to",
        "pdf",
        "--outdir",
        str(conversion_directory),
        str(docx_path),
    ]
    creation_flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    process_encoding = "mbcs" if sys.platform == "win32" else "utf-8"
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding=process_encoding,
        timeout=LIBREOFFICE_TIMEOUT_SECONDS,
        creationflags=creation_flags,
        check=False,
    )
    pdf_path = conversion_directory / f"{docx_path.stem}.pdf"
    if completed.returncode != 0 or not pdf_path.is_file() or pdf_path.stat().st_size == 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "no process output"
        raise RuntimeError(
            f"LibreOffice failed to render {docx_path} with exit code "
            f"{completed.returncode}: {details}"
        )
    return pdf_path


def rasterize(pdf_path: Path) -> tuple[Path, list[Path]]:
    output_directory = Path(tempfile.mkdtemp(prefix="markdown-to-docx-render-"))
    pages: list[Path] = []
    scale = RENDER_DPI / 72
    with fitz.open(pdf_path) as document:
        if document.page_count < 1:
            raise RuntimeError(f"Rendered PDF has no pages: {pdf_path}")
        for page_number, page in enumerate(document, start=1):
            output_path = output_directory / f"page-{page_number}.png"
            pixmap = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
            pixmap.save(output_path)
            pages.append(output_path)
    return output_directory, pages


def render_docx(input_path: str) -> dict[str, object]:
    docx_path = validate_docx(input_path)
    with tempfile.TemporaryDirectory(prefix="markdown-to-docx-profile-") as profile_text:
        with tempfile.TemporaryDirectory(prefix="markdown-to-docx-pdf-") as conversion_text:
            profile = Path(profile_text).resolve()
            conversion_directory = Path(conversion_text).resolve()
            pdf_path = convert_to_pdf(docx_path, conversion_directory, profile)
            output_directory, pages = rasterize(pdf_path)

    return {
        "input": str(docx_path),
        "output_directory": str(output_directory),
        "page_count": len(pages),
        "pages": [str(page) for page in pages],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Render a DOCX to temporary page PNGs and print one JSON result."
    )
    parser.add_argument("input_docx", help="Absolute or relative path to one DOCX file.")
    args = parser.parse_args()

    try:
        result = render_docx(args.input_docx)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
