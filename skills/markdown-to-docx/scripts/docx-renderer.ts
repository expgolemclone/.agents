import { readFileSync } from "node:fs";
import path from "node:path";

import { tokenizeInlineMarkdown } from "./inline-markdown.ts";
import { resolveMarkdownImagePath } from "./image-path.ts";
import type {
  HeadingLevel,
  ListKind,
  ListLevel,
  MarkdownBlock,
  MarkdownTable,
  TableCell,
} from "./markdown-parser.ts";

const W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL = "http://schemas.openxmlformats.org/package/2006/relationships";
const CT = "http://schemas.openxmlformats.org/package/2006/content-types";
const FIRST_CONTENT_RELATIONSHIP_ID = 10;

const INK = "1F2328";
const MUTED = "656D76";
const ACCENT = "0969DA";
const BORDER = "D1D9E0";
const CODE_BG = "F6F8FA";
const TABLE_HEADER_BG = "EAF2FB";
const PAGE_WIDTH_DXA = 11906;
const PAGE_HEIGHT_DXA = 16838;
const PAGE_MARGIN_DXA = 1440;
const CONTENT_WIDTH_DXA = PAGE_WIDTH_DXA - PAGE_MARGIN_DXA * 2;
const LIST_SIZE_HALF_POINTS_BY_DEPTH = [30, 26, 23, 20] as const;
const HEADING_SIZE_SCALE = 1.5;
const CSS_PX_TO_EIGHTH_POINTS = 6;
const WORD_MIN_BORDER_SIZE_EIGHTH_POINTS = 2;

type ZipEntry = { name: string; data: Buffer };
type Hyperlink = { id: string; target: string };
type ImageInfo = {
  id: string;
  target: string;
  sourcePath: string;
  widthPx: number;
  heightPx: number;
};
type ListDefinition = { listId: number; listKind: ListKind; start: number; level: ListLevel };
type RunStyle = {
  bold?: boolean;
  italic?: boolean;
  strike?: boolean;
  code?: boolean;
  hyperlink?: boolean;
  color?: string;
  sizeHalfPoints?: number;
};
type ListTypography = Required<Pick<RunStyle, "bold" | "sizeHalfPoints">>;
type RenderState = {
  bookmarkId: number;
  drawingId: number;
  relationshipId: number;
  hyperlinks: Hyperlink[];
  images: ImageInfo[];
  baseDirectory: string;
};

const CRC32_TABLE = Array.from({ length: 256 }, (_value, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value >>> 0;
});

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ byte) & 0xff]!;
  return (crc ^ 0xffffffff) >>> 0;
}

function dosTime(date = new Date()): { date: number; time: number } {
  const year = Math.max(1980, date.getFullYear());
  return {
    date: ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate(),
    time: (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2),
  };
}

function createZip(entries: ZipEntry[]): Buffer {
  const fileChunks: Buffer[] = [];
  const centralChunks: Buffer[] = [];
  const timestamp = dosTime();
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const checksum = crc32(entry.data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt16LE(timestamp.time, 10);
    local.writeUInt16LE(timestamp.date, 12);
    local.writeUInt32LE(checksum, 14);
    local.writeUInt32LE(entry.data.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(name.length, 26);
    fileChunks.push(local, name, entry.data);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(timestamp.time, 12);
    central.writeUInt16LE(timestamp.date, 14);
    central.writeUInt32LE(checksum, 16);
    central.writeUInt32LE(entry.data.length, 20);
    central.writeUInt32LE(entry.data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    centralChunks.push(central, name);
    offset += local.length + name.length + entry.data.length;
  }

  const centralSize = centralChunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...fileChunks, ...centralChunks, end]);
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(value: string): string {
  return escapeXml(value).replace(/'/g, "&apos;");
}

function runPropertyElements(options: RunStyle = {}): string {
  const props: string[] = [];
  if (options.bold) props.push("<w:b/>");
  if (options.italic) props.push("<w:i/>");
  if (options.strike) props.push("<w:strike/>");
  if (options.code) {
    props.push(
      '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Yu Gothic"/>',
      `<w:shd w:val="clear" w:color="auto" w:fill="${CODE_BG}"/>`,
    );
  }
  const color = options.color ?? (options.hyperlink ? ACCENT : undefined);
  if (color) props.push(`<w:color w:val="${color}"/>`);
  if (options.hyperlink) props.push('<w:u w:val="single"/>');
  if (options.sizeHalfPoints !== undefined) {
    props.push(
      `<w:sz w:val="${options.sizeHalfPoints}"/>`,
      `<w:szCs w:val="${options.sizeHalfPoints}"/>`,
    );
  }
  return props.join("");
}

function runProps(options: RunStyle = {}): string {
  const properties = runPropertyElements(options);
  return properties === "" ? "" : `<w:rPr>${properties}</w:rPr>`;
}

function textRun(text: string, props = ""): string {
  if (text === "") return "";
  return `<w:r>${props}${text
    .split("\n")
    .map(
      (part, index) =>
        `${index === 0 ? "" : "<w:br/>"}<w:t xml:space="preserve">${escapeXml(part)}</w:t>`,
    )
    .join("")}</w:r>`;
}

function hyperlinkRun(
  label: string,
  target: string,
  state: RenderState,
  style: RunStyle = {},
): string {
  const run = textRun(label, runProps({ ...style, hyperlink: true }));
  if (target.startsWith("#")) {
    const anchor = target.slice(1);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(anchor)) {
      throw new SyntaxError(`Invalid internal link target: ${target}`);
    }
    return `<w:hyperlink w:anchor="${escapeAttr(anchor)}" w:history="1">${run}</w:hyperlink>`;
  }
  let url: URL;
  try {
    url = new URL(target);
  } catch {
    throw new SyntaxError(`External links must use absolute URLs: ${target}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:" && url.protocol !== "mailto:") {
    throw new SyntaxError(`Unsupported link protocol: ${url.protocol}`);
  }
  const id = `rId${state.relationshipId++}`;
  state.hyperlinks.push({ id, target });
  return `<w:hyperlink r:id="${id}" w:history="1">${run}</w:hyperlink>`;
}

function inlineXml(text: string, state: RenderState, defaultStyle: RunStyle = {}): string {
  const inlineRunProps = (style: RunStyle = {}): string =>
    runProps({
      ...defaultStyle,
      ...style,
      bold: defaultStyle.bold === true || style.bold === true,
    });
  const runs: string[] = [];
  for (const token of tokenizeInlineMarkdown(text)) {
    if (token.kind === "image") {
      throw new SyntaxError("Markdown images must be standalone paragraphs.");
    }
    if (token.kind === "link") {
      runs.push(
        hyperlinkRun(
          token.text,
          token.target,
          state,
          {
            ...defaultStyle,
            bold: defaultStyle.bold === true,
          },
        ),
      );
    } else if (token.kind === "code") {
      runs.push(textRun(token.text, inlineRunProps({ code: true })));
    } else if (token.kind === "bold") {
      runs.push(textRun(token.text, inlineRunProps({ bold: true })));
    } else if (token.kind === "strike") {
      runs.push(textRun(token.text, inlineRunProps({ strike: true })));
    } else if (token.kind === "italic") {
      runs.push(textRun(token.text, inlineRunProps({ italic: true })));
    } else {
      runs.push(textRun(token.text, inlineRunProps()));
    }
  }
  return runs.join("");
}

function tableCellXml(
  cell: TableCell,
  state: RenderState,
  width: number,
  keepWithNext: boolean,
): string {
  const span = cell.colSpan > 1 ? `<w:gridSpan w:val="${cell.colSpan}"/>` : "";
  const merge = cell.verticalMerge ? `<w:vMerge w:val="${cell.verticalMerge}"/>` : "";
  const fillColor = cell.background ?? (cell.header ? TABLE_HEADER_BG : undefined);
  const fill = fillColor
    ? `<w:shd w:val="clear" w:color="auto" w:fill="${fillColor}"/>`
    : "";
  const borderElements = (["top", "left", "bottom", "right"] as const)
    .map((edge) => {
      const border = cell.borders?.[edge];
      if (!border) return "";
      const sizeEighthPoints = Math.max(
        WORD_MIN_BORDER_SIZE_EIGHTH_POINTS,
        Math.round(border.widthPx * CSS_PX_TO_EIGHTH_POINTS),
      );
      return `<w:${edge} w:val="single" w:sz="${sizeEighthPoints}" w:space="0" w:color="${border.color}"/>`;
    })
    .join("");
  const borders = borderElements === "" ? "" : `<w:tcBorders>${borderElements}</w:tcBorders>`;
  const verticalAlignment = cell.verticalAlign ?? "center";
  const paragraphAlignment = cell.align
    ? `<w:jc w:val="${cell.align === "justify" ? "both" : cell.align}"/>`
    : "";
  const content = cell.verticalMerge === "continue"
    ? ""
    : inlineXml(cell.text, state, { bold: cell.header, color: cell.textColor });
  const pagination = keepWithNext ? "<w:keepNext/>" : "";
  return `<w:tc><w:tcPr><w:tcW w:w="${width}" w:type="dxa"/>${span}${merge}${fill}${borders}<w:vAlign w:val="${verticalAlignment}"/><w:tcMar><w:top w:w="80" w:type="dxa"/><w:left w:w="120" w:type="dxa"/><w:bottom w:w="80" w:type="dxa"/><w:right w:w="120" w:type="dxa"/></w:tcMar></w:tcPr><w:p><w:pPr>${pagination}${paragraphAlignment}<w:spacing w:before="0" w:after="0" w:line="280" w:lineRule="auto"/></w:pPr>${content}</w:p></w:tc>`;
}

function tableXml(table: MarkdownTable, state: RenderState): string {
  const weights = table.columnWidths ?? Array.from({ length: table.columnCount }, () => 1);
  const totalWeight = weights.reduce((sum, value) => sum + value, 0);
  const gridWidths: number[] = [];
  let assignedWidth = 0;
  for (let index = 0; index < table.columnCount; index += 1) {
    const width = index === table.columnCount - 1
      ? CONTENT_WIDTH_DXA - assignedWidth
      : Math.floor(CONTENT_WIDTH_DXA * weights[index]! / totalWeight);
    gridWidths.push(width);
    assignedWidth += width;
  }
  const grid = gridWidths.map((width) => `<w:gridCol w:w="${width}"/>`).join("");
  const rows = table.rows
    .map((row, rowIndex) => {
      const header = row.headerRow ? "<w:tblHeader/>" : "";
      const keepWithNext =
        (table.keepTogether && rowIndex < table.rows.length - 1) ||
        (table.keepWithNext && rowIndex === table.rows.length - 1);
      let column = 0;
      const cells = row.cells.map((cell, cellIndex) => {
        const width = gridWidths
          .slice(column, column + cell.colSpan)
          .reduce((sum, value) => sum + value, 0);
        column += cell.colSpan;
        return tableCellXml(cell, state, width, keepWithNext && cellIndex === row.cells.length - 1);
      }).join("");
      return `<w:tr><w:trPr>${header}<w:cantSplit/></w:trPr>${cells}</w:tr>`;
    })
    .join("");
  const layout = table.columnWidths ? "fixed" : "autofit";
  const tableWidth = table.columnWidths
    ? `<w:tblW w:w="${CONTENT_WIDTH_DXA}" w:type="dxa"/>`
    : '<w:tblW w:w="0" w:type="auto"/>';
  const hasExplicitBorders = table.rows.some((row) => row.cells.some((cell) => cell.borders));
  const borderPolicy = table.suppressDefaultBorders || hasExplicitBorders
    ? '<w:tblBorders><w:top w:val="nil"/><w:left w:val="nil"/><w:bottom w:val="nil"/><w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/></w:tblBorders>'
    : '<w:tblStyle w:val="TableGrid"/>';
  return `<w:tbl><w:tblPr>${borderPolicy}${tableWidth}<w:tblLayout w:type="${layout}"/><w:tblInd w:w="120" w:type="dxa"/></w:tblPr><w:tblGrid>${grid}</w:tblGrid>${rows}</w:tbl>`;
}

function parsePngSize(data: Buffer, sourcePath: string): { widthPx: number; heightPx: number } {
  if (data.length < 24 || data.toString("ascii", 1, 4) !== "PNG") {
    throw new Error(`Image is not a valid PNG file: ${sourcePath}`);
  }
  return { widthPx: data.readUInt32BE(16), heightPx: data.readUInt32BE(20) };
}

function registerImage(markdownPath: string, state: RenderState): ImageInfo {
  const sourcePath = resolveMarkdownImagePath(markdownPath, state.baseDirectory);
  const existing = state.images.find((image) => image.sourcePath === sourcePath);
  if (existing) return existing;
  const data = readFileSync(sourcePath);
  const { widthPx, heightPx } = parsePngSize(data, sourcePath);
  const imageNumber = state.images.length + 1;
  const image: ImageInfo = {
    id: `rId${state.relationshipId++}`,
    target: `media/image${imageNumber}.png`,
    sourcePath,
    widthPx,
    heightPx,
  };
  state.images.push(image);
  return image;
}

function imageParagraphXml(markdownPath: string, alt: string, state: RenderState): string {
  const image = registerImage(markdownPath, state);
  const maxWidthEmu = CONTENT_WIDTH_DXA * 635;
  const maxHeightEmu = (PAGE_HEIGHT_DXA - PAGE_MARGIN_DXA * 2 - 1440) * 635;
  let widthEmu = Math.round(image.widthPx * 9525);
  let heightEmu = Math.round(image.heightPx * 9525);
  const ratio = Math.min(1, maxWidthEmu / widthEmu, maxHeightEmu / heightEmu);
  if (ratio < 1) {
    widthEmu = Math.round(widthEmu * ratio);
    heightEmu = Math.round(heightEmu * ratio);
  }
  const docPrId = state.drawingId++;
  return `<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="80" w:after="120"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="${widthEmu}" cy="${heightEmu}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="${docPrId}" name="Picture ${docPrId}" descr="${escapeAttr(alt)}"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="${escapeAttr(path.basename(image.sourcePath))}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="${image.id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${widthEmu}" cy="${heightEmu}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>`;
}

function paragraphXml(block: MarkdownBlock, state: RenderState): string {
  switch (block.kind) {
    case "pagebreak":
      return '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';
    case "rule":
      return `<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="6" w:color="${BORDER}"/></w:pBdr><w:spacing w:before="80" w:after="80"/></w:pPr></w:p>`;
    case "table":
      return tableXml(block.table, state);
    case "image":
      return imageParagraphXml(block.path, block.alt, state);
    case "heading": {
      const bookmarkId = state.bookmarkId;
      const start = block.bookmarkName
        ? `<w:bookmarkStart w:id="${bookmarkId}" w:name="${escapeAttr(block.bookmarkName)}"/>`
        : "";
      const end = block.bookmarkName ? `<w:bookmarkEnd w:id="${bookmarkId}"/>` : "";
      if (block.bookmarkName) state.bookmarkId += 1;
      return `<w:p><w:pPr><w:pStyle w:val="Heading${block.level}"/></w:pPr>${start}${inlineXml(block.text, state)}${end}</w:p>`;
    }
    case "list": {
      const typography = listTypography(block.level);
      return `<w:p><w:pPr><w:numPr><w:ilvl w:val="${block.level}"/><w:numId w:val="${block.listId}"/></w:numPr><w:spacing w:before="0" w:after="40" w:line="280" w:lineRule="auto"/></w:pPr>${inlineXml(block.text, state, typography)}</w:p>`;
    }
    case "quote":
      return `<w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr>${inlineXml(block.text, state)}</w:p>`;
    case "code":
      return `<w:p><w:pPr><w:pStyle w:val="CodeBlock"/></w:pPr>${textRun(block.text, runProps({ code: true }))}</w:p>`;
    case "paragraph":
      return `<w:p><w:pPr><w:spacing w:after="80"/></w:pPr>${inlineXml(block.text, state)}</w:p>`;
  }
}

function listTypography(level: ListLevel): ListTypography {
  const sizeIndex = Math.min(level, LIST_SIZE_HALF_POINTS_BY_DEPTH.length - 1);
  return {
    bold: level < 2,
    sizeHalfPoints: LIST_SIZE_HALF_POINTS_BY_DEPTH[sizeIndex]!,
  };
}

function listLevelXml(level: ListLevel, kind: ListKind): string {
  const typography = listTypography(level);
  const left = 720 + level * 360;
  const marker = ["•", "◦", "▪"][level % 3]!;
  const format = kind === "bullet" ? "bullet" : "decimal";
  const levelText = kind === "bullet" ? marker : `%${level + 1}.`;
  const font = kind === "bullet"
    ? '<w:rFonts w:ascii="Segoe UI Symbol" w:hAnsi="Segoe UI Symbol" w:hint="default"/>'
    : '<w:rFonts w:ascii="Segoe UI" w:hAnsi="Segoe UI" w:eastAsia="Yu Gothic UI"/>';
  return `<w:lvl w:ilvl="${level}"><w:start w:val="1"/><w:numFmt w:val="${format}"/><w:lvlText w:val="${escapeAttr(levelText)}"/><w:lvlJc w:val="left"/><w:pPr><w:tabs><w:tab w:val="num" w:pos="${left}"/></w:tabs><w:ind w:left="${left}" w:hanging="360"/></w:pPr><w:rPr>${font}<w:color w:val="${level === 0 ? ACCENT : level < 3 ? INK : MUTED}"/>${runPropertyElements(typography)}</w:rPr></w:lvl>`;
}

function numberingXml(definitions: ListDefinition[]): string {
  const levels = (kind: ListKind): string =>
    Array.from({ length: 9 }, (_value, level) => listLevelXml(level as ListLevel, kind)).join("");
  const instances = definitions
    .map((definition) => {
      const abstractId = definition.listKind === "bullet" ? 0 : 1;
      const override = definition.start === 1
        ? ""
        : `<w:lvlOverride w:ilvl="${definition.level}"><w:startOverride w:val="${definition.start}"/></w:lvlOverride>`;
      return `<w:num w:numId="${definition.listId}"><w:abstractNumId w:val="${abstractId}"/>${override}</w:num>`;
    })
    .join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="${W}"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>${levels("bullet")}</w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>${levels("ordered")}</w:abstractNum>${instances}</w:numbering>`;
}

function headingStyle(
  level: HeadingLevel,
  before: number,
  after: number,
  color: string,
): string {
  const listSize = LIST_SIZE_HALF_POINTS_BY_DEPTH[level - 1]!;
  const size = Math.round(listSize * HEADING_SIZE_SCALE);
  const border = level === 1
    ? `<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="6" w:color="${ACCENT}"/></w:pBdr>`
    : level === 2
      ? `<w:pBdr><w:bottom w:val="single" w:sz="4" w:space="4" w:color="${BORDER}"/></w:pBdr>`
      : "";
  return `<w:style w:type="paragraph" w:styleId="Heading${level}"><w:name w:val="heading ${level}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="${before}" w:after="${after}"/>${border}<w:outlineLvl w:val="${level - 1}"/></w:pPr><w:rPr><w:b/><w:color w:val="${color}"/><w:sz w:val="${size}"/><w:szCs w:val="${size}"/></w:rPr></w:style>`;
}

function stylesXml(): string {
  const headings = [
    headingStyle(1, 360, 140, INK),
    headingStyle(2, 260, 100, ACCENT),
    headingStyle(3, 180, 60, INK),
    headingStyle(4, 140, 50, INK),
  ].join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="${W}"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Segoe UI" w:hAnsi="Segoe UI" w:eastAsia="Yu Gothic UI" w:cs="Segoe UI"/><w:color w:val="${INK}"/><w:lang w:val="en-US" w:eastAsia="ja-JP"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:line="312" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:rFonts w:ascii="Segoe UI" w:hAnsi="Segoe UI" w:eastAsia="Yu Gothic UI" w:cs="Segoe UI"/><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:style>${headings}<w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="${CODE_BG}"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="${ACCENT}"/></w:pBdr><w:spacing w:before="120" w:after="120" w:line="264" w:lineRule="auto"/><w:ind w:left="200" w:right="120"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Yu Gothic"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="24" w:space="10" w:color="${BORDER}"/></w:pBdr><w:ind w:left="260"/><w:spacing w:before="80" w:after="80"/></w:pPr><w:rPr><w:color w:val="${MUTED}"/></w:rPr></w:style><w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:uiPriority w:val="39"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/><w:left w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/><w:right w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="${BORDER}"/></w:tblBorders></w:tblPr></w:style></w:styles>`;
}

function settingsXml(): string {
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings xmlns:w="${W}"><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>`;
}

function contentTypesXml(): string {
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="${CT}"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>`;
}

function packageRelsXml(): string {
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${REL}"><Relationship Id="rId1" Type="${R}/officeDocument" Target="word/document.xml"/></Relationships>`;
}

function documentRelsXml(state: RenderState): string {
  const links = state.hyperlinks
    .map((link) => `<Relationship Id="${link.id}" Type="${R}/hyperlink" Target="${escapeAttr(link.target)}" TargetMode="External"/>`)
    .join("");
  const images = state.images
    .map((image) => `<Relationship Id="${image.id}" Type="${R}/image" Target="${escapeAttr(image.target)}"/>`)
    .join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${REL}"><Relationship Id="rId1" Type="${R}/styles" Target="styles.xml"/><Relationship Id="rId2" Type="${R}/settings" Target="settings.xml"/><Relationship Id="rId3" Type="${R}/numbering" Target="numbering.xml"/>${links}${images}</Relationships>`;
}

function documentXml(blocks: MarkdownBlock[], state: RenderState): string {
  const tableSeparator = '<w:p><w:pPr><w:keepNext/><w:spacing w:before="0" w:after="0" w:line="1" w:lineRule="exact"/></w:pPr></w:p>';
  const body = blocks.map((block, index) => {
    const separator =
      block.kind === "table" && blocks[index - 1]?.kind === "table" ? tableSeparator : "";
    return separator + paragraphXml(block, state);
  }).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="${W}" xmlns:r="${R}" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>${body || "<w:p/>"}<w:sectPr><w:pgSz w:w="${PAGE_WIDTH_DXA}" w:h="${PAGE_HEIGHT_DXA}"/><w:pgMar w:top="${PAGE_MARGIN_DXA}" w:right="${PAGE_MARGIN_DXA}" w:bottom="${PAGE_MARGIN_DXA}" w:left="${PAGE_MARGIN_DXA}" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>`;
}

function listDefinitions(blocks: MarkdownBlock[]): ListDefinition[] {
  const definitions = new Map<number, ListDefinition>();
  for (const block of blocks) {
    if (block.kind !== "list") continue;
    const existing = definitions.get(block.listId);
    if (existing && (existing.listKind !== block.listKind ||
      existing.level !== block.level || existing.start !== block.start)) {
      throw new Error(`List ${block.listId} has inconsistent numbering definitions.`);
    }
    definitions.set(block.listId, {
      listId: block.listId,
      listKind: block.listKind,
      start: block.start,
      level: block.level,
    });
  }
  return [...definitions.values()].sort((left, right) => left.listId - right.listId);
}

export function renderDocx(blocks: MarkdownBlock[], baseDirectory: string): Buffer {
  const state: RenderState = {
    bookmarkId: 1,
    drawingId: 1,
    relationshipId: FIRST_CONTENT_RELATIONSHIP_ID,
    hyperlinks: [],
    images: [],
    baseDirectory: path.resolve(baseDirectory),
  };
  const document = documentXml(blocks, state);
  return createZip([
    { name: "[Content_Types].xml", data: Buffer.from(contentTypesXml(), "utf8") },
    { name: "_rels/.rels", data: Buffer.from(packageRelsXml(), "utf8") },
    { name: "word/document.xml", data: Buffer.from(document, "utf8") },
    { name: "word/_rels/document.xml.rels", data: Buffer.from(documentRelsXml(state), "utf8") },
    { name: "word/settings.xml", data: Buffer.from(settingsXml(), "utf8") },
    { name: "word/styles.xml", data: Buffer.from(stylesXml(), "utf8") },
    { name: "word/numbering.xml", data: Buffer.from(numberingXml(listDefinitions(blocks)), "utf8") },
    ...state.images.map((image) => ({
      name: `word/${image.target}`,
      data: readFileSync(image.sourcePath),
    })),
  ]);
}
