import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  markdownBlockSignature,
  normalizeVisibleText,
  parseMarkdown,
  type MarkdownBlock,
} from "./markdown-parser.ts";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const EXTRACTOR_PATH = path.join(SCRIPT_DIRECTORY, "extract-docx-images.py");

type DocxAnchorRecord = { kind: "anchor"; signature: string };
type DocxImageRecord = {
  kind: "image";
  digest: string;
  alt: string;
  staged_path: string;
};
type DocxRecord = DocxAnchorRecord | DocxImageRecord;
type ExtractorResult = { records: DocxRecord[] };

type MarkdownAnchorRecord = {
  kind: "anchor";
  signature: string;
  block: MarkdownBlock;
};
type MarkdownImageRecord = {
  kind: "image";
  digest: string;
  block: Extract<MarkdownBlock, { kind: "image" }>;
};
type MarkdownRecord = MarkdownAnchorRecord | MarkdownImageRecord;

type ImageGap = {
  key: string;
  beforeBlock?: MarkdownBlock;
  afterBlock?: MarkdownBlock;
};
type PositionedImage<T> = { record: T; recordIndex: number; gap: ImageGap };

export type PlannedImageFile = { absolutePath: string; data: Buffer };
export type DocxImageSynchronization = {
  markdown: string;
  importedImagePaths: string[];
  imageFiles: PlannedImageFile[];
};

function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

function assertDigest(value: unknown, context: string): asserts value is string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new Error(`DOCX image extractor returned an invalid SHA-256 digest for ${context}.`);
  }
}

function parseExtractorResult(stdout: string, stagingDirectory: string): ExtractorResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    throw new Error(
      `DOCX image extractor returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (typeof parsed !== "object" || parsed === null || !("records" in parsed) || !Array.isArray(parsed.records)) {
    throw new Error("DOCX image extractor result must contain a records array.");
  }
  const records: DocxRecord[] = parsed.records.map((raw, index) => {
    if (typeof raw !== "object" || raw === null || !("kind" in raw)) {
      throw new Error(`DOCX image extractor returned an invalid record at index ${index}.`);
    }
    if (raw.kind === "anchor") {
      if (!("signature" in raw) || typeof raw.signature !== "string") {
        throw new Error(`DOCX image extractor returned an invalid anchor at index ${index}.`);
      }
      return { kind: "anchor", signature: raw.signature };
    }
    if (raw.kind === "image") {
      if (!("digest" in raw)) {
        throw new Error(`DOCX image extractor omitted an image digest at index ${index}.`);
      }
      assertDigest(raw.digest, `record ${index}`);
      if (!("alt" in raw) || typeof raw.alt !== "string") {
        throw new Error(`DOCX image extractor returned invalid image alt text at index ${index}.`);
      }
      if (!("staged_path" in raw) || typeof raw.staged_path !== "string") {
        throw new Error(`DOCX image extractor returned an invalid staged path at index ${index}.`);
      }
      const expectedName = `${raw.digest}.png`;
      if (raw.staged_path !== expectedName || path.basename(raw.staged_path) !== raw.staged_path) {
        throw new Error(`DOCX image extractor returned an invalid staged filename: ${raw.staged_path}`);
      }
      const stagedPath = path.join(stagingDirectory, raw.staged_path);
      return { kind: "image", digest: raw.digest, alt: raw.alt, staged_path: stagedPath };
    }
    throw new Error(`DOCX image extractor returned an unknown record kind at index ${index}.`);
  });
  return { records };
}

function extractDocxRecords(docxPath: string, stagingDirectory: string): ExtractorResult {
  const extracted = spawnSync("python", [EXTRACTOR_PATH, docxPath, stagingDirectory], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 120_000,
    windowsHide: true,
  });
  if (extracted.error) {
    throw new Error(`Unable to run the DOCX image extractor: ${extracted.error.message}`);
  }
  if (extracted.status !== 0) {
    const detail = extracted.stderr.trim() || extracted.stdout.trim() || `exit code ${extracted.status}`;
    throw new Error(`Unable to synchronize existing DOCX images: ${detail}`);
  }
  if (extracted.stderr.trim() !== "") {
    throw new Error(`DOCX image extractor wrote unexpected stderr output: ${extracted.stderr.trim()}`);
  }
  return parseExtractorResult(extracted.stdout.trim(), stagingDirectory);
}

function resolveMarkdownImagePath(markdownPath: string, baseDirectory: string): string {
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(markdownPath)) {
    throw new Error(`Remote and data images are not supported: ${markdownPath}`);
  }
  const sourcePath = path.isAbsolute(markdownPath)
    ? path.normalize(markdownPath)
    : path.resolve(baseDirectory, markdownPath);
  if (path.extname(sourcePath).toLowerCase() !== ".png") {
    throw new Error(`Unsupported image format for ${markdownPath}. Only PNG is supported.`);
  }
  if (!existsSync(sourcePath) || !statSync(sourcePath).isFile()) {
    throw new Error(`PNG image does not exist or is not a file: ${sourcePath}`);
  }
  return sourcePath;
}

function markdownRecords(markdown: string, markdownDirectory: string): MarkdownRecord[] {
  return parseMarkdown(markdown).flatMap((block): MarkdownRecord[] => {
    if (block.kind === "image") {
      const sourcePath = resolveMarkdownImagePath(block.path, markdownDirectory);
      return [{ kind: "image", digest: sha256(readFileSync(sourcePath)), block }];
    }
    const signature = markdownBlockSignature(block);
    return signature === undefined ? [] : [{ kind: "anchor", signature, block }];
  });
}

function counts(values: string[]): Map<string, number> {
  const result = new Map<string, number>();
  for (const value of values) result.set(value, (result.get(value) ?? 0) + 1);
  return result;
}

function commonUniqueAnchors(
  docxRecords: DocxRecord[],
  sourceRecords: MarkdownRecord[],
): Map<string, MarkdownAnchorRecord> {
  const docxCounts = counts(
    docxRecords.filter((record): record is DocxAnchorRecord => record.kind === "anchor")
      .map((record) => record.signature),
  );
  const sourceAnchors = sourceRecords.filter(
    (record): record is MarkdownAnchorRecord => record.kind === "anchor",
  );
  const sourceCounts = counts(sourceAnchors.map((record) => record.signature));
  const result = new Map<string, MarkdownAnchorRecord>();
  for (const record of sourceAnchors) {
    if (docxCounts.get(record.signature) === 1 && sourceCounts.get(record.signature) === 1) {
      result.set(record.signature, record);
    }
  }
  return result;
}

function imageGap<T extends DocxRecord | MarkdownRecord>(
  records: T[],
  imageIndex: number,
  uniqueAnchors: Map<string, MarkdownAnchorRecord>,
  strict: boolean,
): ImageGap | undefined {
  let before: MarkdownAnchorRecord | undefined;
  let after: MarkdownAnchorRecord | undefined;
  for (let index = imageIndex - 1; index >= 0; index -= 1) {
    const record = records[index]!;
    if (record.kind !== "anchor") continue;
    before = uniqueAnchors.get(record.signature);
    if (before) break;
  }
  for (let index = imageIndex + 1; index < records.length; index += 1) {
    const record = records[index]!;
    if (record.kind !== "anchor") continue;
    after = uniqueAnchors.get(record.signature);
    if (after) break;
  }
  if (!before && !after) {
    const hasAnchors = records.some((record) => record.kind === "anchor");
    if (strict && hasAnchors) {
      throw new Error(
        "Unable to place a DOCX image because no surrounding text or table block maps uniquely to Markdown.",
      );
    }
    if (hasAnchors) return undefined;
  }
  if (
    before?.block.sourceEndLine !== undefined &&
    after?.block.sourceStartLine !== undefined &&
    before.block.sourceEndLine >= after.block.sourceStartLine
  ) {
    if (strict) throw new Error("DOCX image anchors appear in a different order than the Markdown source.");
    return undefined;
  }
  return {
    key: `${before?.signature ?? "^"}\u0000${after?.signature ?? "$"}`,
    beforeBlock: before?.block,
    afterBlock: after?.block,
  };
}

function positionedImages<T extends DocxImageRecord | MarkdownImageRecord>(
  records: Array<DocxRecord | MarkdownRecord>,
  uniqueAnchors: Map<string, MarkdownAnchorRecord>,
  strict: boolean,
): Array<PositionedImage<T>> {
  const result: Array<PositionedImage<T>> = [];
  records.forEach((record, recordIndex) => {
    if (record.kind !== "image") return;
    const gap = imageGap(records, recordIndex, uniqueAnchors, strict);
    if (gap) result.push({ record: record as T, recordIndex, gap });
  });
  return result;
}

function safeAltText(value: string): string {
  const normalized = normalizeVisibleText(value);
  return normalized.includes("]") ? "" : normalized;
}

function insertionLine(gap: ImageGap, beforeImage?: MarkdownImageRecord, afterImage?: MarkdownImageRecord): number {
  if (afterImage?.block.sourceStartLine !== undefined) return afterImage.block.sourceStartLine;
  if (beforeImage?.block.sourceEndLine !== undefined) return beforeImage.block.sourceEndLine + 1;
  if (gap.beforeBlock?.sourceEndLine !== undefined) return gap.beforeBlock.sourceEndLine + 1;
  if (gap.afterBlock?.sourceStartLine !== undefined) return gap.afterBlock.sourceStartLine;
  return 0;
}

function insertImageLines(markdown: string, insertions: Map<number, string[]>): string {
  const newline = markdown.includes("\r\n") ? "\r\n" : "\n";
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const positions = [...insertions.keys()].sort((left, right) => right - left);
  for (const position of positions) {
    if (!Number.isSafeInteger(position) || position < 0 || position > lines.length) {
      throw new Error(`Invalid Markdown image insertion line: ${position}`);
    }
    const references = insertions.get(position)!;
    const inserted: string[] = [];
    references.forEach((reference, index) => {
      if (index > 0) inserted.push("");
      inserted.push(reference);
    });
    if (position > 0 && lines[position - 1] !== "") inserted.unshift("");
    if (position < lines.length && lines[position] !== "") inserted.push("");
    lines.splice(position, 0, ...inserted);
  }
  return lines.join(newline);
}

function groupByGap<T>(images: Array<PositionedImage<T>>): Map<string, Array<PositionedImage<T>>> {
  const result = new Map<string, Array<PositionedImage<T>>>();
  for (const image of images) {
    const group = result.get(image.gap.key) ?? [];
    group.push(image);
    result.set(image.gap.key, group);
  }
  return result;
}

export function planDocxImageSynchronization(
  markdown: string,
  markdownPath: string,
  docxPath: string,
): DocxImageSynchronization {
  const stagingDirectory = mkdtempSync(path.join(tmpdir(), "markdown-to-docx-sync-"));
  try {
    const extracted = extractDocxRecords(docxPath, stagingDirectory);
    const docxImages = extracted.records.filter(
      (record): record is DocxImageRecord => record.kind === "image",
    );
    if (docxImages.length === 0) return { markdown, importedImagePaths: [], imageFiles: [] };

    const markdownDirectory = path.dirname(path.resolve(markdownPath));
    const sourceRecords = markdownRecords(markdown, markdownDirectory);
    const sourceImages = sourceRecords.filter(
      (record): record is MarkdownImageRecord => record.kind === "image",
    );
    const docxCountByDigest = counts(docxImages.map((image) => image.digest));
    const sourceCountByDigest = counts(sourceImages.map((image) => image.digest));
    const remainingByDigest = new Map<string, number>();
    for (const [digest, count] of docxCountByDigest) {
      const missing = Math.max(0, count - (sourceCountByDigest.get(digest) ?? 0));
      if (missing > 0) remainingByDigest.set(digest, missing);
    }
    if (remainingByDigest.size === 0) return { markdown, importedImagePaths: [], imageFiles: [] };

    const uniqueAnchors = commonUniqueAnchors(extracted.records, sourceRecords);
    const positionedDocx = positionedImages<DocxImageRecord>(extracted.records, uniqueAnchors, true);
    const positionedSource = positionedImages<MarkdownImageRecord>(sourceRecords, uniqueAnchors, false);
    const sourceByGap = groupByGap(positionedSource);
    const docxByGap = groupByGap(positionedDocx);
    const insertions = new Map<number, string[]>();
    const importedImagePaths: string[] = [];
    const stagedData = new Map<string, Buffer>();

    for (const [gapKey, images] of docxByGap) {
      const sourceInGap = sourceByGap.get(gapKey) ?? [];
      const matchByDocxIndex = new Map<number, MarkdownImageRecord>();
      let sourceCursor = 0;
      for (const image of images) {
        let matchedIndex = -1;
        for (let index = sourceCursor; index < sourceInGap.length; index += 1) {
          if (sourceInGap[index]!.record.digest === image.record.digest) {
            matchedIndex = index;
            break;
          }
        }
        if (matchedIndex >= 0) {
          sourceCursor = matchedIndex + 1;
          matchByDocxIndex.set(image.recordIndex, sourceInGap[matchedIndex]!.record);
        }
      }

      for (let imageIndex = 0; imageIndex < images.length; imageIndex += 1) {
        const image = images[imageIndex]!;
        if (matchByDocxIndex.has(image.recordIndex)) continue;
        const remaining = remainingByDigest.get(image.record.digest) ?? 0;
        if (remaining < 1) continue;
        remainingByDigest.set(image.record.digest, remaining - 1);

        let previousMatch: MarkdownImageRecord | undefined;
        for (let cursor = imageIndex - 1; cursor >= 0; cursor -= 1) {
          previousMatch = matchByDocxIndex.get(images[cursor]!.recordIndex);
          if (previousMatch) break;
        }
        let nextMatch: MarkdownImageRecord | undefined;
        for (let cursor = imageIndex + 1; cursor < images.length; cursor += 1) {
          nextMatch = matchByDocxIndex.get(images[cursor]!.recordIndex);
          if (nextMatch) break;
        }
        const line = insertionLine(image.gap, previousMatch, nextMatch);
        const relativePath = `images/${image.record.digest}.png`;
        const references = insertions.get(line) ?? [];
        references.push(`![${safeAltText(image.record.alt)}](${relativePath})`);
        insertions.set(line, references);
        importedImagePaths.push(relativePath);

        if (!stagedData.has(image.record.digest)) {
          const data = readFileSync(image.record.staged_path);
          if (sha256(data) !== image.record.digest) {
            throw new Error(`Staged DOCX image failed SHA-256 verification: ${image.record.digest}`);
          }
          stagedData.set(image.record.digest, data);
        }
      }
    }

    for (const [digest, remaining] of remainingByDigest) {
      if (remaining > 0) {
        throw new Error(`Unable to place ${remaining} DOCX image occurrence(s) with digest ${digest}.`);
      }
    }

    const synchronizedMarkdown = insertImageLines(markdown, insertions);
    parseMarkdown(synchronizedMarkdown);
    const imageDirectory = path.join(markdownDirectory, "images");
    if (existsSync(imageDirectory) && !statSync(imageDirectory).isDirectory()) {
      throw new Error(`Markdown image directory path is not a directory: ${imageDirectory}`);
    }
    const imageFiles = [...stagedData].map(([digest, data]) => {
      const absolutePath = path.join(imageDirectory, `${digest}.png`);
      if (existsSync(absolutePath)) {
        if (!statSync(absolutePath).isFile() || !readFileSync(absolutePath).equals(data)) {
          throw new Error(`Existing synchronized image conflicts with DOCX content: ${absolutePath}`);
        }
        return undefined;
      }
      return { absolutePath, data };
    }).filter((file): file is PlannedImageFile => file !== undefined);

    return { markdown: synchronizedMarkdown, importedImagePaths, imageFiles };
  } finally {
    rmSync(stagingDirectory, { recursive: true, force: true });
  }
}
