import { findInlineCodeSpan, markdownInlinePlainText } from "./inline-markdown.ts";
import {
  parseCssDeclarations,
  parseHtmlRgbColor,
  parseTableCellStyle,
  type TableCellBorder,
  type TableCellBorders,
} from "./table-cell-style.ts";
import {
  buildTableGrid,
  parsePositiveTableSpan,
  requireCompleteTableGrid,
} from "./table-grid.ts";

export { markdownInlinePlainText } from "./inline-markdown.ts";
export type { TableCellBorder, TableCellBorders } from "./table-cell-style.ts";

export const PAGE_BREAK_MARKER = "<!-- pagebreak -->";
export const MAX_LIST_LEVEL = 8;

export type HeadingLevel = 1 | 2 | 3 | 4;
export type ListLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8;
export type ListKind = "bullet" | "ordered";
export type VerticalMerge = "restart" | "continue";
export type TableImage = { path: string; alt: string; widthMm: number; heightMm: number };

export type TableCell = {
  text: string;
  image?: TableImage;
  header: boolean;
  colSpan: number;
  rowSpan: number;
  align?: "left" | "center" | "right" | "justify";
  verticalAlign?: "top" | "center" | "bottom";
  background?: string;
  textColor?: string;
  borders?: TableCellBorders;
  verticalMerge?: VerticalMerge;
};

export type TableRow = {
  cells: TableCell[];
  headerRow: boolean;
};

export type MarkdownTable = {
  columnCount: number;
  columnWidths?: number[];
  rows: TableRow[];
  keepTogether: boolean;
  keepWithNext: boolean;
  suppressDefaultBorders: boolean;
};

export type SourceRange = {
  sourceStartLine?: number;
  sourceEndLine?: number;
};

export type MarkdownBlock = SourceRange & (
  | { kind: "paragraph" | "code" | "quote"; text: string }
  | { kind: "heading"; text: string; level: HeadingLevel; bookmarkName?: string }
  | {
      kind: "list";
      text: string;
      level: ListLevel;
      listKind: ListKind;
      listId: number;
      start: number;
    }
  | { kind: "table"; table: MarkdownTable }
  | { kind: "image"; alt: string; path: string }
  | { kind: "pagebreak" }
  | { kind: "rule" }
);

type CodeFence = { marker: string; info: string };
type SourceCell = {
  text: string;
  image?: TableImage;
  header: boolean;
  colSpan: number;
  rowSpan: number;
  align?: TableCell["align"];
  verticalAlign?: TableCell["verticalAlign"];
  background?: string;
  textColor?: string;
  borders?: TableCellBorders;
};
type SourceRow = { cells: SourceCell[]; headerRow: boolean };

function parseFence(line: string): CodeFence | undefined {
  const match = /^\s*(`{3,}|~{3,})(.*)$/.exec(line);
  if (!match) return undefined;
  return { marker: match[1]!, info: match[2]!.trim() };
}

function isClosingFence(line: string, opening: CodeFence): boolean {
  const marker = opening.marker[0] === "`" ? "`" : "~";
  return new RegExp(`^\\s*${marker}{${opening.marker.length},}\\s*$`).test(line);
}

function appendixLabel(index: number): string {
  let value = index + 1;
  let label = "";
  while (value > 0) {
    value -= 1;
    label = String.fromCharCode(65 + (value % 26)) + label;
    value = Math.floor(value / 26);
  }
  return label;
}

export function moveLongCodeBlocksToAppendix(markdown: string, thresholdLines: number): string {
  if (!Number.isSafeInteger(thresholdLines) || thresholdLines < 1) {
    throw new RangeError("The code appendix threshold must be a positive integer.");
  }

  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const body: string[] = [];
  const appendices: Array<CodeFence & { label: string; anchor: string; code: string[] }> = [];

  for (let index = 0; index < lines.length; index += 1) {
    const opening = parseFence(lines[index]!);
    if (!opening) {
      body.push(lines[index]!);
      continue;
    }

    const code: string[] = [];
    let closingIndex: number | undefined;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      if (isClosingFence(lines[cursor]!, opening)) {
        closingIndex = cursor;
        break;
      }
      code.push(lines[cursor]!);
    }
    if (closingIndex === undefined) {
      throw new SyntaxError(`Code fence starting at line ${index + 1} is not closed.`);
    }

    if (code.length > thresholdLines) {
      const label = appendixLabel(appendices.length);
      const anchor = `appendix_code_block_${appendices.length + 1}`;
      appendices.push({ ...opening, label, anchor, code });
      body.push(`[Appendix ${label}](#${anchor})`);
    } else {
      body.push(lines[index]!, ...code, lines[closingIndex]!);
    }
    index = closingIndex;
  }

  if (appendices.length === 0) return markdown;
  while (body.at(-1) === "") body.pop();
  body.push("", PAGE_BREAK_MARKER, "", "## Appendix", "");
  for (const appendix of appendices) {
    body.push(
      `### Appendix ${appendix.label} {#${appendix.anchor}}`,
      "",
      `${appendix.marker}${appendix.info}`.trimEnd(),
      ...appendix.code,
      appendix.marker,
      "",
    );
  }
  body.pop();
  return body.join("\n");
}

export function splitTableRow(line: string): string[] {
  let source = line.trim();
  if (source.startsWith("|")) source = source.slice(1);
  let trailingBackslashes = 0;
  for (let index = source.length - 2; index >= 0 && source[index] === "\\"; index -= 1) {
    trailingBackslashes += 1;
  }
  if (source.endsWith("|") && trailingBackslashes % 2 === 0) {
    source = source.slice(0, -1);
  }
  const cells: string[] = [];
  let current = "";
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]!;
    if (character === "\\" && index + 1 < source.length) {
      current += character + source[index + 1]!;
      index += 1;
      continue;
    }
    if (character === "`") {
      const span = findInlineCodeSpan(source, index);
      if (!span) throw new SyntaxError("Pipe table row contains an unclosed inline code span.");
      current += source.slice(index, span.end);
      index = span.end - 1;
      continue;
    }
    if (character === "|") {
      cells.push(current.trim());
      current = "";
      continue;
    }
    current += character;
  }
  cells.push(current.trim());
  return cells;
}

export function isTableSeparator(line: string): boolean {
  const cells = splitTableRow(line);
  return cells.length > 1 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function parsePipeTable(lines: string[], startIndex: number): { table: MarkdownTable; endIndex: number } {
  const header = splitTableRow(lines[startIndex]!);
  const rows: SourceRow[] = [
    {
      headerRow: true,
      cells: header.map((text) => ({ text, header: true, colSpan: 1, rowSpan: 1 })),
    },
  ];
  let index = startIndex + 2;
  while (index < lines.length && lines[index]!.includes("|") && lines[index]!.trim() !== "") {
    const values = splitTableRow(lines[index]!);
    if (values.length !== header.length) {
      throw new SyntaxError(
        `Pipe table row at line ${index + 1} has ${values.length} cells, expected ${header.length}.`,
      );
    }
    rows.push({
      headerRow: false,
      cells: values.map((text) => ({ text, header: false, colSpan: 1, rowSpan: 1 })),
    });
    index += 1;
  }
  return { table: materializeTable(rows, startIndex + 1), endIndex: index - 1 };
}

function decodeEntities(text: string): string {
  const entities: Record<string, string> = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    quot: '"',
  };
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity: string) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
    return entities[entity.toLowerCase()] ?? match;
  });
}

function parseAttributes(raw: string, tag: string, lineNumber: number): Record<string, string> {
  const attributes: Record<string, string> = {};
  let remaining = raw.trim();
  const pattern = /^([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')\s*/;
  while (remaining !== "") {
    const match = pattern.exec(remaining);
    if (!match) throw new SyntaxError(`Invalid attribute syntax on <${tag}> near line ${lineNumber}.`);
    const name = match[1]!.toLowerCase();
    if (attributes[name] !== undefined) {
      throw new SyntaxError(`Duplicate '${name}' attribute on <${tag}> near line ${lineNumber}.`);
    }
    attributes[name] = match[2] ?? match[3] ?? "";
    remaining = remaining.slice(match[0].length);
  }
  return attributes;
}

function materializeTable(
  sourceRows: SourceRow[],
  lineNumber: number,
  columnWidths?: number[],
  tableStyle: Pick<MarkdownTable, "keepTogether" | "keepWithNext" | "suppressDefaultBorders"> = {
    keepTogether: false,
    keepWithNext: false,
    suppressDefaultBorders: false,
  },
): MarkdownTable {
  const context = `near line ${lineNumber}`;
  const tableGrid = buildTableGrid(sourceRows, context);
  const columnCount = columnWidths?.length ?? tableGrid.columnCount;
  const grid = requireCompleteTableGrid(tableGrid, columnCount, context);

  const rows = grid.map((gridRow, rowIndex): TableRow => {
    const cells: TableCell[] = [];
    for (let column = 0; column < columnCount; ) {
      const occupied = gridRow[column]!;
      if (occupied.originColumn !== column) {
        column += 1;
        continue;
      }
      const continuation = occupied.originRow < rowIndex;
      const borders = occupied.cell.borders ? { ...occupied.cell.borders } : undefined;
      if (borders && occupied.cell.rowSpan > 1) {
        if (rowIndex > occupied.originRow) delete borders.top;
        if (rowIndex < occupied.originRow + occupied.cell.rowSpan - 1) delete borders.bottom;
      }
      cells.push({
        text: continuation ? "" : occupied.cell.text,
        image: continuation ? undefined : occupied.cell.image,
        header: occupied.cell.header,
        colSpan: occupied.cell.colSpan,
        rowSpan: occupied.cell.rowSpan,
        align: occupied.cell.align,
        verticalAlign: occupied.cell.verticalAlign,
        background: occupied.cell.background,
        textColor: occupied.cell.textColor,
        borders: borders && Object.keys(borders).length > 0 ? borders : undefined,
        verticalMerge:
          occupied.cell.rowSpan > 1 ? (continuation ? "continue" : "restart") : undefined,
      });
      column += occupied.cell.colSpan;
    }
    return { cells, headerRow: sourceRows[rowIndex]!.headerRow };
  });
  return { columnCount, columnWidths, rows, ...tableStyle };
}

function cellAlignment(
  value: string | undefined,
  name: string,
  lineNumber: number,
): TableCell["align"] {
  if (value === undefined) return undefined;
  const normalized = value.toLowerCase();
  if (
    normalized === "left" ||
    normalized === "center" ||
    normalized === "right" ||
    normalized === "justify"
  ) {
    return normalized;
  }
  throw new SyntaxError(`Unsupported ${name} value near line ${lineNumber}: ${value}`);
}

function verticalAlignment(value: string | undefined, lineNumber: number): TableCell["verticalAlign"] {
  if (value === undefined) return undefined;
  const normalized = value.toLowerCase();
  if (normalized === "top" || normalized === "bottom") return normalized;
  if (normalized === "center" || normalized === "middle") return "center";
  throw new SyntaxError(`Unsupported valign value near line ${lineNumber}: ${value}`);
}

function tableStyle(
  value: string | undefined,
  lineNumber: number,
): Pick<MarkdownTable, "keepTogether" | "keepWithNext" | "suppressDefaultBorders"> {
  const result = { keepTogether: false, keepWithNext: false, suppressDefaultBorders: false };
  if (value === undefined) return result;
  const declarations = parseCssDeclarations(value, "table style", `near line ${lineNumber}`);
  for (const { property, value: declarationValue } of declarations) {
    const rawValue = declarationValue.toLowerCase();
    if (property === "break-inside" || property === "break-after") {
      if (rawValue !== "avoid") {
        throw new SyntaxError(`Unsupported ${property} value near line ${lineNumber}: ${rawValue}`);
      }
      if (property === "break-inside") result.keepTogether = true;
      else result.keepWithNext = true;
    } else if (property === "border") {
      if (rawValue !== "none") {
        throw new SyntaxError(`Unsupported border value near line ${lineNumber}: ${rawValue}`);
      }
      result.suppressDefaultBorders = true;
    } else {
      throw new SyntaxError(`Unsupported table style property '${property}' near line ${lineNumber}.`);
    }
  }
  if (declarations.length === 0) {
    throw new SyntaxError(`Table style is empty near line ${lineNumber}.`);
  }
  return result;
}

export function parseHtmlTable(html: string, lineNumber: number): MarkdownTable {
  const tokens = html.match(/<[^>]+>|[^<]+/g) ?? [];
  if (tokens.join("") !== html) throw new SyntaxError(`Malformed HTML table near line ${lineNumber}.`);

  const rows: SourceRow[] = [];
  const stack: string[] = [];
  let currentRow: SourceRow | undefined;
  let currentCell: SourceCell | undefined;
  let cellText: string[] = [];
  const columnWidths: number[] = [];
  let inHeaderSection = false;
  let sawTable = false;
  let parsedTableStyle = {
    keepTogether: false,
    keepWithNext: false,
    suppressDefaultBorders: false,
  };

  for (const token of tokens) {
    if (!token.startsWith("<")) {
      if (currentCell) cellText.push(decodeEntities(token));
      else if (token.trim() !== "") {
        throw new SyntaxError(`Text outside a table cell near line ${lineNumber}.`);
      }
      continue;
    }

    const closing = /^<\/\s*([A-Za-z][A-Za-z0-9]*)\s*>$/.exec(token);
    if (closing) {
      const tag = closing[1]!.toLowerCase();
      if (stack.at(-1) !== tag) throw new SyntaxError(`Unexpected </${tag}> near line ${lineNumber}.`);
      stack.pop();
      if (tag === "td" || tag === "th") {
        if (!currentCell || !currentRow) throw new SyntaxError(`Unexpected </${tag}> near line ${lineNumber}.`);
        currentCell.text = cellText
          .join("")
          .replace(/[ \t]*\n[ \t]*/g, " ")
          .replace(/\u000b/g, "\n")
          .trim();
        if (currentCell.image && currentCell.text !== "") {
          throw new SyntaxError(`Image cells cannot mix text and images near line ${lineNumber}.`);
        }
        currentRow.cells.push(currentCell);
        currentCell = undefined;
        cellText = [];
      } else if (tag === "tr") {
        if (!currentRow) throw new SyntaxError(`Unexpected </tr> near line ${lineNumber}.`);
        rows.push(currentRow);
        currentRow = undefined;
      } else if (tag === "thead") {
        inHeaderSection = false;
      }
      continue;
    }

    const opening = /^<\s*([A-Za-z][A-Za-z0-9]*)([^>]*)>$/.exec(token);
    if (!opening) throw new SyntaxError(`Malformed table tag near line ${lineNumber}.`);
    const tag = opening[1]!.toLowerCase();
    const selfClosing = /\/\s*>$/.test(token);
    const rawAttributes = opening[2]!.replace(/\/\s*$/, "");
    const attributes = parseAttributes(rawAttributes, tag, lineNumber);
    const allowedTags = new Set([
      "table",
      "colgroup",
      "col",
      "thead",
      "tbody",
      "tfoot",
      "tr",
      "th",
      "td",
      "br",
      "img",
    ]);
    if (!allowedTags.has(tag)) throw new SyntaxError(`Unsupported <${tag}> inside a table near line ${lineNumber}.`);

    if (tag === "img") {
      if (!currentCell || stack.at(-1) !== "td" || currentCell.image || cellText.join("").includes("\u000b")) {
        throw new SyntaxError(`An image requires its own td cell near line ${lineNumber}.`);
      }
      const unexpected = Object.keys(attributes).filter((name) => !["src", "alt", "style"].includes(name));
      if (unexpected.length > 0 || !attributes.src || attributes.alt === undefined || !attributes.style) {
        throw new SyntaxError(`An img requires only src, alt and width/height style near line ${lineNumber}.`);
      }
      const dimensions = new Map<string, number>();
      for (const { property, value } of parseCssDeclarations(attributes.style, "image style", `near line ${lineNumber}`)) {
        if (!["width", "height"].includes(property) || !/^(?:\d+(?:\.\d+)?|\.\d+)mm$/.test(value)) {
          throw new SyntaxError(`Image dimensions must be positive mm values near line ${lineNumber}.`);
        }
        const dimension = Number.parseFloat(value);
        if (!Number.isFinite(dimension) || dimension <= 0) {
          throw new SyntaxError(`Image dimensions must be positive mm values near line ${lineNumber}.`);
        }
        dimensions.set(property, dimension);
      }
      if (dimensions.size !== 2) throw new SyntaxError(`Image width and height are required near line ${lineNumber}.`);
      currentCell.image = {
        path: attributes.src, alt: attributes.alt,
        widthMm: dimensions.get("width")!, heightMm: dimensions.get("height")!,
      };
      continue;
    }
    if (tag === "br") {
      if (!currentCell || currentCell.image) throw new SyntaxError(`<br> requires a text-only table cell near line ${lineNumber}.`);
      if (Object.keys(attributes).length > 0) throw new SyntaxError(`<br> does not accept attributes near line ${lineNumber}.`);
      cellText.push("\u000b");
      continue;
    }
    if (tag === "col") {
      if (stack.at(-1) !== "colgroup") {
        throw new SyntaxError(`<col> must be directly inside <colgroup> near line ${lineNumber}.`);
      }
      const unexpected = Object.keys(attributes).filter((name) => name !== "width");
      if (unexpected.length > 0 || attributes.width === undefined) {
        throw new SyntaxError(`<col> requires only a width attribute near line ${lineNumber}.`);
      }
      const width = Number.parseFloat(attributes.width);
      if (!Number.isFinite(width) || width <= 0) {
        throw new SyntaxError(`Column width must be positive near line ${lineNumber}.`);
      }
      columnWidths.push(width);
      continue;
    }
    if (selfClosing) throw new SyntaxError(`<${tag}/> is not valid in a table near line ${lineNumber}.`);
    if (tag === "table") {
      if (sawTable || stack.length > 0) throw new SyntaxError(`Nested tables are not supported near line ${lineNumber}.`);
      const unexpected = Object.keys(attributes).filter((name) => name !== "style");
      if (unexpected.length > 0) {
        throw new SyntaxError(`Unsupported '${unexpected[0]}' attribute on <table> near line ${lineNumber}.`);
      }
      parsedTableStyle = tableStyle(attributes.style, lineNumber);
      sawTable = true;
    } else if (tag === "colgroup") {
      if (stack.at(-1) !== "table") {
        throw new SyntaxError(`<colgroup> must be directly inside <table> near line ${lineNumber}.`);
      }
      if (Object.keys(attributes).length > 0) {
        throw new SyntaxError(`<colgroup> does not accept attributes near line ${lineNumber}.`);
      }
    } else if (tag === "thead" || tag === "tbody" || tag === "tfoot") {
      if (stack.at(-1) !== "table") throw new SyntaxError(`<${tag}> must be directly inside <table>.`);
      if (Object.keys(attributes).length > 0) throw new SyntaxError(`<${tag}> does not accept attributes.`);
      if (tag === "thead") inHeaderSection = true;
    } else if (tag === "tr") {
      if (!["table", "thead", "tbody", "tfoot"].includes(stack.at(-1) ?? "")) {
        throw new SyntaxError(`<tr> is not in a table section near line ${lineNumber}.`);
      }
      if (Object.keys(attributes).length > 0) throw new SyntaxError(`<tr> does not accept attributes.`);
      currentRow = { cells: [], headerRow: inHeaderSection };
    } else {
      if (stack.at(-1) !== "tr" || !currentRow) {
        throw new SyntaxError(`<${tag}> must be directly inside <tr> near line ${lineNumber}.`);
      }
      const unexpected = Object.keys(attributes).filter(
        (name) => !["rowspan", "colspan", "align", "valign", "bgcolor", "style"].includes(name),
      );
      if (unexpected.length > 0) {
        throw new SyntaxError(`Unsupported '${unexpected[0]}' attribute on <${tag}> near line ${lineNumber}.`);
      }
      const context = `near line ${lineNumber}`;
      const parsedStyle = parseTableCellStyle(attributes.style, context);
      currentCell = {
        text: "",
        header: tag === "th",
        colSpan: parsePositiveTableSpan(attributes.colspan, "colspan", context),
        rowSpan: parsePositiveTableSpan(attributes.rowspan, "rowspan", context),
        align: cellAlignment(attributes.align, "align", lineNumber),
        verticalAlign: verticalAlignment(attributes.valign, lineNumber),
        background: parseHtmlRgbColor(attributes.bgcolor, "bgcolor", context),
        textColor: parsedStyle.textColor,
        borders: parsedStyle.borders,
      };
      cellText = [];
    }
    stack.push(tag);
  }

  if (!sawTable || stack.length > 0 || currentCell || currentRow) {
    throw new SyntaxError(`HTML table near line ${lineNumber} is not closed correctly.`);
  }
  return materializeTable(
    rows,
    lineNumber,
    columnWidths.length > 0 ? columnWidths : undefined,
    parsedTableStyle,
  );
}

function stripHeadingBookmark(text: string): { text: string; bookmarkName?: string } {
  const match = /^(.*?)\s*\{#([A-Za-z_][A-Za-z0-9_]*)\}\s*$/.exec(text);
  if (!match) return { text };
  return { text: match[1]!.trim(), bookmarkName: match[2]! };
}

export function normalizeVisibleText(text: string): string {
  return text.replace(/\s+/gu, " ").trim();
}

export function markdownBlockSignature(block: MarkdownBlock): string | undefined {
  if (block.kind === "image" || block.kind === "pagebreak" || block.kind === "rule") {
    return undefined;
  }
  if (block.kind === "table") {
    const rows = block.table.rows.map((row) =>
      row.cells
        .map((cell) => normalizeVisibleText(markdownInlinePlainText(cell.text)))
        .join("\u001f")
    );
    return `table:${rows.join("\u001e")}`;
  }
  return `paragraph:${normalizeVisibleText(markdownInlinePlainText(block.text))}`;
}

function listLevel(indent: string, lineNumber: number): ListLevel {
  const width = indent.replace(/\t/g, "    ").length;
  if (width % 2 !== 0) {
    throw new RangeError(`List indentation must use multiples of two spaces at line ${lineNumber}.`);
  }
  const level = width / 2;
  if (level > MAX_LIST_LEVEL) {
    throw new RangeError(`List nesting must not exceed nine levels at line ${lineNumber}.`);
  }
  return level as ListLevel;
}

export function parseMarkdown(
  markdown: string,
  options: { codeAppendixThreshold?: number } = {},
): MarkdownBlock[] {
  const source =
    options.codeAppendixThreshold === undefined
      ? markdown
      : moveLongCodeBlocksToAppendix(markdown, options.codeAppendixThreshold);
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const result: MarkdownBlock[] = [];
  const pending: string[] = [];
  let pendingStartLine: number | undefined;
  let pendingEndLine: number | undefined;
  let activeFence: CodeFence | undefined;
  let activeFenceStartLine: number | undefined;
  let code: string[] = [];
  let nextListId = 1;
  let activeLists: Array<{ kind: ListKind; id: number; start: number } | undefined> = [];

  const flushParagraph = (): void => {
    if (pending.length > 0) {
      result.push({
        kind: "paragraph",
        text: pending.join(" "),
        sourceStartLine: pendingStartLine,
        sourceEndLine: pendingEndLine,
      });
      pending.length = 0;
      pendingStartLine = undefined;
      pendingEndLine = undefined;
    }
  };
  const resetLists = (): void => {
    activeLists = [];
  };

  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index]!.replace(/\s+$/u, "");
    if (activeFence) {
      if (isClosingFence(raw, activeFence)) {
        result.push({
          kind: "code",
          text: code.join("\n"),
          sourceStartLine: activeFenceStartLine,
          sourceEndLine: index,
        });
        activeFence = undefined;
        activeFenceStartLine = undefined;
        code = [];
      } else {
        code.push(raw);
      }
      continue;
    }

    const fence = parseFence(raw);
    if (fence) {
      flushParagraph();
      resetLists();
      activeFence = fence;
      activeFenceStartLine = index;
      code = [];
      continue;
    }
    if (raw.trim() === "") {
      flushParagraph();
      resetLists();
      continue;
    }
    if (raw.trim() === PAGE_BREAK_MARKER) {
      flushParagraph();
      resetLists();
      result.push({ kind: "pagebreak", sourceStartLine: index, sourceEndLine: index });
      continue;
    }
    if (/^\s*<table(?:\s|>)/i.test(raw)) {
      flushParagraph();
      resetLists();
      const tableStartLine = index;
      const tableLines = [raw];
      while (!/<\/table>\s*$/i.test(tableLines.at(-1)!)) {
        index += 1;
        if (index >= lines.length) throw new SyntaxError(`HTML table starting at line ${index - tableLines.length + 1} is not closed.`);
        tableLines.push(lines[index]!);
      }
      result.push({
        kind: "table",
        table: parseHtmlTable(tableLines.join("\n"), tableStartLine + 1),
        sourceStartLine: tableStartLine,
        sourceEndLine: index,
      });
      continue;
    }
    if (/^\s*<\/?[A-Za-z]/.test(raw)) {
      throw new SyntaxError(`Raw HTML other than <table> is not supported at line ${index + 1}.`);
    }
    if (/^\s*:::/u.test(raw)) {
      throw new SyntaxError(`Custom directives are not supported at line ${index + 1}.`);
    }

    const image = /^!\[([^\]]*)\]\(([^)]+)\)$/.exec(raw.trim());
    if (image) {
      flushParagraph();
      resetLists();
      result.push({
        kind: "image",
        alt: image[1]!,
        path: image[2]!.trim(),
        sourceStartLine: index,
        sourceEndLine: index,
      });
      continue;
    }
    if (index + 1 < lines.length && raw.includes("|") && isTableSeparator(lines[index + 1]!)) {
      flushParagraph();
      resetLists();
      const parsed = parsePipeTable(lines, index);
      result.push({
        kind: "table",
        table: parsed.table,
        sourceStartLine: index,
        sourceEndLine: parsed.endIndex,
      });
      index = parsed.endIndex;
      continue;
    }

    const heading = /^(#{1,6})\s+(.+)$/.exec(raw);
    if (heading) {
      const level = heading[1]!.length;
      if (level > 4) {
        throw new SyntaxError(`Only heading levels 1 through 4 are supported at line ${index + 1}.`);
      }
      flushParagraph();
      resetLists();
      const cleaned = stripHeadingBookmark(heading[2]!.trim());
      result.push({
        kind: "heading",
        text: cleaned.text,
        level: level as HeadingLevel,
        bookmarkName: cleaned.bookmarkName,
        sourceStartLine: index,
        sourceEndLine: index,
      });
      continue;
    }
    const quote = /^>\s?(.*)$/.exec(raw);
    if (quote) {
      flushParagraph();
      resetLists();
      result.push({
        kind: "quote",
        text: quote[1]!,
        sourceStartLine: index,
        sourceEndLine: index,
      });
      continue;
    }
    if (/^(?:\s{0,3})(?:-{3,}|\*{3,}|_{3,})\s*$/.test(raw)) {
      flushParagraph();
      resetLists();
      result.push({ kind: "rule", sourceStartLine: index, sourceEndLine: index });
      continue;
    }

    const list = /^([ \t]*)([-*+]|\d+[.)])\s+(.+)$/.exec(raw);
    if (list) {
      flushParagraph();
      const listKind: ListKind = /^\d/.test(list[2]!) ? "ordered" : "bullet";
      const start = listKind === "ordered" ? Number.parseInt(list[2]!, 10) : 1;
      const level = listLevel(list[1]!, index + 1);
      activeLists.length = level + 1;
      if (activeLists[level]?.kind !== listKind) {
        activeLists[level] = { kind: listKind, id: nextListId++, start };
      }
      const activeList = activeLists[level]!;
      const task = /^\[([ xX])\]\s+(.+)$/.exec(list[3]!);
      result.push({
        kind: "list",
        text: task ? `${task[1]!.toLowerCase() === "x" ? "☑" : "☐"} ${task[2]!}` : list[3]!.trim(),
        level,
        listKind,
        listId: activeList.id,
        start: activeList.start,
        sourceStartLine: index,
        sourceEndLine: index,
      });
      continue;
    }
    resetLists();
    pendingStartLine ??= index;
    pendingEndLine = index;
    pending.push(raw.trim());
  }

  if (activeFence) {
    throw new SyntaxError(`Code fence is not closed before the end of the document.`);
  }
  flushParagraph();
  return result;
}
