#!/usr/bin/env python3
"""Inspect DOCX body images and emit staged PNGs plus ordered block records."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import posixpath
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree

try:
    from PIL import Image, ImageOps, UnidentifiedImageError
except ImportError as error:  # pragma: no cover - exercised through the CLI error path
    raise SystemExit("Pillow is required to synchronize DOCX images.") from error


W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
REL = "http://schemas.openxmlformats.org/package/2006/relationships"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
V = "urn:schemas-microsoft-com:vml"


def qname(namespace: str, local_name: str) -> str:
    return f"{{{namespace}}}{local_name}"


def normalize_text(value: str) -> str:
    return " ".join(value.split())


def visible_text(element: ElementTree.Element) -> str:
    parts: list[str] = []
    for node in element.iter():
        if node.tag == qname(W, "t"):
            parts.append(node.text or "")
        elif node.tag == qname(W, "tab"):
            parts.append("\t")
        elif node.tag in {qname(W, "br"), qname(W, "cr")}:
            parts.append("\n")
    return normalize_text("".join(parts))


def parse_xml(package: zipfile.ZipFile, entry_name: str) -> ElementTree.Element:
    try:
        return ElementTree.fromstring(package.read(entry_name))
    except KeyError as error:
        raise ValueError(f"DOCX package is missing {entry_name}.") from error
    except ElementTree.ParseError as error:
        raise ValueError(f"DOCX package contains invalid XML in {entry_name}.") from error


def relationship_map(package: zipfile.ZipFile) -> dict[str, tuple[str, str, bool]]:
    root = parse_xml(package, "word/_rels/document.xml.rels")
    relationships: dict[str, tuple[str, str, bool]] = {}
    for relationship in root.findall(qname(REL, "Relationship")):
        identifier = relationship.get("Id")
        target = relationship.get("Target")
        relationship_type = relationship.get("Type")
        if not identifier or target is None or relationship_type is None:
            raise ValueError("DOCX document relationships contain an incomplete entry.")
        relationships[identifier] = (
            target,
            relationship_type,
            relationship.get("TargetMode", "").lower() == "external",
        )
    return relationships


def relationship_entry(target: str) -> str:
    if target.startswith("/"):
        normalized = posixpath.normpath(target.lstrip("/"))
    else:
        normalized = posixpath.normpath(posixpath.join("word", target))
    if normalized == ".." or normalized.startswith("../"):
        raise ValueError(f"DOCX image relationship escapes the package root: {target}")
    return normalized


def reject_header_footer_images(
    package: zipfile.ZipFile,
    relationships: dict[str, tuple[str, str, bool]],
) -> None:
    for target, relationship_type, external in relationships.values():
        if not relationship_type.endswith(("/header", "/footer")):
            continue
        if external:
            raise ValueError("External headers and footers are not supported.")
        entry_name = relationship_entry(target)
        root = parse_xml(package, entry_name)
        if root.find(f".//{qname(A, 'blip')}") is not None or root.find(
            f".//{qname(V, 'imagedata')}"
        ) is not None:
            raise ValueError("Images in DOCX headers or footers cannot be represented in Markdown.")


def normalized_png(source: bytes, relationship_id: str) -> bytes:
    try:
        with Image.open(io.BytesIO(source)) as opened:
            if getattr(opened, "n_frames", 1) != 1:
                raise ValueError(
                    f"Animated or multi-frame image relationship {relationship_id} is not supported."
                )
            opened.load()
            if opened.format == "PNG":
                return source
            transposed = ImageOps.exif_transpose(opened)
            has_alpha = transposed.mode in {"RGBA", "LA"} or "transparency" in transposed.info
            converted = transposed.convert("RGBA" if has_alpha else "RGB")
            output = io.BytesIO()
            converted.save(output, format="PNG", optimize=False, compress_level=9)
            return output.getvalue()
    except (UnidentifiedImageError, OSError) as error:
        raise ValueError(
            f"DOCX image relationship {relationship_id} is not a supported raster image."
        ) from error


def staged_image(
    package: zipfile.ZipFile,
    relationships: dict[str, tuple[str, str, bool]],
    relationship_id: str,
    staging_directory: Path,
) -> tuple[str, str]:
    relationship = relationships.get(relationship_id)
    if relationship is None:
        raise ValueError(f"DOCX image references missing relationship {relationship_id}.")
    target, relationship_type, external = relationship
    if external:
        raise ValueError(f"External DOCX image relationship {relationship_id} is not supported.")
    if not relationship_type.endswith("/image"):
        raise ValueError(f"DOCX drawing relationship {relationship_id} does not target an image.")
    entry_name = relationship_entry(target)
    try:
        source = package.read(entry_name)
    except KeyError as error:
        raise ValueError(f"DOCX image part is missing: {entry_name}") from error
    png = normalized_png(source, relationship_id)
    digest = hashlib.sha256(png).hexdigest()
    staged_path = staging_directory / f"{digest}.png"
    if staged_path.exists():
        if staged_path.read_bytes() != png:
            raise ValueError(f"SHA-256 collision while staging DOCX image {relationship_id}.")
    else:
        staged_path.write_bytes(png)
    return digest, staged_path.name


def drawing_blips(paragraph: ElementTree.Element) -> list[tuple[str, str]]:
    alt_by_element: dict[int, str] = {}
    for drawing in paragraph.iter(qname(W, "drawing")):
        doc_pr = drawing.find(f".//{qname(WP, 'docPr')}")
        alt = "" if doc_pr is None else (doc_pr.get("descr") or doc_pr.get("title") or "")
        for blip in drawing.findall(f".//{qname(A, 'blip')}"):
            alt_by_element[id(blip)] = alt
    for picture in paragraph.iter(qname(W, "pict")):
        for image_data in picture.findall(f".//{qname(V, 'imagedata')}"):
            alt_by_element[id(image_data)] = image_data.get("title") or ""

    result: list[tuple[str, str]] = []
    for node in paragraph.iter():
        if node.tag == qname(A, "blip"):
            relationship_id = node.get(qname(R, "embed")) or node.get(qname(R, "link"))
        elif node.tag == qname(V, "imagedata"):
            relationship_id = node.get(qname(R, "id"))
        else:
            continue
        if not relationship_id:
            raise ValueError("DOCX image does not declare a relationship ID.")
        result.append((relationship_id, alt_by_element.get(id(node), "")))
    return result


def table_signature(table: ElementTree.Element) -> str:
    rows: list[str] = []
    for row in table.findall(qname(W, "tr")):
        cells = [visible_text(cell) for cell in row.findall(qname(W, "tc"))]
        rows.append("\x1f".join(cells))
    separator = "\x1e"
    return f"table:{separator.join(rows)}"


def table_images(
    table: ElementTree.Element,
    package: zipfile.ZipFile,
    relationships: dict[str, tuple[str, str, bool]],
    staging_directory: Path,
) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    signature = table_signature(table)
    for row_index, row in enumerate(table.findall(qname(W, "tr"))):
        column = 0
        for cell in row.findall(qname(W, "tc")):
            blips = drawing_blips(cell)
            if blips:
                paragraphs = cell.findall(qname(W, "p"))
                if (len(blips) != 1 or len(paragraphs) != 1 or visible_text(cell)
                        or cell.find(f".//{qname(W, 'tbl')}") is not None
                        or cell.find(f".//{qname(W, 'txbxContent')}") is not None
                        or len(cell.findall(f".//{qname(WP, 'inline')}")) != 1
                        or cell.find(f".//{qname(WP, 'anchor')}") is not None):
                    raise ValueError("DOCX table images require an image-only cell with one inline image.")
                relationship_id, alt = blips[0]
                digest, staged_path = staged_image(
                    package, relationships, relationship_id, staging_directory
                )
                records.append({
                    "kind": "table-image", "signature": signature,
                    "row": row_index, "column": column,
                    "digest": digest, "alt": alt, "staged_path": staged_path,
                })
            span = cell.find(f"{qname(W, 'tcPr')}/{qname(W, 'gridSpan')}")
            column += int(span.get(qname(W, "val"), "1")) if span is not None else 1
    return records


def inspect_docx(input_path: Path, staging_directory: Path) -> dict[str, object]:
    if input_path.suffix.lower() != ".docx":
        raise ValueError(f"DOCX input must use the .docx extension: {input_path}")
    if not input_path.is_file():
        raise FileNotFoundError(f"DOCX input does not exist or is not a file: {input_path}")
    if not staging_directory.is_dir():
        raise FileNotFoundError(f"Image staging directory does not exist: {staging_directory}")

    try:
        with zipfile.ZipFile(input_path) as package:
            corrupt_entry = package.testzip()
            if corrupt_entry is not None:
                raise ValueError(f"DOCX package contains a corrupt entry: {corrupt_entry}")
            document = parse_xml(package, "word/document.xml")
            relationships = relationship_map(package)
            reject_header_footer_images(package, relationships)
            body = document.find(qname(W, "body"))
            if body is None:
                raise ValueError("DOCX document.xml does not contain w:body.")

            records: list[dict[str, object]] = []
            for child in body:
                if child.tag == qname(W, "p"):
                    blips = drawing_blips(child)
                    if blips and child.find(f".//{qname(W, 'txbxContent')}") is not None:
                        raise ValueError("Images in DOCX text boxes cannot be represented in Markdown.")
                    text = visible_text(child)
                    if blips and text:
                        raise ValueError(
                            "DOCX paragraphs that mix visible text and images cannot be represented in Markdown."
                        )
                    if text:
                        records.append({"kind": "anchor", "signature": f"paragraph:{text}"})
                    for relationship_id, alt in blips:
                        digest, staged_path = staged_image(
                            package, relationships, relationship_id, staging_directory
                        )
                        records.append(
                            {
                                "kind": "image",
                                "digest": digest,
                                "alt": alt,
                                "staged_path": staged_path,
                            }
                        )
                elif child.tag == qname(W, "tbl"):
                    records.append({"kind": "anchor", "signature": table_signature(child)})
                    records.extend(table_images(child, package, relationships, staging_directory))
                elif child.tag == qname(W, "sectPr"):
                    continue
                elif child.find(f".//{qname(A, 'blip')}") is not None or child.find(
                    f".//{qname(V, 'imagedata')}"
                ) is not None:
                    raise ValueError("DOCX image is inside an unsupported body container.")
            return {"records": records}
    except zipfile.BadZipFile as error:
        raise ValueError(f"DOCX input is not a valid ZIP package: {input_path}") from error


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Inspect DOCX body images and print one compact JSON result."
    )
    parser.add_argument("input_docx", help="Existing DOCX file to inspect.")
    parser.add_argument("staging_directory", help="Existing temporary image directory.")
    args = parser.parse_args()
    try:
        result = inspect_docx(
            Path(args.input_docx).expanduser().resolve(),
            Path(args.staging_directory).expanduser().resolve(),
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
