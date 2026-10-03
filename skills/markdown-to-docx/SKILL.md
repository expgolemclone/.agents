---
name: markdown-to-docx
description: Create or update verified Word DOCX reports from Markdown or selected Customine-exported XLSX content, preserving tables, nested lists, and Word-pasted images.
---

# Markdown to DOCX

Use the bundled CLIs, not manual document reconstruction.

1. Read [Markdown authoring and verification](references/markdown.md) completely. For Customine XLSX, also read and follow [the XLSX workflow](references/customine-xlsx.md).
2. Inspect the complete Markdown source and referenced PNGs. Choose absolute input/output paths and an existing output directory.
3. Run from this skill directory:

```powershell
node scripts/markdown-to-docx.ts C:\path\input.md C:\path\output.docx
python scripts/render-docx.py C:\path\output.docx
```

Existing output DOCX files are inspected first: missing body images are imported into Markdown before regeneration. Markdown text remains authoritative. Ambiguous or unsupported imports fail without changing the source or existing DOCX.

Add `--code-appendix-threshold N` only to move code blocks longer than `N` lines into linked appendices.

4. Run the renderer as a black box; inspect its implementation only if it fails. Validate its JSON and inspect every page at 100 percent using the reference's verification checklist. Do not report completion before rendered QA passes.
