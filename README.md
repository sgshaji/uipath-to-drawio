# uipath-to-drawio

Convert UiPath workflow files (`.xaml`) into editable draw.io diagrams (`.drawio`).

> **Status: version 1, not yet released.** It draws state machines, flowcharts and a project map. Sequences get a summary page for now. See [CONTEXT.md](CONTEXT.md) for the plan.

## What it does

- Turns one `.xaml` file, or a whole UiPath project, into diagrams you can open and edit in draw.io.
- Keeps the layout you see in UiPath Studio for flowcharts and state machines, stretched so the text fits.
- Shows which workflow calls which on a first "Project map" page, with a page per workflow. Click a box to jump to that workflow's page.
- Writes a conversion report listing anything it couldn't draw or find.
- Runs offline in the PowerShell that comes with Windows, with nothing to install. It only reads your files and only writes to the output folder.

## How to use it

```powershell
# One workflow file: writes Main.drawio next to it
.\src\Convert-UiPathToDrawio.ps1 -Path C:\UiPath\MyProcess\Main.xaml

# A whole project: writes MyProcess.drawio (one page per workflow) into C:\Diagrams
.\src\Convert-UiPathToDrawio.ps1 -Path C:\UiPath\MyProcess -OutputPath C:\Diagrams
```

If Windows blocks the script, run it with `powershell -ExecutionPolicy Bypass -File .\src\Convert-UiPathToDrawio.ps1 ...`.

| Option | Meaning |
| --- | --- |
| `-Path` | A `.xaml` file or a project folder |
| `-OutputPath` | Where to write. Default: the folder the input is in |
| `-OnePerFile` | One `.drawio` per workflow, plus a project map file, instead of one file with a page per workflow. Links between pages only work within one file |
| `-IncludeDetails` | Add transition and decision conditions, switch expressions and file names worked out at run time. Off by default, so server names and values don't end up in shared diagrams |

Open the result at [app.diagrams.net](https://app.diagrams.net) (File > Open from > Device), in the draw.io desktop app, or in VS Code with the "Draw.io Integration" extension.

## What gets drawn

| In UiPath | In the diagram |
| --- | --- |
| State | Rounded box listing the workflows it invokes. Final states have a thick red border |
| Transition | Arrow labelled with its name |
| Flowchart step | Box with the step's name |
| Invoke Workflow File step | Purple box linked to that workflow's page |
| Flow decision / switch | Diamond, with True/False or case labels on the arrows |
| Sequence and other workflows | A summary card listing the workflows it invokes |
| Invoked file that doesn't exist | Dashed red box, marked "missing" |
| Invoked file outside the project folder | Dashed grey box, marked "outside the project". It is never looked up, and only its file name is shown unless you use `-IncludeDetails` |
| Link that leads nowhere | Not drawn, and listed as a warning in the report |
| `.xaml` file that isn't a workflow | A page saying so, and listed in the report |
| Folder that can't be read, or a link to another folder | Skipped, and listed in the report; the rest of the project is still converted |

If a diagram file can't be written (for example because it is open or read-only), the other files and the report are still written, the report says which file failed and why, and the run ends with exit code 1.
| Activity the tool doesn't recognise | Dashed grey box with the activity type, and listed in the report |

## Checking it works

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Converter.ps1   # Windows PowerShell 5.1
pwsh -File .\tests\Test-Converter.ps1                                  # PowerShell 7
```

The tests convert the made-up workflows in [samples/](samples/) and the made-up edge cases in [tests/fixtures/](tests/fixtures/), and check the results. To check a diagram made from your own project without adding that project to the tests:

```powershell
pwsh -File .\tests\Test-Converter.ps1 -CheckFile C:\Diagrams\MyProcess.drawio
```

## Not affiliated with UiPath

This is an independent project. "UiPath" is used only to describe the files it reads.
