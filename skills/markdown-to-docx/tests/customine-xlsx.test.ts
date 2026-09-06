import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { renderDocx } from "../scripts/docx-renderer.ts";
import { parseMarkdown } from "../scripts/markdown-parser.ts";
import { convertWorkbookToHtml } from "../scripts/customine/xlsx-to-html.ts";
import {
  extractTablesFromHtml,
  renderSelectionsToMarkdown,
} from "../scripts/customine/extract-tables.ts";

const LIBREOFFICE_HTML = [
  "<!doctype html><html><body>",
  '<a name="table0"><h1>Sheet 1: Customine ページ 2</h1></a>',
  '<table cellspacing="0" border="0">',
  '<colgroup width="100"></colgroup><colgroup width="240"></colgroup>',
  '<tr><td colspan="3"><b>Customine ページ 2</b></td></tr>',
  '<tr><td style="border-top: 2px solid #000000; border-left: .01px solid #112233" align="center" valign="top" bgcolor="#DDEEFF"><font color="#FFFFFF">番号</font></td><td colspan="2">設定</td></tr>',
  '<tr><td>101</td><td>申請日 &lt; 2026/04/01 &amp; **literal**</td></tr>',
  "</table>",
  '<a name="table1"><h1>Sheet 2: Customine ページ 3</h1></a>',
  "<table><tr><td>Only</td></tr></table>",
  "</body></html>",
].join("");

test("extractor normalizes LibreOffice tables without losing source text", () => {
  const tables = extractTablesFromHtml(LIBREOFFICE_HTML);
  assert.equal(tables.length, 2);
  assert.equal(tables[0]!.id, "table0");
  assert.equal(tables[0]!.sheetName, "Customine ページ 2");
  assert.equal(tables[0]!.columnCount, 3);
  assert.deepEqual(tables[0]!.columnWidths, [100, 240, 240]);
  assert.equal(tables[0]!.rows[2]!.cells.length, 3);
  assert.equal(tables[0]!.rows[2]!.cells[2]!.plain, "");

  const markdown = renderSelectionsToMarkdown(tables, [{ tableId: "table0" }]);
  assert.match(markdown, /<col width="100">/);
  assert.match(markdown, /<col width="240">/);
  assert.match(
    markdown,
    /align="center" valign="top" bgcolor="#DDEEFF" style="color:#FFFFFF;border-top:2px solid #000000;border-left:0.01px solid #112233"/,
  );
  assert.match(markdown, /\*\*Customine ページ 2\*\*/);
  assert.match(markdown, /申請日 &lt; 2026\/04\/01 &amp; \\\*\\\*literal\\\*\\\*/);
  assert.doesNotMatch(markdown, /## table0/);
});

test("Customine extraction renders through the integrated Markdown pipeline", () => {
  const markdown = renderSelectionsToMarkdown(extractTablesFromHtml(LIBREOFFICE_HTML), [
    { tableId: "table0" },
  ]);
  const docx = renderDocx(parseMarkdown(markdown), process.cwd());
  assert.equal(docx.subarray(0, 2).toString("ascii"), "PK");
});

test("single-sheet LibreOffice HTML receives a deterministic table0 id", () => {
  const tables = extractTablesFromHtml("<html><body><table><tr><td>A</td></tr></table></body></html>");
  assert.equal(tables[0]!.id, "table0");
  assert.equal(tables[0]!.sheetName, "A");
});

test("worksheet anchors bind to the following table instead of table position", () => {
  const tables = extractTablesFromHtml([
    "<html><body>",
    "<table><tr><td>Unanchored</td></tr></table>",
    '<a name="table9">Sheet 10: Anchored</a>',
    "<table><tr><td>Anchored</td></tr></table>",
    "</body></html>",
  ].join(""));
  assert.equal(tables[0]!.id, "table0");
  assert.equal(tables[0]!.sheetName, "Unanchored");
  assert.equal(tables[1]!.id, "table9");
  assert.equal(tables[1]!.sheetName, "Anchored");
});

test("extractor rejects unsupported presentation values instead of dropping them", () => {
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td align="diagonal">Value</td></tr></table>'),
    /Unsupported align value/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><colgroup width="wide"></colgroup><tr><td>Value</td></tr></table>'),
    /Column width must be positive/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td style="padding: 1px">Value</td></tr></table>'),
    /Unsupported cell style property 'padding'/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td style="border-top: 1px dashed #000000">Value</td></tr></table>'),
    /Unsupported border-top value/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td style="border-top: 0px solid #000000">Value</td></tr></table>'),
    /greater than 0px/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td><font color="white">Value</font></td></tr></table>'),
    /Unsupported font color value/,
  );
  assert.throws(
    () => extractTablesFromHtml('<table><tr><td><font color="#FFFFFF">White</font>Default</td></tr></table>'),
    /Mixed text colors/,
  );
});

test("row selections reject cuts through rowspan", () => {
  const tables = extractTablesFromHtml([
    '<a name="table0"><h1>Sheet 1: Page</h1></a>',
    "<table>",
    '<tr><td rowspan="2">A</td><td>B</td></tr>',
    "<tr><td>C</td></tr>",
    "<tr><td>D</td><td>E</td></tr>",
    "</table>",
  ].join(""));
  assert.throws(
    () => renderSelectionsToMarkdown(tables, [{ tableId: "table0", startRow: 2, endRow: 3 }]),
    /cuts through rowspan/,
  );
  assert.match(
    renderSelectionsToMarkdown(tables, [{ tableId: "table0", startRow: 1, endRow: 2 }]),
    /rowspan="2"/,
  );
});

test("Customine actions become page-aware tables without terminal border rows", () => {
  const tables = extractTablesFromHtml([
    '<a name="table0"><h1>Sheet 1: Page</h1></a>',
    "<table>",
    '<tr><td colspan="2"><b>(1) Page</b></td></tr>',
    '<tr><td bgcolor="#757171">アクション 1</td><td>有効</td></tr>',
    '<tr><td style="border-left:2px solid #000000">設定</td><td style="border-right:2px solid #000000">値</td></tr>',
    '<tr><td style="border-top:2px solid #000000"><br></td><td style="border-top:2px solid #000000"><br></td></tr>',
    '<tr><td bgcolor="#757171">アクション 2</td><td>有効</td></tr>',
    '<tr><td style="border-left:2px solid #000000">設定</td><td style="border-right:2px solid #000000">値</td></tr>',
    '<tr><td style="border-top:2px solid #000000"><br></td><td style="border-top:2px solid #000000"><br></td></tr>',
    "</table>",
  ].join(""));

  const markdown = renderSelectionsToMarkdown(tables, [{ tableId: "table0" }]);
  assert.equal(markdown.match(/<table style="break-inside:avoid">/g)?.length, 2);
  assert.equal(markdown.match(/<table style="break-after:avoid;border:none">/g)?.length, 1);
  assert.equal(markdown.match(/<thead>/g)?.length, 2);
  assert.equal(markdown.match(/<tr>/g)?.length, 5);
  assert.match(markdown, /<thead>\s*<tr><td bgcolor="#757171">アクション 1<\/td>/);
  assert.match(
    markdown,
    /<td style="border-bottom:2px solid #000000;border-left:2px solid #000000">設定<\/td>/,
  );
  assert.match(
    markdown,
    /<td style="border-right:2px solid #000000;border-bottom:2px solid #000000">値<\/td>/,
  );
  assert.doesNotMatch(markdown, /<tr><td style="border-top:2px solid #000000"><br><\/td>/);
  assert.throws(
    () => renderSelectionsToMarkdown(tables, [{ tableId: "table0", startRow: 2, endRow: 3 }]),
    /cuts through Customine action rows 2-4/,
  );

  const crossing = extractTablesFromHtml([
    "<table>",
    '<tr><td rowspan="2">Page</td><td>Title</td></tr>',
    '<tr><td bgcolor="#757171">アクション 1</td></tr>',
    "<tr><td>Setting</td><td>Value</td></tr>",
    "</table>",
  ].join(""));
  assert.throws(
    () => renderSelectionsToMarkdown(crossing, [{ tableId: "table0" }]),
    /rowspan crosses the boundary of アクション 1/,
  );
});

test("converter refuses existing destinations without deleting them", () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "customine-xlsx-safety-"));
  try {
    const input = path.join(directory, "input.xlsx");
    const output = path.join(directory, "output.html");
    const renderDirectory = path.join(directory, "render");
    const sentinel = path.join(renderDirectory, "keep.txt");
    writeFileSync(input, "fixture");
    mkdirSync(renderDirectory);
    writeFileSync(sentinel, "keep");
    assert.throws(
      () => convertWorkbookToHtml(input, output, renderDirectory),
      /Render directory already exists/,
    );
    assert.equal(existsSync(sentinel), true);

    rmSync(renderDirectory, { recursive: true, force: true });
    writeFileSync(output, "existing");
    assert.throws(
      () => convertWorkbookToHtml(input, output, renderDirectory),
      /HTML output already exists/,
    );
    assert.equal(existsSync(output), true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
