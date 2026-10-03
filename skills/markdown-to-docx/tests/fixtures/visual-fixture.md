# Markdown to DOCX QA

This fixture checks **bold**, *italic*, ~~strikethrough~~, `inline code`, and an [external link](https://example.com).

## Lists

### Third-level heading

#### Fourth-level heading

- Top-level bullet
  - Second-level bullet with a long sentence that wraps under the item text instead of the marker.
    - [x] Third-level completed task with an [external link](https://example.com)
      - Fourth-level bullet with `inline code`, *italic*, and ~~strikethrough~~.
        - Fifth-level bullet with **explicit bold** that remains readable at the minimum size.
    - [ ] Third-level open task

3. Ordered item starting at three
  1. Second-level ordered item
    1. Third-level ordered item
      1. Fourth-level ordered item
        1. Fifth-level ordered item at the minimum size
4. Ordered item with another wrapped sentence for list alignment verification.

- First parent with a nested list starting at three
  3. Child three
  4. Child four
- Second parent with an independent nested list
  7. Child seven
  8. Child eight

Literal code must retain backslashes: `a\*b`, `C:\temp\file`, and ``a`b\*c``.

> A blockquote must keep a visible left border and readable spacing.

---

## Pipe table

| Item | Owner | Status |
| --- | --- | --- |
| Specification | A. Example | Done |
| Visual verification | B. Example | In progress |

## Merged HTML table

<table>
  <colgroup>
    <col width="120">
    <col width="260">
    <col width="100">
  </colgroup>
  <thead>
    <tr><th colspan="2">Work summary</th><th>Status</th></tr>
  </thead>
  <tbody>
    <tr><td rowspan="2">Area A</td><td>Task 1 with **bold text**</td><td>Done</td></tr>
    <tr><td>Task 2 with literal **markers**<br>Second line</td><td align="center">Open</td></tr>
    <tr><td>Area B</td><td colspan="2">One cell spanning two columns</td></tr>
  </tbody>
</table>

### Fully spanned rows

<table>
  <colgroup><col width="100"><col width="100"></colgroup>
  <tr><td rowspan="3" colspan="2">This cell spans all three rows.</td></tr>
  <tr></tr>
  <tr></tr>
</table>

## Long code block

```ts
const rows = 3;
const columns = 3;
const horizontalMerge = true;
const verticalMerge = true;
const numbering = "native";
console.log({ rows, columns, horizontalMerge, verticalMerge, numbering });
```

The long code block above moves to the Appendix during visual QA.
