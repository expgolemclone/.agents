# Frontend Design Systems Source Index

Source pointers for `../SKILL.md` and `technical-reference.md` in the current v3.0.1 package.

## Verification Policy

- Do not add browser, API, accessibility-law, security, adoption, or version claims without checking a current authoritative source.
- A source URL is a starting point, not proof that a feature fits the repository's browser matrix, product scope, or build pipeline.
- Record the verification date, source URL, scope, and confirmed behavior when adding a time-sensitive claim to release documentation.
- The architecture examples in this package are conditional guidance; they do not establish current ecosystem support, adoption, or legal applicability.

## Source Pointers

| Topic | Source | Use |
|---|---|---|
| CSS nesting | https://www.w3.org/TR/css-nesting-1/ | Check syntax and support requirements before adoption. |
| OKLCH | https://evilmartians.com/chronicles/oklch-in-css-why-quit-rgb-hsl | Background on perceptual color workflow; validate browser and pipeline fit separately. |
| Container queries | https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_container_queries | Check component-query support and fallback needs. |
| Scroll-driven animations | https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations | Check browser support, motion policy, and fallback requirements. |
| WCAG 2.2 | https://www.w3.org/TR/WCAG22/ | Establish applicable accessibility success criteria and measurement method. |
| European Accessibility Act | https://commission.europa.eu/strategy-and-policy/policies/justice-and-fundamental-rights/disability/european-accessibility-act-eaa_en | Confirm product and jurisdictional applicability with the responsible team. |
| Local design handoff | Repository design source | Treat `Design.md`, `design.md`, tokens, or another approved source as project-local inputs, not an external standard. |
