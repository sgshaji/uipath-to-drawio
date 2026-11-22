# Usage guide

See the [README](../README.md) for installation, the sample quick start, supported content and command-line options. This guide explains how the converter represents your files and how to interpret incomplete results.

## Finding workflows

- **Project folder:** the converter scans for `.xaml` files in the folder and its subfolders. It skips:
  - folders whose names start with a dot, such as Studio's `.local`, `.settings` and `.objects`;
  - Studio's backup files, whose names start with `~`;
  - hidden files and folders;
  - links to other folders, including junctions and symbolic links, which can loop or lead outside the project;
  - folders it cannot read. Unreadable folders and skipped links are listed in the report; the rest of the project is still converted.
- **Single file:** only that file is converted. The converter searches upwards for `project.json` to find the project root for resolving invoked file names. If none is found, it uses the file's own folder.
- **Main workflow:** taken from `main` in `project.json`, otherwise `Main.xaml`. When included in the conversion, it is the first workflow page and is highlighted on the project map.

Converting a single file does not recursively convert the files it invokes. Use a project folder when you want the project map and linked workflow pages.

## Reading workflows

Each file is read as XML. Nothing in it is run or evaluated. The top-level activity determines the page type:

| Kind | Representation |
| --- | --- |
| State machine | A diagram of states, transitions and invoked workflows. |
| Flowchart | A diagram of steps, decisions, switches and connections. |
| Sequence | A sequence page: its activities top to bottom, with its If, Else If and Switch branches, Try/Catch regions and loops. See [Sequences](#sequences). (Release 0.1.0 gives a summary page instead.) |
| Other activity, such as Try/Catch or a loop | A summary listing the workflows it invokes. Activities inside it are not drawn step by step. |
| Empty workflow | A page identifying it as empty. |
| A `.xaml` file that is not a UiPath workflow | A page explaining that it is not a workflow, plus a report entry. |
| A file that cannot be read | A page identifying the read failure, plus a report entry with the reason and, for malformed XML, the line and position. |

Summary pages are intentional, not evidence that the workflow has no business logic. A flowchart nested inside a top-level sequence is not treated as a top-level flowchart.

## Diagram details

### State machines

- A start marker points to the initial state.
- Each state lists the workflows it invokes on entry or exit. Workflows invoked during a transition are listed on its source state, marked with the transition's name.
- Final states have a thick red border.
- Transitions are arrows labelled with their names. `-IncludeDetails` adds their conditions.
- A nested state machine is not expanded; its invoked workflows are listed on the outer state. Other activities inside a state are not drawn individually.

### Flowcharts

- A start marker points to the first step.
- Each step is named after its activity:
  - an Invoke Workflow File step names the invoked file;
  - a sequence or other container lists workflows invoked inside it, without expanding its activities;
  - a step whose activity comes from neither a UiPath package nor .NET's Workflow Foundation (for example, a project's own library or a third-party package) shows its activity type in a plain dashed box. The report lists each such type with its package;
  - a nested flowchart or state machine is not expanded; this is noted in the report.
- Decisions are diamonds with the branch labels saved in Studio, such as Yes and No, or True and False when no labels are saved. As in Studio, the decision's text sits below the diamond; when an arrow meets the diamond's bottom point, the text moves to the lower right so the arrow does not run through it.
- Switches are diamonds with case names and a default branch. The default label comes from Studio when available, otherwise it is Default.
- A connection that points to a step that does not exist is not drawn and produces a report warning.

### Sequences

A workflow whose top-level activity is a Sequence gets a sequence page. Sequence pages were added in release 0.2.0.

- The sequence is a frame with its name at the top. Its activities are stacked inside it, top to bottom, in the order written, joined by arrows.
- A sequence inside it is a frame of its own, up to 8 levels deep. Frames are draw.io containers: moving one moves its contents. A deeper sequence is collapsed into one box saying how many activities it holds.
- An Invoke Workflow File step names the invoked file and links to its page, or is marked missing, outside the project or set at run time.
- A single activity is a box named by its display name, or by its type when it has none. An activity from another library or package is a dashed box showing its type.
- **If, Else If and Switch are drawn with their branches.** The decision is a diamond named by its display name. Its branches sit side by side below it, each labelled, and meet again at a small dot; the sequence carries on from the dot.
  - An If has a Then branch and an Else branch, in that order.
  - A Switch has one branch per case, labelled with the case value, in the order the file lists them, and then Default.
  - An Else If (UiPath's Else If activity) is a chain: the first condition's Else leads to a diamond for the next condition, and so on; the Else block is the last Else. This keeps the order in which the conditions are tried.
  - Each branch holds what the file holds: a sequence is a frame, a nested decision is drawn the same way, and other containers are dashed boxes.
  - **A branch with nothing in it** (a missing Then or Else, an empty case, a missing Default) is an arrow straight to the dot: when it is taken, nothing happens.
  - Decisions count towards the 8-level depth limit, like sequences, Try Catches and loops.
- **A Try Catch is a frame holding its regions** in the order written: Try, each Catch named after its exception type (for example `System.Exception`, or `BusinessRuleException` when the file gives no .NET namespace), and Finally if there is one. An empty region says "(nothing here)".
  - No arrows join the regions. Handling an exception is not an ordinary path, and the file does not say which Catch handles a given exception.
  - The headers say only what Microsoft's Workflow Foundation documentation states: a Catch runs "only if the Try throws one" of its type; Finally runs "after the Try, or a Catch that handled its exception, completes". Finally is not described as always running, because it does not run for an exception that no Catch handles.
- **A loop is a frame holding its body**, with no arrow looping back. The header of the body says when it runs, in the words of UiPath's and Microsoft's documentation:
  - For Each: once for each item in the collection. For Each Row: once for each row of the data table.
  - While: while the Condition is true; the Condition is checked before each run.
  - Do While: once, then again while the Condition is true; the Condition is checked after each run.
  - Retry Scope: an Action region ("run again if it throws an error or the Condition is not met") and a Condition region holding the condition activity. The retry count is not shown, because what the number means differs between versions of the activity, and nothing is said about an empty Condition, because its effect is not documented.
  - With `-IncludeDetails`, a While shows its condition above the body, a Do While below it, and a For Each or For Each Row its collection or data table above it, as text.
- **Break, Continue, Return, Throw, Rethrow and Terminate Workflow end the path.** Their box has a heavier border and says what the activity does ("exits the loop", "skips the rest of this iteration", "ends the workflow without an error", "throws an exception", "rethrows the exception", "ends the workflow"), and no arrow leaves it. An arrow means "this may run next":
  - A sequence ends the path if one of its own activities does: nothing after that activity has an arrow in.
  - A decision ends the path if every one of its branches does. Its branches then have no dot to meet at, and no arrow leaves the decision.
  - A Do While ends the path if its body always ends the workflow (Return, Throw, Rethrow or Terminate Workflow), because its body runs at least once.
  - A Try Catch, and any other loop, keeps the arrow after it: an exception may be caught, a loop may run zero times, and Break and Continue act only inside their loop.
- **Any other activity that holds activities is not expanded.** Application and browser scopes, Parallel For Each, For Each File, Repeat Number Of Times, nested flowcharts and state machines, and containers from other packages are each drawn as one dashed box. The box names the activity type, says how many activities it holds, and lists the workflows invoked inside it. Nothing is drawn or guessed about what it does with its contents.
- A Comment Out box says its activities are commented out and do not run; workflows invoked inside it are listed as commented out.
- Conditions, switch expressions and collections are never evaluated. They are left out by default; `-IncludeDetails` adds them as text.

The report's line for each workflow ends with "Activities drawn: N of M", counting the activities below the top-level one. On a sequence page, the activities not drawn are exactly those inside the dashed boxes. The line also counts the decisions drawn with their branches, by type, and the activities not expanded, by type. A page with a step diagram is not necessarily complete: only "Activities drawn: N of N" means every activity is shown.

### Layout

The converter reads both inline ViewState and the separate ViewStateManager layout format. When every node has a usable saved position, those relative positions and Studio's arrow routes are retained. The layout may be stretched horizontally and vertically to fit longer labels.

Arrow labels normally sit halfway along their arrows. Where Studio's routes run close together, a label that would land on another label, a box or a decision's text is moved along its own arrow to the nearest clear place. Boxes and routes are never moved for this. A long label on a short arrow can still touch a nearby box when no clear place exists.

If any node's position is missing or damaged, the whole diagram uses an automatic top-to-bottom layout instead. Arrows are routed around boxes, with separate routes for parallel connections. The report states which layout was used.

Sequence pages ignore saved positions, since Studio arranges a sequence's activities in order itself. Each frame's activities are centred and stacked top to bottom, so every arrow runs straight down.

## Workflow links

The converter reads **Invoke Workflow File** activities and resolves literal file names relative to the project root, not the calling file's folder. This follows UiPath's documentation for the activity, which says the file path "is relative to the current project folder". A workflow that names a file relative to its own folder is therefore reported as missing, even if such a file exists there. Both slash styles in XAML paths are accepted.

| State | Meaning | Representation |
| --- | --- | --- |
| Linked | The target is part of the conversion. | A link to its workflow page when pages share one output file. |
| Missing | The target does not exist. | Dashed red, marked "missing". |
| Not converted | The target exists but was not included, for example because it is in a skipped folder. | Dashed grey and marked "not converted" on the map; named without a link on workflow pages. |
| Outside the project | The path leads to another drive, a network share or above the project root. It is never looked up. | Dashed grey, marked "outside the project". Only the file name is shown unless `-IncludeDetails` is used. |
| Set at run time | The target is an expression, so the converter cannot resolve it without execution. | Dashed grey, marked "file name set at run time". `-IncludeDetails` shows the expression. |

The project map has one box per converted workflow and an arrow for each caller/callee pair. Repeated invokes of the same target are counted on the arrow, for example "x3".

The map is laid out top to bottom, callers above the workflows they invoke. In large projects it is kept to a readable width:

- A row wider than about 1,600 pixels is wrapped onto several rows. Workflows that invoke nothing go in the upper rows, and workflows whose arrows continue further down go in the lowest one.
- An arrow that must pass rows on its way down drops through a gap left between boxes, like the trunk of an organisation chart. Arrows from the same workflow share that trunk.
- Workflows that neither invoke nor are invoked by any other converted workflow are placed in rows of their own at the bottom.

An arrow only goes round the side of the map when an invoke leads back up, for example when two workflows invoke each other.

Only Invoke Workflow File creates these links. Invoke Process and Run Parallel Process are not followed. Coded workflows (`.cs`) are not converted; invoked names that do not end in `.xaml` are treated as set at run time.

## Output files

| Input and options | Output |
| --- | --- |
| Project folder | `<project>.drawio`, with the project map followed by workflow pages, and `<project>.conversion-report.txt`. The project name comes from `project.json`, otherwise the folder name. |
| Project folder with `-OnePerFile` | One `.drawio` per workflow, named from its relative path, such as `Framework_Init.drawio`; `<project> - project map.drawio`; and the report. Output names are made unique when paths would produce the same name. Page links are not retained across these separate files. |
| Single `.xaml` file | `<file>.drawio` with one workflow page and `<file>.conversion-report.txt`. Invoked workflows are named but are not converted or linked. |

`-OutputPath` names a folder, not a file. It is created if needed. Without it, output goes beside the input file or beside the project folder.

**Existing files with the same output names are replaced.** Save annotated diagrams under different names or in a separate folder; regeneration does not merge edits.

The converter writes each file to a temporary file in the output folder before copying it into place. If a diagram cannot be written, it records the failure and continues with the other outputs. The report is written last so it can include diagram write failures. A run can leave some completed outputs even when it exits with an error.

## Conversion report

**Always read the report.** Exit code **0** means the outputs were written, not that every workflow could be read or every activity could be drawn. Exit code **1** means the tool could not start or could not write an output, including the report itself.

`-PassThru` returns `DrawioFiles`, `ReportFile`, `Workflows`, `Warnings`, `SkippedFolders` and `WriteErrors`. The workflow count is not a count of fully rendered workflows, and an empty `Warnings` array is not a completeness check: read failures, summary pages and unresolved invokes have their own report sections.

| Section | What to check |
| --- | --- |
| Workflows converted | Each file's kind, what was drawn or summarised, and whether Studio's layout was used. A listed workflow may instead have a read-error page. |
| Invoked workflows not found | Missing targets and the workflows that invoke them. |
| Invoked files outside the project folder | Targets deliberately not looked up; their existence is unknown. |
| File names set at run time, so not linked | Targets that cannot be resolved without evaluating an expression. |
| Activities by source | Activity counts grouped by where each type comes from: UiPath packages, Workflow Foundation (part of .NET), and other libraries or packages. Types from other libraries are listed one by one with their package, count and the files that use them (the first five, then a count of the rest). Grouping by source does not mean the converter understands what an activity does. |
| Not drawn in version 1 | Summary-only workflows, activities inside states, and activities inside boxes not expanded on sequence pages, with how many activities each leaves out. |
| Warnings | Unresolved diagram connections, missing start nodes and nested diagrams that were not expanded. |
| Files that could not be read | Read failures, such as malformed XML or access denied. |
| Files that are not workflows | Files with a `.xaml` extension that contain other kinds of XML. |
| Folders skipped | Unreadable folders and links that were not followed. |
| Files that could not be written | Failed diagram writes and their reasons. |

The report avoids absolute input and output paths in its header, but retains file names, project-relative paths and some activity labels. `-IncludeDetails` can also add runtime expressions and full outside-project invoke paths. Neither diagrams nor reports are anonymised; follow the [privacy guidance](../README.md#privacy-and-security) before sharing them.

## Diagram legend

| Shape | Meaning |
| --- | --- |
| Green circle | Start of a state machine or flowchart. |
| Blue rounded box | A state, with invoked workflows listed under its name where applicable. |
| Box with a thick red border | A final state. |
| White box | A flowchart step. |
| Purple box | A step that invokes a workflow. |
| Grey box with a header | A container or summary page listing invoked workflows. |
| Blue-grey frame with a header | A sequence, holding its activities top to bottom. |
| Dashed grey box with a header | An activity holding others that is not expanded (such as a browser scope), or a Comment Out. The first line says what it is and how many activities it holds. |
| Small grey dot | On a sequence page, where the branches of a decision meet again. |
| Frame with a light orange header | A Try Catch, holding its Try, Catch and Finally regions. |
| Frame with a light green header | A loop or Retry Scope, holding its body. |
| White box with a heavier border | Break, Continue, Throw, Rethrow or Terminate Workflow: the path ends there, so no arrow leaves it. |
| Dashed grey box showing a type in brackets | A flowchart step whose activity comes from another library or package (not UiPath or Workflow Foundation). |
| Yellow diamond | A flow decision. |
| Orange diamond | A flow switch. |
| Blue box on the project map | A workflow. The main workflow has a thick border; an unreadable file is red. |
| Dashed red box | A missing invoked file. |
| Dashed grey box | An invoked file that was not converted, is outside the project or is set at run time; or a file that is not a workflow. Read the label to distinguish them. |

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| "running scripts is disabled on this system" or "is not digitally signed" | Review and unblock the downloaded script as described in the [quick start](../README.md#quick-start). Unblocking removes the download mark; it does not change execution policy. On managed devices, follow your organisation's policy. |
| "Path not found" | Check `-Path`. Use **Copy as path** in File Explorer and keep quotes around paths containing spaces. |
| "Could not write ... diagram file(s)" | Check folder permissions, read-only files, disk space and whether another application has locked an output. The report names failed diagrams when it can be written. |
| A diagram opens as XML in Visual Studio Code | Install the Draw.io Integration extension, or open it in the draw.io desktop app. |
| A page lists invoked workflows but has no individual steps | Its top-level activity is summary-only. See [supported content](../README.md#supported-content); `-IncludeDetails` does not enable deeper rendering. |
| A workflow is missing from the output | Check the [scanning rules](#finding-workflows) and skipped-folder report. Single-file conversion includes only the selected file. |
| The layout differs from Studio | Longer labels can stretch a saved layout, and crowded arrow labels are moved along their arrows. Any missing or damaged node position makes the whole diagram use automatic layout. |

Where your execution policy permits a per-process override, you can run the sample in a separate Windows PowerShell process without changing the machine-wide policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Convert-UiPathToDrawio.ps1 -Path .\samples\project -OutputPath .\output\demo
```

An organisation-enforced policy may still prevent this; do not use it to circumvent those controls.

## Checking a generated file

From the repository folder, check the quick-start output with the existing test script:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Converter.ps1 -CheckFile .\output\demo\OrderIntakeDemo.drawio
```

`-CheckFile` checks XML structure, cell identifiers, arrow targets, page links and encoding. It does **not** prove that every activity was drawn or that the visual layout is readable. Open the file in draw.io and inspect it separately; use the offline desktop app for confidential diagrams.
