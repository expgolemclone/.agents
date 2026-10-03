const ESCAPABLE_MARKDOWN_CHARACTERS = new Set([
  "\\",
  "`",
  "*",
  "_",
  "[",
  "]",
  "{",
  "}",
  "(",
  ")",
  "#",
  "+",
  ".",
  "!",
  "|",
  ">",
  "~",
  "-",
]);

const INLINE_MARKDOWN_PATTERN =
  /!?\[[^\]]*\]\([^)]*\)|`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\*[^*]+\*|_[^_]+_/g;

export type InlineMarkdownToken =
  | { kind: "text" | "code" | "bold" | "italic" | "strike"; text: string }
  | { kind: "link"; text: string; target: string }
  | { kind: "image"; alt: string; target: string };

type ProtectedMarkdown = {
  text: string;
  restore: (value: string) => string;
};

function protectMarkdownEscapes(source: string): ProtectedMarkdown {
  const escapedValues: string[] = [];
  let text = "";
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]!;
    const escaped = source[index + 1];
    if (
      character === "\\" &&
      escaped !== undefined &&
      ESCAPABLE_MARKDOWN_CHARACTERS.has(escaped)
    ) {
      const escapeIndex = escapedValues.push(escaped) - 1;
      text += `\u0000${escapeIndex}\u0000`;
      index += 1;
      continue;
    }
    text += character;
  }
  return {
    text,
    restore: (value: string): string =>
      value.replace(/\u0000(\d+)\u0000/g, (_match, rawIndex: string) => {
        const restored = escapedValues[Number.parseInt(rawIndex, 10)];
        if (restored === undefined) throw new Error("Invalid Markdown escape token.");
        return restored;
      }),
  };
}

export function tokenizeInlineMarkdown(source: string): InlineMarkdownToken[] {
  const protectedMarkdown = protectMarkdownEscapes(source);
  const tokens: InlineMarkdownToken[] = [];
  let index = 0;
  for (const match of protectedMarkdown.text.matchAll(INLINE_MARKDOWN_PATTERN)) {
    const rawToken = match[0];
    const start = match.index;
    if (start > index) {
      tokens.push({
        kind: "text",
        text: protectedMarkdown.restore(protectedMarkdown.text.slice(index, start)),
      });
    }

    const image = /^!\[([^\]]*)\]\(([^)]*)\)$/.exec(rawToken);
    const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(rawToken);
    const code = /^`([^`]+)`$/.exec(rawToken);
    const bold = /^(?:\*\*|__)(.*)(?:\*\*|__)$/.exec(rawToken);
    const strike = /^~~(.*)~~$/.exec(rawToken);
    const italic = /^(?:\*|_)(.*)(?:\*|_)$/.exec(rawToken);

    if (image) {
      tokens.push({
        kind: "image",
        alt: protectedMarkdown.restore(image[1]!),
        target: protectedMarkdown.restore(image[2]!),
      });
    } else if (link) {
      tokens.push({
        kind: "link",
        text: protectedMarkdown.restore(link[1]!),
        target: protectedMarkdown.restore(link[2]!),
      });
    } else if (code) {
      tokens.push({ kind: "code", text: protectedMarkdown.restore(code[1]!) });
    } else if (bold) {
      tokens.push({ kind: "bold", text: protectedMarkdown.restore(bold[1]!) });
    } else if (strike) {
      tokens.push({ kind: "strike", text: protectedMarkdown.restore(strike[1]!) });
    } else if (italic) {
      tokens.push({ kind: "italic", text: protectedMarkdown.restore(italic[1]!) });
    } else {
      tokens.push({ kind: "text", text: protectedMarkdown.restore(rawToken) });
    }
    index = start + rawToken.length;
  }
  if (index < protectedMarkdown.text.length) {
    tokens.push({
      kind: "text",
      text: protectedMarkdown.restore(protectedMarkdown.text.slice(index)),
    });
  }
  return tokens;
}

export function inlineMarkdownTokensPlainText(tokens: readonly InlineMarkdownToken[]): string {
  return tokens
    .map((token) => token.kind === "image" ? token.alt : token.text)
    .join("");
}

export function markdownInlinePlainText(source: string): string {
  return inlineMarkdownTokensPlainText(tokenizeInlineMarkdown(source));
}

export function escapeMarkdownText(source: string): string {
  let escaped = "";
  for (const character of source) {
    if (ESCAPABLE_MARKDOWN_CHARACTERS.has(character)) escaped += "\\";
    escaped += character;
  }
  return escaped;
}
