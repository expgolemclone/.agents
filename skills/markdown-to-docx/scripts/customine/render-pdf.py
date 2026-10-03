#!/usr/bin/env python3
"""Render one PDF into a caller-created directory of page PNGs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    import fitz
except ImportError as error:
    raise SystemExit("PyMuPDF is required to render PDF pages.") from error


RENDER_DPI = 144


def render_pdf(input_argument: str, output_argument: str) -> dict[str, object]:
    input_path = Path(input_argument).expanduser().resolve()
    output_directory = Path(output_argument).expanduser().resolve()
    if input_path.suffix.lower() != ".pdf" or not input_path.is_file():
        raise ValueError(f"PDF input does not exist or is not a PDF file: {input_path}")
    if not output_directory.is_dir():
        raise ValueError(f"Render output directory does not exist: {output_directory}")
    if any(output_directory.glob("page-*.png")):
        raise ValueError(f"Render output already contains page PNGs: {output_directory}")

    pages: list[str] = []
    scale = RENDER_DPI / 72
    with fitz.open(input_path) as document:
        if document.page_count < 1:
            raise ValueError(f"PDF contains no pages: {input_path}")
        for page_number, page in enumerate(document, start=1):
            output_path = output_directory / f"page-{page_number}.png"
            pixmap = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
            pixmap.save(output_path)
            pages.append(str(output_path))
    return {"page_count": len(pages), "pages": pages}


def main() -> None:
    parser = argparse.ArgumentParser(description="Render a PDF into page PNGs.")
    parser.add_argument("input_pdf")
    parser.add_argument("output_directory")
    args = parser.parse_args()
    try:
        result = render_pdf(args.input_pdf, args.output_directory)
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
