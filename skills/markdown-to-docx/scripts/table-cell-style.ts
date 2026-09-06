export const TABLE_CELL_EDGES = ["top", "right", "bottom", "left"] as const;
export const MAX_TABLE_BORDER_WIDTH_PX = 16;

export type TableCellEdge = typeof TABLE_CELL_EDGES[number];
export type TableCellBorder = {
  widthPx: number;
  style: "solid";
  color: string;
};
export type TableCellBorders = Partial<Record<TableCellEdge, TableCellBorder>>;
export type ParsedTableCellStyle = {
  textColor?: string;
  borders?: TableCellBorders;
};

export type CssDeclaration = {
  property: string;
  value: string;
};

export function parseCssDeclarations(
  source: string | undefined,
  styleName: string,
  context: string,
): CssDeclaration[] {
  if (source === undefined || source.trim() === "") return [];
  const declarations: CssDeclaration[] = [];
  const seen = new Set<string>();
  for (const rawDeclaration of source.split(";")) {
    const declaration = rawDeclaration.trim();
    if (declaration === "") continue;
    const match = /^([a-z-]+)\s*:\s*(.+)$/i.exec(declaration);
    if (!match) throw new SyntaxError(`Malformed ${styleName} '${declaration}' ${context}.`);
    const property = match[1]!.toLowerCase();
    if (seen.has(property)) {
      throw new SyntaxError(`Duplicate ${styleName} property '${property}' ${context}.`);
    }
    seen.add(property);
    declarations.push({ property, value: match[2]!.trim() });
  }
  return declarations;
}

function parseCssRgbColor(value: string, name: string, context: string): string {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  if (!match) {
    throw new SyntaxError(`${name} must be a six-digit #RRGGBB color ${context}.`);
  }
  return match[1]!.toUpperCase();
}

export function parseHtmlRgbColor(
  value: string | undefined,
  name: string,
  context: string,
): string | undefined {
  if (value === undefined) return undefined;
  const match = /^#?([0-9a-f]{6})$/i.exec(value.trim());
  if (!match) throw new SyntaxError(`Unsupported ${name} value '${value}' ${context}.`);
  return match[1]!.toUpperCase();
}

export function parseTableCellStyle(
  value: string | undefined,
  context: string,
): ParsedTableCellStyle {
  const result: ParsedTableCellStyle = {};
  const borders: TableCellBorders = {};
  for (const { property, value: rawValue } of parseCssDeclarations(
    value,
    "cell style",
    context,
  )) {
    if (property === "color") {
      result.textColor = parseCssRgbColor(rawValue, "color", context);
      continue;
    }
    const edgeMatch = /^border-(top|right|bottom|left)$/.exec(property);
    if (!edgeMatch) {
      throw new SyntaxError(`Unsupported cell style property '${property}' ${context}.`);
    }
    const borderMatch = /^((?:\d+(?:\.\d+)?|\.\d+))px\s+solid\s+(#[0-9a-f]{6})$/i.exec(rawValue);
    if (!borderMatch) {
      throw new SyntaxError(`Unsupported ${property} value '${rawValue}' ${context}.`);
    }
    const widthPx = Number.parseFloat(borderMatch[1]!);
    if (
      !Number.isFinite(widthPx) ||
      widthPx <= 0 ||
      widthPx > MAX_TABLE_BORDER_WIDTH_PX
    ) {
      throw new SyntaxError(
        `${property} width must be greater than 0px and at most ${MAX_TABLE_BORDER_WIDTH_PX}px ${context}.`,
      );
    }
    borders[edgeMatch[1] as TableCellEdge] = {
      widthPx,
      style: "solid",
      color: parseCssRgbColor(borderMatch[2]!, `${property} color`, context),
    };
  }
  if (Object.keys(borders).length > 0) result.borders = borders;
  return result;
}
