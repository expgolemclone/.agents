export type SpannedTableCell = {
  colSpan: number;
  rowSpan: number;
};

export type TableGridRow<T extends SpannedTableCell> = {
  cells: readonly T[];
};

export type OccupiedTableCell<T extends SpannedTableCell> = {
  cell: T;
  originRow: number;
  originColumn: number;
};

export type TableGrid<T extends SpannedTableCell> = {
  rows: Array<Array<OccupiedTableCell<T> | undefined>>;
  columnCount: number;
  rowSpanRanges: Array<{ start: number; end: number }>;
};

export function parsePositiveTableSpan(
  value: string | undefined,
  name: string,
  context: string,
): number {
  if (value === undefined) return 1;
  if (!/^\d+$/.test(value)) {
    throw new SyntaxError(`${name} must be a positive integer ${context}.`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new SyntaxError(`${name} must be a positive integer ${context}.`);
  }
  return parsed;
}

function validateSpan(value: number, name: "colSpan" | "rowSpan", context: string): void {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new SyntaxError(`${name} must be a positive integer ${context}.`);
  }
}

export function buildTableGrid<T extends SpannedTableCell>(
  sourceRows: readonly TableGridRow<T>[],
  context: string,
): TableGrid<T> {
  if (sourceRows.length === 0) throw new SyntaxError(`Table ${context} has no rows.`);
  const rows: Array<Array<OccupiedTableCell<T> | undefined>> = [];
  const rowSpanRanges: Array<{ start: number; end: number }> = [];

  for (let rowIndex = 0; rowIndex < sourceRows.length; rowIndex += 1) {
    const sourceRow = sourceRows[rowIndex]!;
    // A row may be fully occupied by preceding rowspans without declaring cells.
    rows[rowIndex] ??= [];
    let column = 0;
    for (const cell of sourceRow.cells) {
      validateSpan(cell.colSpan, "colSpan", context);
      validateSpan(cell.rowSpan, "rowSpan", context);
      while (rows[rowIndex]![column] !== undefined) column += 1;
      const occupied: OccupiedTableCell<T> = {
        cell,
        originRow: rowIndex,
        originColumn: column,
      };
      if (cell.rowSpan > 1) {
        rowSpanRanges.push({ start: rowIndex, end: rowIndex + cell.rowSpan - 1 });
      }
      for (let rowOffset = 0; rowOffset < cell.rowSpan; rowOffset += 1) {
        const targetRow = rowIndex + rowOffset;
        if (targetRow >= sourceRows.length) {
          throw new SyntaxError(`rowspan ${context} extends beyond the final table row.`);
        }
        rows[targetRow] ??= [];
        for (let columnOffset = 0; columnOffset < cell.colSpan; columnOffset += 1) {
          const targetColumn = column + columnOffset;
          if (rows[targetRow]![targetColumn] !== undefined) {
            throw new SyntaxError(`Cell spans overlap ${context}.`);
          }
          rows[targetRow]![targetColumn] = occupied;
        }
      }
      column += cell.colSpan;
    }
  }

  return {
    rows,
    columnCount: Math.max(...rows.map((row) => row.length)),
    rowSpanRanges,
  };
}

export function assertTableGridWithinColumns<T extends SpannedTableCell>(
  grid: TableGrid<T>,
  columnCount: number,
  context: string,
): void {
  if (!Number.isSafeInteger(columnCount) || columnCount < 1) {
    throw new SyntaxError(`Table ${context} must have at least one column.`);
  }
  if (grid.rows.some((row) => row.length > columnCount)) {
    throw new SyntaxError(`Cell span exceeds the ${columnCount}-column grid ${context}.`);
  }
}

export function requireCompleteTableGrid<T extends SpannedTableCell>(
  grid: TableGrid<T>,
  columnCount: number,
  context: string,
): Array<Array<OccupiedTableCell<T>>> {
  assertTableGridWithinColumns(grid, columnCount, context);
  for (const row of grid.rows) {
    if (
      row.length !== columnCount ||
      Array.from({ length: columnCount }, (_value, column) => row[column]).some(
        (cell) => cell === undefined,
      )
    ) {
      throw new SyntaxError(`Table grid is incomplete ${context}.`);
    }
  }
  return grid.rows as Array<Array<OccupiedTableCell<T>>>;
}
