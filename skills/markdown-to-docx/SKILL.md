---
name: markdown-to-docx
description: Convert local Markdown files or Customine-exported XLSX workbooks into verified Microsoft Word DOCX documents, including structured tables, nested lists, Word-pasted raster images, and selected Customine sheets, pages, actions, TODOs, edit details, or results. Use when Codex needs to create or update a DOCX from Markdown or prepare a faithful Word report from a Customine workbook.
---

# Markdown and Customine XLSX to DOCX

Use the bundled deterministic CLIs. Require Node.js 22.18 or newer and run `npm ci` in this skill directory when dependencies are not installed. DOCX image synchronization and rendered QA require Python, Pillow, LibreOffice, and PyMuPDF.

## Choose the workflow

- For a Markdown source or an existing DOCX whose body images must be synchronized, follow the instructions below.
- For a Customine-exported XLSX workbook, read [references/customine-xlsx.md](references/customine-xlsx.md) completely and follow that workflow before returning here for the shared DOCX conversion and verification steps.

## Convert

1. Inspect the complete Markdown source and all referenced local PNG files.
2. Choose explicit absolute input and output paths. Require an existing output directory.
3. Run from this skill directory:

```powershell
node scripts/markdown-to-docx.ts C:\path\input.md C:\path\output.docx
```

4. When the output DOCX exists, let the CLI synchronize missing body images into the Markdown before regeneration.
5. Add `--code-appendix-threshold N` only when code blocks longer than `N` lines must move to an Appendix with internal links.
6. Run the renderer as a black box. Do not read or reproduce its implementation unless it fails:

```powershell
python scripts/render-docx.py C:\path\output.docx
```

7. Read its single JSON result, then inspect every path in `pages` at 100 percent. Do not report completion when render QA has not passed.

The CLI never creates a missing output directory. It keeps the existing DOCX unchanged until synchronization and DOCX generation both succeed.

## Synchronize existing DOCX images

- Keep Markdown text as the source of truth. Import only DOCX body images that are not already referenced by Markdown.
- Extract inline and floating images from standalone body paragraphs. Save each unique image as `images/<sha256>.png` beside the Markdown and insert a standalone Markdown image paragraph at its uniquely matched document position.
- Preserve repeated image occurrences while storing identical image content once. Reuse an existing identical content-addressed PNG.
- Keep PNG bytes unchanged. Normalize other Pillow-readable single-frame raster images to PNG.
- Reject invalid DOCX packages, ambiguous positions, mixed text-and-image paragraphs, table or text-box images, header or footer images, external images, vector images, and animated or multi-frame images. Leave the Markdown, image directory, and existing DOCX unchanged on rejection.

## Author supported Markdown

Use headings 1 through 4, paragraphs, blockquotes, horizontal rules, fenced code, unordered lists, ordered lists, task lists, pipe tables, links, bold, italic, strikethrough, inline code, and `<!-- pagebreak -->`. Escape literal Markdown punctuation with a backslash. Pipe tables accept escaped pipes and pipes inside inline code. Heading levels 5 and 6 are rejected instead of being degraded to body text.

Heading sizes are 1.5 times the corresponding list hierarchy size. DOCX supports half-point increments, so the 17.25 pt result for heading 3 is rounded to 17.5 pt:

| Heading level | Size | Weight |
| --- | ---: | --- |
| 1 | 22.5 pt | Bold |
| 2 | 19.5 pt | Bold |
| 3 | 17.5 pt | Bold |
| 4 | 15 pt | Bold |

Nested unordered, ordered, and task lists use the same hierarchy typography for their text and leading markers:

| List depth | Size | Weight |
| --- | ---: | --- |
| 1 | 15 pt | Bold |
| 2 | 13 pt | Bold |
| 3 | 11.5 pt | Regular |
| 4 and deeper | 10 pt | Regular |

Explicit Markdown bold remains bold at every list depth. Links, inline code, italic, and strikethrough inherit the size of their list depth.

Place each image in its own paragraph:

```markdown
![Architecture diagram](images/architecture.png)
```

Resolve relative image paths from the Markdown file. Use local PNG files only. Do not use remote, data URI, JPEG, SVG, or inline images.

## Author merged tables

Use an HTML table block with `rowspan` and `colspan`:

```html
<table>
  <colgroup>
    <col width="120">
    <col width="260">
    <col width="100">
  </colgroup>
  <thead>
    <tr><th colspan="2">Summary</th><th>Status</th></tr>
  </thead>
  <tbody>
    <tr><td rowspan="2">Area A</td><td>Task 1</td><td>Done</td></tr>
    <tr><td>Task 2</td><td>Open</td></tr>
  </tbody>
</table>
```

Allow only `table`, `colgroup`, `col`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`, and `br` tags. Allow positive `width` on `col`. A table may use the restricted styles `break-inside:avoid`, `break-after:avoid`, and `border:none` in any combination. `break-inside:avoid` keeps all rows on one page whenever they fit, while still permitting an oversized table to span pages. `break-after:avoid` keeps the table with the following block. `border:none` suppresses the generic Word table grid when cells do not declare explicit borders. Leading rows inside `thead` repeat on every continued page without changing `td` cell styling; use `th` when header typography and fill are also wanted. Consecutive table blocks remain independent Word tables.

Allow `rowspan`, `colspan`, `align`, `valign`, and six-digit RGB `bgcolor` on cells. A cell may also use a restricted `style` containing one `color:#RRGGBB` declaration and per-edge `border-top`, `border-right`, `border-bottom`, and `border-left` declarations in `<positive width up to 16px> solid #RRGGBB` form. Positive fractional border widths are accepted and rendered at no less than Word's 0.25pt minimum. Use inline Markdown inside cells and backslash-escape literal punctuation. Reject nested tables, block elements, incomplete width declarations, nonrectangular grids, overlapping spans, unknown CSS, and unsupported attributes instead of degrading them.

## Verify

- Confirm the CLI exits successfully and the output begins with a valid ZIP package signature.
- When synchronizing, confirm every imported Markdown reference resolves under the sibling `images` directory, uses the content SHA-256 filename, and appears in the regenerated DOCX.
- Confirm Word numbering definitions exist for bullet and ordered lists.
- Confirm merged tables contain `w:gridSpan` and `w:vMerge` in the DOCX XML.
- Confirm explicit column widths produce fixed table layout and proportional `w:gridCol` values.
- Confirm explicit text colors produce `w:color` and explicit cell borders produce per-edge `w:tcBorders` without inheriting the generic TableGrid border.
- Confirm `break-inside:avoid` produces chained `w:keepNext` only on the final cell paragraph of each nonfinal row, `break-after:avoid` chains the final row to the next block, and `thead` produces leading `w:tblHeader` rows.
- Confirm adjacent HTML table blocks have an intervening near-zero-height Word paragraph so they cannot be merged into one table by WordprocessingML rules.
- Run `scripts/render-docx.py` without composing LibreOffice or PDF commands manually.
- Confirm its JSON `page_count` matches the number of `pages`, then inspect every page for text clipping, list alignment, cell borders, merged cells, image scaling, fonts, and page breaks.
