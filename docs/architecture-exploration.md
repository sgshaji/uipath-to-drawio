# Architecture exploration: a common workflow representation

**Status: proposal for review. Nothing in this document is implemented.** It assesses whether the converter can grow towards supporting other workflow platforms (such as n8n and Power Automate) without a rewrite, and proposes how to prepare for that while the immediate work stays on UiPath. Section 8 is the detailed plan for the next milestone, UiPath sequence support.

Evidence comes from the current converter (`src/Convert-UiPathToDrawio.ps1`) and from the compatibility run over 93 public UiPath projects ([compatibility report](compatibility-report.md)). Statements about n8n and Power Automate formats are from their public documentation and are marked where they still need checking against real exported files.

## 1. Where the converter is today

The converter is one PowerShell script of about 2,500 lines and 70 functions. It already works in stages, but the stages share data structures and some stages make decisions that belong to others.

| Stage | Main functions | What it produces |
| --- | --- | --- |
| Find files | `Get-WorkflowFiles`, `Find-ProjectRoot`, `Read-ProjectJson` | A list of `.xaml` files and the project root |
| Parse | `Read-XmlFile`, `Read-Workflow`, `Get-InvokeInfo`, `Get-ViewState` | An XML document per file, plus a workflow record (kind, invoked files, activity inventory by source) |
| Workflow semantics and graph | `Get-StateMachineGraph`, `Get-FlowchartGraph` | Nodes and edges (`New-Node`, `New-Edge`) |
| Layout | `Set-StudioLayout`, `Set-AutoLayout`, `Set-ClearLabelPlaces` | Positions and sizes on nodes, routes and label positions on edges |
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

## 3. Two representations: one to draw, one to migrate

Two different things could be called "a common workflow representation". They have different purposes, different correctness standards and different costs. This project builds only the first.

| | Visualization representation (this project) | Migration representation (future, not planned) |
| --- | --- | --- |
| **Purpose** | Show a reader the structure of a workflow: what runs inside what, in what order, where it branches, what it calls. | Re-create a workflow's behaviour on another platform. |
| **What it must hold** | Containment, order, branches and their labels, calls between workflows, saved positions, and diagnostics saying what was not drawn. | Everything that affects behaviour: triggers; expressions, parsed and typed; variables and arguments with their types and scopes; data flow between activities; integration dependencies (packages, connections, credentials, queues, assets); retries, time-outs and error handling; side effects; and runtime behaviour such as transactions, parallelism and concurrency. |
| **Treatment of expressions and settings** | Opaque text, never parsed or evaluated, shown only with `-IncludeDetails`. | Must be parsed and translated, so a parser per expression language would be needed. |
| **Allowed loss** | Lossy by design. Every loss must be counted and reported, not hidden. | Must be lossless, or must list exactly what could not be carried over. A silent loss is a defect. |
| **How correctness is judged** | The picture matches the file's structure: checked by fixtures, geometric checks and visual review. | The migrated workflow behaves the same: needs execution-level testing on both platforms. |
| **Safety** | Reading only. Nothing from the file is executed or evaluated. | Translation would still not execute anything, but its output would, so its mistakes have real effects. |

**The migration representation is not the visualization representation with more fields.** A diagram can be correct while ignoring variables, data flow and error semantics; a migration cannot. Growing one into the other would either load the diagram path with work it does not need, or tempt the diagram path into claiming understanding it does not have.

**What the visualization design must do so as not to block a future migration layer:**

- Give every node a stable identifier and keep its platform type name (`SourceType`) and where it came from in the file (file and element path), so that another layer could attach to the same nodes later.
- Keep platform detail in an opaque `Details` bag instead of discarding it at parse time, but never interpret it in shared stages.
- Never present a diagram as a statement about runtime behaviour. The README and report already say that diagrams show structure, not behaviour.

**Not to be implemented now:** expression parsing, variable or argument tracking, data-flow analysis, dependency inventories beyond the existing activity-by-source counts, trigger or retry semantics, or any translation to another platform. These belong to a migration effort that would need its own approval, corpus and test strategy.

## 4. Proposed visualization representation

A small set of records, built from PowerShell hashtables like the existing ones. PowerShell classes are not proposed: they behave awkwardly when a script is reloaded, and hashtables keep the code compatible with Windows PowerShell 5.1 and easy to test.

The central idea: **a workflow is a tree of containers, and any container can hold either an ordered list of children or a graph of nodes and edges.** That one shape covers structured nesting (UiPath sequences, Power Automate scopes) and free-form graphs (UiPath flowcharts and state machines, n8n workflows), and lets them nest inside each other.

| Record | Fields | Notes |
| --- | --- | --- |
| **Workflow** | `Id`, `Name`, `SourcePath` (relative), `Platform`, `Kind`, `Root` (a node), `Calls`, `Diagnostics` | `Kind` is what the reader sees: state machine, flowchart, sequence, graph, summary, not a workflow, unreadable. |
| **Node** | `Id`, `Kind`, `Label`, `SourceType`, `Source`, `Slots`, `Edges`, `LayoutHint`, `Details` | `Kind` is semantic (below). `SourceType` keeps the platform's own type name, such as `Assign` or `n8n-nodes-base.httpRequest`; `Source` is where the node is in the file. |
| **Slot** | `Name`, `Children` | The named parts of a container: a sequence has one slot; If has `Then` and `Else`; Try/Catch has `Try`, one per catch, and `Finally`. |
| **Edge** | `From`, `To`, `Kind`, `Label` | `Kind`: next, true, false, case, default, transition, output, error. Used inside graph containers. |
| **Call** | `FromNode`, `Target`, `Status`, `Raw` | `Status`: linked, missing, not converted, outside the project, set at run time. Feeds the project map. |
| **Diagnostic** | `Severity`, `Code`, `Message`, `NodeId` | Feeds the report: activities from other packages, broken links, nesting not expanded, activities not drawn. |

Semantic node kinds: `start`, `end`, `step`, `call`, `decision`, `switch`, `state`, `finalState`, `sequence`, `branch` (If), `loop`, `tryCatch`, `parallel`, `graph` (a flowchart, state machine or n8n workflow body), `collapsed` (detail deliberately not generated; see section 8), `unknown`.

Two fields keep platforms apart without leaking:

- **`LayoutHint`** holds a position and size the source saved, if any. UiPath Studio saves them in ViewState; n8n saves a position for every node. A layout stage can use hints when they are complete and fall back to automatic layout otherwise, as today.
- **`Details`** is a platform-specific bag: conditions, expressions, parameters. Shared stages never interpret it. A platform-specific formatter decides what, if anything, is shown with `-IncludeDetails`.

Between the representation and layout sits a **lowering** step that turns containers into drawable shapes: a sequence becomes a frame of boxes stacked top to bottom; If becomes a diamond with two side-by-side frames that join again; a loop becomes a labelled frame with a return arrow; a graph container keeps its nodes and edges. Its output is the diagram graph the existing layout and renderer already handle, extended with frames.

## 5. How each platform fits

| Concept | UiPath | n8n (exported workflow JSON) | Power Automate (flow definition) |
| --- | --- | --- | --- |
| Workflow body | Top-level activity of a `.xaml` file | `nodes` and `connections` | `actions` in the definition |
| Ordered steps | Sequence (slot with children) | None: execution order comes from connections | Actions ordered by `runAfter` |
| Free-form graph | Flowchart, state machine (graph container) | The whole workflow is one graph container | Not used |
| Branching | FlowDecision, If, Switch | IF and Switch nodes: numbered outputs whose meaning depends on the node type | Condition (`actions` / `else`), Switch (cases) |
| Nesting | Deep: containers inside containers (median depth 2, up to 27 in the corpus) | Flat; sub-workflows only through Execute Workflow | Scopes, conditions and loops nest actions |
| Calling other workflows | Invoke Workflow File (path relative to the project folder, as UiPath documents) | Execute Workflow node (workflow ID) | Child flows |
| Saved positions | Studio ViewState | Node `position` | None |
| Annotations | Annotation text | Sticky-note nodes | Action descriptions |

**To verify before any implementation:** the n8n and Power Automate columns come from documentation, not from a corpus of real exported files. In particular, how n8n's numbered outputs map to labels for each node type and version, and how Power Automate exports name and nest scopes, must be checked against real examples.

## 6. What must stay platform-specific

| Area | Why it cannot be shared | Proposed handling |
| --- | --- | --- |
| **Expressions** | VB and C# in UiPath, JavaScript-style `{{ }}` in n8n, the workflow definition language in Power Automate. | Kept as opaque text in `Details`. Never parsed or evaluated: that keeps the converter safe on untrusted files. Shown only with `-IncludeDetails`. |
| **Branch meaning** | A UiPath decision is true or false; an n8n output index means different things per node type; Power Automate's `runAfter` can depend on success, failure or time-out. | The platform reader turns it into an edge `Kind` and `Label`. Shared stages only draw what they are given. |
| **Nesting** | UiPath nests deeply, n8n hardly at all, Power Automate in scopes. | Expressed through slots and graph containers; the reader decides which applies. |
| **Execution semantics** | State-machine triggers, Try/Catch rethrow and parallel branches in UiPath; per-item execution, merge modes and error workflows in n8n; retry and concurrency settings in Power Automate. | Not represented (see section 3). The diagram shows structure, not runtime behaviour, and the report says so, as the README already does for UiPath. |
| **Sensitive metadata** | UI selectors and arguments in UiPath; credential references in n8n; connection references in Power Automate. | Dropped by the reader by default. Never in shared records unless `-IncludeDetails` asks and the platform formatter allows it. |
| **Call resolution** | File paths in UiPath, workflow IDs in n8n, child-flow references in Power Automate. | Each reader resolves calls and sets `Call.Status`. The project map only consumes the result. |

## 7. Recommended incremental architecture

**Principles**

- No rewrite. Each step keeps every existing test passing in both PowerShell versions, and keeps the corpus results unchanged unless the step is meant to change them.
- One script until a second platform is actually approved. `CLAUDE.md` says to stay with one script "until there is a clear reason to split"; a second platform would be that reason, a hypothetical one is not.
- No new dependencies: no graph-layout libraries (such as Graphviz or ELK), no modules. Offline by design.
- The representation stays internal. It is not published as a format until two platforms use it.

**Steps**

1. **Separate presentation from semantics** (UiPath only, no visible change). Graph builders set a semantic `Kind`; one function maps kinds to draw.io styles. Acceptance: all tests pass, and corpus output is byte-identical before and after.
2. **Add containers and slots, driven by sequence support** (UiPath only). A recursive reader turns sequences, If, Try/Catch and loops into the representation. A lowering step turns them into frames for layout. Flowchart and state-machine builders emit graph containers. See section 8.
3. **Move UiPath specifics behind one boundary.** ViewState becomes `LayoutHint`; conditions and expressions move into `Details`; invoke resolution produces `Call` records. Shared stages no longer see XML elements.
4. **Only if a second platform is approved:** split the script into a shared part and platform readers (for example `src/core.ps1`, `src/uipath.ps1`, `src/n8n.ps1`, loaded by one entry script), keep `Convert-UiPathToDrawio.ps1` as a compatible entry point, and prototype n8n from exported workflow JSON, which `ConvertFrom-Json` reads in Windows PowerShell 5.1 with no extra modules. Renaming the repository can wait until there is evidence of demand.

**What not to do yet:** a plug-in framework, PowerShell classes, a public schema for the representation, external layout engines, a graphical interface, or anything from the migration column of section 3.

## 8. Plan: detailed UiPath sequence support

The compatibility run shows why this comes first: **88% of real workflows are sequences, and only 64 of 657 workflows (10%) get a detailed diagram today.** In the corpus, workflows use 3,303 sequences, 925 If activities, 456 Try/Catches and 285 loops, with containers nested to a median depth of 2 and a maximum of 27.

### 8.1 What a sequence diagram means

A diagram may only claim what the file states. These rules fix what each drawn construct means, so that a reader can trust it:

| Construct | Drawn as | What the drawing claims | What it does not claim |
| --- | --- | --- | --- |
| Sequence | A frame; children top to bottom, joined by arrows | Children run in the written order | Anything about what each child does |
| If | A diamond with the condition's display name; Then and Else frames side by side, joining again below | Exactly one branch runs | Which branch, or the condition's text (only with `-IncludeDetails`) |
| Else If (UiPath's If Else If) | A chain of diamonds, each with its own Then frame; a final Else frame | Conditions are tried in order; the first true one runs | As for If |
| Switch | A diamond with one frame per case, labelled with the case value, and a default frame | One case, or the default, runs | Case values' types or matching rules |
| Try/Catch | A frame with a Try part, one part per Catch labelled with its exception type, and a Finally part | The written structure | Which exceptions are thrown where, or rethrow behaviour |
| Loops (For Each, For Each Row, While, Do While) | A labelled frame with a return arrow; Do While checks after the body, While before | The body repeats | How many times, or over what |
| Retry Scope | A labelled frame with its action and condition parts | The written structure | Retry counts or intervals (only with `-IncludeDetails`) |
| Parallel, Parallel For Each, Pick | Branches side by side in one frame, marked "branches run in parallel" (Pick: "first trigger wins") | The branches are siblings | Any order between branches; nothing is drawn as sequential |
| Break, Continue, Throw, Rethrow, Terminate Workflow | A step with an end marker: no arrow continues from it | Control leaves at this point | Where it goes, beyond the immediate loop or handler |
| Invoke Workflow File | A step linked to the invoked workflow's page | The call, with its status (linked, missing, set at run time, outside the project) | What the invoked workflow does |
| Flowchart or state machine nested in a sequence | A step linking to, or embedding, the existing graph drawing (S4) | As today | As today |

### 8.2 Where detail is deliberately not generated

Some content cannot be drawn in detail without guessing. In each case the converter draws a **collapsed box** saying what it holds and why it is not expanded, and the report counts it. This is a fixed rule, not a fallback for bugs.

| Case | Why it cannot safely be expanded | What is shown |
| --- | --- | --- |
| An activity from another library or package that contains other activities | Its execution order, conditions and repetition are unknown: it may run its children in sequence, in parallel, conditionally or not at all | The activity type, its package, and "contains N activities, not expanded: unknown container" |
| Bodies held in properties of unknown activities (for example an `ActivityAction` of a custom activity) | Same as above, and the property name does not say when the body runs | Counted inside the collapsed box above |
| Nesting deeper than the depth limit (`-MaxDepth`) | Keeps very deep files readable and fast | "N activities not drawn (deeper than the limit)" |
| A sequence longer than a size limit (to be set in S1 from the corpus, for example 200 activities) | A single page of hundreds of boxes is not readable | The first part drawn, the rest collapsed with a count |
| File names set at run time | Would need evaluating an expression | As today: "file name set at run time" |
| Coded workflows (`.cs`) and Invoke Code | Code, not workflow structure | A step naming the file or saying "code", never the code |
| Triggers, global exception handlers, Orchestrator settings | Behaviour lives outside the workflow file | Named where they appear in the file; no behavioural claims |

No collapsed box is ever silent. Every one adds a counted line to the report's "Not drawn" section, so a reader can see how much of each workflow the diagram covers.

### 8.3 Milestones

**Status:** S0 and S1 are done (after release 0.1.0; results in the [compatibility report](compatibility-report.md#sequence-pages-s0-and-s1)). Differences from the plan below: the depth limit is fixed at 8 rather than a `-MaxDepth` parameter, because the deepest nesting of sequences in the corpus is 4; there is no size limit, because the longest sequence in the corpus has 24 activities; and the flowchart and state-machine protection uses page hashes of the samples and fixtures in the tests, plus every corpus page in the compatibility run.

| Milestone | Scope | Acceptance criteria |
| --- | --- | --- |
| **S0. Preparation** | Step 1 of section 7 (presentation separated from semantics). Record the corpus results, including every `.drawio` file's hash, as a baseline. Add the coverage measures of 8.5 to the compatibility script, computed from the reports. | All tests pass in both PowerShell versions. Corpus output byte-identical to the baseline. Coverage measures reproduce today's figures (64 of 657 workflows in detail). |
| **S1. Sequences** | Top-level and nested sequences as frames of steps. Invoke steps link to their pages. Activities from other packages as plain boxes with their type. Collapsed boxes as in 8.2, with `-MaxDepth` (default set from corpus data, for example 4) and a size limit. Deterministic frame layout: children stacked top to bottom, frames sized by content, no saved Studio positions (sequences have none). | Every sequence workflow in the corpus gets a step diagram instead of a summary, apart from counted collapsed boxes. No structure, arrow, label or frame-overlap problems. Identical output in both PowerShell versions. Median conversion time no more than twice today's. Flowchart and state-machine pages byte-identical to the S0 baseline. Manual review of 10 diagrams chosen at random from the corpus, each checked against its file. |
| **S2. Branching** | If, Else If and Switch inside sequences, per 8.1. | Made-up fixtures for each construct: empty branches, a missing Else, nesting three deep, a Switch with only a default. Corpus criteria as in S1. Each branch frame's label checked against the file in the manual review. |
| **S3. Errors and loops** | Try/Catch, Retry Scope, the loops, Parallel and Pick, and the activities that end a path (Break, Throw and so on), per 8.1. | As S2, plus a made-up fixture nested 27 levels deep and a sequence of 500 activities, both within the time limit and drawn with the collapsed boxes the limits require. |
| **S4. Expanding inside graphs** | Optionally expand the sequences inside flowchart steps and state entries, using draw.io's collapsible containers. | Off by default at first. When on, no overlaps with Studio-layout neighbours. When off, output byte-identical to S3. |
| **S5. Readability** | UI automation steps (Click, Type Into) as one-line boxes named from their display names only, never their selectors; annotations as notes. | No selectors in any output without `-IncludeDetails`: a corpus check searches every output for selector markup. |

### 8.4 Regression protection

- **Flowcharts and state machines** keep their current output until a milestone is meant to change them. Each milestone's corpus run compares every flowchart and state-machine page with the previous baseline. Any difference fails the milestone unless it is listed and explained.
- **Made-up fixtures** for each construct and each collapsed-box case. Never third-party files.
- **Geometric checks** the tests already run (no arrow through a box, no shared paths, no overlapping labels), extended to frames: no frame overlaps a sibling, and every child lies inside its frame.
- **Both PowerShell versions** produce identical files, checked by the test script and the corpus run.

### 8.5 Measuring coverage honestly

Coverage is reported, never targeted at the expense of correctness. A construct that cannot be drawn correctly is collapsed and counted (8.2), not drawn approximately.

| Measure | Definition |
| --- | --- |
| Workflows drawn in detail | Workflows whose page draws every activity, apart from counted collapsed boxes |
| Activities drawn | Activities drawn as their own step, frame or diamond, as a share of all activities counted in the report |
| Activities collapsed, by reason | From the collapsed-box counts, one figure per reason in 8.2 |
| Constructs drawn | For each of If, Switch, Try/Catch, each loop, Parallel: how many were drawn and how many collapsed |

Each release's compatibility report states these figures next to the previous release's. The manual review sample in each milestone checks that what is counted as drawn is drawn correctly.

## 9. Recommended order

1. Release `v0.1.0` from the current, stabilized state (release only with approval). The release-candidate checklist is in [`release-checklist.md`](release-checklist.md).
2. S0 and S1 (sequences): the largest gain in coverage, from about 10% of workflows drawn in detail to most of them.
3. S2 and S3.
4. Reassess demand. Only then consider an n8n prototype, starting with a spike on a handful of exported workflows to verify section 5. A migration representation (section 3) is a separate decision.
