# Migration-semantics requirements ledger

**Status: documentation only.** This ledger records what building the visualizer has taught us about the meaning of UiPath workflows, for a future migration and modernization engine (UiPath, n8n, Power Automate cloud flows). Nothing here is implemented, and this project does not convert or migrate workflows. The visualizer's own internal model is deliberately not a migration model (see [architecture-exploration.md](architecture-exploration.md#3-two-representations-one-to-draw-one-to-migrate)).

**How to read an entry**

- **Observed** facts come from the [compatibility corpus](compatibility-report.md) (93 public projects, 657 workflow files) or from UiPath's documentation, as stated.
- **Migration requirement** is what a migration engine would have to handle. It is a requirement, not a design.
- **Target notes** about n8n and Power Automate are from their public documentation and are **unverified** against real exported flows unless marked otherwise.
- Entries are added as we learn; none is removed without a note saying why.

## Control flow

| ID | Observed | Migration requirement | Target notes (unverified) |
| --- | --- | --- | --- |
| CF1 | A Sequence runs its activities in the order written. 88% of workflow files have a Sequence at the top; sequences nest up to 4 deep in the corpus, and containers of all kinds up to 27. | Preserve order exactly; flatten or re-nest without changing order. Deep nesting must survive the target's own nesting limits. | Power Automate scopes nest actions; n8n has no nesting, only connections and sub-workflows. |
| CF2 | If has an optional Then and an optional Else: of 925 If activities, 76 have no Then and 362 no Else. The condition is an attribute (854) or a `.Condition` element (71). | A missing branch means "do nothing", not "unknown". Both attribute and element forms must be read. | Power Automate's Condition always has both branches (one may be empty). n8n's IF node has true and false outputs. |
| CF3 | Else If (UiPath's `IfElseIf`) holds ordered blocks with `BlockType` If, ElseIf or Else; the first block whose condition holds runs, else the Else block. A block may have no activity. 8 in the corpus. | Keep the evaluation order: it matters when several conditions hold. A chain of conditions is a faithful translation; a single multi-way switch is not, unless conditions are proven exclusive. | Power Automate: nested Conditions. n8n: a Switch node in rules mode; whether it stops at the first match must be checked per version. |
| CF4 | Switch is typed (`x:String` 24, `x:Int32` 3). Cases are activities keyed by `x:Key` (attribute or element); a case can be empty (`x:Null`); Default is optional (present in 19 of 27). | Key type and equality semantics (case sensitivity of strings, number formats) must carry over. An absent Default means "do nothing". | Power Automate Switch compares to literal case values; its rules for types must be checked. n8n Switch compares by rules. |
| CF5 | Flowcharts are free graphs: steps, decisions, switches, loops back to earlier steps. Branch labels (TrueLabel, FalseLabel) are presentation stored in Studio's layout data, not semantics. | Translate arbitrary graphs, including cycles, into the target's structured control flow, or reject with a reason. Ignore presentation-only data. | Neither target has free-form goto; loops need Do-until (Power Automate) or loop-back connections (n8n). |
| CF6 | State machines (20 in the corpus, many REFramework) have states with Entry and Exit, transitions with Trigger, Condition and Action, and final states. | Needs an explicit state variable and a loop, or a redesign. Trigger semantics must be understood before translation. | No direct equivalent in either target. |
| CF7 | Comment Out disables the activities inside it. 29 sit in sequences in the corpus (not inside other containers). The project map still counts workflows invoked inside one. | Disabled code must not be migrated as live code; it may be kept as documentation. | Power Automate and n8n have no "commented-out" activities; they would be dropped or kept as notes. |
| CF8 | Loops: For Each (157), For Each Row (128), While, Do While, and UiPath's interruptible variants; Break and Continue. | Loop bounds, the collection's item type, and early exit must be preserved. | Power Automate: Apply to each (concurrency options), Do until. n8n: items are processed per node by default, which is a different execution model. |
| CF9 | Parallel and Pick exist in the vocabulary but are rare in this corpus; not yet measured. | Concurrency, cancellation of other branches (Pick) and shared variable access. | To be investigated. |

## Expressions

| ID | Observed | Migration requirement | Target notes (unverified) |
| --- | --- | --- | --- |
| EX1 | Expressions are VB (70 projects) or C# (23). VB is written as `[text]` in attributes; C# as `CSharpValue` and `CSharpReference` elements, which carry layout IDs. | A parser and translator per source language. Never evaluate source expressions during analysis. | Power Automate uses its workflow definition language; n8n uses JavaScript in `{{ }}`. |
| EX2 | 16 invoked file names are computed at run time from data (for example REFramework's test runner). | Dynamic invocation cannot be resolved statically. It needs a runtime mapping or a manual decision. | Child flows and sub-workflows are referenced by ID, not by computed path. |
| EX3 | Conditions and switch expressions can be long, multi-line and refer to variables, arguments and .NET methods. | Type information and .NET library calls must be mapped or flagged. | Not all .NET methods have equivalents. |

## Data and dependencies

| ID | Observed | Migration requirement | Target notes (unverified) |
| --- | --- | --- | --- |
| DD1 | Invoke Workflow File passes in, out and in/out arguments. Not yet inventoried in the corpus. | Map argument direction and types; out arguments need explicit return values. | Child flows return outputs explicitly; n8n sub-workflows return items. |
| DD2 | Variables are declared on containers (for example `Sequence.Variables`) and scoped to them. | Preserve scope or rename to avoid collisions when flattening. | Power Automate variables are flow-wide and initialized at top level. |
| DD3 | Invoke paths are relative to the project folder, as UiPath documents ("The file path is relative to the current project folder"). 13 of 15 missing invokes in the corpus are files absent from the uploaded repositories. | Resolve calls by the documented rule; report missing targets; never guess. | Targets use IDs; a mapping from file to flow is needed. |
| DD4 | `project.json` lists package dependencies and versions. Activities come from UiPath packages (about 6,360 uses), Workflow Foundation (about 7,350) and other libraries (140). Not yet inventoried by package version. | Each package's activities need a target equivalent, a connector, or a manual rewrite. Custom libraries need their own analysis. | Power Automate connectors and n8n nodes cover different services. |

## Errors and retries

| ID | Observed | Migration requirement | Target notes (unverified) |
| --- | --- | --- | --- |
| ER1 | Try/Catch (456) with typed catches, an exception variable, and Finally; Throw and Rethrow. REFramework distinguishes business rule exceptions from system exceptions. | Exception types and their handling order must be preserved; business versus system errors drive different paths. | Power Automate: scopes with "run after" (failed, timed out, skipped). n8n: error outputs and error workflows. The models differ. |
| ER2 | Retry Scope (46) retries its action while a condition fails, with a count and interval. REFramework also retries whole transactions through its state machine and configuration. | Retry counts, intervals and what is retried must be explicit. | Power Automate has per-action retry policies; n8n has per-node retry settings. |
| ER3 | A project-level global exception handler exists in UiPath. Not yet analysed in the corpus. | Must be found and translated, or reported. | To be investigated. |

## Platform-specific constructs

| ID | Observed | Migration requirement | Target notes (unverified) |
| --- | --- | --- | --- |
| PS1 | UI automation (Click, Type Into, selectors) and scopes: Browser Scope 55, Use Application/Browser 38, Excel Application Scope 28 sit in sequences (not inside other containers). A scope provides an implicit context (an application, a workbook) to the activities inside it. | UI steps have no cloud equivalent; they need desktop automation or a rewrite to an API. The implicit context of a scope must become explicit. | Power Automate desktop flows handle UI automation; cloud flows do not. n8n has no UI automation. |
| PS2 | Orchestrator concepts: queues and transaction items, assets, credentials, transaction status. | Map to the target's storage, secrets and work-queue facilities, or keep an orchestrator. | To be investigated. |
| PS3 | Studio layout data (ViewState) is presentation only: positions, sizes, branch labels. | Ignore for semantics; optionally use for layout. | Not applicable. |
| PS4 | Coded workflows (`.cs`) exist in newer Studio versions; not downloaded or analysed. | Code needs separate translation or wrapping. | To be investigated. |

## Changes to this ledger

- 22 November 2026: created from the visualizer's corpus work up to milestone S2.
