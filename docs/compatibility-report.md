# Compatibility report: public UiPath projects

**Tested: 22 November 2026.** Converter: commit `4cbcf07` plus the two reliability fixes described below (in review, not yet committed). Windows 11, PowerShell 7.7 and Windows PowerShell 5.1. All figures come from a from-scratch run of [`tests/compatibility/Invoke-CompatibilityRun.ps1`](../tests/compatibility/Invoke-CompatibilityRun.ps1) over the pinned corpus.

## Terms used in this report

- **Converted** (or processed): the converter read every workflow file in the project and wrote a valid diagram file and report, without errors. It says nothing about how much of each workflow is drawn.
- **Drawn in detail**: the workflow's page is a full diagram: every state and transition of a state machine, or every step, decision and switch of a flowchart.
- **Summary only**: the workflow's page lists only the workflows it invokes. This is how version 1 shows sequences and every other top-level activity.

A project can be converted successfully while every one of its workflows is summary only. Read the two measures separately.

## Summary

- **93 public UiPath projects** (657 workflow files), from Studio 2018 to Studio 2026, covering classic, Windows-Legacy and Windows projects, VB and C# expressions, processes, libraries and test projects.
- **Before the fixes**, one project failed to convert: an activity property name crashed the converter (R1 below).
- **After the fixes**, all 93 projects are converted in both PowerShell versions, with **byte-identical output in PowerShell 5.1 and 7**. No diagram has a structural problem, and automatically laid-out pages have no arrow or label problems. Being converted does not mean being drawn in detail; see the next point.
- **Coverage is the main gap.** 88% of real workflows have a Sequence at the top level, which gets only a summary page. Only **64 of 657 workflows (10%)** get a detailed diagram, and 63 of the 93 projects have no detailed diagram at all.
- Conversion takes about 1 second per project. The slowest project took 3 seconds in PowerShell 7 and 2.4 seconds in Windows PowerShell 5.1; times vary from run to run.

## How the corpus was chosen

Projects were found with GitHub code search for `project.json` files containing `studioVersion`, with further searches for each target framework, expression language and project type, and by the `uipath` and `reframework` repository topics. Every hit with a readable `project.json` (98 projects) was included rather than hand-picked. Five repositories could no longer be fetched, leaving 93.

Each project is pinned to the exact commit tested, in [`tests/compatibility/corpus.csv`](../tests/compatibility/corpus.csv). No third-party files are stored in this repository.

**Limits of the sample**

- Most projects are personal, learning or demonstration projects, and many are built on REFramework. Large enterprise projects are under-represented.
- **No cross-platform ("Portable") projects** were found. There are only 3 libraries and 1 test project.
- Coded workflows (`.cs`) were not downloaded, so this report adds nothing about them beyond the documented limitation.
- Studio versions come from each `project.json`, not from inspecting the files.

## Corpus and coverage

| Target framework | Projects | Workflows | Drawn in detail | Summary only |
| --- | --- | --- | --- | --- |
| Classic (no target framework) | 27 | 257 | 31 | 226 |
| Windows-Legacy | 29 | 187 | 18 | 169 |
| Windows | 37 | 213 | 15 | 198 |

| Studio version | Projects | Workflows | Drawn in detail | Summary only |
| --- | --- | --- | --- | --- |
| 2018 and 2019 | 23 | 201 | 24 | 177 |
| 2020 and 2021 | 35 | 249 | 25 | 224 |
| 2022 and 2023 | 10 | 56 | 4 | 52 |
| 2024 and later | 25 | 151 | 11 | 140 |

| Expression language | Projects | Workflows | Drawn in detail | Summary only |
| --- | --- | --- | --- | --- |
| VB (stated or default) | 70 | 574 | 59 | 515 |
| C# | 23 | 83 | 5 | 78 |

| Project type | Projects | Workflows | Drawn in detail | Summary only |
| --- | --- | --- | --- | --- |
| Process (stated or default) | 89 | 601 | 59 | 542 |
| Library | 3 | 35 | 0 | 35 |
| Test project | 1 | 21 | 5 | 16 |

Projects have a median of 3 workflow files and a maximum of 32.

## What real workflows look like

The top-level activity of each of the 657 workflow files:

| Top-level activity | Files | Share | How the converter shows it |
| --- | --- | --- | --- |
| Sequence | 578 | 88% | Summary page |
| Flowchart | 44 | 7% | Detailed diagram |
| State machine | 20 | 3% | Detailed diagram |
| Try/Catch | 10 | 2% | Summary page |
| Other (5 single cases) | 5 | 1% | Summary page |

Inside these workflows there are 3,303 sequences, 925 If, 456 Try/Catch, 285 loops (157 For Each and 128 For Each Row), 46 Retry Scope and 718 Invoke Workflow File activities. Containers nest to a median depth of 2 per file (90th percentile 6, maximum 27).

## Results

| Check | Result |
| --- | --- |
| Projects converted, PowerShell 7 and 5.1 | 93 of 93 (92 before fix R1) |
| Identical `.drawio` output in both versions | 93 of 93 |
| Structural check of every diagram (well-formed XML, unique ids, arrows to real shapes, plain numbers) | No problems |
| Arrow and label checks on automatically laid-out pages | No problems. Every state machine and flowchart in this corpus had a complete Studio layout, so these checks ran on the project maps. |
| Rows overflowing their box (680 boxes with listed workflows, first runs) | None |
| Studio layout used | All 64 detailed diagrams |
| File names with non-ASCII characters (Swedish, Korean, Japanese) | Converted correctly |
| Unreadable files, files that are not workflows, folders skipped | None in this corpus |

**Invoked files reported missing (15):** each was checked against the whole repository. 13 are genuinely absent, typically REFramework's `Framework` files left out of an upload. 2 are ambiguous (R7).

**File names set at run time (16):** all are VB expressions that build the file name from data, as REFramework's test runner does. Reporting them as unknown is correct.

**Visual review:** the largest state machine, flowchart and project map were rendered with the draw.io desktop app and inspected. Findings R4 and R5 come from that review.

## Reliability issues, in priority order

| ID | Priority | Issue | Evidence | Status |
| --- | --- | --- | --- | --- |
| **R1** | **P0** | **A whole project failed to convert** because an activity had a property named `Attributes`. PowerShell lets an XML attribute hide the element property of the same name, so the converter got text instead of the attribute list. Any activity property named like an XML property (`Attributes`, `ChildNodes`, `ParentNode`, `InnerText` and others) could do this. | `fc205/DependencyViewer` (Get XML Node Attributes activity). Reproduced with a made-up test input. | **Fixed, in review.** XML properties are now read through .NET's accessors. Test added. All 93 projects convert, and the diagrams of the other 92 are byte-identical to before. |
| **R2** | **P1** | **The report listed expressions as unrecognised activities.** C# projects give every expression element a layout ID, so `CSharpValue` and `CSharpReference` were counted as activities, as were Multiple Assign items (`AssignOperation`). | In the first runs, 49 of 93 projects' lists got shorter after the fix; 23 C# projects were affected. | **Fixed, in review.** Test added. |
| **R3** | **P1** | **Most workflows get only a summary page.** | 593 of 657 workflows; 63 of 93 projects have no detailed diagram. | Open: the sequence roadmap in [architecture-exploration.md](architecture-exploration.md#7-roadmap-detailed-uipath-sequence-support). |
| **R4** | P2 | **Large project maps are hard to read.** Workflows used by several callers are pushed to the bottom row, so arrows skip rows and are routed round side lanes, and the map becomes very wide. | `Sundsvallskommun/RPA-elevresor`: 33 boxes and 37 arrows, 9 of them round side lanes; the map is 5,265 pixels wide. | Open. Proposed: place each workflow by its shortest distance from the main workflow, and wrap very wide rows. |
| **R5** | P2 | **Labels collide on some Studio-layout diagrams.** Where Studio's own routes run close together, their labels overlap. Decision labels, drawn below the diamond as in Studio, can overlap outgoing arrows. One state listing many workflows stretches the whole layout, making every state tall. | `GirishKolhe/RPA_UiPath-Generate-Yearly-Report` (state machine: three transition labels overlap); `tosigoto/UiPath-SimpleOCR` (flowchart: decision labels over arrows). | Open. Proposed: move labels along the route to a clear spot; grow a crowded box instead of stretching the whole layout. |
| **R6** | P2 | **The "Activity types not recognised" list is long and alarming.** It lists every activity not on a short built-in list (258 distinct types, such as Browser Scope and Element Exists), although this only matters where they appear as flowchart steps. | Every project with UI or Excel automation. | Open. Proposed: list only the types actually drawn as unrecognised boxes, and summarise the rest. |
| **R7** | P3 | **Invoke paths written relative to the calling file are reported missing.** In a repository holding several projects under one `project.json`, some workflows invoke files relative to their own folder. The converter follows UiPath's documented rule (relative to the project folder); whether Studio falls back to the calling file's folder is unverified. | `DongJoonHan/RPA`: 2 invokes. | Open. Proposed: when a file is missing, say in the report if it exists relative to the calling file. |

## Supported project types, as tested

| Project type | Converts | Detailed diagrams |
| --- | --- | --- |
| Classic (Studio 2018 to 2020) | Yes (27 of 27) | State machines and flowcharts |
| Windows-Legacy | Yes (29 of 29) | State machines and flowcharts |
| Windows | Yes (37 of 37) | State machines and flowcharts |
| VB and C# expression projects | Yes | Expressions are not shown without `-IncludeDetails` |
| Libraries | Yes (3 of 3) | None in the sample: all their workflows were sequences |
| Test projects | Yes (1 of 1) | As for processes |
| Cross-platform (Portable) | Not tested: none found | Unknown |
| Coded workflows (`.cs`) | Not converted, by design | None |

## Known limitations

Documented in the README and confirmed by the corpus:

- Sequences, If, Try/Catch and loops get summary pages (R3).
- Activities inside states, and nested flowcharts and state machines, are not expanded.
- Only Invoke Workflow File creates links on the project map.
- Diagrams show structure, not runtime behaviour.

## Reproducing this report

```powershell
pwsh -File .\tests\compatibility\Invoke-CompatibilityRun.ps1
```

The script needs Git to download the corpus. It fetches only the `.xaml` and `project.json` files of each repository, at the commit listed in `corpus.csv`, into a folder in the temp directory. It converts each project in PowerShell 7 and Windows PowerShell 5.1, runs the diagram checks, and writes `results.csv` and `summary.txt` there. Nothing is written to this repository, and nothing from the downloaded projects is executed.

After each download the script confirms that the folder holds the pinned commit, and that every `.xaml` and `project.json` file in that commit is on disk. A project that fails this check is still converted, but it is flagged as an incomplete download and left out of the totals.

**How this was checked:** the script was run from an empty folder. It fetched all 93 projects at their pinned commits. For 92 of them, the diagrams were byte-identical to an earlier, independent run. The one difference is explained below.

**A lesson from the first attempt:** an earlier download used long folder names and silently lost 18 files of one project to Windows' 260-character path limit, which made 10 invoked files look missing. The script now uses short folder names and Git's long-path setting, and the figures in this report come from that corrected run.
