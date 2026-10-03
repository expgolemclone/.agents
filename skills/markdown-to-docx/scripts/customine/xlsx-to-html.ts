import { execFileSync } from "node:child_process";
import { pythonExecutable } from "@expgolemclone/envx-runtime";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";

export type ConversionResult = {
  input: string;
  output: string;
  table_count: number;
  render_directory: string;
  page_count: number;
  pages: string[];
};

function usage(): string {
  return [
    "Usage:",
    "  node scripts/customine/xlsx-to-html.ts <input.xlsx> <output.html> --render-dir <new-directory>",
    "",
    "The output HTML and render directory must not already exist.",
  ].join("\n");
}

function requiredExecutableFromEnvironment(name: string): string | undefined {
  const configured = process.env[name];
  if (!configured) return undefined;
  const resolved = path.resolve(configured);
  if (!existsSync(resolved) || !statSync(resolved).isFile()) {
    throw new Error(`${name} does not point to an executable file: ${resolved}`);
  }
  return resolved;
}

export function resolveLibreOffice(): string {
  const configured = requiredExecutableFromEnvironment("LIBREOFFICE_PATH");
  if (configured) return configured;
  if (process.platform === "win32") {
    const programFiles = process.env.ProgramFiles;
    if (!programFiles) throw new Error("ProgramFiles is not defined.");
    const executable = path.join(programFiles, "LibreOffice", "program", "soffice.com");
    if (!existsSync(executable) || !statSync(executable).isFile()) {
      throw new Error(
        `LibreOffice CLI does not exist at ${executable}. Set LIBREOFFICE_PATH explicitly.`,
      );
    }
    return executable;
  }
  if (process.platform === "darwin") {
    const executable = "/Applications/LibreOffice.app/Contents/MacOS/soffice";
    if (!existsSync(executable) || !statSync(executable).isFile()) {
      throw new Error(
        `LibreOffice CLI does not exist at ${executable}. Set LIBREOFFICE_PATH explicitly.`,
      );
    }
    return executable;
  }
  if (process.platform === "linux") return "soffice";
  throw new Error(`Unsupported platform: ${process.platform}`);
}

function resolvePython(): string {
  return pythonExecutable();
}

function waitForNonEmptyFile(filePath: string, timeoutMilliseconds = 15_000): void {
  const deadline = Date.now() + timeoutMilliseconds;
  const waitBuffer = new Int32Array(new SharedArrayBuffer(4));
  while (Date.now() <= deadline) {
    if (existsSync(filePath) && statSync(filePath).isFile() && statSync(filePath).size > 0) return;
    Atomics.wait(waitBuffer, 0, 0, 50);
  }
  throw new Error(`Expected output was not created within ${timeoutMilliseconds} ms: ${filePath}`);
}

function runExecutable(executable: string, args: string[]): void {
  try {
    execFileSync(executable, args, { stdio: "pipe", windowsHide: true });
  } catch (error) {
    const details =
      error && typeof error === "object" && "stderr" in error && Buffer.isBuffer(error.stderr)
        ? error.stderr.toString("utf8").trim()
        : "";
    throw new Error(
      `Command failed: ${executable} ${args.join(" ")}${details ? `\n${details}` : ""}`,
      { cause: error },
    );
  }
}

function validatePaths(inputPath: string, outputPath: string, renderPath: string): void {
  if (!existsSync(inputPath) || !statSync(inputPath).isFile()) {
    throw new Error(`XLSX input does not exist or is not a file: ${inputPath}`);
  }
  if (path.extname(inputPath).toLowerCase() !== ".xlsx") {
    throw new Error(`Input must use the .xlsx extension: ${inputPath}`);
  }
  if (![".html", ".htm"].includes(path.extname(outputPath).toLowerCase())) {
    throw new Error(`Output must use the .html or .htm extension: ${outputPath}`);
  }
  if (!existsSync(path.dirname(outputPath)) || !statSync(path.dirname(outputPath)).isDirectory()) {
    throw new Error(`HTML output directory does not exist: ${path.dirname(outputPath)}`);
  }
  if (existsSync(outputPath)) {
    throw new Error(`HTML output already exists: ${outputPath}`);
  }
  if (!existsSync(path.dirname(renderPath)) || !statSync(path.dirname(renderPath)).isDirectory()) {
    throw new Error(`Render parent directory does not exist: ${path.dirname(renderPath)}`);
  }
  if (existsSync(renderPath)) {
    throw new Error(`Render directory already exists: ${renderPath}`);
  }
}

export function convertWorkbookToHtml(
  inputArgument: string,
  outputArgument: string,
  renderArgument: string,
): ConversionResult {
  const input = path.resolve(inputArgument);
  const output = path.resolve(outputArgument);
  const renderDirectory = path.resolve(renderArgument);
  validatePaths(input, output, renderDirectory);

  const workDirectory = mkdtempSync(path.join(os.tmpdir(), "customine-xlsx-html-"));
  const profile = path.join(workDirectory, "profile");
  const htmlDirectory = path.join(workDirectory, "html");
  const pdfDirectory = path.join(renderDirectory, "pdf");
  let createdOutput = false;
  let createdRenderDirectory = false;

  try {
    mkdirSync(profile);
    mkdirSync(htmlDirectory);
    mkdirSync(renderDirectory);
    createdRenderDirectory = true;
    mkdirSync(pdfDirectory);

    const libreOffice = resolveLibreOffice();
    const commonArguments = [
      "--headless",
      "--norestore",
      "--nodefault",
      "--nofirststartwizard",
      `-env:UserInstallation=${pathToFileURL(profile).href}`,
    ];
    runExecutable(libreOffice, [
      ...commonArguments,
      "--convert-to",
      "html:HTML (StarCalc)",
      "--outdir",
      htmlDirectory,
      input,
    ]);

    const generatedHtml = path.join(
      htmlDirectory,
      `${path.basename(input, path.extname(input))}.html`,
    );
    waitForNonEmptyFile(generatedHtml);
    let html = readFileSync(generatedHtml, "utf8");
    const tableCount = (html.match(/<table(?:\s|>)/gi) ?? []).length;
    if (tableCount < 1) throw new Error("LibreOffice HTML contains no worksheet tables.");

    const printCss = [
      '<style id="customine-print">',
      "  @media print {",
      "    body { margin: 0; background: white; }",
      "    table:not(:last-of-type) { break-after: page; }",
      "  }",
      "</style>",
    ].join("\n");
    if (!/<\/head>/i.test(html)) throw new Error("LibreOffice HTML has no closing head element.");
    html = html.replace(/<\/head>/i, `${printCss}\n</head>`);
    writeFileSync(output, html, "utf8");
    createdOutput = true;

    runExecutable(libreOffice, [
      ...commonArguments,
      "--convert-to",
      "pdf:writer_pdf_Export",
      "--outdir",
      pdfDirectory,
      output,
    ]);
    const pdf = path.join(
      pdfDirectory,
      `${path.basename(output, path.extname(output))}.pdf`,
    );
    waitForNonEmptyFile(pdf);
    runExecutable(resolvePython(), [
      fileURLToPath(new URL("render-pdf.py", import.meta.url)),
      pdf,
      renderDirectory,
    ]);

    const pages = readdirSync(renderDirectory)
      .filter((entry) => /^page-\d+\.png$/i.test(entry))
      .sort((left, right) => {
        const leftNumber = Number.parseInt(/\d+/.exec(left)![0], 10);
        const rightNumber = Number.parseInt(/\d+/.exec(right)![0], 10);
        return leftNumber - rightNumber;
      })
      .map((entry) => path.join(renderDirectory, entry));
    if (pages.length < 1) throw new Error("PDF renderer created no PNG pages.");

    return {
      input,
      output,
      table_count: tableCount,
      render_directory: renderDirectory,
      page_count: pages.length,
      pages,
    };
  } catch (error) {
    if (createdOutput) rmSync(output, { force: true });
    if (createdRenderDirectory) rmSync(renderDirectory, { recursive: true, force: true });
    throw error;
  } finally {
    rmSync(workDirectory, { recursive: true, force: true });
  }
}

export function runCli(argv: string[]): void {
  const parsed = parseArgs({
    args: argv,
    allowPositionals: true,
    strict: true,
    options: {
      "render-dir": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (parsed.values.help) {
    console.log(usage());
    return;
  }
  if (parsed.positionals.length !== 2 || !parsed.values["render-dir"]) {
    throw new Error(`${usage()}\n\nExactly one input, one output, and --render-dir are required.`);
  }
  console.log(JSON.stringify(
    convertWorkbookToHtml(
      parsed.positionals[0]!,
      parsed.positionals[1]!,
      parsed.values["render-dir"],
    ),
  ));
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))
) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
