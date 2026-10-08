import assert from "node:assert/strict";
import test from "node:test";

import {
  inlineMarkdownTokensPlainText,
  tokenizeInlineMarkdown,
} from "../scripts/inline-markdown.ts";
import {
  parseHtmlRgbColor,
  parseTableCellStyle,
} from "../scripts/table-cell-style.ts";
import {
  buildTableGrid,
  parsePositiveTableSpan,
  requireCompleteTableGrid,
} from "../scripts/table-grid.ts";

test("inline Markdown has one token stream for rendering and plain text", () => {
  const tokens = tokenizeInlineMarkdown(
    "plain \\*literal\\* [link](https://example.test/a\\)) `code` **bold** __strong__ *italic* _em_ ~~strike~~ ![alt](image.png)",
  );

  assert.deepEqual(tokens, [
    { kind: "text", text: "plain *literal* " },
    { kind: "link", text: "link", target: "https://example.test/a)" },
    { kind: "text", text: " " },
    { kind: "code", text: "code" },
    { kind: "text", text: " " },
    { kind: "bold", text: "bold" },
    { kind: "text", text: " " },
    { kind: "bold", text: "strong" },
    { kind: "text", text: " " },
    { kind: "italic", text: "italic" },
    { kind: "text", text: " " },
    { kind: "italic", text: "em" },
    { kind: "text", text: " " },
    { kind: "strike", text: "strike" },
    { kind: "text", text: " " },
    { kind: "image", alt: "alt", target: "image.png" },
  ]);
  assert.equal(
    inlineMarkdownTokensPlainText(tokens),
    "plain *literal* link code bold strong italic em strike alt",
  );
});

test("inline code preserves literal backslashes and matching backtick delimiters", () => {
  for (const [source, text] of [
    ["`a\\*b`", "a\\*b"],
    ["`C:\\temp\\file`", "C:\\temp\\file"],
    ["`\\\\ \\`", "\\\\ \\"],
    ["`` a`b\\*c ``", "a`b\\*c"],
    ["`   `", "   "],
    ["`a\nb`", "a b"],
  ]) {
    assert.deepEqual(tokenizeInlineMarkdown(source!), [{ kind: "code", text }]);
  }
  assert.deepEqual(tokenizeInlineMarkdown("\\`literal\\`"), [{ kind: "text", text: "`literal`" }]);
});

test("table cell style parsing normalizes colors and borders", () => {
  assert.deepEqual(
    parseTableCellStyle(
      "color:#aabbcc; border-top:.01px solid #001122; border-left:16px solid #FFFFFF",
      "in table0",
    ),
    {
      textColor: "AABBCC",
      borders: {
        top: { widthPx: 0.01, style: "solid", color: "001122" },
        left: { widthPx: 16, style: "solid", color: "FFFFFF" },
      },
    },
  );
  assert.equal(parseHtmlRgbColor("#abcdef", "bgcolor", "in table0"), "ABCDEF");
  assert.equal(parseHtmlRgbColor("abcdef", "bgcolor", "in table0"), "ABCDEF");

  for (const [style, expected] of [
    ["color:#000000;color:#FFFFFF", /Duplicate cell style property 'color' in table0/],
    ["color", /Malformed cell style 'color' in table0/],
    ["padding:1px", /Unsupported cell style property 'padding' in table0/],
    ["color:red", /six-digit #RRGGBB color in table0/],
    ["border-top:1px dashed #000000", /Unsupported border-top value/],
    ["border-top:0px solid #000000", /greater than 0px/],
    ["border-top:16.01px solid #000000", /at most 16px/],
  ] as const) {
    assert.throws(() => parseTableCellStyle(style, "in table0"), expected);
  }
});

type TestCell = { id: string; colSpan: number; rowSpan: number };

function cell(id: string, colSpan = 1, rowSpan = 1): TestCell {
  return { id, colSpan, rowSpan };
}

test("table grid materializes spans and exposes origin coordinates", () => {
  const grid = buildTableGrid([
    { cells: [cell("A"), cell("B", 1, 2), cell("C")] },
    { cells: [cell("D"), cell("E")] },
  ], "in table0");
  const rows = requireCompleteTableGrid(grid, 3, "in table0");

  assert.equal(grid.columnCount, 3);
  assert.deepEqual(grid.rowSpanRanges, [{ start: 0, end: 1 }]);
  assert.equal(rows[1]![1]!.cell.id, "B");
  assert.equal(rows[1]![1]!.originRow, 0);
  assert.equal(rows[1]![2]!.cell.id, "E");
  assert.equal(rows[1]![2]!.originColumn, 2);
});

test("table grid accepts fully spanned rows but still rejects uncovered cells", () => {
  const grid = buildTableGrid([
    { cells: [cell("A", 2, 3)] },
    { cells: [] },
    { cells: [] },
  ], "in table0");
  const rows = requireCompleteTableGrid(grid, 2, "in table0");
  assert.equal(rows[2]![1]!.cell.id, "A");
  const incomplete = buildTableGrid([
    { cells: [cell("A", 1, 2), cell("B")] },
    { cells: [] },
  ], "in table0");
  assert.throws(() => requireCompleteTableGrid(incomplete, 2, "in table0"), /grid is incomplete/);
});

test("table grid rejects invalid, overlapping, out-of-range, and incomplete spans", () => {
  assert.equal(parsePositiveTableSpan(undefined, "rowspan", "in table0"), 1);
  assert.equal(parsePositiveTableSpan("2", "rowspan", "in table0"), 2);
  assert.throws(
    () => parsePositiveTableSpan("0", "rowspan", "in table0"),
    /positive integer in table0/,
  );
  assert.throws(
    () => buildTableGrid([{ cells: [cell("A", 1, 1.5)] }], "in table0"),
    /rowSpan must be a positive integer in table0/,
  );
  assert.throws(
    () => buildTableGrid([{ cells: [cell("A", 1, 2)] }], "in table0"),
    /extends beyond the final table row/,
  );
  assert.throws(
    () => buildTableGrid([
      { cells: [cell("A"), cell("B", 1, 2)] },
      { cells: [cell("C", 2)] },
    ], "in table0"),
    /Cell spans overlap in table0/,
  );

  const tooWide = buildTableGrid([{ cells: [cell("A", 3)] }], "in table0");
  assert.throws(
    () => requireCompleteTableGrid(tooWide, 2, "in table0"),
    /exceeds the 2-column grid in table0/,
  );
  const incomplete = buildTableGrid([
    { cells: [cell("A"), cell("B")] },
    { cells: [cell("C")] },
  ], "in table0");
  assert.throws(
    () => requireCompleteTableGrid(incomplete, 2, "in table0"),
    /grid is incomplete in table0/,
  );
});
