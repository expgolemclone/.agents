# Customine XLSX workflow

Convert a Customine-exported XLSX workbook into a DOCX report without redesigning its selected content as a generic summary table. Use the bundled CLIs for conversion and selection because these steps preserve workbook presentation and action boundaries.

Require LibreOffice and Python with PyMuPDF in addition to the dependencies in the parent skill. On Windows, LibreOffice is resolved from `%ProgramFiles%\LibreOffice\program\soffice.com`. Set `LIBREOFFICE_PATH` or `PYTHON_PATH` to an explicit absolute executable only for a non-default installation.

## 1. Convert and inspect

Choose an HTML output path and render directory that do not exist. Run from the parent skill directory:

~~~powershell
node scripts/customine/xlsx-to-html.ts C:\path\input.xlsx C:\path\workbook.html --render-dir C:\path\html-render
~~~

The CLI prints one JSON object:

~~~json
{"input":"C:\\path\\input.xlsx","output":"C:\\path\\workbook.html","table_count":4,"render_directory":"C:\\path\\html-render","page_count":4,"pages":["C:\\path\\html-render\\page-1.png"]}
~~~

Confirm `table_count` is the expected worksheet count and `page_count` matches `pages`. Inspect every rendered PNG at 100 percent for missing sheets, clipped text, broken Japanese, incorrect widths, and incorrect merges.

The converter never deletes or overwrites an existing HTML path or render directory.

## 2. Select complete tables or rows

List normalized worksheet tables and one-based row previews:

~~~powershell
node scripts/customine/extract-tables.ts C:\path\workbook.html --list
~~~

Select complete tables or one-based inclusive row ranges into a new Markdown fragment. Repeat `--select` in report order:

~~~powershell
node scripts/customine/extract-tables.ts C:\path\workbook.html C:\path\selected.md --select table0:1-12 --select table3
~~~

- `table0` selects the complete first worksheet table.
- `table2:4-16` selects rows 4 through 16, inclusive.
- The output path must not exist.
- Use the manifest to include only requested sheets, pages, and actions.
- Keep the action header, やること, detail settings, 条件, and 追加の条件 together.

The extractor rejects ranges that cut through a rowspan or a detected Customine action. It emits each action as an independent `<table style="break-inside:avoid">` block and places its action row in `thead`, so a continued action repeats that row. A page-title table uses `break-after:avoid;border:none` to stay with the first action without acquiring Word's default grid. A complete action stays on one page whenever it fits.

The generated fragment preserves relative widths, rowspan, colspan, alignment, cell fills, uniform cell text colors, per-edge solid borders, and literal workbook text. Positive border widths up to 16px are preserved so the DOCX renderer can raise hairline borders to Word's minimum. Omitted trailing cells are filled, and a terminal border-only row is folded into the preceding content row. Mixed text colors and unsupported CSS are rejected instead of being dropped.

Do not hand-edit generated table HTML. Rerun the extractor with corrected selections.

## 3. Compose the report

Create a separate report Markdown file. Use ordinary Markdown for narrative sections and copy complete generated heading and table blocks from the selected fragment.

~~~markdown
# 開発依頼書 改修報告

## TODO

- 管理番号を年度単位で採番する.

## 編集箇所

<!-- selected.mdの見出しとtableブロックを完全な単位で配置 -->

## 結果

管理番号は4月開始の年度単位で採番されます.
~~~

Include no LibreOffice navigation block, unrelated action, or technical table ID.

## 4. Create and verify the DOCX

Return to the parent skill's `Convert` and `Verify` sections with the report Markdown and requested DOCX path. Render the DOCX and inspect every page.

Before delivery, confirm all requested TODOs, pages, and actions are present and unrelated content is absent. Confirm merged cells, relative widths, cell fills, text colors, borders, comparison operators, Markdown punctuation, and Japanese text remain correct. At every page boundary inside or immediately before a Customine table, confirm there is no isolated action row or border-only row and that a continued action repeats its action row.

## Failure handling

- Stop when LibreOffice or Python with PyMuPDF is unavailable.
- Stop when the worksheet count, selected rows, or rendered output differs from the request.
- Fix the deterministic converter or extractor when valid LibreOffice HTML is rejected. Do not substitute a layout-losing parser or manual table reconstruction.
