# Compatibility report: public UiPath projects

This report has two parts, measured on the same pinned corpus of 93 public projects:

- **[Part 1: release 0.1.0](#part-1-release-010)**, published on 22 November 2026 (tag `v0.1.0`). Its figures are kept as they were measured and describe what the released download does. In 0.1.0, sequences get a summary page.
- **[Part 2: unreleased work on the main branch](#part-2-unreleased-work-on-the-main-branch)**: milestones S0, S1 and S2, built after 0.1.0. Nothing in Part 2 is in a release yet.

All figures come from runs of [`tests/compatibility/Invoke-CompatibilityRun.ps1`](../tests/compatibility/Invoke-CompatibilityRun.ps1) on Windows 11 with PowerShell 7.7 and Windows PowerShell 5.1.

## Terms used in this report

- **Converted** (or processed): the converter read every workflow file in the project and wrote a valid diagram file and report, without errors. It says nothing about how much of each workflow is drawn.
- **Drawn in detail**: the workflow's page is a full diagram: every state and transition of a state machine, or every step, decision and switch of a flowchart.
- **Summary only**: the workflow's page lists only the workflows it invokes. In release 0.1.0 this is how sequences and every other top-level activity are shown.
- **Step-by-step page** (Part 2): a state machine, flowchart or sequence page that draws steps. It can still leave activities out: on a sequence page, an activity that holds others and is not expanded is one box.
- **Activities drawn**: activities below each workflow's top-level one that are drawn as their own shape. A workflow has **every activity drawn** only when none is left out.
- **Not expanded**: an activity that holds others, drawn as one box that says how many activities it holds.

A project can be converted successfully while every one of its workflows is summary only, and a workflow can have a step-by-step page without every activity drawn. Read the measures separately.

## Part 1: Release 0.1.0

**Tested: 22 November 2026.** First run: commit `4cbcf07`, which led to fixes R1 and R2 (commit `818850a`). Re-run after the R4, R5 and R6 changes, with the converter as released in 0.1.0 (commit `70be985`).

### Summary

- **93 public UiPath projects** (657 workflow files), from Studio 2018 to Studio 2026, covering classic, Windows-Legacy and Windows projects, VB and C# expressions, processes, libraries and test projects.
- **Before the fixes**, one project failed to convert: an activity property name crashed the converter (R1 below).
- **After the fixes**, all 93 projects are converted in both PowerShell versions, with **byte-identical output in PowerShell 5.1 and 7**. No diagram has a structural problem, and automatically laid-out pages have no arrow or label problems. Being converted does not mean being drawn in detail; see the next point.
- **Coverage is the main gap.** 88% of real workflows have a Sequence at the top level, which gets only a summary page. Only **64 of 657 workflows (10%)** get a detailed diagram, and 63 of the 93 projects have no detailed diagram at all.
- Conversion takes about 1 second per project. The slowest project took 3 seconds in PowerShell 7 and 2.4 seconds in Windows PowerShell 5.1; times vary from run to run.

### How the corpus was chosen

Projects were found with GitHub code search for `project.json` files containing `studioVersion`, with further searches for each target framework, expression language and project type, and by the `uipath` and `reframework` repository topics. Every hit with a readable `project.json` (98 projects) was included rather than hand-picked. Five repositories could no longer be fetched, leaving 93.

Each project is pinned to the exact commit tested, in [`tests/compatibility/corpus.csv`](../tests/compatibility/corpus.csv). No third-party files are stored in this repository.

**Limits of the sample**

- Most projects are personal, learning or demonstration projects, and many are built on REFramework. Large enterprise projects are under-represented.
- **No cross-platform ("Portable") projects** were found. There are only 3 libraries and 1 test project.
- Coded workflows (`.cs`) were not downloaded, so this report adds nothing about them beyond the documented limitation.
- Studio versions come from each `project.json`, not from inspecting the files.

### Corpus and coverage

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

### What real workflows look like

The top-level activity of each of the 657 workflow files:

| Top-level activity | Files | Share | How 0.1.0 shows it |
| --- | --- | --- | --- |
| Sequence | 578 | 88% | Summary page |
| Flowchart | 44 | 7% | Detailed diagram |
| State machine | 20 | 3% | Detailed diagram |
| Try/Catch | 10 | 2% | Summary page |
| Other (5 single cases) | 5 | 1% | Summary page |

Inside these workflows there are 3,303 sequences, 925 If, 456 Try/Catch, 285 loops (157 For Each and 128 For Each Row), 46 Retry Scope and 718 Invoke Workflow File activities. Containers nest to a median depth of 2 per file (90th percentile 6, maximum 27).

### Results

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

**Invoked files reported missing (15):** each was checked against the whole repository. 13 are genuinely absent, typically REFramework's `Framework` files left out of an upload. The other 2 name a file relative to the calling workflow's folder; under UiPath's documented rule they are missing too (R7).

**File names set at run time (16):** all are VB expressions that build the file name from data, as REFramework's test runner does. Reporting them as unknown is correct.

**Visual review:** the largest state machine, flowchart and project map were rendered with the draw.io desktop app and inspected. Findings R4 and R5 come from that review, and their fixes were checked the same way.

### Reliability issues, in priority order

| ID | Priority | Issue | Evidence | Status |
| --- | --- | --- | --- | --- |
| **R1** | **P0** | **A whole project failed to convert** because an activity had a property named `Attributes`. PowerShell lets an XML attribute hide the element property of the same name, so the converter got text instead of the attribute list. Any activity property named like an XML property (`Attributes`, `ChildNodes`, `ParentNode`, `InnerText` and others) could do this. | `fc205/DependencyViewer` (Get XML Node Attributes activity). Reproduced with a made-up test input. | **Fixed** (commit `818850a`). XML properties are now read through .NET's accessors. Test added. All 93 projects convert, and the diagrams of the other 92 are byte-identical to before. |
| **R2** | **P1** | **The report listed expressions as unrecognised activities.** C# projects give every expression element a layout ID, so `CSharpValue` and `CSharpReference` were counted as activities, as were Multiple Assign items (`AssignOperation`). | In the first runs, 49 of 93 projects' lists got shorter after the fix; 23 C# projects were affected. | **Fixed** (commit `818850a`). Test added. |
| **R3** | **P1** | **Most workflows get only a summary page.** | 593 of 657 workflows; 63 of 93 projects have no detailed diagram. | Open in 0.1.0. On the main branch (unreleased), sequences are drawn step by step with their If, Else If and Switch branches: see [Part 2](#part-2-unreleased-work-on-the-main-branch). |
| **R4** | P2 | **Large project maps are hard to read.** Workflows used by several callers are pushed to the bottom row, so arrows skip rows and are routed round side lanes, and the map becomes very wide. | `Sundsvallskommun/RPA-elevresor`: 33 boxes and 37 arrows, 9 of them round side lanes; the map is 5,265 pixels wide. | **Fixed.** Rows wider than about 1,600 pixels wrap onto several rows; arrows that pass rows drop through gaps between boxes instead of side lanes; workflows with no arrows go to the bottom. See [R4 comparison](#r4-layout-approaches-compared). Across the corpus, maps wider than 2,000 pixels fell from 19 to 0 (widest 5,331 to 1,769), arrow crossings from 980 to 609, and maps with arrows routed outside the boxes from 17 to 5. None of the remaining 5 is a side lane: each is a trunk running in the gap at the end of a row, within 40 pixels of the outermost box. Wrapped maps are taller (19 maps more than 1.5 times taller). |
| **R5** | P2 | **Labels collide on some Studio-layout diagrams.** Where Studio's own routes run close together, their labels overlap. Decision labels, drawn below the diamond as in Studio, can overlap outgoing arrows. One state listing many workflows stretches the whole layout, making every state tall. | `GirishKolhe/RPA_UiPath-Generate-Yearly-Report` (state machine: three transition labels overlap); `tosigoto/UiPath-SimpleOCR` (flowchart: decision labels over arrows). | **Partly fixed.** A label that would land on another label, a box or a decision's text is moved along its own arrow to the nearest clear place; a decision's text moves to the lower right when an arrow meets the diamond's bottom point. Label overlaps on Studio-layout pages fell from 10 to 2 across the corpus; 13 pages changed, and only in label placement. **Remaining:** a long label on a short arrow can still touch a box when no clear place exists (2 pages); one crowded state still stretches the whole layout. |
| **R6** | P2 | **The "Activity types not recognised" list is long and alarming.** It lists every activity not on a short built-in list (258 distinct types, such as Browser Scope and Element Exists), although this only matters where they appear as flowchart steps. | Every project with UI or Excel automation. | **Fixed.** The report now groups activities by source: UiPath packages, Workflow Foundation (part of .NET), and other libraries or packages, with a count per type. Only the last group is listed one by one, with its package and the files that use it; across the corpus it holds 140 uses, mainly projects' own libraries. Nothing is hidden: every activity is counted in one group. Flowchart steps from UiPath packages (such as Digitize Document) are no longer drawn as unknown boxes (2 diagrams changed). Summary pages now say how many activities they leave out. |
| **R7** | P3 | **Invoke paths written relative to the calling file are reported missing.** In a repository holding several projects under one `project.json`, some workflows invoke files relative to their own folder. The converter follows UiPath's documented rule (relative to the project folder); whether Studio falls back to the calling file's folder is unverified. | `DongJoonHan/RPA`: 2 invokes. | **Investigated; no change.** UiPath's documentation for Invoke Workflow File says: "The file path is relative to the current project folder." It documents no fallback to the calling file's folder, and its error messages treat a path outside the project as a failure. The converter already follows the documented rule, so these invokes are correctly reported missing. Forum reports (2025) agree but are not authoritative. |

### R4: layout approaches compared

The project map's automatic layout puts each workflow in a row by its longest call path from the top. In the 11 widest maps, one row held 11 to 18 workflows, most of them invoking nothing further, plus a few workflows connected to nothing at all. Approaches considered:

| Approach | Tried | Result |
| --- | --- | --- |
| A. Previous layout | Baseline | Wide, short maps; long arrows go round side lanes. |
| B. Rank by shortest path from Main instead of longest | Not built | Moves workflows between rows but does not reduce how many share a row, so on its own it does not fix the width. |
| C. Wrap wide rows, keep side lanes | Not built | Every arrow into a lower wrapped row would become a side-lane arrow, which is the other half of the problem. |
| **D. Wrap wide rows; arrows pass rows through gaps between boxes; unconnected workflows to the bottom** | **Built (chosen)** | See below. |
| D + crossing reduction (reorder rows towards linked boxes) | Built, then removed | Cut row-to-row crossings but not drawn crossings, which come mostly from the horizontal tracks between rows. Worse than D on 6 of 11 maps. |
| E. Full layered layout with crossing minimisation and coordinate assignment | Not built | Large change for a small project; revisit only if D proves insufficient. |

Measured on the 11 widest maps (sums over all 11; "outside" counts arrows with any point beyond the outermost boxes):

| | Arrow crossings | Arrows outside the boxes | Total arrow length (pixels) |
| --- | --- | --- | --- |
| A. Previous | 528 | 26 | 354,696 |
| D. Chosen | 368 | 12 | 169,467 |
| D + crossing reduction | 398 | 32 | 196,637 |

D is deterministic: it uses only the input's order and fixed rules, so PowerShell 5.1 and 7 give byte-identical files. It applies to the project map only. Flowchart and state-machine pages are laid out as before.

### Supported project types, as tested in 0.1.0

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

### Known limitations of 0.1.0

Documented in the 0.1.0 README and confirmed by the corpus:

- Sequences, If, Try/Catch and loops get summary pages (R3).
- Activities inside states, and nested flowcharts and state machines, are not expanded.
- Only Invoke Workflow File creates links on the project map.
- Diagrams show structure, not runtime behaviour.

## Part 2: Unreleased work on the main branch

After release 0.1.0, milestones S0, S1 and S2 of the [sequence plan](architecture-exploration.md#8-plan-detailed-uipath-sequence-support) were built and each was run against the same 93 projects. Every run converted all 93 projects in both PowerShell versions with identical output, and found no diagram check problems.

### What each milestone changed

| Milestone | What it does | Pages changed, compared with the previous run |
| --- | --- | --- |
| **S0** | The graph builders say what each shape is; one function decides how it is drawn. No visible change. | None: all 750 pages (657 workflow pages and 93 project maps) byte-identical to 0.1.0 |
| **S1** | Top-level sequences are drawn step by step: frames for sequences, boxes for activities, invoke steps linked. Any activity holding others is one box, not expanded. | The 578 sequence pages. The other 172 (state machines, flowcharts, project maps, remaining summary pages) byte-identical |
| **S2** | On sequence pages, If, Else If and Switch are drawn as decisions with their labelled branches, meeting again at a dot; an empty branch goes straight to the dot. | 161 sequence pages: exactly the 161 that contain an If, Else If or Switch within the depth limit (the two sets were compared). The other 589 byte-identical, including every state machine, flowchart and project map page |

### Coverage

| Measure | 0.1.0 (released) | S1 | S2 |
| --- | --- | --- | --- |
| Projects converted, both PowerShell versions | 93 of 93 | 93 of 93 | 93 of 93 |
| Workflows with a step-by-step page | 64 of 657 | 642 of 657 | 642 of 657 |
| Workflows with a summary page only | 593 | 15 | 15 |
| Activities drawn as their own shape | 299 of 13,191 (2.3%) | 2,429 (18.4%) | 3,451 (26.2%) |
| Workflows with every activity drawn | 13 | 169 | 246 |
| Decisions drawn with their branches (If, Else If, Switch) | 0 on sequence pages | 0 | 308 |
| Activities on sequence pages that hold others, not expanded | n/a (summary pages) | 703 | 525 |

**A step-by-step page is not a complete one.** Of the 642 workflows with a step-by-step page, 246 have every activity drawn. "Activities" counts every activity below each workflow's top-level one: on a state-machine page none of them is drawn (states and transitions are not activities); on a flowchart page, each step's own activity is.

| Workflow kind (S2) | Workflows | Activities drawn | Every activity drawn |
| --- | --- | --- | --- |
| Sequence | 578 | 3,152 of 10,663 (30%) | 233 |
| Flowchart | 44 | 299 of 1,239 (24%) | 13 |
| State machine | 20 | 0 of 1,103 | 0 |
| Summary pages (10 Try/Catch, 4 other top-level activities, 1 empty) | 15 | 0 of 186 | 0 |

### Control flow drawn in S2

| Construct | In the corpus | Drawn with branches on sequence pages |
| --- | --- | --- |
| If | 925 | 297 |
| Switch | 27 | 10 |
| Else If (UiPath's `IfElseIf`) | 8 | 1 |

Those 308 decisions have 641 branches; 141 of them are empty (a missing Then or Else, an empty case, a missing Default) and are drawn as going straight on. The other If, Switch and Else If activities are not drawn as decisions because they sit somewhere S2 does not expand: inside a Try/Catch, loop or scope; inside a flowchart step or a state; or in one of the 15 summary pages. Two activities are past the depth limit of 8 levels, which counts sequences and decisions, and are each one box ("Nested too deep to draw", holding 1 and 5 activities).

No Switch case had a missing, null or empty key, so no case label in the corpus is a placeholder.

**Still not expanded on sequence pages (S2), 525 activities:** Try/Catch 134, For Each 76, Browser Scope 64, Use Application/Browser 40, Comment Out 36, For Each Row 36, Excel Application Scope 32, Open Browser 20, Retry Scope 17, Open Application 9, and 61 more across 22 other types (each 7 or fewer), including 2 past the depth limit. Some counts are higher than in S1 (Try/Catch 113 to 134) because activities that were hidden inside a collapsed If are now drawn in its branches, where they are themselves not expanded.

### How the drawings were checked against the files

For every one of the 578 sequence pages, a separate script rebuilt the structure from the workflow file and compared it with the drawing: each frame must hold exactly the file's activities in the written order; each decision must have the file's branches, with the same labels in the same order; each branch must hold what the file holds, or go straight on when the file has nothing. The script reads the XAML independently of the converter.

| Run | Pages compared | Mismatches |
| --- | --- | --- |
| S1 drawings | 578 | 0 (S1 checks: frames and order) |
| Control: 0.1.0 drawings against the S1 check | 578 | 563 (the other 15 are empty sequences) |
| Control: S1 drawings against the S2 check | 578 | 161: exactly the pages with decisions, which S1 drew as boxes |
| S2 drawings | 578 | 0 |

The geometric checks also ran on every sequence page: every shape inside its container, no overlap, no arrow through a shape, no label over a shape or another label. No problems in S1 or S2. Pages were also rendered with the draw.io desktop app and inspected, including the largest, a Switch, an Else If chain and the page with the most decisions (14).

### Remaining gaps and layout defects

- **Most activities are still not drawn individually** (26% are). The largest groups are Try/Catch and loops (S3), and application and browser scopes, which are not yet in the plan.
- **Flowcharts and state machines inside sequences**, and **activities inside states and flowchart steps**, are not expanded (S4).
- **Layout:** a decision with a long display name becomes a very wide, flat diamond; long Else If chains and deeply nested decisions make pages tall (the tallest branching page is about 4,100 pixels). No overlaps or crossings were found by the checks.
- Conditions and switch expressions are not shown by default; with `-IncludeDetails` they are shown as text, never evaluated.

## Reproducing this report

```powershell
pwsh -File .\tests\compatibility\Invoke-CompatibilityRun.ps1
```

The script needs Git to download the corpus. It fetches only the `.xaml` and `project.json` files of each repository, at the commit listed in `corpus.csv`, into a folder in the temp directory. It converts each project in PowerShell 7 and Windows PowerShell 5.1, runs the diagram checks, and writes `results.csv` and `summary.txt` there. Nothing is written to this repository, and nothing from the downloaded projects is executed.

After each download the script confirms that the folder holds the pinned commit, and that every `.xaml` and `project.json` file in that commit is on disk. A project that fails this check is still converted, but it is flagged as an incomplete download and left out of the totals.

**How this was checked:** the script was run from an empty folder. It fetched all 93 projects at their pinned commits. For 92 of them, the diagrams were byte-identical to an earlier, independent run. The one difference is explained below.

**A lesson from the first attempt:** an earlier download used long folder names and silently lost 18 files of one project to Windows' 260-character path limit, which made 10 invoked files look missing. The script now uses short folder names and Git's long-path setting, and the figures in this report come from that corrected run.
