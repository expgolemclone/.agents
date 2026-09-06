import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

import { renderDocx } from "./docx-renderer.ts";
import {
  planDocxImageSynchronization,
  type PlannedImageFile,
} from "./docx-image-sync.ts";
import { parseMarkdown } from "./markdown-parser.ts";

export type SynchronizationOptions = {
  codeAppendixThreshold?: number;
};

export type SynchronizationResult = {
  importedImagePaths: string[];
  markdownChanged: boolean;
};

function validatePathExtensions(inputPath: string, outputPath: string): void {
  const inputExtension = path.extname(inputPath).toLowerCase();
  if (inputExtension !== ".md" && inputExtension !== ".markdown") {
    throw new Error(`Markdown input must use the .md or .markdown extension: ${inputPath}`);
  }
  if (path.extname(outputPath).toLowerCase() !== ".docx") {
    throw new Error(`DOCX output must use the .docx extension: ${outputPath}`);
  }
}

function temporarySibling(targetPath: string): string {
  return path.join(path.dirname(targetPath), `.${path.basename(targetPath)}.${randomUUID()}.tmp`);
}

function stageFile(targetPath: string, data: string | Buffer): string {
  const temporaryPath = temporarySibling(targetPath);
  writeFileSync(temporaryPath, data, { flag: "wx" });
  return temporaryPath;
}

function removeCreatedImages(files: string[], imageDirectory?: string): void {
  for (const file of files) rmSync(file, { force: true });
  if (imageDirectory && existsSync(imageDirectory) && readdirSync(imageDirectory).length === 0) {
    rmdirSync(imageDirectory);
  }
}

function materializeImages(files: PlannedImageFile[]): {
  createdFiles: string[];
  createdDirectory?: string;
} {
  if (files.length === 0) return { createdFiles: [] };
  const imageDirectory = path.dirname(files[0]!.absolutePath);
  if (files.some((file) => path.dirname(file.absolutePath) !== imageDirectory)) {
    throw new Error("Synchronized DOCX images must use one Markdown image directory.");
  }
  let createdDirectory: string | undefined;
  if (!existsSync(imageDirectory)) {
    mkdirSync(imageDirectory);
    createdDirectory = imageDirectory;
  } else if (!statSync(imageDirectory).isDirectory()) {
    throw new Error(`Markdown image directory path is not a directory: ${imageDirectory}`);
  }
  const createdFiles: string[] = [];
  try {
    for (const file of files) {
      writeFileSync(file.absolutePath, file.data, { flag: "wx" });
      createdFiles.push(file.absolutePath);
    }
    return { createdFiles, createdDirectory };
  } catch (error) {
    removeCreatedImages(createdFiles, createdDirectory);
    throw error;
  }
}

function restoreMarkdown(inputPath: string, originalMarkdown: Buffer): void {
  const temporaryPath = stageFile(inputPath, originalMarkdown);
  try {
    renameSync(temporaryPath, inputPath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

export function synchronizeMarkdownToDocx(
  inputPath: string,
  outputPath: string,
  options: SynchronizationOptions = {},
): SynchronizationResult {
  const resolvedInput = path.resolve(inputPath);
  const resolvedOutput = path.resolve(outputPath);
  validatePathExtensions(resolvedInput, resolvedOutput);
  if (!existsSync(resolvedInput) || !statSync(resolvedInput).isFile()) {
    throw new Error(`Markdown input does not exist or is not a file: ${resolvedInput}`);
  }
  const outputDirectory = path.dirname(resolvedOutput);
  if (!existsSync(outputDirectory) || !statSync(outputDirectory).isDirectory()) {
    throw new Error(`DOCX output directory does not exist: ${outputDirectory}`);
  }
  if (existsSync(resolvedOutput) && !statSync(resolvedOutput).isFile()) {
    throw new Error(`DOCX output path is not a file: ${resolvedOutput}`);
  }
  if (
    options.codeAppendixThreshold !== undefined &&
    (!Number.isSafeInteger(options.codeAppendixThreshold) || options.codeAppendixThreshold < 1)
  ) {
    throw new RangeError("The code appendix threshold must be a positive integer.");
  }

  const originalMarkdown = readFileSync(resolvedInput);
  const markdown = originalMarkdown.toString("utf8");
  const synchronization = existsSync(resolvedOutput)
    ? planDocxImageSynchronization(markdown, resolvedInput, resolvedOutput)
    : { markdown, importedImagePaths: [], imageFiles: [] };
  const markdownChanged = synchronization.markdown !== markdown;
  const materialized = materializeImages(synchronization.imageFiles);
  let markdownTemporaryPath: string | undefined;
  let outputTemporaryPath: string | undefined;
  let markdownCommitted = false;
  try {
    const blocks = parseMarkdown(synchronization.markdown, options);
    const output = renderDocx(blocks, path.dirname(resolvedInput));
    if (markdownChanged) markdownTemporaryPath = stageFile(resolvedInput, synchronization.markdown);
    outputTemporaryPath = stageFile(resolvedOutput, output);
    if (markdownTemporaryPath) {
      renameSync(markdownTemporaryPath, resolvedInput);
      markdownTemporaryPath = undefined;
      markdownCommitted = true;
    }
    renameSync(outputTemporaryPath, resolvedOutput);
    outputTemporaryPath = undefined;
  } catch (error) {
    let rollbackError: unknown;
    if (markdownCommitted) {
      try {
        restoreMarkdown(resolvedInput, originalMarkdown);
      } catch (caught) {
        rollbackError = caught;
      }
    }
    removeCreatedImages(materialized.createdFiles, materialized.createdDirectory);
    if (rollbackError) {
      throw new AggregateError(
        [error, rollbackError],
        "DOCX conversion failed and the original Markdown could not be restored.",
      );
    }
    throw error;
  } finally {
    if (markdownTemporaryPath) rmSync(markdownTemporaryPath, { force: true });
    if (outputTemporaryPath) rmSync(outputTemporaryPath, { force: true });
  }
  return { importedImagePaths: synchronization.importedImagePaths, markdownChanged };
}

export function usage(): string {
  return [
    "Usage:",
    "  node scripts/markdown-to-docx.ts <input.md> <output.docx> [--code-appendix-threshold N]",
    "",
    "An existing output DOCX is inspected first and missing body images are synchronized into Markdown.",
    "",
    "Options:",
    "  --code-appendix-threshold N  Move fenced code blocks longer than N lines to Appendix.",
    "  --help                       Show this help.",
  ].join("\n");
}

export function runCli(argv: string[]): void {
  const parsed = parseArgs({
    args: argv,
    allowPositionals: true,
    strict: true,
    options: {
      "code-appendix-threshold": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (parsed.values.help) {
    console.log(usage());
    return;
  }
  if (parsed.positionals.length !== 2) {
    throw new Error(`${usage()}\n\nExactly one input path and one output path are required.`);
  }

  const rawThreshold = parsed.values["code-appendix-threshold"];
  let codeAppendixThreshold: number | undefined;
  if (rawThreshold !== undefined) {
    if (!/^\d+$/.test(rawThreshold)) {
      throw new RangeError("--code-appendix-threshold must be a positive integer.");
    }
    codeAppendixThreshold = Number.parseInt(rawThreshold, 10);
    if (!Number.isSafeInteger(codeAppendixThreshold) || codeAppendixThreshold < 1) {
      throw new RangeError("--code-appendix-threshold must be a positive integer.");
    }
  }
  const result = synchronizeMarkdownToDocx(parsed.positionals[0]!, parsed.positionals[1]!, {
    codeAppendixThreshold,
  });
  if (result.importedImagePaths.length > 0) {
    console.log(
      `Synchronized ${result.importedImagePaths.length} DOCX image(s) into ${path.resolve(parsed.positionals[0]!)}`,
    );
  }
  console.log(`Converted: ${path.resolve(parsed.positionals[0]!)} -> ${path.resolve(parsed.positionals[1]!)}`);
}

const entryPoint = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (entryPoint === import.meta.url) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
