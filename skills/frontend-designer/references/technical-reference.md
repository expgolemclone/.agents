# Frontend Design Systems Technical Reference

This is the curated v3.0.1 technical basis for architecture decisions. It contains optional decision matrices, examples, safeguards, and command prerequisites that are intentionally outside `../SKILL.md`.

## How to Use This Reference

- Read `../SKILL.md` first for activation, hard rules, and evidence gates.
- Treat every architecture pattern and command below as a candidate, not a universal replacement for repository-native practice.
- Before adoption, inspect the design source, browser matrix, accessibility scope, performance evidence, team conventions, tooling availability, and migration cost.
- Verify time-sensitive claims through `source-index.md`; this reference intentionally makes no adoption or universal-support claim.

## Decision Inputs

| Input | Why it changes the decision |
|---|---|
| Existing CSS architecture and naming | Determines whether layers, modules, utilities, CSS-in-JS, BEM-like names, or another local convention are the least disruptive choice. |
| Design source | An existing `Design.md`, `design.md`, token file, Figma export, or approved tool may define visual and state contracts; no particular source is mandatory. |
| Browser matrix and fallback policy | Determines whether a CSS feature can be primary, needs a fallback, or must not be introduced. |
| Accessibility scope | Determines applicable legal/product criteria while preserving semantic HTML, keyboard access, focus visibility, contrast measurement, and reduced motion as baseline safeguards. |
| Performance evidence | Determines whether containment, animation, image, font, or rendering changes improve the actual target instead of moving cost elsewhere. |
| Team conventions, tooling, and migration cost | Determines whether a technically valid option can be maintained and safely introduced. |

---

## 1. CSS Architecture and Naming

Select the existing repository-native approach unless a change has a clear benefit, compatible toolchain, migration plan, and accepted cost.

| Condition | Candidate approach | Guardrail |
|---|---|---|
| The repository already orders CSS with cascade layers | Extend the established layer order. | Do not reorder third-party or existing layers without auditing cascade effects. |
| A component must be portable and the browser matrix supports it | Use container queries for internal layout decisions. | Keep a fallback or use viewport/layout composition where support or scope requires it. |
| Existing modules, utilities, CSS-in-JS, BEM-like names, or semantic classes are established | Follow that naming and ownership model. | Do not label another paradigm obsolete or prohibit it without repository evidence. |
| A relational selector could replace script state | Consider `:has()` after checking browser support and invalidation cost. | Keep explicit state or a fallback when the matrix requires it. |

Illustrative layer order when the repository uses layers:

```css
@layer vendor, tokens, reset, components, utilities;
```

Do not add this declaration solely because it appears here. It can change cascade precedence.

---

## 2. Tokens, Color, Typography, and Themes

Tokens are contracts between design, implementation, and component states. Preserve the repository's primitive/semantic/component tiers or equivalent role model.

| Decision | Guidance |
|---|---|
| Token hierarchy | Use primitive values for raw scales, semantic roles for intent, and component hooks for local override points when that matches the existing contract. Define loading, disabled, error, success, and selected states with their components. |
| Color format | When an approved token contract and the browser/build matrix select OKLCH, keep newly specified tokens OKLCH-only. Retain a legacy format when migration cost, compatibility, or source design requires it. |
| Contrast | Measure each foreground/background and focus-indicator combination against the applicable criterion; perceptual color notation does not replace contrast measurement. |
| Fluid typography | Use container units when the component establishes a query container and the matrix supports them. Use the repository's viewport, fixed, or other scale when it better fits the component and fallback policy. |
| Dark mode | Use dark-mode-first only when product requirements and the approved design source require it. Choose semantic tokens, a class, media preference, or another existing theme mechanism accordingly. |

Illustrative OKLCH token when the decision gate permits it:

```css
--p-brand-500: oklch(0.6 0.15 250);
--s-surface: var(--p-surface-0);
--c-card-background: var(--s-surface);
```

---

## 3. Components, Layout, and Responsive Behavior

Use semantic structure and declare the state contract before visual treatment.

| Component concern | Safeguard |
|---|---|
| Card or reusable region | Give it an accessible name where needed; keep external spacing under the parent layout; use a query container only if component-local adaptation is valuable and supported. |
| Dialog | Prefer a native `<dialog>` when it fits the repository's browser and accessibility policy; otherwise preserve the established focus-management contract. |
| Table or data list | Use native table semantics for tabular data, including headers and scope. Use another semantic structure only when the data model is not tabular. |
| Form | Keep labels, validation messages, error association, keyboard order, and post-interaction state explicit. |
| Navigation | Use `<nav>` and list semantics where applicable; do not make sticky or scroll-driven behavior a default requirement. |
| Page or dashboard layout | Choose named areas, grid, flex, bento-like composition, or another topology from information architecture and responsive evidence; visual trends do not define the component model. |

Use container queries for portable component recomposition when the browser matrix and component ownership support them. Use viewport media queries for document-level layout, global navigation, or when the repository's responsive system requires them. Choose mobile-first or desktop-first from content, product priorities, and existing code; neither is universally correct.

Reserve media geometry with `aspect-ratio`, dimensions, or an equivalent layout contract when it reduces measured layout shift. Do not replace a working layout solely to use a preferred pattern.

---

## 4. Accessibility and Motion

Use native HTML before ARIA substitutes. Accessibility requirements are implementation contracts, not visual polish.

| Concern | Baseline safeguard |
|---|---|
| Text and non-text contrast | Measure contrast against the applicable success criterion; document the pair and state, not only the token name. |
| Focus | Provide a persistent, visible `:focus-visible` indicator with measurable contrast and geometry that fits the applicable criterion. Keep focused content unobscured by sticky UI. |
| Keyboard and semantics | Preserve native keyboard behavior, labels, names, roles, and states. Add ARIA only when native semantics cannot express the contract. |
| Touch and pointer | Define target size and spacing from the applicable product/accessibility scope; do not infer a legal target from a visual trend. |
| Reduced motion | Honor `prefers-reduced-motion` with an equivalent low-motion or static experience; do not remove state feedback. |
| Motion implementation | Prefer the smallest mechanism that meets the interaction need. Gate WAAPI, scroll-driven CSS, observers, and script listeners on the browser matrix, motion policy, and measured main-thread cost. |

Example focus and motion treatment; adapt token names and values to the repository contract:

```css
:focus-visible {
  outline: 2px solid var(--s-focus);
  outline-offset: 4px;
}

@media (prefers-reduced-motion: reduce) {
  .transitioning {
    animation: none;
    transition-duration: 0ms;
  }
}
```

---

## 5. Visual Direction and Performance

Visual trends are optional treatments. Adopt them only when the approved design source, content hierarchy, browser matrix, accessibility scope, and performance evidence support them.

| Area | Decision rule |
|---|---|
| Bento-like grids, glass, gradients, or bold type | Use only when they improve the stated information hierarchy and retain contrast, focus, affordance, and responsive behavior. |
| Dark-first presentation | Use only when the product and design source require it; preserve equivalent semantics and contrast in every supported theme. |
| `content-visibility` and `contain` | Use only after confirming the rendering and accessibility behavior for the content and measuring the relevant performance target. |
| `will-change` | Use transiently and only when profiling justifies it; remove it when the animation no longer needs it. |
| Images and fonts | Select formats, fallbacks, dimensions, loading strategy, and font metrics from the actual delivery/browser matrix and layout-shift evidence. |

Avoid declaring a format, rendering feature, or trend universally supported, adopted, prohibited, or optimal without current project-specific evidence.

---

## 6. Local Design Handoff

A repository may use `Design.md`, `design.md`, token files, a design-system package, a design-tool export, or another approved source. Inspect the actual source before implementation.

When a local source exists:

1. Extract its token, semantic, component, and state contracts instead of guessing defaults.
2. Preserve its case-sensitive path and ownership; do not require a file rename or claim that the path is an external standard.
3. Reconcile conflicts with repository code and team conventions before generating CSS.
4. Validate contrast, focus, reduced motion, responsive behavior, and performance against the target implementation.

A local handoff can improve reviewability, but it does not replace product decisions, accessibility acceptance criteria, browser support policy, or performance evidence.

---

## 7. Command Availability

Run a command only when the repository already provides the dependency, target, permission, and expected evidence. Prefer its documented package-manager scripts. Do not introduce an implicit install or external audit target merely to follow this reference.

| Need | Conditional validation |
|---|---|
| Token contrast | Use the repository's contrast test or an approved checker when it can evaluate the real token/state pairs. |
| Accessibility and performance | Run the repository's configured audit against an approved target when the environment and target are available. |
| CSS support | Check the project browser matrix or configured compatibility tooling before adopting a platform feature. |
| Images or fonts | Use the repository's delivery pipeline and measure output, fallback, and layout shift before changing formats or loading behavior. |

If no relevant command or environment is available, report that evidence is needed rather than inventing a successful validation result.

---

## Resources

- CSS Nesting W3C: https://www.w3.org/TR/css-nesting-1/
- MDN Container Queries: https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_container_queries
- CSS Scroll-Driven Animations: https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations
- WCAG 2.2: https://www.w3.org/TR/WCAG22/
- Source index: `source-index.md`
