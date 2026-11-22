# Architecture exploration: a common workflow representation

**Status: proposal for review. Nothing in this document is implemented.** It assesses whether the converter can grow towards supporting other workflow platforms (such as n8n and Power Automate) without a rewrite, and proposes how to prepare for that while the immediate work stays on UiPath.

Evidence comes from the current converter (`src/Convert-UiPathToDrawio.ps1`) and from the compatibility run over 93 public UiPath projects ([compatibility report](compatibility-report.md)). Statements about n8n and Power Automate formats are from their public documentation and are marked where they still need checking against real exported files.

## 1. Where the converter is today

The converter is one PowerShell script of about 2,200 lines and 66 functions. It already works in stages, but the stages share data structures and some stages make decisions that belong to others.

| Stage | Main functions | What it produces |
| --- | --- | --- |
| Find files | `Get-WorkflowFiles`, `Find-ProjectRoot`, `Read-ProjectJson` | A list of `.xaml` files and the project root |
| Parse | `Read-XmlFile`, `Read-Workflow`, `Get-InvokeInfo`, `Get-ViewState` | An XML document per file, plus a workflow record (kind, invoked files, activity inventory) |
| Workflow semantics and graph | `Get-StateMachineGraph`, `Get-FlowchartGraph` | Nodes and edges (`New-Node`, `New-Edge`) |
| Layout | `Set-StudioLayout`, `Set-AutoLayout` | Positions and sizes on nodes, routes and label positions on edges |
| Render | `New-WorkflowPage`, `New-ProjectMapPage`, `Add-GraphToPage`, `Write-DrawioFile` | draw.io pages and the `.drawio` file |
| Report | `Get-ReportText` | The conversion report |

The node-and-edge records are already close to a platform-neutral representation. What stops them being one:

1. **Presentation is decided during parsing.** The graph builders set draw.io style strings and choose shapes while they read the XAML.
2. **The graph is flat.** It has no containment, but sequences, If, Try/Catch and loops are nested structures, and 88% of real workflows are sequences.
3. **UiPath details leak into shared stages.** Nodes keep a reference to their XML element, layout reads UiPath's ViewState directly, and call resolution follows UiPath's path rules.
4. **No home for platform-specific detail.** Conditions and expressions are folded into labels when `-IncludeDetails` is set, rather than kept as data that a renderer can choose to show.

## 2. Is a common representation feasible?

Yes, incrementally, and without a rewrite. The layout and draw.io rendering stages are already platform-neutral in practice: they only read node kinds, sizes, positions and edges. The work is in the middle: making parsing produce a representation without presentation decisions, and adding nesting to it.

The nesting work has to happen anyway for detailed UiPath sequence support. So the cheapest path is to design the sequence work around the representation, rather than build the representation separately.

## 3. Proposed representation

A small set of records, built from PowerShell hashtables like the existing ones. PowerShell classes are not proposed: they behave awkwardly when a script is reloaded, and hashtables keep the code compatible with Windows PowerShell 5.1 and easy to test.

The central idea: **a workflow is a tree of containers, and any container can hold either an ordered list of children or a graph of nodes and edges.** That one shape covers structured nesting (UiPath sequences, Power Automate scopes) and free-form graphs (UiPath flowcharts and state machines, n8n workflows), and lets them nest inside each other.

| Record | Fields | Notes |
| --- | --- | --- |
| **Workflow** | `Id`, `Name`, `SourcePath` (relative), `Platform`, `Kind`, `Root` (a node), `Calls`, `Diagnostics` | `Kind` is what the reader sees: state machine, flowchart, sequence, graph, summary, not a workflow, unreadable. |
| **Node** | `Id`, `Kind`, `Label`, `SourceType`, `Slots`, `Edges`, `LayoutHint`, `Details` | `Kind` is semantic (below). `SourceType` keeps the platform's own type name, such as `Assign` or `n8n-nodes-base.httpRequest`. |
| **Slot** | `Name`, `Children` | The named parts of a container: a sequence has one slot; If has `Then` and `Else`; Try/Catch has `Try`, one per catch, and `Finally`. |
| **Edge** | `From`, `To`, `Kind`, `Label` | `Kind`: next, true, false, case, default, transition, output, error. Used inside graph containers. |
| **Call** | `FromNode`, `Target`, `Status`, `Raw` | `Status`: linked, missing, not converted, outside the project, set at run time. Feeds the project map. |
| **Diagnostic** | `Severity`, `Code`, `Message`, `NodeId` | Feeds the report: unknown types, broken links, nesting not expanded. |

Semantic node kinds: `start`, `end`, `step`, `call`, `decision`, `switch`, `state`, `finalState`, `sequence`, `branch` (If), `loop`, `tryCatch`, `parallel`, `graph` (a flowchart, state machine or n8n workflow body), `unknown`.

Two fields keep platforms apart without leaking:

- **`LayoutHint`** holds a position and size the source saved, if any. UiPath Studio saves them in ViewState; n8n saves a position for every node. A layout stage can use hints when they are complete and fall back to automatic layout otherwise, as today.
- **`Details`** is a platform-specific bag: conditions, expressions, parameters. Shared stages never interpret it. A platform-specific formatter decides what, if anything, is shown with `-IncludeDetails`.

Between the representation and layout sits a **lowering** step that turns containers into drawable shapes: a sequence becomes a frame of boxes stacked top to bottom; If becomes a diamond with two side-by-side frames that join again; a loop becomes a labelled frame with a return arrow; a graph container keeps its nodes and edges. Its output is the diagram graph the existing layout and renderer already handle, extended with frames.

## 4. How each platform fits

| Concept | UiPath | n8n (exported workflow JSON) | Power Automate (flow definition) |
| --- | --- | --- | --- |
| Workflow body | Top-level activity of a `.xaml` file | `nodes` and `connections` | `actions` in the definition |
| Ordered steps | Sequence (slot with children) | None: execution order comes from connections | Actions ordered by `runAfter` |
| Free-form graph | Flowchart, state machine (graph container) | The whole workflow is one graph container | Not used |
| Branching | FlowDecision, If, Switch | IF and Switch nodes: numbered outputs whose meaning depends on the node type | Condition (`actions` / `else`), Switch (cases) |
| Nesting | Deep: containers inside containers (median depth 2, up to 27 in the corpus) | Flat; sub-workflows only through Execute Workflow | Scopes, conditions and loops nest actions |
| Calling other workflows | Invoke Workflow File (path relative to the project) | Execute Workflow node (workflow ID) | Child flows |
| Saved positions | Studio ViewState | Node `position` | None |
| Annotations | Annotation text | Sticky-note nodes | Action descriptions |

**To verify before any implementation:** the n8n and Power Automate columns come from documentation, not from a corpus of real exported files. In particular, how n8n's numbered outputs map to labels for each node type and version, and how Power Automate exports name and nest scopes, must be checked against real examples.

## 5. What must stay platform-specific

| Area | Why it cannot be shared | Proposed handling |
| --- | --- | --- |
| **Expressions** | VB and C# in UiPath, JavaScript-style `{{ }}` in n8n, the workflow definition language in Power Automate. | Kept as opaque text in `Details`. Never parsed or evaluated: that keeps the converter safe on untrusted files. Shown only with `-IncludeDetails`. |
| **Branch meaning** | A UiPath decision is true or false; an n8n output index means different things per node type; Power Automate's `runAfter` can depend on success, failure or time-out. | The platform reader turns it into an edge `Kind` and `Label`. Shared stages only draw what they are given. |
| **Nesting** | UiPath nests deeply, n8n hardly at all, Power Automate in scopes. | Expressed through slots and graph containers; the reader decides which applies. |
| **Execution semantics** | State-machine triggers, Try/Catch rethrow and parallel branches in UiPath; per-item execution, merge modes and error workflows in n8n; retry and concurrency settings in Power Automate. | Not represented. The diagram shows structure, not runtime behaviour, and the report says so, as the README already does for UiPath. |
| **Sensitive metadata** | UI selectors and arguments in UiPath; credential references in n8n; connection references in Power Automate. | Dropped by the reader by default. Never in shared records unless `-IncludeDetails` asks and the platform formatter allows it. |
| **Call resolution** | File paths in UiPath, workflow IDs in n8n, child-flow references in Power Automate. | Each reader resolves calls and sets `Call.Status`. The project map only consumes the result. |

## 6. Recommended incremental architecture

**Principles**

- No rewrite. Each step keeps every existing test passing in both PowerShell versions, and keeps the corpus results unchanged unless the step is meant to change them.
- One script until a second platform is actually approved. `CLAUDE.md` says to stay with one script "until there is a clear reason to split"; a second platform would be that reason, a hypothetical one is not.
- No new dependencies: no graph-layout libraries (such as Graphviz or ELK), no modules. Offline by design.
- The representation stays internal. It is not published as a format until two platforms use it.

**Steps**

1. **Separate presentation from semantics** (UiPath only, no visible change). Graph builders set a semantic `Kind`; one function maps kinds to draw.io styles. Acceptance: all tests pass, and corpus output is byte-identical before and after.
2. **Add containers and slots, driven by sequence support** (UiPath only). A recursive reader turns sequences, If, Try/Catch and loops into the representation. A lowering step turns them into frames for layout. Flowchart and state-machine builders emit graph containers. See section 7.
3. **Move UiPath specifics behind one boundary.** ViewState becomes `LayoutHint`; conditions and expressions move into `Details`; invoke resolution produces `Call` records. Shared stages no longer see XML elements.
4. **Only if a second platform is approved:** split the script into a shared part and platform readers (for example `src/core.ps1`, `src/uipath.ps1`, `src/n8n.ps1`, loaded by one entry script), keep `Convert-UiPathToDrawio.ps1` as a compatible entry point, and prototype n8n from exported workflow JSON, which `ConvertFrom-Json` reads in Windows PowerShell 5.1 with no extra modules. Renaming the repository can wait until there is evidence of demand.

**What not to do yet:** a plug-in framework, PowerShell classes, a public schema for the representation, external layout engines, or a graphical interface.

## 7. Roadmap: detailed UiPath sequence support

The compatibility run shows why this comes first: **88% of real workflows are sequences, and only 64 of 657 workflows (10%) get a detailed diagram today.** In the corpus, workflows use 925 If activities, 456 Try/Catches and 285 loops, with containers nested to a median depth of 2 and a maximum of 27.

| Milestone | Scope | Acceptance criteria |
| --- | --- | --- |
| **S0. Preparation** | Step 1 of section 6. Record the corpus results as a baseline. | All tests pass in both PowerShell versions; corpus output byte-identical to the baseline. |
| **S1. Sequences** | Top-level and nested sequences as frames of steps, top to bottom. Invoke steps link to their pages; unrecognised activities shown with their type. Nesting below a depth limit (`-MaxDepth`, default to be decided, for example 4) is collapsed into one box saying how many steps it holds, and noted in the report. | Every sequence workflow in the corpus gets a step diagram instead of a summary. No structure or arrow problems; frames do not overlap. Identical output in both PowerShell versions. Median conversion time no more than twice today's. Manual review of a sample of 10 diagrams. |
| **S2. Branching** | If, Else If and Switch inside sequences: a diamond with side-by-side branch frames that join again. | Made-up fixtures for each construct, including empty branches and nesting; corpus criteria as in S1. |
| **S3. Errors and loops** | Try/Catch (Try, each Catch labelled with its exception type, Finally), Retry Scope, For Each, For Each Row, While, Do While, Parallel: labelled frames, loops with a return arrow. | As S2, plus a fixture nested 27 levels deep and one sequence of 500 activities, within the time limit. |
| **S4. Expanding inside graphs** | Optionally expand the sequences inside flowchart steps and state entries, using draw.io's collapsible containers. | Off by default at first; on, no overlaps with Studio-layout neighbours. |
| **S5. Readability** | UI automation steps (Click, Type Into) as one-line boxes named from their display names only, never their selectors; annotations as notes. | No selectors in any output without `-IncludeDetails`; corpus privacy check. |

**Test strategy for every milestone:** made-up XAML fixtures for each construct (never third-party files), the geometric checks the tests already run (no arrow through a box, no shared paths, no overlapping labels), extended to frames, and a full corpus run before each release, compared with the previous baseline.

## 8. Recommended order

1. Release `v0.1.0` once the reliability fixes from the compatibility run are reviewed (release only with approval).
2. S0 and S1 (sequences): the largest gain in coverage, from about 10% of workflows drawn in detail to most of them.
3. S2 and S3.
4. Reassess demand. Only then consider an n8n prototype, starting with a spike on a handful of exported workflows to verify section 4.
