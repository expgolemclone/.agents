import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { pythonExecutable } from '@expgolemclone/envx-runtime';
import test from "node:test";
import { fileURLToPath } from "node:url";

import { renderDocx } from "../scripts/docx-renderer.ts";
import {
  moveLongCodeBlocksToAppendix,
  parseHtmlTable,
  parseMarkdown,
} from "../scripts/markdown-parser.ts";
import { synchronizeMarkdownToDocx } from "../scripts/markdown-to-docx.ts";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const SKILL_DIRECTORY = path.resolve(TEST_DIRECTORY, "..");
const CLI_PATH = path.join(SKILL_DIRECTORY, "scripts", "markdown-to-docx.ts");
const RENDER_CLI_PATH = path.join(SKILL_DIRECTORY, "scripts", "render-docx.py");
const VISUAL_FIXTURE_PATH = path.join(TEST_DIRECTORY, "fixtures", "visual-fixture.md");
const ONE_PIXEL_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg==",
  "base64",
);

async function withTempDirectory(
  run: (directory: string) => void | Promise<void>,
): Promise<void> {
  const root = process.platform === 'win32' ? 'C:/dev/tmp' : tmpdir();
  mkdirSync(root, { recursive: true });
  const directory = mkdtempSync(path.join(root, "markdown-to-docx-test-"));
  try {
    await run(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function storedZipEntry(buffer: Buffer, entryName: string): Buffer {
  let offset = 0;
  while (
    offset + 30 <= buffer.length &&
    buffer.readUInt32LE(offset) === 0x04034b50
  ) {
    const compressionMethod = buffer.readUInt16LE(offset + 8);
    const compressedSize = buffer.readUInt32LE(offset + 18);
    const nameLength = buffer.readUInt16LE(offset + 26);
    const extraLength = buffer.readUInt16LE(offset + 28);
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const name = buffer.subarray(nameStart, nameStart + nameLength).toString("utf8");
    assert.equal(compressionMethod, 0);
    if (name === entryName) return buffer.subarray(dataStart, dataStart + compressedSize);
    offset = dataStart + compressedSize;
  }
  assert.fail(`ZIP entry not found: ${entryName}`);
}

function zipXml(buffer: Buffer, entryName: string): string {
  return storedZipEntry(buffer, entryName).toString("utf8");
}

function replaceDocxPngWithJpeg(docxPath: string): void {
  const script = [
    "import io, os, sys, zipfile",
    "from PIL import Image",
    "source = sys.argv[1]",
    "temporary = source + '.tmp'",
    "image = Image.new('RGB', (2, 1), (20, 120, 220))",
    "jpeg = io.BytesIO()",
    "image.save(jpeg, format='JPEG', quality=90)",
    "with zipfile.ZipFile(source, 'r') as zin, zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as zout:",
    "    for info in zin.infolist():",
    "        name = info.filename",
    "        data = zin.read(name)",
    "        if name == 'word/media/image1.png':",
    "            name = 'word/media/image1.jpeg'",
    "            data = jpeg.getvalue()",
    "        elif name == 'word/_rels/document.xml.rels':",
    "            data = data.replace(b'media/image1.png', b'media/image1.jpeg')",
    "        elif name == '[Content_Types].xml':",
    "            data = data.replace(b'</Types>', b'<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/></Types>')",
    "        zout.writestr(name, data)",
    "os.replace(temporary, source)",
  ].join("\n");
  const converted = spawnSync(pythonExecutable(), ["-c", script, docxPath], {
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(converted.status, 0, converted.stderr);
}

function paragraphXmlContaining(documentXml: string, text: string): string {
  const paragraph = documentXml
    .match(/<w:p>.*?<\/w:p>/g)
    ?.find((candidate) => candidate.includes(`>${text}</w:t>`));
  assert.ok(paragraph, `Paragraph not found for text: ${text}`);
  return paragraph;
}

function runXmlContaining(paragraphXml: string, text: string): string {
  const run = paragraphXml
    .match(/<w:r>.*?<\/w:r>/g)
    ?.find((candidate) => candidate.includes(`>${text}</w:t>`));
  assert.ok(run, `Run not found for text: ${text}`);
  return run;
}

function abstractNumberingXml(numberingXml: string, abstractId: number): string {
  const startToken = `<w:abstractNum w:abstractNumId="${abstractId}">`;
  const start = numberingXml.indexOf(startToken);
  assert.notEqual(start, -1, `Abstract numbering definition not found: ${abstractId}`);
  const end = numberingXml.indexOf("</w:abstractNum>", start);
  assert.notEqual(end, -1, `Abstract numbering definition is incomplete: ${abstractId}`);
  return numberingXml.slice(start, end + "</w:abstractNum>".length);
}

function numberingLevelXml(abstractXml: string, level: number): string {
  const startToken = `<w:lvl w:ilvl="${level}">`;
  const start = abstractXml.indexOf(startToken);
  assert.notEqual(start, -1, `Numbering level not found: ${level}`);
  const end = abstractXml.indexOf("</w:lvl>", start);
  assert.notEqual(end, -1, `Numbering level is incomplete: ${level}`);
  return abstractXml.slice(start, end + "</w:lvl>".length);
}

function assertTypography(xml: string, sizeHalfPoints: number, bold: boolean): void {
  assert.match(xml, new RegExp(`<w:sz w:val="${sizeHalfPoints}"/>`));
  assert.match(xml, new RegExp(`<w:szCs w:val="${sizeHalfPoints}"/>`));
  if (bold) {
    assert.match(xml, /<w:b\/>/);
  } else {
    assert.doesNotMatch(xml, /<w:b\/>/);
  }
}

function wordStyleXml(stylesXml: string, styleId: string): string {
  const startToken = `<w:style w:type="paragraph" w:styleId="${styleId}">`;
  const start = stylesXml.indexOf(startToken);
  assert.notEqual(start, -1, `Word style not found: ${styleId}`);
  const end = stylesXml.indexOf("</w:style>", start);
  assert.notEqual(end, -1, `Word style is incomplete: ${styleId}`);
  return stylesXml.slice(start, end + "</w:style>".length);
}

test("parseMarkdown creates typed blocks for the supported Markdown surface", () => {
  const blocks = parseMarkdown(
    [
      "# Title",
      "",
      "Paragraph with **bold**.",
      "",
      "- bullet",
      "  - [x] task",
      "",
      "3. ordered",
      "4. next",
      "",
      "> quote",
      "",
      "---",
      "",
      "```ts",
      "const value = 1;",
      "```",
      "",
      "<!-- pagebreak -->",
    ].join("\n"),
  );

  assert.deepEqual(blocks.map((block) => block.kind), [
    "heading",
    "paragraph",
    "list",
    "list",
    "list",
    "list",
    "quote",
    "rule",
    "code",
    "pagebreak",
  ]);
  const lists = blocks.filter((block) => block.kind === "list");
  assert.deepEqual(
    lists.map((block) => ({
      kind: block.listKind,
      level: block.level,
      id: block.listId,
      start: block.start,
      text: block.text,
    })),
    [
      { kind: "bullet", level: 0, id: 1, start: 1, text: "bullet" },
      { kind: "bullet", level: 1, id: 2, start: 1, text: "☑ task" },
      { kind: "ordered", level: 0, id: 3, start: 3, text: "ordered" },
      { kind: "ordered", level: 0, id: 3, start: 3, text: "next" },
    ],
  );
});

test("parseMarkdown supports every list level and rejects ambiguous indentation", () => {
  const blocks = parseMarkdown(
    Array.from(
      { length: 9 },
      (_value, level) => `${" ".repeat(level * 2)}- level-${level}`,
    ).join("\n"),
  );
  assert.deepEqual(
    blocks.map((block) => block.kind === "list" ? block.level : undefined),
    [0, 1, 2, 3, 4, 5, 6, 7, 8],
  );
  assert.throws(() => parseMarkdown(" - invalid"), /multiples of two spaces/);
  assert.throws(() => parseMarkdown(`${" ".repeat(18)}- too-deep`), /nine levels/);
});

test("parseMarkdown supports heading levels one through four and rejects deeper headings", () => {
  const blocks = parseMarkdown(
    ["# First", "## Second", "### Third", "#### Fourth"].join("\n"),
  );
  assert.deepEqual(
    blocks.map((block) => block.kind === "heading" ? block.level : undefined),
    [1, 2, 3, 4],
  );
  assert.throws(
    () => parseMarkdown("##### Fifth"),
    /Only heading levels 1 through 4 are supported at line 1/,
  );
  assert.throws(
    () => parseMarkdown("# First\n###### Sixth"),
    /Only heading levels 1 through 4 are supported at line 2/,
  );
});

test("code appendix conversion is opt-in and preserves internal anchors", () => {
  const markdown = ["Intro", "", "```ts", "1", "2", "3", "```"].join("\n");
  assert.equal(parseMarkdown(markdown).some((block) => block.kind === "pagebreak"), false);

  const transformed = moveLongCodeBlocksToAppendix(markdown, 2);
  assert.match(transformed, /\[Appendix A\]\(#appendix_code_block_1\)/);
  assert.match(transformed, /## Appendix/);
  assert.match(transformed, /\{#appendix_code_block_1\}/);
  assert.equal(parseMarkdown(markdown, { codeAppendixThreshold: 2 }).some((block) => block.kind === "pagebreak"), true);
});

test("unclosed code fences and nonpositive appendix thresholds fail", () => {
  assert.throws(() => parseMarkdown("```ts\nconst x = 1;"), /not closed/);
  assert.throws(() => moveLongCodeBlocksToAppendix("body", 0), /positive integer/);
  assert.throws(() => parseMarkdown(":::customine\npage: A\n:::"), /Custom directives/);
});

test("parseHtmlTable materializes colspan and rowspan without overlap", () => {
  const table = parseHtmlTable(
    [
      "<table>",
      "<thead><tr><th colspan=\"2\">**Summary**</th><th>Status</th></tr></thead>",
      "<tbody>",
      "<tr><td rowspan=\"2\" style=\"border-top:2px solid #000000;border-right:1px solid #112233;border-bottom:2px solid #000000;border-left:1px solid #112233\">Area A</td><td>Task 1</td><td>Done</td></tr>",
      "<tr><td>Task 2<br>continued</td><td>Open</td></tr>",
      "</tbody>",
      "</table>",
    ].join("\n"),
    1,
  );

  assert.equal(table.columnCount, 3);
  assert.equal(table.rows[0]!.headerRow, true);
  assert.equal(table.rows[0]!.cells[0]!.colSpan, 2);
  assert.equal(table.rows[1]!.cells[0]!.verticalMerge, "restart");
  assert.equal(table.rows[2]!.cells[0]!.verticalMerge, "continue");
  assert.deepEqual(Object.keys(table.rows[1]!.cells[0]!.borders ?? {}), ["top", "right", "left"]);
  assert.deepEqual(Object.keys(table.rows[2]!.cells[0]!.borders ?? {}), ["right", "bottom", "left"]);
  assert.equal(table.rows[2]!.cells[1]!.text, "Task 2\ncontinued");
});

test("HTML table pagination keeps complete groups and repeats only explicit table rows", () => {
  const table = parseHtmlTable(
    [
      '<table style="break-inside:avoid">',
      "<thead><tr><td>Repeat row</td><td>Status</td></tr></thead>",
      "<tbody><tr><td>Final row</td><td>Done</td></tr></tbody>",
      "</table>",
    ].join(""),
    1,
  );
  assert.equal(table.keepTogether, true);
  assert.equal(table.keepWithNext, false);
  assert.equal(table.suppressDefaultBorders, false);
  assert.equal(table.rows[0]!.headerRow, true);
  assert.equal(table.rows[0]!.cells[0]!.header, false);

  const documentXml = zipXml(renderDocx([{ kind: "table", table }], process.cwd()), "word/document.xml");
  assert.match(documentXml, /<w:tblHeader\/>/);
  assert.equal(documentXml.match(/<w:keepNext\/>/g)?.length, 1);
  const firstRowXml = documentXml.match(/<w:tr>.*?<\/w:tr>/)?.[0];
  assert.ok(firstRowXml);
  assert.equal(firstRowXml.match(/<w:keepNext\/>/g)?.length, 1);
  assert.doesNotMatch(documentXml, /w:fill="EAF2FB"/);

  const blocks = parseMarkdown([
    '<table style="break-after:avoid;border:none"><tr><td>Preamble</td></tr></table>',
    "",
    '<table style="break-inside:avoid"><tr><td>Action</td></tr><tr><td>End</td></tr></table>',
  ].join("\n"));
  assert.equal(blocks[0]?.kind, "table");
  if (blocks[0]?.kind !== "table") assert.fail("Expected a table.");
  assert.equal(blocks[0].table.suppressDefaultBorders, true);
  const adjacentXml = zipXml(renderDocx(blocks, process.cwd()), "word/document.xml");
  assert.match(
    adjacentXml,
    /<\/w:tbl><w:p><w:pPr><w:keepNext\/><w:spacing w:before="0" w:after="0" w:line="1" w:lineRule="exact"\/><\/w:pPr><\/w:p><w:tbl>/,
  );
  assert.equal(adjacentXml.match(/<w:keepNext\/>/g)?.length, 3);
});

test("HTML tables reject unsupported attributes, invalid spans, and incomplete grids", () => {
  assert.throws(
    () => parseHtmlTable("<table><tr><td style=\"color:red\">A</td></tr></table>", 1),
    /six-digit #RRGGBB color/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td style=\"padding:1px\">A</td></tr></table>", 1),
    /Unsupported cell style property 'padding'/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td style=\"border-top:1px dashed #000000\">A</td></tr></table>", 1),
    /Unsupported border-top value/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td style=\"border-top:0px solid #000000\">A</td></tr></table>", 1),
    /greater than 0px/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td rowspan=\"0\">A</td></tr></table>", 1),
    /positive integer/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></table>", 1),
    /grid is incomplete near line 1/,
  );
  assert.throws(
    () => parseHtmlTable("<table><tr><td><strong>A</strong></td></tr></table>", 1),
    /Unsupported <strong>/,
  );
  assert.throws(
    () => parseHtmlTable('<table style="page-break-inside:avoid"><tr><td>A</td></tr></table>', 1),
    /Unsupported table style property 'page-break-inside'/,
  );
  assert.throws(
    () => parseHtmlTable('<table style="border:solid"><tr><td>A</td></tr></table>', 1),
    /Unsupported border value/,
  );
});

test("pipe tables require the same number of cells on every row", () => {
  assert.throws(
    () => parseMarkdown("| A | B |\n| --- | --- |\n| only one |"),
    /has 1 cells, expected 2/,
  );
});

test("pipe tables preserve escaped pipes and pipes inside code spans", () => {
  const blocks = parseMarkdown([
    "| Value | Code |",
    "| --- | --- |",
    "| left \\| right | `x|y` |",
  ].join("\n"));
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0]!.kind, "table");
  if (blocks[0]!.kind !== "table") assert.fail("Expected a table.");
  assert.equal(blocks[0]!.table.rows[1]!.cells[0]!.text, "left \\| right");
  assert.equal(blocks[0]!.table.rows[1]!.cells[1]!.text, "`x|y`");
});

test("HTML tables support explicit widths, colors, borders, alignment, and escaped Markdown", () => {
  const table = parseHtmlTable([
    "<table>",
    "<colgroup><col width=\"100\"><col width=\"300\"></colgroup>",
    "<tr><td align=\"center\" valign=\"top\" bgcolor=\"#ABCDEF\" style=\"color:#FFFFFF;border-top:2px solid #000000;border-right:1px solid #112233;border-bottom:2px solid #000000;border-left:.01px solid #112233\">\\*\\*literal\\*\\*</td><td>**formatted**</td></tr>",
    "</table>",
  ].join("\n"), 1);
  assert.deepEqual(table.columnWidths, [100, 300]);
  assert.equal(table.rows[0]!.cells[0]!.align, "center");
  assert.equal(table.rows[0]!.cells[0]!.verticalAlign, "top");
  assert.equal(table.rows[0]!.cells[0]!.background, "ABCDEF");
  assert.equal(table.rows[0]!.cells[0]!.textColor, "FFFFFF");
  assert.deepEqual(table.rows[0]!.cells[0]!.borders, {
    top: { widthPx: 2, style: "solid", color: "000000" },
    right: { widthPx: 1, style: "solid", color: "112233" },
    bottom: { widthPx: 2, style: "solid", color: "000000" },
    left: { widthPx: 0.01, style: "solid", color: "112233" },
  });

  const documentXml = zipXml(renderDocx([{ kind: "table", table }], process.cwd()), "word/document.xml");
  assert.match(documentXml, /<w:tblLayout w:type="fixed"\/>/);
  assert.match(documentXml, /<w:gridCol w:w="2256"\/>/);
  assert.match(documentXml, /<w:gridCol w:w="6770"\/>/);
  assert.match(documentXml, /<w:jc w:val="center"\/>/);
  assert.match(documentXml, /<w:vAlign w:val="top"\/>/);
  assert.match(documentXml, /<w:shd w:val="clear" w:color="auto" w:fill="ABCDEF"\/>/);
  assert.match(documentXml, /<w:tcBorders><w:top w:val="single" w:sz="12" w:space="0" w:color="000000"\/><w:left w:val="single" w:sz="2" w:space="0" w:color="112233"\/><w:bottom w:val="single" w:sz="12" w:space="0" w:color="000000"\/><w:right w:val="single" w:sz="6" w:space="0" w:color="112233"\/><\/w:tcBorders>/);
  assert.match(documentXml, /<w:color w:val="FFFFFF"\/><\/w:rPr><w:t xml:space="preserve">\*\*literal\*\*<\/w:t>/);
  assert.match(documentXml, /<w:tblBorders><w:top w:val="nil"\/>/);
  assert.doesNotMatch(documentXml, /<w:tblStyle w:val="TableGrid"\/>/);
  assert.match(documentXml, /<w:t xml:space="preserve">\*\*literal\*\*<\/w:t>/);
  assert.match(documentXml, /<w:b\/><\/w:rPr><w:t xml:space="preserve">formatted<\/w:t>/);

  const plainTable = parseHtmlTable("<table><tr><td>A</td></tr></table>", 1);
  const plainXml = zipXml(renderDocx([{ kind: "table", table: plainTable }], process.cwd()), "word/document.xml");
  assert.match(plainXml, /<w:tblStyle w:val="TableGrid"\/>/);
});

test("renderDocx writes real numbering, merged cells, links, and styles", () => {
  const blocks = parseMarkdown(
    [
      "# Report",
      "",
      "- [link](https://example.test)",
      "  - child",
      "",
      "1. first",
      "2. second",
      "",
      "<table>",
      "<tr><th colspan=\"2\">Header</th></tr>",
      "<tr><td rowspan=\"2\">A</td><td>B</td></tr>",
      "<tr><td>C</td></tr>",
      "</table>",
    ].join("\n"),
  );
  const buffer = renderDocx(blocks, process.cwd());
  const documentXml = zipXml(buffer, "word/document.xml");
  const numberingXml = zipXml(buffer, "word/numbering.xml");
  const relsXml = zipXml(buffer, "word/_rels/document.xml.rels");

  assert.equal(buffer.subarray(0, 2).toString("ascii"), "PK");
  assert.match(documentXml, /<w:numPr>/);
  assert.match(documentXml, /<w:gridSpan w:val="2"\/>/);
  assert.match(documentXml, /<w:vMerge w:val="restart"\/>/);
  assert.match(documentXml, /<w:vMerge w:val="continue"\/>/);
  assert.match(numberingXml, /<w:abstractNum w:abstractNumId="0">/);
  assert.match(numberingXml, /<w:abstractNum w:abstractNumId="1">/);
  assert.match(numberingXml, /<w:startOverride w:val="1"\/>|<w:num w:numId=/);
  assert.match(relsXml, /Target="https:\/\/example\.test" TargetMode="External"/);
  assert.match(zipXml(buffer, "word/styles.xml"), /w:styleId="Heading4"/);
});

test("nested ordered lists keep their starts and restart under each parent", () => {
  const blocks = parseMarkdown([
    "- Parent", "  3. Child three", "  4. Child four",
    "- Other parent", "  7. Child seven", "  8. Child eight",
    "1. Ordered parent", "  5. Child five", "  6. Child six",
    "2. Next parent", "  1. Child one",
  ].join("\n"));
  const lists = blocks.filter((block) => block.kind === "list");
  for (const [first, second] of [[1, 2], [4, 5], [7, 8]]) {
    assert.equal(lists[first!]!.listId, lists[second!]!.listId);
  }
  assert.equal(new Set([lists[1]!.listId, lists[4]!.listId, lists[7]!.listId, lists[10]!.listId]).size, 4);
  assert.equal(lists[6]!.listId, lists[9]!.listId);
  const numbering = zipXml(renderDocx(blocks, process.cwd()), "word/numbering.xml");
  for (const index of [1, 4, 7]) {
    const child = lists[index]!;
    assert.match(numbering, new RegExp(`<w:num w:numId="${child.listId}"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="1"><w:startOverride w:val="${child.start}"/>`));
  }
});

test("fully spanned HTML rows produce valid continuation cells", () => {
  const table = parseHtmlTable('<table><tr><td colspan="2" rowspan="3">A</td></tr><tr></tr><tr></tr></table>', 1);
  assert.equal(table.rows.length, 3);
  assert.deepEqual(table.rows.map((row) => row.cells[0]!.verticalMerge), ["restart", "continue", "continue"]);
  assert.ok(table.rows.every((row) => row.cells[0]!.colSpan === 2));
  const document = zipXml(renderDocx([{ kind: "table", table }], process.cwd()), "word/document.xml");
  assert.equal(document.match(/<w:vMerge w:val="continue"\/>/g)?.length, 2);
});

test("renderDocx preserves backslashes inside inline code and pipe-table code spans", () => {
  const blocks = parseMarkdown('`a\\*b`\n\n| Value | Code |\n| --- | --- |\n| literal | ``a`b\\*c|d`` |');
  const document = zipXml(renderDocx(blocks, process.cwd()), "word/document.xml");
  assert.ok(document.includes('>a\\*b</w:t>'));
  assert.ok(document.includes('>a`b\\*c|d</w:t>'));
});

test("renderDocx scales heading typography from the list hierarchy", () => {
  const blocks = parseMarkdown(
    ["# First", "## Second", "### Third", "#### Fourth"].join("\n"),
  );
  const stylesXml = zipXml(renderDocx(blocks, process.cwd()), "word/styles.xml");
  const sizesHalfPoints = [45, 39, 35, 30];

  for (const [index, sizeHalfPoints] of sizesHalfPoints.entries()) {
    assertTypography(wordStyleXml(stylesXml, `Heading${index + 1}`), sizeHalfPoints, true);
  }
  assert.doesNotMatch(stylesXml, /w:styleId="Heading[56]"/);
});

test("renderDocx applies list hierarchy typography to content and markers", () => {
  const blocks = parseMarkdown(
    [
      "- bullet-level-1",
      "  - bullet-level-2",
      "    - [x] task-level-3 with [link](https://example.test), `code`, *italic*, and ~~strike~~",
      "      - bullet-level-4 with **explicit-bold**",
      "        - bullet-level-5",
      "",
      "1. ordered-level-1",
      "  1. ordered-level-2",
      "    1. ordered-level-3",
      "      1. ordered-level-4",
      "        1. ordered-level-5",
    ].join("\n"),
  );
  const buffer = renderDocx(blocks, process.cwd());
  const documentXml = zipXml(buffer, "word/document.xml");
  const numberingXml = zipXml(buffer, "word/numbering.xml");
  const expectedTypography = [
    { sizeHalfPoints: 30, bold: true },
    { sizeHalfPoints: 26, bold: true },
    { sizeHalfPoints: 23, bold: false },
    { sizeHalfPoints: 20, bold: false },
    { sizeHalfPoints: 20, bold: false },
  ];
  const bulletTexts = [
    "bullet-level-1",
    "bullet-level-2",
    "☑ task-level-3 with ",
    "bullet-level-4 with ",
    "bullet-level-5",
  ];

  for (const [level, typography] of expectedTypography.entries()) {
    const bulletText = bulletTexts[level]!;
    const bulletParagraph = paragraphXmlContaining(documentXml, bulletText);
    const bulletRun = runXmlContaining(bulletParagraph, bulletText);
    assertTypography(bulletRun, typography.sizeHalfPoints, typography.bold);

    const orderedParagraph = paragraphXmlContaining(documentXml, `ordered-level-${level + 1}`);
    const orderedRun = runXmlContaining(orderedParagraph, `ordered-level-${level + 1}`);
    assertTypography(orderedRun, typography.sizeHalfPoints, typography.bold);

    for (const abstractId of [0, 1]) {
      const levelXml = numberingLevelXml(
        abstractNumberingXml(numberingXml, abstractId),
        level,
      );
      assertTypography(levelXml, typography.sizeHalfPoints, typography.bold);
    }
  }

  const taskParagraph = paragraphXmlContaining(documentXml, "link");
  assertTypography(runXmlContaining(taskParagraph, "☑ task-level-3 with "), 23, false);
  for (const text of ["link", "code", "italic", "strike"]) {
    assertTypography(runXmlContaining(taskParagraph, text), 23, false);
  }

  const explicitBoldParagraph = paragraphXmlContaining(documentXml, "explicit-bold");
  assertTypography(runXmlContaining(explicitBoldParagraph, "bullet-level-4 with "), 20, false);
  assertTypography(runXmlContaining(explicitBoldParagraph, "explicit-bold"), 20, true);
});

test("renderer rejects unsupported link protocols and inline images", () => {
  assert.throws(
    () => renderDocx(parseMarkdown("[local](relative.html)"), process.cwd()),
    /absolute URLs/,
  );
  assert.throws(
    () => renderDocx(parseMarkdown("Text ![image](image.png) inline"), process.cwd()),
    /standalone paragraphs/,
  );
});

test("synchronizeMarkdownToDocx resolves PNG images relative to the Markdown file", () =>
  withTempDirectory((directory) => {
    const imageDirectory = path.join(directory, "images");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    mkdirSync(imageDirectory);
    writeFileSync(path.join(imageDirectory, "pixel.png"), ONE_PIXEL_PNG);
    writeFileSync(
      inputPath,
      "# Image\n\n![One pixel](images/pixel.png)",
      "utf8",
    );

    synchronizeMarkdownToDocx(inputPath, outputPath);

    const buffer = readFileSync(outputPath);
    assert.equal(buffer.subarray(0, 2).toString("ascii"), "PK");
    assert.deepEqual(storedZipEntry(buffer, "word/media/image1.png"), ONE_PIXEL_PNG);
    assert.match(zipXml(buffer, "word/document.xml"), /descr="One pixel"/);
  }));

test("absolute local PNG paths work in conversion and image synchronization", () =>
  withTempDirectory((directory) => {
    const seedPath = path.join(directory, "seed.png");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(seedPath, ONE_PIXEL_PNG);
    for (const imagePath of [seedPath, seedPath.replace(/\\/g, "/")]) {
      rmSync(outputPath, { force: true });
      writeFileSync(inputPath, `Before\n\n![Existing](${imagePath})\n\n![Missing](${imagePath})\n\nAfter`);
      synchronizeMarkdownToDocx(inputPath, outputPath);
      writeFileSync(inputPath, `Before\n\n![Existing](${imagePath})\n\nAfter`);
      const result = synchronizeMarkdownToDocx(inputPath, outputPath);
      assert.equal(result.importedImagePaths.length, 1);
      assert.equal(zipXml(readFileSync(outputPath), "word/document.xml").match(/<w:drawing>/g)?.length, 2);
    }
    for (const imagePath of ["https://example.test/image.png", "data:image/png;base64,AAAA", "file:///image.png"]) {
      assert.throws(() => renderDocx(parseMarkdown(`![Remote](${imagePath})`), directory), /Remote and data/);
    }
  }));

test("repeated drawings and many hyperlinks have unique document identifiers", () =>
  withTempDirectory((directory) => {
    writeFileSync(path.join(directory, "seed.png"), ONE_PIXEL_PNG);
    const markdown = [
      "![First](seed.png)",
      Array.from({ length: 1001 }, (_, index) => `[Link ${index}](https://example.test/${index})`).join(" "),
      "![Second](seed.png)",
    ].join("\n\n");
    const buffer = renderDocx(parseMarkdown(markdown), directory);
    const document = zipXml(buffer, "word/document.xml");
    const ids = [...document.matchAll(/<wp:docPr id="(\d+)"/g)].map((match) => match[1]);
    assert.equal(ids.length, 2);
    assert.equal(new Set(ids).size, 2);
    const relationships = zipXml(buffer, "word/_rels/document.xml.rels");
    const relationshipIds = [...relationships.matchAll(/<Relationship Id="([^"]+)"/g)].map((match) => match[1]);
    assert.equal(new Set(relationshipIds).size, relationshipIds.length);
    assert.equal(relationships.match(/Type="[^"]+\/image"/g)?.length, 1);
  }));

test("conversion rejects an invalid existing DOCX without changing either source file", () =>
  withTempDirectory((directory) => {
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    const markdown = "# Preserve\n\nNew content";
    const invalidDocx = Buffer.from("existing DOCX content must survive", "utf8");
    writeFileSync(inputPath, markdown, "utf8");
    writeFileSync(outputPath, invalidDocx);

    assert.throws(
      () => synchronizeMarkdownToDocx(inputPath, outputPath),
      /not a valid ZIP package/,
    );

    assert.equal(readFileSync(inputPath, "utf8"), markdown);
    assert.deepEqual(readFileSync(outputPath), invalidDocx);
    assert.equal(existsSync(path.join(directory, "images")), false);
  }));

test("existing DOCX-only images are extracted beside Markdown and restored in place", () =>
  withTempDirectory((directory) => {
    const seedPath = path.join(directory, "seed.png");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(seedPath, ONE_PIXEL_PNG);
    writeFileSync(
      inputPath,
      "# Image sync\n\nBefore\n\n![Seed image](seed.png)\n\nAfter",
      "utf8",
    );
    synchronizeMarkdownToDocx(inputPath, outputPath);
    writeFileSync(inputPath, "# Image sync\n\nBefore\n\nAfter", "utf8");
    rmSync(seedPath);

    const result = synchronizeMarkdownToDocx(inputPath, outputPath);

    const imageFiles = readdirSync(path.join(directory, "images"));
    assert.equal(imageFiles.length, 1);
    assert.match(imageFiles[0]!, /^[0-9a-f]{64}\.png$/);
    const relativePath = `images/${imageFiles[0]!}`;
    assert.deepEqual(result.importedImagePaths, [relativePath]);
    assert.equal(result.markdownChanged, true);
    assert.equal(
      readFileSync(inputPath, "utf8"),
      `# Image sync\n\nBefore\n\n![Seed image](${relativePath})\n\nAfter`,
    );
    assert.deepEqual(readFileSync(path.join(directory, relativePath)), ONE_PIXEL_PNG);
    assert.deepEqual(storedZipEntry(readFileSync(outputPath), "word/media/image1.png"), ONE_PIXEL_PNG);

    const synchronizedMarkdown = readFileSync(inputPath, "utf8");
    const second = synchronizeMarkdownToDocx(inputPath, outputPath);
    assert.deepEqual(second.importedImagePaths, []);
    assert.equal(second.markdownChanged, false);
    assert.equal(readFileSync(inputPath, "utf8"), synchronizedMarkdown);
    assert.deepEqual(readdirSync(path.join(directory, "images")), imageFiles);
  }));

test("repeated DOCX image occurrences share one extracted file and retain their count", () =>
  withTempDirectory((directory) => {
    const seedPath = path.join(directory, "seed.png");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(seedPath, ONE_PIXEL_PNG);
    writeFileSync(
      inputPath,
      "Before\n\n![First](seed.png)\n\n![Second](seed.png)\n\nAfter",
      "utf8",
    );
    synchronizeMarkdownToDocx(inputPath, outputPath);
    writeFileSync(inputPath, "Before\n\nAfter", "utf8");
    rmSync(seedPath);

    const result = synchronizeMarkdownToDocx(inputPath, outputPath);

    assert.equal(result.importedImagePaths.length, 2);
    assert.equal(new Set(result.importedImagePaths).size, 1);
    assert.equal(readdirSync(path.join(directory, "images")).length, 1);
    assert.equal(readFileSync(inputPath, "utf8").match(/^!\[/gm)?.length, 2);
    assert.equal(zipXml(readFileSync(outputPath), "word/document.xml").match(/<w:drawing>/g)?.length, 2);
  }));

test("existing DOCX raster images are normalized from JPEG to content-addressed PNG", () =>
  withTempDirectory((directory) => {
    const seedPath = path.join(directory, "seed.png");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(seedPath, ONE_PIXEL_PNG);
    writeFileSync(inputPath, "Before\n\n![Photo](seed.png)\n\nAfter", "utf8");
    synchronizeMarkdownToDocx(inputPath, outputPath);
    replaceDocxPngWithJpeg(outputPath);
    writeFileSync(inputPath, "Before\n\nAfter", "utf8");
    rmSync(seedPath);

    const result = synchronizeMarkdownToDocx(inputPath, outputPath);

    assert.equal(result.importedImagePaths.length, 1);
    const extractedPath = path.join(directory, result.importedImagePaths[0]!);
    const extractedPng = readFileSync(extractedPath);
    assert.equal(extractedPng.subarray(1, 4).toString("ascii"), "PNG");
    const digest = createHash("sha256").update(extractedPng).digest("hex");
    assert.equal(path.basename(extractedPath), `${digest}.png`);
    assert.notDeepEqual(extractedPng, ONE_PIXEL_PNG);
    assert.deepEqual(storedZipEntry(readFileSync(outputPath), "word/media/image1.png"), extractedPng);
  }));

test("ambiguous DOCX image placement fails before changing Markdown, images, or DOCX", () =>
  withTempDirectory((directory) => {
    const seedPath = path.join(directory, "seed.png");
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(seedPath, ONE_PIXEL_PNG);
    writeFileSync(inputPath, "Same\n\n![Image](seed.png)\n\nSame", "utf8");
    synchronizeMarkdownToDocx(inputPath, outputPath);
    const markdown = "Same\n\nSame";
    writeFileSync(inputPath, markdown, "utf8");
    rmSync(seedPath);
    const originalDocx = readFileSync(outputPath);

    assert.throws(
      () => synchronizeMarkdownToDocx(inputPath, outputPath),
      /no surrounding text or table block maps uniquely/,
    );

    assert.equal(readFileSync(inputPath, "utf8"), markdown);
    assert.deepEqual(readFileSync(outputPath), originalDocx);
    assert.equal(existsSync(path.join(directory, "images")), false);
  }));

test("duplicate nearby anchors cannot be bypassed by distant unique anchors", () =>
  withTempDirectory((directory) => {
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(path.join(directory, "seed.png"), ONE_PIXEL_PNG);
    writeFileSync(inputPath, "Start\n\nRepeated\n\n![Image](seed.png)\n\nRepeated\n\nEnd");
    synchronizeMarkdownToDocx(inputPath, outputPath);
    const markdown = "Start\n\nRepeated\n\nRepeated\n\nEnd";
    writeFileSync(inputPath, markdown);
    const originalDocx = readFileSync(outputPath);
    assert.throws(() => synchronizeMarkdownToDocx(inputPath, outputPath), /maps uniquely/);
    assert.equal(readFileSync(inputPath, "utf8"), markdown);
    assert.deepEqual(readFileSync(outputPath), originalDocx);
    assert.equal(existsSync(path.join(directory, "images")), false);
  }));

test("extra Markdown anchors make a DOCX image gap ambiguous", () =>
  withTempDirectory((directory) => {
    const inputPath = path.join(directory, "report.md");
    const outputPath = path.join(directory, "report.docx");
    writeFileSync(path.join(directory, "seed.png"), ONE_PIXEL_PNG);
    for (const [docxMarkdown, markdown] of [
      ["Start\n\n![Image](seed.png)\n\nEnd", "Start\n\nNew paragraph\n\nEnd"],
      ["![Image](seed.png)\n\nEnd", "New paragraph\n\nEnd"],
      ["Start\n\n![Image](seed.png)", "Start\n\nNew paragraph"],
    ]) {
      rmSync(outputPath, { force: true });
      writeFileSync(inputPath, docxMarkdown!);
      synchronizeMarkdownToDocx(inputPath, outputPath);
      writeFileSync(inputPath, markdown!);
      const originalDocx = readFileSync(outputPath);
      assert.throws(() => synchronizeMarkdownToDocx(inputPath, outputPath), /ambiguous/);
      assert.equal(readFileSync(inputPath, "utf8"), markdown);
      assert.deepEqual(readFileSync(outputPath), originalDocx);
      assert.equal(existsSync(path.join(directory, "images")), false);
    }
  }));

test("conversion rejects unsupported image formats and missing output directories", () =>
  withTempDirectory((directory) => {
    const inputPath = path.join(directory, "report.md");
    writeFileSync(inputPath, "![Photo](photo.jpg)", "utf8");
    assert.throws(
      () => synchronizeMarkdownToDocx(inputPath, path.join(directory, "report.docx")),
      /Only PNG/,
    );
    assert.throws(
      () => synchronizeMarkdownToDocx(inputPath, path.join(directory, "missing", "report.docx")),
      /output directory does not exist/,
    );
  }));

test("tall PNG images are constrained by the printable page height", () =>
  withTempDirectory((directory) => {
    const tallPng = Buffer.from(ONE_PIXEL_PNG);
    tallPng.writeUInt32BE(100, 16);
    tallPng.writeUInt32BE(5000, 20);
    writeFileSync(path.join(directory, "tall.png"), tallPng);
    const buffer = renderDocx(parseMarkdown("![Tall](tall.png)"), directory);
    const documentXml = zipXml(buffer, "word/document.xml");
    const extent = /<wp:extent cx="(\d+)" cy="(\d+)"\/>/.exec(documentXml);
    assert.ok(extent);
    assert.ok(Number(extent[2]) <= 7_948_930);
  }));

test("CLI converts a file and reports invalid invocations with nonzero status", () =>
  withTempDirectory((directory) => {
    const inputPath = path.join(directory, "input.md");
    const outputPath = path.join(directory, "output.docx");
    writeFileSync(inputPath, "# CLI\n\nBody", "utf8");

    const success = spawnSync(
      process.execPath,
      [CLI_PATH, inputPath, outputPath, "--code-appendix-threshold", "5"],
      { cwd: SKILL_DIRECTORY, encoding: "utf8" },
    );
    assert.equal(success.status, 0, success.stderr);
    assert.match(success.stdout, /Converted:/);
    assert.equal(readFileSync(outputPath).subarray(0, 2).toString("ascii"), "PK");

    const failure = spawnSync(process.execPath, [CLI_PATH, inputPath], {
      cwd: SKILL_DIRECTORY,
      encoding: "utf8",
    });
    assert.equal(failure.status, 1);
    assert.match(failure.stderr, /Exactly one input path and one output path are required/);
  }));

test("black-box renderer returns compact JSON and one PNG path per page", { timeout: 120_000 }, () =>
  withTempDirectory((directory) => {
    const localizedDirectory = path.join(directory, "日本語");
    mkdirSync(localizedDirectory);
    const outputPath = path.join(localizedDirectory, "render.docx");
    synchronizeMarkdownToDocx(VISUAL_FIXTURE_PATH, outputPath);

    const rendered = spawnSync(pythonExecutable(), [RENDER_CLI_PATH, outputPath], {
      cwd: SKILL_DIRECTORY,
      encoding: "utf8",
      timeout: 120_000,
    });
    assert.equal(rendered.status, 0, rendered.stderr);
    assert.equal(rendered.stderr.trim(), "");
    const result = JSON.parse(rendered.stdout.trim()) as {
      output_directory: string;
      page_count: number;
      pages: string[];
    };
    try {
      assert.equal(result.page_count, result.pages.length);
      assert.ok(result.page_count > 0);
      assert.ok(result.pages.every((page) => existsSync(page)));
      assert.ok(result.pages.every((page) => readFileSync(page).subarray(1, 4).toString("ascii") === "PNG"));
    } finally {
      rmSync(result.output_directory, { recursive: true, force: true });
    }
  }));
