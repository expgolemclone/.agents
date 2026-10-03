import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { parse, type DefaultTreeAdapterMap } from "parse5";

import { escapeMarkdownText } from "../inline-markdown.ts";
import {
  parseHtmlRgbColor,
  parseTableCellStyle,
  TABLE_CELL_EDGES,
  type ParsedTableCellStyle,
  type TableCellBorder,
  type TableCellBorders,
  type TableCellEdge,
} from "../table-cell-style.ts";
import {
  buildTableGrid,
  parsePositiveTableSpan,
  requireCompleteTableGrid,
} from "../table-grid.ts";

type Node = DefaultTreeAdapterMap["node"];
type Element = DefaultTreeAdapterMap["element"];

type SourceCell = {
  markdown: string;
  plain: string;
  header: boolean;
  colSpan: number;
  rowSpan: number;
  align?: "left" | "center" | "right" | "justify";
  verticalAlign?: "top" | "center" | "bottom";
  background?: string;
  textColor?: string;
  borders?: TableCellBorders;
};

type SourceRow = { cells: SourceCell[] };

export type ExtractedTable = {
  id: string;
  sheetName: string;
  columnCount: number;
  columnWidths?: number[];
  rows: SourceRow[];
  rowSpanRanges: Array<{ start: number; end: number }>;
};

type Selection = {
  tableId: string;
  startRow?: number;
  endRow?: number;
};

type TableHtmlOptions = {
  headerRowCount?: number;
  keepTogether?: boolean;
  keepWithNext?: boolean;
  suppressDefaultBorders?: boolean;
};

const CUSTOMINE_ACTION_LABEL = /^(?:アクション|Action)\s+[0-9]+$/u;

function usage(): string {
  return [
    "Usage:",
    "  node scripts/customine/extract-tables.ts <input.html> --list",
    "  node scripts/customine/extract-tables.ts <input.html> <new-output.md> --select <table-id[:start-end]> [--select ...]",
    "",
    "Rows are one-based and inclusive. A row range that cuts through rowspan is rejected.",
  ].join("\n");
}

function isElement(node: Node): node is Element {
  return "tagName" in node;
}

function childNodes(node: Node): Node[] {
  return "childNodes" in node ? node.childNodes : [];
}

function attribute(element: Element, name: string): string | undefined {
  return element.attrs.find((item) => item.name.toLowerCase() === name.toLowerCase())?.value;
}

function allElements(node: Node): Element[] {
  const result: Element[] = [];
  for (const child of childNodes(node)) {
    if (isElement(child)) result.push(child);
    result.push(...allElements(child));
  }
  return result;
}

function descendantElements(element: Element, tagName: string): Element[] {
  return allElements(element).filter((item) => item.tagName === tagName);
}

function directElementChildren(element: Element, tags?: Set<string>): Element[] {
  return element.childNodes.filter(
    (node): node is Element => isElement(node) && (!tags || tags.has(node.tagName)),
  );
}

function plainText(node: Node): string {
  if ("value" in node) return node.value;
  if (isElement(node) && node.tagName === "br") return "\n";
  return childNodes(node).map(plainText).join("");
}

function normalizePlainText(value: string): string {
  return value
    .replace(/\u00a0/g, " ")
    .replace(/[ \t\r\n]+/g, " ")
    .trim();
}

function escapeMarkdown(value: string): string {
  return escapeMarkdownText(value);
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttribute(value: string): string {
  return escapeHtml(value).replace(/"/g, "&quot;");
}

function inlineMarkdown(node: Node): string {
  if ("value" in node) {
    const normalized = node.value.replace(/\u00a0/g, " ").replace(/[ \t\r\n]+/g, " ");
    return escapeHtml(escapeMarkdown(normalized));
  }
  if (!isElement(node)) return "";
  if (node.tagName === "br") return "<br>";
  const content = node.childNodes.map(inlineMarkdown).join("");
  if (content.trim() === "") return content;
  if (node.tagName === "b" || node.tagName === "strong") return `**${content}**`;
  if (node.tagName === "i" || node.tagName === "em") return `*${content}*`;
  if (node.tagName === "s" || node.tagName === "strike") return `~~${content}~~`;
  return content;
}

function positiveInteger(value: string | undefined, name: string, tableId: string): number {
  return parsePositiveTableSpan(value === "" ? undefined : value, name, `in ${tableId}`);
}

function normalizeAlignment(
  value: string | undefined,
  tableId: string,
): SourceCell["align"] {
  if (value === undefined || value.trim() === "") return undefined;
  const normalized = value?.toLowerCase();
  if (
    normalized === "left" ||
    normalized === "center" ||
    normalized === "right" ||
    normalized === "justify"
  ) {
    return normalized;
  }
  throw new SyntaxError(`Unsupported align value '${value}' in ${tableId}.`);
}

function normalizeVerticalAlignment(
  value: string | undefined,
  tableId: string,
): SourceCell["verticalAlign"] {
  if (value === undefined || value.trim() === "") return undefined;
  const normalized = value?.toLowerCase();
  if (normalized === "top" || normalized === "bottom") return normalized;
  if (normalized === "middle" || normalized === "center") return "center";
  throw new SyntaxError(`Unsupported valign value '${value}' in ${tableId}.`);
}

function normalizeColor(
  value: string | undefined,
  name: string,
  tableId: string,
): string | undefined {
  const color = parseHtmlRgbColor(value, name, `in ${tableId}`);
  return color === undefined ? undefined : `#${color}`;
}

function normalizeBackground(value: string | undefined, tableId: string): string | undefined {
  return normalizeColor(value, "bgcolor", tableId);
}

function sourceCellStyle(
  parsed: ParsedTableCellStyle,
): Pick<SourceCell, "textColor" | "borders"> {
  const borders = parsed.borders === undefined
    ? undefined
    : Object.fromEntries(
      Object.entries(parsed.borders).map(([edge, border]) => [
        edge,
        border === undefined ? undefined : { ...border, color: `#${border.color}` },
      ]),
    ) as TableCellBorders;
  return {
    textColor: parsed.textColor === undefined ? undefined : `#${parsed.textColor}`,
    borders,
  };
}

function cellTextColor(
  cell: Element,
  inheritedColor: string | undefined,
  tableId: string,
): string | undefined {
  const colors = new Set<string | undefined>();
  const visit = (node: Node, color: string | undefined): void => {
    if ("value" in node) {
      if (node.value.replace(/\u00a0/g, " ").trim() !== "") colors.add(color);
      return;
    }
    if (!isElement(node)) {
      for (const child of childNodes(node)) visit(child, color);
      return;
    }
    let effectiveColor = color;
    if (node.tagName === "font") {
      const declaredColor = attribute(node, "color");
      if (declaredColor !== undefined) {
        effectiveColor = normalizeColor(declaredColor, "font color", tableId);
      }
    }
    for (const child of node.childNodes) visit(child, effectiveColor);
  };
  for (const child of cell.childNodes) visit(child, inheritedColor);
  if (colors.size === 0) return inheritedColor;
  if (colors.size > 1) {
    throw new SyntaxError(`Mixed text colors are not supported in one cell in ${tableId}.`);
  }
  return colors.values().next().value;
}

function sourceRows(table: Element, tableId: string): SourceRow[] {
  const nestedTables = descendantElements(table, "table");
  if (nestedTables.length > 0) throw new SyntaxError(`Nested tables are not supported in ${tableId}.`);
  const rows = descendantElements(table, "tr");
  if (rows.length < 1) throw new SyntaxError(`Table ${tableId} contains no rows.`);
  return rows.map((row) => {
    const cells = directElementChildren(row, new Set(["td", "th"])).map((cell): SourceCell => {
      const style = sourceCellStyle(
        parseTableCellStyle(attribute(cell, "style"), `in ${tableId}`),
      );
      const markdown = cell.childNodes
        .map(inlineMarkdown)
        .join("")
        .replace(/ +/g, " ")
        .replace(/ ?<br> ?/g, "<br>")
        .trim();
      return {
        markdown,
        plain: normalizePlainText(plainText(cell)),
        header: cell.tagName === "th",
        colSpan: positiveInteger(attribute(cell, "colspan"), "colspan", tableId),
        rowSpan: positiveInteger(attribute(cell, "rowspan"), "rowspan", tableId),
        align: normalizeAlignment(attribute(cell, "align"), tableId),
        verticalAlign: normalizeVerticalAlignment(attribute(cell, "valign"), tableId),
        background: normalizeBackground(attribute(cell, "bgcolor"), tableId),
        textColor: cellTextColor(cell, style.textColor, tableId),
        borders: style.borders,
      };
    });
    if (cells.length < 1) throw new SyntaxError(`Table ${tableId} contains an empty row.`);
    return { cells };
  });
}

function sourceColumnWidths(table: Element, tableId: string): number[] {
  const widths: number[] = [];
  for (const group of descendantElements(table, "colgroup")) {
    const columns = directElementChildren(group, new Set(["col"]));
    if (columns.length > 0) {
      for (const column of columns) {
        const rawWidth = attribute(column, "width");
        const width = Number.parseFloat(rawWidth ?? "");
        const span = positiveInteger(attribute(column, "span"), "column span", "column group");
        if (rawWidth === undefined || !Number.isFinite(width) || width <= 0) {
          throw new SyntaxError(`Column width must be positive in ${tableId}.`);
        }
        for (let index = 0; index < span; index += 1) widths.push(width);
      }
      continue;
    }
    const rawWidth = attribute(group, "width");
    const width = Number.parseFloat(rawWidth ?? "");
    const span = positiveInteger(attribute(group, "span"), "column span", "column group");
    if (rawWidth === undefined || !Number.isFinite(width) || width <= 0) {
      throw new SyntaxError(`Column width must be positive in ${tableId}.`);
    }
    for (let index = 0; index < span; index += 1) widths.push(width);
  }
  return widths;
}

function rectangularize(
  rows: SourceRow[],
  widths: number[],
  tableId: string,
): Pick<ExtractedTable, "columnCount" | "columnWidths" | "rows" | "rowSpanRanges"> {
  const sourceGrid = buildTableGrid(rows, `in ${tableId}`);
  const columnCount = Math.max(widths.length, sourceGrid.columnCount);
  const normalizedRows = sourceGrid.rows.map((gridRow, rowIndex): SourceRow => {
    const cells: SourceCell[] = [];
    for (let column = 0; column < columnCount; ) {
      const occupied = gridRow[column];
      if (occupied) {
        if (occupied.originRow === rowIndex && occupied.originColumn === column) {
          cells.push(occupied.cell);
        }
        column += occupied.cell.colSpan;
        continue;
      }
      let end = column + 1;
      while (end < columnCount && gridRow[end] === undefined) end += 1;
      cells.push({
        markdown: "",
        plain: "",
        header: false,
        colSpan: end - column,
        rowSpan: 1,
      });
      column = end;
    }
    return { cells };
  });

  let columnWidths: number[] | undefined;
  if (widths.length > 0) {
    columnWidths = widths.slice(0, columnCount);
    const missingWidth = columnWidths.at(-1)!;
    while (columnWidths.length < columnCount) columnWidths.push(missingWidth);
  }
  const normalizedGrid = buildTableGrid(normalizedRows, `in ${tableId}`);
  requireCompleteTableGrid(normalizedGrid, columnCount, `in ${tableId}`);
  return {
    columnCount,
    columnWidths,
    rows: normalizedRows,
    rowSpanRanges: sourceGrid.rowSpanRanges,
  };
}

export function extractTablesFromHtml(html: string): ExtractedTable[] {
  const document = parse(html);
  const elements = allElements(document);
  const tables = elements.filter((element) => element.tagName === "table");
  const anchorByTable = new Map<Element, Element>();
  let pendingAnchor: Element | undefined;
  for (const element of elements) {
    const name = attribute(element, "name");
    if (element.tagName === "a" && name !== undefined && /^table\d+$/i.test(name)) {
      if (pendingAnchor) {
        throw new SyntaxError("Multiple worksheet anchors occur before one table.");
      }
      pendingAnchor = element;
    } else if (element.tagName === "table") {
      if (pendingAnchor) anchorByTable.set(element, pendingAnchor);
      pendingAnchor = undefined;
    }
  }
  const tableIds = new Set<string>();
  return tables.map((table, index) => {
    const anchor = anchorByTable.get(table);
    const id = anchor ? attribute(anchor, "name")! : `table${index}`;
    if (tableIds.has(id)) throw new SyntaxError(`Duplicate worksheet table id: ${id}`);
    tableIds.add(id);
    const rows = sourceRows(table, id);
    const widths = sourceColumnWidths(table, id);
    const normalized = rectangularize(rows, widths, id);
    const anchorText = anchor ? normalizePlainText(plainText(anchor)) : "";
    const firstCell = normalized.rows[0]?.cells[0]?.plain ?? "";
    const sheetName = anchorText.replace(/^Sheet\s+\d+:\s*/i, "") || firstCell || id;
    return { id, sheetName, ...normalized };
  });
}

function parseSelection(value: string): Selection {
  const match = /^([^:]+)(?::(\d+)-(\d+))?$/.exec(value);
  if (!match) throw new SyntaxError(`Invalid selection: ${value}`);
  if (!match[2]) return { tableId: match[1]! };
  const startRow = Number.parseInt(match[2], 10);
  const endRow = Number.parseInt(match[3]!, 10);
  if (startRow < 1 || endRow < startRow) {
    throw new RangeError(`Invalid row range in selection: ${value}`);
  }
  return { tableId: match[1]!, startRow, endRow };
}

function selectedRows(table: ExtractedTable, selection: Selection): SourceRow[] {
  if (selection.startRow === undefined || selection.endRow === undefined) return table.rows;
  if (selection.endRow > table.rows.length) {
    throw new RangeError(
      `Selection ${table.id}:${selection.startRow}-${selection.endRow} exceeds ${table.rows.length} rows.`,
    );
  }
  const start = selection.startRow - 1;
  const end = selection.endRow - 1;
  for (const span of table.rowSpanRanges) {
    const intersects = span.start <= end && span.end >= start;
    const contained = span.start >= start && span.end <= end;
    if (intersects && !contained) {
      throw new RangeError(
        `Selection ${table.id}:${selection.startRow}-${selection.endRow} cuts through rowspan rows ${span.start + 1}-${span.end + 1}.`,
      );
    }
  }
  for (const range of customineActionRanges(table.rows, table.id)) {
    const intersects = range.start <= end && range.end >= start;
    const contained = range.start >= start && range.end <= end;
    if (intersects && !contained) {
      throw new RangeError(
        `Selection ${table.id}:${selection.startRow}-${selection.endRow} cuts through Customine action rows ${range.start + 1}-${range.end + 1}.`,
      );
    }
  }
  return table.rows.slice(start, end + 1);
}

function customineActionLabel(row: SourceRow, tableId: string): string | undefined {
  const labels = row.cells
    .filter((cell) => cell.background !== undefined && CUSTOMINE_ACTION_LABEL.test(cell.plain))
    .map((cell) => cell.plain);
  if (labels.length > 1) {
    throw new SyntaxError(`Multiple Customine action labels occur in one row in ${tableId}.`);
  }
  return labels[0];
}

function customineActionRanges(
  rows: SourceRow[],
  tableId: string,
): Array<{ start: number; end: number; label: string }> {
  const starts: Array<{ row: number; label: string }> = [];
  for (const [row, value] of rows.entries()) {
    const label = customineActionLabel(value, tableId);
    if (label) starts.push({ row, label });
  }
  return starts.map((start, index) => ({
    start: start.row,
    end: (starts[index + 1]?.row ?? rows.length) - 1,
    label: start.label,
  }));
}

function cloneRows(rows: SourceRow[]): SourceRow[] {
  return rows.map((row) => ({
    cells: row.cells.map((cell) => ({
      ...cell,
      borders: cell.borders ? { ...cell.borders } : undefined,
    })),
  }));
}

function sameBorder(left: TableCellBorder | undefined, right: TableCellBorder | undefined): boolean {
  if (left === undefined || right === undefined) return left === right;
  return left.widthPx === right.widthPx && left.style === right.style && left.color === right.color;
}

function isTerminalBorderRow(row: SourceRow): boolean {
  let hasTopBorder = false;
  for (const cell of row.cells) {
    if (cell.plain !== "" || cell.header || cell.background || cell.textColor || cell.rowSpan !== 1) {
      return false;
    }
    for (const edge of Object.keys(cell.borders ?? {}) as TableCellEdge[]) {
      if (edge !== "top") return false;
      hasTopBorder = true;
    }
  }
  return hasTopBorder;
}

function occupiedGrid(
  rows: SourceRow[],
  columnCount: number,
  context: string,
) {
  const grid = buildTableGrid(rows, `in ${context}`);
  return requireCompleteTableGrid(grid, columnCount, `in ${context}`);
}

function foldTerminalBorderRow(
  rows: SourceRow[],
  columnCount: number,
  tableId: string,
  actionLabel: string,
): SourceRow[] {
  const result = cloneRows(rows);
  const terminalRow = result.at(-1);
  if (!terminalRow || !isTerminalBorderRow(terminalRow)) return result;
  if (result.length < 2) {
    throw new SyntaxError(`${actionLabel} has a terminal border row without content in ${tableId}.`);
  }
  const grid = occupiedGrid(result, columnCount, `${actionLabel} in ${tableId}`);
  const terminalIndex = result.length - 1;
  const previousIndex = terminalIndex - 1;
  const bordersByCell = new Map<SourceCell, TableCellBorder | undefined>();
  for (let column = 0; column < columnCount; column += 1) {
    const terminal = grid[terminalIndex]![column]!;
    if (terminal.originRow !== terminalIndex) {
      throw new SyntaxError(`A rowspan overlaps the terminal border row of ${actionLabel} in ${tableId}.`);
    }
    const previousCell = grid[previousIndex]![column]!.cell;
    const border = terminal.cell.borders?.top;
    if (bordersByCell.has(previousCell)) {
      if (!sameBorder(bordersByCell.get(previousCell), border)) {
        throw new SyntaxError(
          `The terminal border cannot be represented on the preceding merged cell of ${actionLabel} in ${tableId}.`,
        );
      }
    } else {
      bordersByCell.set(previousCell, border);
    }
  }
  for (const [cell, border] of bordersByCell) {
    if (!border) continue;
    const existing = cell.borders?.bottom;
    if (existing && !sameBorder(existing, border)) {
      throw new SyntaxError(`Conflicting bottom border on ${actionLabel} in ${tableId}.`);
    }
    cell.borders = { ...cell.borders, bottom: border };
  }
  result.pop();
  return result;
}

function cellHtml(cell: SourceCell): string {
  const tag = cell.header ? "th" : "td";
  const attributes: string[] = [];
  if (cell.rowSpan > 1) attributes.push(`rowspan="${cell.rowSpan}"`);
  if (cell.colSpan > 1) attributes.push(`colspan="${cell.colSpan}"`);
  if (cell.align) attributes.push(`align="${cell.align}"`);
  if (cell.verticalAlign) attributes.push(`valign="${cell.verticalAlign}"`);
  if (cell.background) attributes.push(`bgcolor="${cell.background}"`);
  const style: string[] = [];
  if (cell.textColor) style.push(`color:${cell.textColor}`);
  for (const edge of TABLE_CELL_EDGES) {
    const border = cell.borders?.[edge];
    if (border) {
      style.push(`border-${edge}:${border.widthPx}px ${border.style} ${border.color}`);
    }
  }
  if (style.length > 0) attributes.push(`style="${escapeAttribute(style.join(";"))}"`);
  return `<${tag}${attributes.length ? ` ${attributes.join(" ")}` : ""}>${cell.markdown}</${tag}>`;
}

function tableHtml(
  table: ExtractedTable,
  rows: SourceRow[],
  options: TableHtmlOptions = {},
): string {
  if (rows.length === 0) throw new SyntaxError(`Cannot render an empty table for ${table.id}.`);
  const styles: string[] = [];
  if (options.keepTogether) styles.push("break-inside:avoid");
  if (options.keepWithNext) styles.push("break-after:avoid");
  if (options.suppressDefaultBorders) styles.push("border:none");
  const parts = [`<table${styles.length > 0 ? ` style="${styles.join(";")}"` : ""}>`];
  if (table.columnWidths) {
    parts.push("  <colgroup>");
    for (const width of table.columnWidths) {
      parts.push(`    <col width="${width}">`);
    }
    parts.push("  </colgroup>");
  }
  const headerRowCount = options.headerRowCount ?? 0;
  if (headerRowCount < 0 || headerRowCount > rows.length) {
    throw new RangeError(`Invalid header row count for ${table.id}.`);
  }
  if (headerRowCount > 0) {
    parts.push("  <thead>");
    for (const row of rows.slice(0, headerRowCount)) {
      parts.push(`    <tr>${row.cells.map(cellHtml).join("")}</tr>`);
    }
    parts.push("  </thead>");
  }
  if (headerRowCount < rows.length) parts.push("  <tbody>");
  for (const row of rows.slice(headerRowCount)) {
    parts.push(`    <tr>${row.cells.map(cellHtml).join("")}</tr>`);
  }
  if (headerRowCount < rows.length) parts.push("  </tbody>");
  parts.push("</table>");
  return parts.join("\n");
}

function customineTablesHtml(table: ExtractedTable, rows: SourceRow[]): string {
  const ranges = customineActionRanges(rows, table.id);
  if (ranges.length === 0) return tableHtml(table, rows);
  const grid = occupiedGrid(rows, table.columnCount, `selected rows of ${table.id}`);
  for (const range of ranges) {
    for (let column = 0; column < table.columnCount; column += 1) {
      const first = grid[range.start]![column]!;
      const last = grid[range.end]![column]!;
      if (
        first.originRow < range.start ||
        last.originRow + last.cell.rowSpan - 1 > range.end
      ) {
        throw new SyntaxError(`A rowspan crosses the boundary of ${range.label} in ${table.id}.`);
      }
    }
  }
  const parts: string[] = [];
  if (ranges[0]!.start > 0) {
    parts.push(tableHtml(table, rows.slice(0, ranges[0]!.start), {
      keepWithNext: true,
      suppressDefaultBorders: true,
    }));
  }
  for (const range of ranges) {
    const actionRows = foldTerminalBorderRow(
      rows.slice(range.start, range.end + 1),
      table.columnCount,
      table.id,
      range.label,
    );
    parts.push(tableHtml(table, actionRows, { headerRowCount: 1, keepTogether: true }));
  }
  return parts.join("\n\n");
}

export function renderSelectionsToMarkdown(
  tables: ExtractedTable[],
  selections: Selection[],
): string {
  const tableMap = new Map(tables.map((table) => [table.id, table]));
  const seen = new Set<string>();
  const sections = selections.map((selection) => {
    const key = `${selection.tableId}:${selection.startRow ?? "*"}-${selection.endRow ?? "*"}`;
    if (seen.has(key)) throw new Error(`Duplicate selection: ${key}`);
    seen.add(key);
    const table = tableMap.get(selection.tableId);
    if (!table) throw new Error(`Table not found: ${selection.tableId}`);
    const rows = selectedRows(table, selection);
    return `## ${escapeMarkdown(table.sheetName)}\n\n${customineTablesHtml(table, rows)}`;
  });
  return `${sections.join("\n\n")}\n`;
}

function tableManifest(tables: ExtractedTable[]): object[] {
  return tables.map((table) => ({
    id: table.id,
    sheet_name: table.sheetName,
    row_count: table.rows.length,
    column_count: table.columnCount,
    rows: table.rows.map((row, index) => ({
      row: index + 1,
      text: row.cells.map((cell) => cell.plain).filter(Boolean),
    })),
  }));
}

export function runCli(argv: string[]): void {
  const parsed = parseArgs({
    args: argv,
    allowPositionals: true,
    strict: true,
    options: {
      list: { type: "boolean" },
      select: { type: "string", multiple: true },
      help: { type: "boolean", short: "h" },
    },
  });
  if (parsed.values.help) {
    console.log(usage());
    return;
  }
  if (parsed.positionals.length < 1 || parsed.positionals.length > 2) {
    throw new Error(usage());
  }
  const input = path.resolve(parsed.positionals[0]!);
  if (!existsSync(input) || !statSync(input).isFile()) {
    throw new Error(`HTML input does not exist or is not a file: ${input}`);
  }
  const tables = extractTablesFromHtml(readFileSync(input, "utf8"));
  if (parsed.values.list) {
    if (parsed.positionals.length !== 1 || parsed.values.select) {
      throw new Error("--list accepts only one input path and no selections.");
    }
    console.log(JSON.stringify(tableManifest(tables)));
    return;
  }
  const selections = parsed.values.select?.map(parseSelection);
  if (parsed.positionals.length !== 2 || !selections || selections.length < 1) {
    throw new Error(`${usage()}\n\nOutput path and at least one --select are required.`);
  }
  const output = path.resolve(parsed.positionals[1]!);
  if (!existsSync(path.dirname(output)) || !statSync(path.dirname(output)).isDirectory()) {
    throw new Error(`Markdown output directory does not exist: ${path.dirname(output)}`);
  }
  if (existsSync(output)) throw new Error(`Markdown output already exists: ${output}`);
  writeFileSync(output, renderSelectionsToMarkdown(tables, selections), "utf8");
  console.log(JSON.stringify({ input, output, selection_count: selections.length }));
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
