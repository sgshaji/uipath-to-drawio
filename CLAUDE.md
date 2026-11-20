# CLAUDE.md

Working rules for Claude Code in this repository. Read `CONTEXT.md` first: it has the background, scope, decisions and the technical notes on UiPath XAML and the draw.io format.

## Hard rules

- **Never commit real UiPath projects or workflows.** Real `.xaml` files (from clients, employers or anyone else) go only in `private/`, which Git ignores. Use them for local checks only, and never copy their content (names, paths, expressions, selectors) into code, tests, docs or commit messages.
- **Test data is made up.** Samples in `samples/` and test fixtures are written by hand for this project. Don't copy UiPath's own templates (such as REFramework) into the repository; write an equivalent.
- **No secrets.** Nothing in this tool needs keys or passwords.
- **Not affiliated with UiPath.** Use "UiPath" only to describe what the tool reads. No UiPath logos.
- **Don't publish** (create the GitHub repository, make it public, or release) until the open decisions in `CONTEXT.md` on employer policy and licence are settled and the owner says so.

## Conventions

- **PowerShell only**, compatible with **Windows PowerShell 5.1 and PowerShell 7**. No modules or packages needed at run time.
  - No PowerShell 7-only syntax: no `??`, `?.`, ternary `? :`, `&&` / `||` pipeline chains, or `-Parallel`.
  - Read files as UTF-8 explicitly; write `.drawio` files as UTF-8 without a byte-order mark.
- **Read XAML with `[xml]`** and match elements by **local name**, never by namespace prefix (they vary between Studio versions).
- **Never execute or evaluate anything from a XAML file.** It is data only.
- **Output must open in draw.io.** After any change to the output, check a generated file opens at app.diagrams.net or in the draw.io desktop app, and say so. If you can't check it, say that too.
- **Unknown activities are never dropped.** Draw them as a plain box and list them in the conversion report.
- **Keep it small.** One script plus helper functions until there is a clear reason to split into a module.
- Plain English in the README and docs. Keep `CONTEXT.md` current: record decisions and new findings about XAML there.

## Layout

| Path | Contents |
| --- | --- |
| `src/` | The converter script |
| `samples/` | Made-up UiPath workflows for trying and testing the tool |
| `tests/` | Automated tests |
| `docs/` | User documentation and images |
| `private/` | Real files for local checks only. Ignored by Git |
| `output/` | Generated diagrams. Ignored by Git |

## Environment

- Windows 11 on ARM, PowerShell 7 and Windows PowerShell 5.1 (5.1.26100), Git Bash.
- Windows PowerShell ships Pester 3.4.0. The test framework choice is an open decision in `CONTEXT.md`.
- The folder sits in OneDrive. That's fine here: there is no runtime data.
- Git: use the repository-local identity, as in the owner's other personal repositories. Commit or push only when asked.
