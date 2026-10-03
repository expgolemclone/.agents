import { existsSync, statSync } from "node:fs";
import path from "node:path";

/** Resolve local PNG paths without confusing Windows drive letters with URI schemes. */
export function resolveMarkdownImagePath(markdownPath: string, baseDirectory: string): string {
  if (!path.isAbsolute(markdownPath) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(markdownPath)) {
    throw new Error(`Remote and data images are not supported: ${markdownPath}`);
  }
  const sourcePath = path.resolve(baseDirectory, markdownPath);
  if (path.extname(sourcePath).toLowerCase() !== ".png") {
    throw new Error(`Unsupported image format for ${markdownPath}. Only PNG is supported.`);
  }
  if (!existsSync(sourcePath) || !statSync(sourcePath).isFile()) {
    throw new Error(`PNG image does not exist or is not a file: ${sourcePath}`);
  }
  return sourcePath;
}
