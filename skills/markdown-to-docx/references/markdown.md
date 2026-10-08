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
| Heading 1 | 20 pt | Bold |
| Heading 2 | 16 pt | Bold |
| Heading 3 | 13 pt | Bold |
| Heading 4 | 11.5 pt | Bold |
| Fenced code blocks, including appendices | 9.5 pt | Regular |

Heading sizes are independent of list typography. Inline code, links, bold, italic, and strikethrough retain the containing block's size.

## Images

Use only local PNG images in standalone paragraphs, with paths relative to the Markdown file or local absolute paths:

```markdown
![Architecture diagram](images/architecture.png)
```

Remote, data URI, JPEG, SVG, and inline images in prose are rejected. Image-only HTML table cells are supported as described below.

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

- Tags: `table`, `colgroup`, `col`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`, `br`, `img`.
- Columns: positive `width` on every `col`; widths determine fixed, proportional layout.
- Table styles: `break-inside:avoid`, `break-after:avoid`, `border:none`, in any combination.
- Cell attributes: positive integer `rowspan` and `colspan`, `align`, `valign`, six-digit RGB `bgcolor`.
- Cell styles: one `color:#RRGGBB` and per-edge `border-top`, `border-right`, `border-bottom`, `border-left` in `<positive width up to 16px> solid #RRGGBB` form. Fractional widths are raised to Word's 0.25pt minimum.
- Cell content: inline Markdown with escaped literal punctuation; use `br` for line breaks. Alternatively, a `td` may contain one `img` and whitespace only. Images require `src`, `alt`, and a `style` containing only positive `width` and `height` in `mm`, both required. Local PNG path rules still apply. Mixed text/image cells, multiple images and other attributes/styles are rejected.

`break-inside:avoid` keeps a complete table on one page when it fits; oversized tables may span pages. `break-after:avoid` keeps the table with the following block. `border:none` suppresses the generic grid. Leading `thead` rows repeat on continued pages; `td` retains ordinary cell styling, while `th` also adds header typography and fill. Consecutive tables remain independent.

Reject nested tables, block elements, incomplete widths, nonrectangular grids, overlapping spans, unknown CSS, and unsupported attributes. A row fully occupied by preceding rowspans may declare no cells.

## Resume photo layout

Keep the title and date above the personal-information table. Put the portrait in its top-right body cell, spanning the short identity/address rows. Let long contact values span the remaining columns.

```html
<table style="break-inside:avoid">
  <colgroup><col width="120"><col width="280"><col width="120"></colgroup>
  <tbody>
    <tr><th>Name</th><td>Sample Person</td><td rowspan="2" valign="top"><img src="images/portrait.png" alt="Portrait" style="width:30mm;height:40mm"></td></tr>
    <tr><th>Address</th><td>Sample address</td></tr>
    <tr><th>Email</th><td colspan="2">sample@example.test</td></tr>
  </tbody>
</table>
```

Image dimensions define a maximum display box, not a crop: fit the original aspect ratio within it, centered horizontally unless the cell specifies `align`. PNG bytes remain unchanged; do not generate, stretch or retouch a portrait. Boxes exceeding the cell's usable width or printable page height are rejected. Leave room for cell padding when choosing column weights. For a single first-page portrait, use `tbody`, not repeating `thead`.

Inspect the source pixel dimensions and report insufficient resolution for print rather than claiming that a larger display size improves it. A 30mm-wide portrait needs about 355 pixels for 300dpi. Move an existing standalone photo into its new cell instead of leaving both occurrences.

## Existing DOCX image synchronization

Markdown text remains the source of truth. Before regeneration, import only missing DOCX body-image occurrences at uniquely matched positions.

- Extract inline or floating images from standalone body paragraphs into sibling `images/<sha256>.png` files and insert standalone Markdown image paragraphs.
- Preserve repeated occurrences but store identical content once; reuse existing identical content-addressed PNGs.
- Keep PNG bytes unchanged. Normalize other Pillow-readable single-frame raster images to PNG.
- Existing image-only table cells with one inline raster image must map to a unique Markdown table signature and the same row/column origin. The declared cell's Markdown image path, dimensions and alt text govern regeneration, including explicit photo replacement or resizing. Table photos do not count as standalone occurrences. Moving a standalone image into a new cell satisfies that existing occurrence without reimporting it.
- Do not automatically import DOCX-only table images. Removing a represented photo declaration or changing its table text/structure so that it no longer maps uniquely is rejected. Express supported photo edits in the declared cell; intentional table restructuring/removal requires a new output DOCX path rather than ambiguous import.
- Reject invalid packages, ambiguous positions, mixed text/image paragraphs or cells, multiple/floating table images, text-box images, header/footer images, external or vector images, and animated or multi-frame images.
- On rejection, leave Markdown, images, and the existing DOCX unchanged. Do not guess a position by skipping duplicate or unmatched surrounding text.

## Verification

Confirm successful CLI exit and a valid ZIP package signature. Inspect the DOCX XML for applicable features:

- Typography: `w:sz` and `w:szCs` use half-point units and match the typography table, through direct formatting or paragraph-style inheritance. All list text and markers use 21; headings use 40, 32, 26, and 23; code blocks use 19.
- Bullet and ordered numbering definitions, including the actual level's start value for nested lists.
- Merges: `w:gridSpan`, `w:vMerge`.
- Explicit widths: fixed layout and proportional `w:gridCol` values.
- Explicit colors/borders: `w:color`, per-edge `w:tcBorders`, no inherited generic TableGrid borders.
- Pagination: `w:keepNext` only on the final cell paragraph of each nonfinal kept-together row; keep-with-next on the final row; leading `w:tblHeader` rows.
- Adjacent tables: an intervening near-zero-height paragraph.
- Repeated images: unique `wp:docPr` IDs and valid, unique relationship IDs.
- Imported images: references resolve under sibling `images`, use SHA-256 filenames, and appear in the regenerated DOCX.
- Photo cells: inline drawings stay inside the intended cell, image extent fits the declared physical box without aspect distortion, and merged continuation cells do not repeat the drawing. Run conversion a second time with the existing output; it must not duplicate or reimport a represented portrait.

Run `scripts/render-docx.py` as a black box, without composing LibreOffice/PDF commands manually. Read its JSON, confirm `page_count` equals the number of `pages`, and inspect every PNG at 100 percent for clipping, list alignment, cell borders, merged cells, image scaling, fonts, and page breaks. For resumes, also verify that the photo appears once in the upper-right personal-information area, contact text is readable, and no image/text overlaps occur. Do not report completion without passing rendered QA.
