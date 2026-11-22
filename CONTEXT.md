# Context

Background, decisions and technical notes for this project. Read this first, then `CLAUDE.md`.

## What this is

A small command-line utility that converts **UiPath workflow files (`.xaml`)** into **editable draw.io diagrams (`.drawio`)**. It works on one file or a whole UiPath project folder.

It is meant to be a standalone, public, open-source project.

## Why it exists

- UiPath has no built-in way to export a workflow or project as a diagram. On the UiPath forum, people are told to redraw by hand ([1](https://forum.uipath.com/t/convert-xaml-file-to-diagram/455674), [2](https://forum.uipath.com/t/export-project-to-flowchart/2821428), [3](https://forum.uipath.com/t/how-to-create-vsd-flowchart-mircrosoft-visio-from-uipath-xaml/2801)).
- Related projects do other things: [flindersuni/rpa-doc](https://github.com/flindersuni/rpa-doc) writes text documentation from XAML; "rpax" ([forum post](https://forum.uipath.com/t/what-would-you-do-with-multi-project-uipath-workflow-data/5253844)) is a public CLI ([rpapub/rpax](https://github.com/rpapub/rpax)) that parses UiPath projects into JSON call graphs and diagrams; [marcelocruzrpa/uipath-xaml-viewer](https://github.com/marcelocruzrpa/uipath-xaml-viewer) shows XAML workflows as interactive diagrams on GitHub and GitLab; [AutoFor/uipath-xaml-visualizer](https://github.com/AutoFor/uipath-xaml-visualizer) is another viewer. None of them writes editable draw.io files (checked November 2026).
- Who it helps: teams documenting robots, reviewers and auditors, and teams moving processes off UiPath (for example to n8n or Power Automate), who need to see what a robot actually does.

The idea came from a real migration of a UiPath process to n8n. **None of that client's material belongs in this repository** (see `CLAUDE.md`).

## Goals

1. Any UiPath `.xaml` → a `.drawio` file that opens in draw.io and can be edited.
2. A whole project → one `.drawio` with a page per workflow, plus a first page showing which workflow calls which.
3. Nothing to install for users: runs in the PowerShell that ships with Windows.
4. Safe by default: reads only, writes only to the output folder, runs offline, and leaves out expressions and selectors unless asked.

## How it is used

```powershell
# One file
.\src\Convert-UiPathToDrawio.ps1 -Path .\Main.xaml

# A whole project
.\src\Convert-UiPathToDrawio.ps1 -Path C:\UiPath\MyProcess -OutputPath C:\Diagrams\MyProcess
```

| Option | Meaning |
| --- | --- |
| `-Path` | A `.xaml` file or a project folder |
| `-OutputPath` | Where to write. Default: the folder the input is in |
| `-OnePerFile` | One `.drawio` per `.xaml` plus a project map file, instead of one file with a page per workflow |
| `-IncludeDetails` | Add conditions, expressions and run-time file names. Off by default, so server names and values don't end up in shared diagrams |
| `-PassThru` | Return an object listing the files written (used by the tests) |
| `-MaxDepth <n>` | **Not built yet.** Planned for when sequences are drawn, to stop drawing nested steps below a depth |

Outputs:

- `<name>.drawio`, where `<name>` is the project name from `project.json` (or the folder name), or the file name for a single file.
- `<name>.conversion-report.txt`: what was converted, invoked files not found, file names set at run time, activity types not recognised, what version 1 doesn't draw, and warnings. Unknown activities are still drawn as a plain box.

## Scope

**Version 1 (built, November 2026)**

- State machines (for example REFramework's `Main.xaml`): states, transitions with their names, the workflows each state invokes.
- Flowcharts: steps, decisions (True/False), switches, start node.
- Project map: every `InvokeWorkflowFile` link between files.
- Positions taken from Studio's saved layout (ViewState) where present.
- Conversion report.

**Later**

- Sequences with automatic layout (`Sequence`, `If`, `TryCatch`, loops as frames).
- Collapsing UI automation steps to one-line boxes (for example "Click: Terminate").
- Annotations as notes.
- Mermaid output as a second format.
- Publishing to the PowerShell Gallery.

## How each UiPath element is drawn

| UiPath | draw.io |
| --- | --- |
| State | Rounded box; lists the workflows it invokes |
| Final state | Rounded box, end styling |
| Transition | Arrow labelled with its display name |
| Flowchart step | Box |
| Flow decision / switch | Diamond; True/False or case labels |
| Sequence | Boxes top to bottom |
| If | Diamond; Then and Else side by side |
| Try/Catch, loops | Labelled frame |
| Invoke Workflow File | Box linked to that workflow's page |
| UI steps (click, type) | One short box |
| Annotation | Note beside the step |

## Technical notes: UiPath XAML

Learned by inspecting a standard REFramework `Main.xaml` (55 KB, 486 elements). Verify against more samples.

- A `.xaml` file is XML. Root element: `Activity`, with `x:Class` = the workflow name.
- Namespaces vary by Studio version and project type (Windows, Windows-Legacy, cross-platform). **Match on element local names** (`local-name()` in XPath), not on prefixes.
- **State machine**
  - `StateMachine` → `StateMachine.InitialState` holds the first `State` inline.
  - Each `State` has `DisplayName`, optional `IsFinal="True"`, and `State.Entry` / `State.Exit` / `State.Transitions`.
  - A `Transition` sits inside its **source** state's `State.Transitions`.
  - Its **target** is either written inline (`Transition.To` → `State`), or given as `To="{x:Reference __ReferenceID1}"`, pointing at a state's `x:Name`. Build a map of `x:Name` → state first, then resolve.
  - The condition is in `Transition.Condition` (or a `Condition` attribute), for example `[SystemError Is Nothing]`. Expressions may be VB or C#.
- **Invoke Workflow File**: `InvokeWorkflowFile` with `WorkflowFileName` (relative path, backslashes, for example `Framework\GetTransactionData.xaml`) and `DisplayName`. Find its owning state by walking up the parents.
- **Layout (ViewState)** comes in two formats; the converter reads both.
  - *Older*: a `WorkflowViewStateService.ViewState` child on the element itself.
  - *Newer* (the REFramework `Main.xaml` checked uses this): the element has a `WorkflowViewState.IdRef` attribute (for example `State_3`), and the layout sits at the end of the file in `WorkflowViewState.ViewStateManager` → `ViewStateManager` → `ViewStateData Id="State_3"` → `WorkflowViewStateService.ViewState`.
  - Either way it's a `Dictionary` with entries keyed `ShapeLocation` (Point, `"x,y"`), `ShapeSize` (Size, `"w,h"`) and `ConnectorLocation` (PointCollection, `"x1,y1 x2,y2 ..."`). Numbers use `.` for decimals and can have many places (`86.6666666666667`).
  - The `StateMachine`'s (or `Flowchart`'s) own ViewState holds the **start marker**: `ShapeLocation`, sometimes `ShapeSize` (60×75 when missing), and `ConnectorLocation` for the arrow to the first node.
  - A connector's first point lies on the source shape's border and its last on the target's; the points between are the corners of Studio's route.
  - Studio's shapes are small (a state can be 124×134), so text needs more room. The converter stretches the whole picture, with one factor across and another down, so routes stay straight and still meet the shapes.
- **Flowchart**: `Flowchart`, `Flowchart.StartNode`, `FlowStep` (`FlowStep.Next`), `FlowDecision` (`FlowDecision.True` / `.False`, or `True=` / `False=` attributes), `FlowSwitch`; nodes linked by `x:Reference` in the same way. The flowchart's direct `<x:Reference>` children list every node.
  - Branch labels are ViewState entries, **not** attributes (corrected after the November 2026 audit). .NET's `FlowDecision` has only `Condition`, `True`, `False` and `DisplayName`; Studio saves `<x:String x:Key="TrueLabel">Yes</x:String>` and `FalseLabel` in the decision's ViewState, in either layout format. A switch's default-branch label is `DefaultCaseDisplayName` in its ViewState (from the WF designer source; not yet seen in a real file). Missing or blank labels fall back to True, False and Default.
  - `FlowSwitch` cases are children with an `x:Key`. The .NET XAML writer uses four forms, and the converter reads all of them:
    - an inline node with a key attribute: `<FlowStep x:Key="North" ...>`;
    - an inline node with a key element: `<FlowStep ...><x:Key><x:String>North</x:String></x:Key>`;
    - a reference with a key attribute: `<x:Reference x:Key="North">name</x:Reference>`;
    - a reference with a key element, used when a target is shared or defined elsewhere: `<x:Reference>name<x:Key>North</x:Key></x:Reference>`. Read the name from the element's own text, not `InnerText`, which glues the key on.
  - The default is `FlowSwitch.Default` or a `Default=` attribute. The designer shows a null key as `(null)` and an empty one as `(empty)`.
  - Connector keys, confirmed against the WF designer source (`FlowchartDesigner.xaml.cs`): `ConnectorLocation` for a step's Next, `TrueConnector` / `FalseConnector` for a decision, `<case>Connector` for a switch case and `Default` for its default branch. There is no `DefaultConnector`.
  - A link can be written but lead nowhere (a reference to a name that doesn't exist). The converter warns for each one; a link written as `{x:Null}` means "no link" and gets no warning.
- **Invoke paths**: `WorkflowFileName` is relative to the project folder (not to the calling file) and can use `/` or `\`. UiPath's documentation for the activity confirms it: "The file path is relative to the current project folder", with no fallback to the caller's folder (checked November 2026, finding R7). It can also be an expression (`[folder + "\x.xaml"]`); treat anything that isn't a plain path ending in `.xaml` as set at run time.
  - The converter tidies a path as text before using it: `.` and empty parts are dropped and `..` steps back a folder, so `Sub\..\Sub\A.xaml`, `Sub\\A.xaml` and `.\Sub/A.xaml` all mean `Sub\A.xaml`.
  - A path that leads out of the project folder (another drive, a network share, or `..` past the top) is shown as "outside the project" and is **never looked up**. A workflow can name any server, and checking such a path would make Windows contact it. By default only the file name is shown, because the full path can name a server or a user.
  - Don't use `System.IO.Path` methods on these names: on Windows PowerShell 5.1 they throw on `|`, `<`, `>` and control characters, which a workflow can contain.
- **Studio's own folders** (`.local`, `.settings`, `.objects` and so on) start with a dot. Skip them when scanning a project.
- **Activity properties can share names with XML properties.** UiPath's Get XML Node Attributes activity writes `Attributes="[...]"`. PowerShell lets an attribute or child element hide the XML property of the same name, so `$element.Attributes` returned that text and a whole project failed to convert (found in the November 2026 compatibility run). Always read XML properties through .NET's accessors: `$node.get_Attributes()`, `.get_LocalName()`, `.get_ChildNodes()` and so on.
- **In C# projects, every expression carries a layout ID.** `CSharpValue` and `CSharpReference` elements (and Multiple Assign's `AssignOperation` items) have `WorkflowViewState.IdRef` attributes, so "has an IdRef" does not mean "is an activity".
- **Where an activity comes from is in its namespace.** UiPath's activities use `http://schemas.uipath.com/...` or a `clr-namespace:UiPath...` / `assembly=UiPath...` namespace; .NET's Workflow Foundation uses `http://schemas.microsoft.com/netfx/2009/xaml/activities` or `clr-namespace:System.Activities...` (also `Microsoft.VisualBasic.Activities`, `Microsoft.CSharp.Activities`). Anything else is a project's own library or a third-party package; its `assembly=` part names the package. In the 93-project corpus: about 7,350 Workflow Foundation uses, 6,360 UiPath and 140 other.
- **Real projects are mostly sequences.** In 93 public projects (639 files), 88% of workflows have a Sequence at the top level, 6% a Flowchart and 3% a State Machine. Containers nest to a median depth of 2, up to 27. See `docs/compatibility-report.md`.
- **REFramework `Main.xaml`** is a template: states Initialization → Get Transaction Data → Process Transaction → End Process, with transitions Successful initialization, System Error, New Transaction, No Data, Successful transaction, BRE, Error. Every REFramework project has it, so it's a good first test case. The project-specific logic is in `Process.xaml` and the files it calls.

## Technical notes: draw.io format

- Uncompressed XML: `mxfile` → `diagram` (one per page, with `id` and `name`) → `mxGraphModel` → `root`.
- `root` always starts with `<mxCell id="0"/>` and `<mxCell id="1" parent="0"/>`.
- Shapes: `mxCell vertex="1" parent="1"` with `mxGeometry x y width height`. Arrows: `mxCell edge="1" source=… target=…`.
- With `html=1` in a style, the label (`value`) is HTML, so it must be XML-escaped (`&lt;b&gt;`).
- A link to another page: `link="data:page/id,<diagram id>"`. The `link` attribute goes on a `<UserObject>` wrapper, which also holds the `id` and the text (as `label`), with the `mxCell` inside it. Checked in the web viewer: clicking a linked shape opens the page.
- Without `html=1`, labels are plain text and `&#xa;` (a newline) breaks the line. The converter uses plain labels, so nothing needs HTML escaping.
- `exitX`/`exitY`/`entryX`/`entryY` in an edge style pin where an arrow leaves and enters a shape (0 to 1 across each side). Combined with `edgeStyle=none` and waypoints, this redraws Studio's routes exactly.
- XML comments in the file can trip some readers; leave them out.
- Opening a file: app.diagrams.net (File → Open from → Device), the draw.io desktop app, or VS Code with the "Draw.io Integration" extension (without it, VS Code shows raw XML).
- **Checking a file offline**: the desktop app can export from the command line, which proves it parses the file: `"%LOCALAPPDATA%\Programs\drawio\app\draw.io.exe" -x -f png -p 2 -o page2.png file.drawio` (`-p` is the 1-based page). Use this for anything made from files in `private/`, so they never go to a website.
- Useful shape styles: `rounded=1`, `rhombus`, `ellipse`, `shape=document`, `shape=cylinder3`, `swimlane` (card with header), `edgeStyle=orthogonalEdgeStyle`.

## Decisions made

| Decision | Choice | Why |
| --- | --- | --- |
| Language | PowerShell, compatible with Windows PowerShell 5.1 and PowerShell 7 | Nothing to install for users on locked-down machines |
| Dependencies | None at run time | Same reason |
| Output | Native `.drawio` (not Mermaid first) | Editable, and Studio's own layout can be kept |
| Test data | Made-up XAML only | No client or third-party material in a public repo |
| Default detail | No expressions or selectors | They can contain server names and data |
| Tests (for now) | A plain PowerShell script, `tests/Test-Converter.ps1`, with no Pester | Runs in both PowerShell versions with nothing to install. Revisit when the Pester decision is made |
| Layout | Studio's layout when every node has a saved position; otherwise a simple top-to-bottom layout for the whole diagram | Mixing the two looks worse than either |
| Output name | `<name>.drawio` and `<name>.conversion-report.txt` | Several runs into one folder don't overwrite each other's reports |
| Real files in checks | Converted into `output/` and checked offline (structure tests and the desktop app), never loaded into a website | Keeps client material off third-party services |
| Paths outside the project | Shown as "outside the project", never looked up; file name only unless `-IncludeDetails` | Looking up a network path from someone else's workflow contacts a server they chose |
| Output names with `-OnePerFile` | Each workflow gets a unique file name (`A_B`, `A_B_2`, ...); the map's name is reserved first | One workflow's diagram must never overwrite another's |
| Page order | Main workflow first, then by path in plain character order | `Sort-Object` orders `-`, `_` and `\` differently in Windows PowerShell 5.1 and PowerShell 7 |
| Test inputs | Edge cases live in `tests/fixtures/` (made up); `samples/` stays a short set of readable examples | Keeps the samples simple while the tests grow |
| User documentation | The README leads with supported content and a runnable sample; `docs/usage.md` holds detailed conversion rules, reports and troubleshooting | Readers should know what is drawn versus summarised before running the tool; successful output writing is not a guarantee of complete rendering |
| Arrows in automatic layout | Every arrow gets a fixed path through the gaps between rows: down to the next row; round a lane on the right when it skips rows; round a lane on the left when it loops back; a small loop on the right for a link to itself. Each run across a gap has its own track, boxes are entered at spread-out points, and a label sits just above the box its arrow leads to (stacked when several arrive) | Leaving routing to draw.io stacked parallel arrows on top of each other and ran side arrows through boxes. The tests now redraw every arrow from the file and fail if one crosses a box, two share a path, or a label overlaps a label or a box |
| Numbers in the output | Rounded to 2 places via the 15-digit text form and decimal arithmetic | Windows PowerShell 5.1 and PowerShell 7 round doubles (and turn them into decimals) differently; this way both write identical files |
| Report contents | File and folder names only, never full paths; a file that can't be read is described ("not well-formed XML (line 2, position 40)", "access denied"), never with .NET's own message | Reports get shared. Full paths name the user's account and folders, and .NET's XML errors quote the file's content |
| Speed | Look nodes up through a dictionary keyed by XML element, never by scanning a list | Scanning made big workflows slow in proportion to the square of their size: a 1,000-step flowchart took 16 s (49 s in Windows PowerShell 5.1); now about 5 s in both |
| Scanning a project | The converter walks the folders itself. It skips Studio's dot-folders, `~` backup files (Studio's copies of unsaved changes), real links to other folders (junctions and symbolic links, found by `LinkType`), and folders it can't read; each skipped folder is listed in the report | One unreadable subfolder used to stop the whole project. Links can loop or lead outside. OneDrive and other cloud folders carry the same `ReparsePoint` flag as links, so that flag alone can't be used |
| Writing files | Each file is written to a temporary file in the output folder, then copied into place. A file that can't be written is listed in the report; the others are still written; the run ends with exit code 1 | A failure used to leave a half-written diagram and no report. (`File.Replace` is avoided: PowerShell passes `$null` to .NET as an empty string, which `Replace` rejects, so every overwrite failed) |
| Files that aren't workflows | A file whose top element is a known activity (for example `<StateMachine>`) is drawn from that. Any other top element (`<html>`, `<Window>`) gets a page and a report entry saying it is not a workflow | Before, they were mislabelled ("state", "flowstep") and not drawn, with no explanation |
| Errors the user can fix | One plain line and exit code 1 ("Path not found: ...") | PowerShell's own error display adds script line numbers that mean nothing to a user |
| Damaged saved layouts | `NaN`, infinity and values beyond ±1,000,000 count as missing, so the diagram is laid out automatically | They can only come from a damaged file, and drawn as-is they broke the picture or crashed draw.io's export |
| Compatibility testing | A pinned corpus of public projects (`tests/compatibility/corpus.csv`) and a script that downloads only their `.xaml` and `project.json` files into the temp folder and converts them (`tests/compatibility/Invoke-CompatibilityRun.ps1`). Third-party files and outputs never enter the repository | Real-world coverage without storing anyone else's workflows; a repeatable baseline before each release |
| Activity report | Activities are grouped by source (UiPath packages, Workflow Foundation, other libraries or packages), judged from the namespace only. Every activity is counted in one group. Only "other" types are listed one by one, with package and files; only their flowchart steps are drawn as dashed boxes | The old "not recognised" list named every activity not on a short built-in list (258 types in the corpus), so UiPath's own activities looked like failures. The source is a fact in the file; the converter still claims no understanding of what an activity does (R6) |
| Large project maps | Rows wider than 1,600 pixels wrap onto several rows (workflows that invoke nothing first); an arrow that passes rows drops through a zero-width gap kept in each row, shared by all arrows from the same box; workflows with no arrows go to the bottom. Project map only | Compared with the old layout and a crossing-reduction variant on the corpus's 11 widest maps (see `docs/compatibility-report.md`): no map over 2,000 pixels wide, fewer crossings, half the arrow length. The crossing-reduction step was dropped because drawn crossings got worse (R4) |
| Labels on Studio layouts | A label is moved along its own arrow to the first clear place (no other label, box or decision text); a decision's text moves to the lower right when an arrow meets its bottom point. Boxes and Studio's routes are never moved | Studio's routes can run side by side, putting labels on top of each other; moving only labels keeps Studio's layout faithful (R5) |
| Multi-platform direction | Explored, not adopted. See `docs/architecture-exploration.md`: UiPath sequence support first, built around a small internal representation; another platform only if approved. That representation is for **drawing** only. A **migration** representation (triggers, expressions, variables, data flow, dependencies, retries, errors, side effects, runtime behaviour) is a different thing, is not planned, and is not to be grown out of the drawing one | Avoids a premature rewrite while keeping the option open; keeps diagrams from claiming an understanding of behaviour they do not have |

## Open decisions

- [x] **Employer policy:** checked and cleared by the owner (November 2026). The repository is public.
- [x] **Licence:** MIT (`LICENSE`).
- [x] **Repository name:** `uipath-to-drawio`, at github.com/sgshaji/uipath-to-drawio. Say "for UiPath" descriptively, use no UiPath logo, and state it isn't affiliated with UiPath.
- [ ] **Test framework:** Windows ships Pester 3.4; Pester 5 is better but needs installing (developers only). For now the tests are a plain script (see Decisions made); decide before the test suite grows much.
- [ ] **Task Capture:** UiPath Task Capture can import XAML ([docs](https://docs.uipath.com/task-capture/standalone/2020.10/user-guide/importing-and-editing-a-xaml-file)). Check what it exports, so the README can say how this tool differs.

## Next steps

1. Check flowchart and switch connector keys against a real flowchart saved by Studio (put it in `private/`).
2. Try a whole real project from `private/`, not just `Main.xaml`, to exercise the project map at size.
3. Keep the README screenshots in `docs/images/` current: they are exported from the samples with the draw.io desktop app (`draw.io.exe -x -f png -b 16 -s 1.5 -p <page> -o docs/images/<name>.png <file>.drawio`).
4. Sequence support, per the plan in `docs/architecture-exploration.md` section 8 (milestones S0 to S5, with the drawing rules, the cases where detail is deliberately not generated, and the coverage measures).
5. Remaining reliability items from `docs/compatibility-report.md`: R3 (summary pages; the sequence roadmap), and the rest of R5 (long labels on short arrows; one crowded state stretching the whole layout).
