# uipath-to-drawio

Convert UiPath workflow files (`.xaml`) into editable draw.io diagrams (`.drawio`).

> **Status: version 1.** It draws state machines, flowcharts and a project map. Sequences get a summary page for now. See [CONTEXT.md](CONTEXT.md) for the plan.

## What it does

- Turns one `.xaml` file, or a whole UiPath project, into diagrams you can open and edit in draw.io.
- Keeps the layout you see in UiPath Studio for flowcharts and state machines, stretched so the text fits.
- Shows which workflow calls which on a first "Project map" page, with a page per workflow. Click a box to jump to that workflow's page.
- Writes a conversion report listing anything it couldn't draw or find.
- Runs offline in the PowerShell that comes with Windows, with nothing to install.

## What you need

- Windows, with Windows PowerShell 5.1 (built in) or PowerShell 7.
- Something to open `.drawio` files: [app.diagrams.net](https://app.diagrams.net) in a browser, the [draw.io desktop app](https://www.drawio.com/), or VS Code with the "Draw.io Integration" extension.

## Quick start

**1. Get the tool.** On GitHub, choose **Code > Download ZIP** and unzip it, for example to `C:\Tools\uipath-to-drawio`. Or clone it:

```powershell
git clone https://github.com/sgshaji/uipath-to-drawio.git C:\Tools\uipath-to-drawio
```

If you downloaded the ZIP, Windows marks the files as coming from the internet and may refuse to run them. Unblock them once:

```powershell
Get-ChildItem -Recurse C:\Tools\uipath-to-drawio | Unblock-File
```

**2. Open PowerShell in the tool's folder.**

```powershell
cd C:\Tools\uipath-to-drawio
```

**3. Convert.** Point `-Path` at your workflow file or project folder, and `-OutputPath` at the folder where the diagram should go:

```powershell
# A whole project (recommended): one diagram file with a project map and a linked page per workflow
.\src\Convert-UiPathToDrawio.ps1 -Path "C:\UiPath\MyProcess" -OutputPath "C:\Diagrams"

# A single workflow file
.\src\Convert-UiPathToDrawio.ps1 -Path "C:\UiPath\MyProcess\Main.xaml" -OutputPath "C:\Diagrams"
```

To try it first without your own files, convert the made-up sample project that comes with the tool:

```powershell
.\src\Convert-UiPathToDrawio.ps1 -Path ".\samples\project" -OutputPath ".\output\try"
```

**4. Open the result.** The tool prints the files it wrote, for example:

```
Wrote C:\Diagrams\MyProcess.drawio
Wrote C:\Diagrams\MyProcess.conversion-report.txt
```

Open the `.drawio` file in draw.io. The `.conversion-report.txt` beside it lists anything that couldn't be drawn or found.

## Paths: where your files go

Your UiPath files can stay where they are: `-Path` just points to them.

- **Full paths always work,** whichever folder PowerShell is in. To get one, right-click the file or folder in File Explorer and choose **Copy as path**, then paste it after `-Path`.
- **Paths starting with `.\` are relative** to the folder PowerShell is in. `.\src\Convert-UiPathToDrawio.ps1` only works when PowerShell is in the tool's folder (step 2). From anywhere else, use the script's full path with `&` in front:

  ```powershell
  & "C:\Tools\uipath-to-drawio\src\Convert-UiPathToDrawio.ps1" -Path "C:\UiPath\MyProcess" -OutputPath "C:\Diagrams"
  ```

- **Keep the quotes** around paths that contain spaces.
- **For a whole project,** point `-Path` at the project folder: the one that contains `project.json`.
- **Without `-OutputPath`,** results are written next to the input: beside the `.xaml` file, or beside the project folder.

If you work inside a clone of this repository, put real UiPath files in the `private` folder and write results to the `output` folder. Git ignores both, so client files and diagrams can never be committed by mistake.

## What you get

| You convert | You get |
| --- | --- |
| A project folder | `<project name>.drawio`, named from `project.json`, with a "Project map" page first and then a page per workflow, all linked. Plus `<project name>.conversion-report.txt` |
| A single `.xaml` file | `<file name>.drawio` with one page, plus `<file name>.conversion-report.txt`. The workflows it calls are listed, but not linked, because they aren't converted |
| A project folder with `-OnePerFile` | One `.drawio` per workflow and a separate project-map file. Pages in different files can't link to each other |

## Options

| Option | Meaning |
| --- | --- |
| `-Path` | The `.xaml` file or project folder to convert. Required |
| `-OutputPath` | The folder to write to; it is created if it doesn't exist. Default: the folder the input is in |
| `-OnePerFile` | One `.drawio` per workflow, plus a project-map file, instead of one file with a page per workflow |
| `-IncludeDetails` | Add transition and decision conditions, switch expressions, file names worked out at run time, and full paths of invoked files outside the project. Off by default, so server names and data don't end up in diagrams you share |

For the full built-in help, run `Get-Help .\src\Convert-UiPathToDrawio.ps1 -Full`.

## What gets drawn

| In UiPath | In the diagram |
| --- | --- |
| State | Rounded box listing the workflows it invokes. Final states have a thick red border |
| Transition | Arrow labelled with its name |
| Flowchart step | Box with the step's name |
| Invoke Workflow File step | Purple box naming the file it calls. When you convert a whole project (without `-OnePerFile`), it links to that workflow's page |
| Flow decision | Diamond. The arrows carry the branch labels saved in Studio (for example Yes and No), or True and False |
| Flow switch | Diamond. The arrows carry the case names and Default |
| Sequence and other workflows | A summary card listing the workflows it invokes |
| Invoked file that doesn't exist | Dashed red box, marked "missing" |
| Invoked file outside the project folder | Dashed grey box, marked "outside the project". It is never looked up, and only its file name is shown unless you use `-IncludeDetails` |
| Activity the tool doesn't recognise | Dashed grey box with the activity type, and listed in the report |
| Link that leads nowhere | Not drawn, and listed as a warning in the report |
| `.xaml` file that isn't a workflow | A page saying so, and listed in the report |
| Folder that can't be read, or a link to another folder | Skipped, and listed in the report; the rest of the project is still converted |

## Safe by default

- It only reads your files, and only writes to the output folder.
- It never runs or evaluates anything from a workflow; the files are treated as data.
- It works offline and sends nothing anywhere. Paths that lead outside the project, such as network shares, are never looked up.
- Conditions, expressions and outside paths are left out of the diagram unless you use `-IncludeDetails`.
- The report names files but never gives full paths, so it doesn't reveal your user name or folders.

## If something goes wrong

| Message | What to do |
| --- | --- |
| "...cannot be loaded because running scripts is disabled on this system" or "...is not digitally signed" | Unblock the files (see step 1 of the quick start), or run it this way: `powershell -ExecutionPolicy Bypass -File .\src\Convert-UiPathToDrawio.ps1 -Path "..." -OutputPath "..."` |
| "The term '.\src\Convert-UiPathToDrawio.ps1' is not recognized" | PowerShell is not in the tool's folder. Run `cd` to the tool's folder first, or use the script's full path with `&` in front (see "Paths" above) |
| "Path not found: ..." | The `-Path` you gave doesn't exist. Use **Copy as path** in File Explorer to get the exact path |
| "Could not write 1 diagram file(s)..." | A `.drawio` file was open or read-only. Close it and run again; the report says which file it was |

The tool ends with exit code 0 when everything was written, and 1 when something went wrong, so scripts can check the result.

## Checking it works

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Converter.ps1   # Windows PowerShell 5.1
pwsh -File .\tests\Test-Converter.ps1                                  # PowerShell 7
```

The tests convert the made-up workflows in [samples/](samples/) and the made-up edge cases in [tests/fixtures/](tests/fixtures/), and check the results. To check a diagram made from your own project without adding that project to the tests:

```powershell
pwsh -File .\tests\Test-Converter.ps1 -CheckFile "C:\Diagrams\MyProcess.drawio"
```

## Licence

[MIT](LICENSE).

## Not affiliated with UiPath

This is an independent project. "UiPath" is used only to describe the files it reads.
