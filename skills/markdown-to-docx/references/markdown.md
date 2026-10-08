# Markdown authoring and verification

## Prerequisites

Require Node.js 22.18+ and shared runtime dependencies. Image synchronization and rendered QA also require Python, Pillow, LibreOffice, and PyMuPDF. If installation is needed, follow the envx repository's `RULES.md`, then run `pwsh -NoProfile -File C:/dev/settings/envx/runtimes/manage.ps1 -Operation Install`. Never install packages in this skill directory.

## Supported Markdown

Use headings 1 through 4, paragraphs, blockquotes, horizontal rules, fenced code, unordered, ordered and task lists, pipe tables, links, bold, italic, strikethrough, inline code, and `<!-- pagebreak -->`. Heading levels 5 and 6 are rejected. Escape literal Markdown punctuation with a backslash outside code. Code spans preserve literal backslashes and may use matching multi-backtick delimiters. Pipe tables accept escaped pipes and pipes inside code spans.

Lists use two-space indentation, up to nine levels. Each nested list has its own numbering instance and start value; returning to a parent starts a new child list. All list text and markers use the body size. Indentation distinguishes depth; depths 1 and 2 are bold, and depths 3 through 9 are regular. Explicit bold remains bold at every depth.

## Typography

| Element | Size | Weight |
| --- | ---: | --- |
| Body paragraphs and blockquotes | 10.5 pt | Regular |
| Table cells | 10.5 pt | Regular; header cells are bold |
| Lists and their markers, all nine depths | 10.5 pt | Bold at depths 1 and 2; regular thereafter |
| Heading 1 | 22.5 pt | Bold |
| Heading 2 | 19.5 pt | Bold |
| Heading 3 | 17.5 pt | Bold |
| Heading 4 | 15 pt | Bold |
| Fenced code blocks, including appendices | 9.5 pt | Regular |

Heading sizes are independent of list typography. Inline code, links, bold, italic, and strikethrough retain the containing block's size.

## Images

Use only local PNG images in standalone paragraphs, with paths relative to the Markdown file or local absolute paths:

```markdown
![Architecture diagram](images/architecture.png)
```

Remote, data URI, JPEG, SVG, and inline images are rejected.

## Merged tables

Use restricted HTML table blocks:

```html
<table style="break-inside:avoid">
  <colgroup><col width="120"><col width="260"><col width="100"></colgroup>
  <thead><tr><th colspan="2">Summary</th><th>Status</th></tr></thead>
  <tbody>
    <tr><td rowspan="2">Area A</td><td>Task 1</td><td>Done</td></tr>
    <tr><td>Task 2</td><td>Open</td></tr>
  </tbody>
</table>
```

- Tags: `table`, `colgroup`, `col`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`, `br`.
- Columns: positive `width` on every `col`; widths determine fixed, proportional layout.
- Table styles: `break-inside:avoid`, `break-after:avoid`, `border:none`, in any combination.
- Cell attributes: positive integer `rowspan` and `colspan`, `align`, `valign`, six-digit RGB `bgcolor`.
- Cell styles: one `color:#RRGGBB` and per-edge `border-top`, `border-right`, `border-bottom`, `border-left` in `<positive width up to 16px> solid #RRGGBB` form. Fractional widths are raised to Word's 0.25pt minimum.
- Cell content: inline Markdown with escaped literal punctuation; use `br` for line breaks.

`break-inside:avoid` keeps a complete table on one page when it fits; oversized tables may span pages. `break-after:avoid` keeps the table with the following block. `border:none` suppresses the generic grid. Leading `thead` rows repeat on continued pages; `td` retains ordinary cell styling, while `th` also adds header typography and fill. Consecutive tables remain independent.

Reject nested tables, block elements, incomplete widths, nonrectangular grids, overlapping spans, unknown CSS, and unsupported attributes. A row fully occupied by preceding rowspans may declare no cells.

## Existing DOCX image synchronization

Markdown text remains the source of truth. Before regeneration, import only missing DOCX body-image occurrences at uniquely matched positions.

- Extract inline or floating images from standalone body paragraphs into sibling `images/<sha256>.png` files and insert standalone Markdown image paragraphs.
- Preserve repeated occurrences but store identical content once; reuse existing identical content-addressed PNGs.
- Keep PNG bytes unchanged. Normalize other Pillow-readable single-frame raster images to PNG.
- Reject invalid packages, ambiguous positions, mixed text/image paragraphs, table or text-box images, header/footer images, external or vector images, and animated or multi-frame images.
- On rejection, leave Markdown, images, and the existing DOCX unchanged. Do not guess a position by skipping duplicate or unmatched surrounding text.

## Verification

Confirm successful CLI exit and a valid ZIP package signature. Inspect the DOCX XML for applicable features:

- Typography: `w:sz` and `w:szCs` use half-point units and match the typography table, through direct formatting or paragraph-style inheritance. All list text and markers use 21; headings use 45, 39, 35, and 30; code blocks use 19.
- Bullet and ordered numbering definitions, including the actual level's start value for nested lists.
- Merges: `w:gridSpan`, `w:vMerge`.
- Explicit widths: fixed layout and proportional `w:gridCol` values.
- Explicit colors/borders: `w:color`, per-edge `w:tcBorders`, no inherited generic TableGrid borders.
- Pagination: `w:keepNext` only on the final cell paragraph of each nonfinal kept-together row; keep-with-next on the final row; leading `w:tblHeader` rows.
- Adjacent tables: an intervening near-zero-height paragraph.
- Repeated images: unique `wp:docPr` IDs and valid, unique relationship IDs.
- Imported images: references resolve under sibling `images`, use SHA-256 filenames, and appear in the regenerated DOCX.

Run `scripts/render-docx.py` as a black box, without composing LibreOffice/PDF commands manually. Read its JSON, confirm `page_count` equals the number of `pages`, and inspect every PNG at 100 percent for clipping, list alignment, cell borders, merged cells, image scaling, fonts, and page breaks. Do not report completion without passing rendered QA.
