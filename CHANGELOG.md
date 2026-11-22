# Changelog

All notable changes to this project are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## 0.1.0 (release candidate, not yet released)

The first release. It converts UiPath workflow files (`.xaml`) into editable draw.io diagrams, on Windows, with nothing to install beyond PowerShell.

### What it does

- **State machines:** states, named transitions, the start marker, final states, and the workflows each state invokes.
- **Flowcharts:** steps, decisions, switches, branch labels and connections. A step whose activity comes from a custom or third-party package is drawn as a dashed box showing its type.
- **Project map:** one box per workflow and an arrow for each workflow call, with links to each workflow's page. Missing, outside-project and run-time file names are marked, never guessed. Large projects are wrapped onto several rows to keep the map readable.
- **Summary pages** for every other workflow, such as sequences, listing the workflows they invoke and how many activities they do not draw.
- **Conversion report** for every run: what was drawn and what was summarised, missing references, activities grouped by source (UiPath packages, Workflow Foundation, other libraries or packages), warnings, and read or write failures.
- **Studio's saved layout** is used when every node has one. It is stretched to fit the text, and crowded arrow labels are moved along their arrows to a clear place. Otherwise the diagram is laid out automatically, with arrows routed around boxes.

### Safety and privacy

- Workflow files are read as data. Nothing in them is executed or evaluated, and nothing is uploaded.
- Paths outside the project, including network shares, are never looked up.
- Conditions, expressions and run-time file names are left out unless `-IncludeDetails` is given. Names and labels remain, so outputs are not anonymised.

### Compatibility

- Windows PowerShell 5.1 and PowerShell 7 give byte-identical output.
- Tested on 93 public UiPath projects (Studio 2018 to 2026; classic, Windows-Legacy and Windows; VB and C#): all converted, with no diagram problems. See the [compatibility report](docs/compatibility-report.md).

### Known limitations

- **Most real workflows get a summary page only.** Sequences, If, Try/Catch and loops are not drawn step by step; in the compatibility corpus, 10% of workflows are drawn in detail. Sequence support is the next milestone.
- Activities inside states, and flowcharts or state machines nested inside other activities, are not expanded.
- Only Invoke Workflow File creates links. Invoke Process, Run Parallel Process and coded workflows (`.cs`) are not followed.
- Invoked file names are resolved relative to the project folder, as UiPath documents. A name written relative to the calling file's folder is reported as missing.
- On Studio layouts, a long arrow label on a short arrow can still touch a nearby box, and one crowded state stretches the whole layout.
- Cross-platform (portable) projects have not been tested: none was available in the corpus.
- Diagrams show structure, not runtime behaviour.
