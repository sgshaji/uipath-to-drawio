<#
.SYNOPSIS
    Converts a corpus of public UiPath projects and records how the converter copes with each.

.DESCRIPTION
    For every project listed in corpus.csv, this script:
      1. downloads only the .xaml and project.json files of the repository, at the exact commit listed,
         into a work folder outside this repository (Git is needed for this step only);
      2. converts the project in PowerShell 7 and in Windows PowerShell 5.1, each in its own process;
      3. checks the diagrams (well-formed XML, unique ids, arrows that point at real shapes, plain
         numbers, and on automatically laid-out pages: no arrow through a box, no shared paths, no
         overlapping labels), and compares the two PowerShell versions' output byte for byte;
      4. writes results.csv and summary.txt to the work folder.

    The downloaded projects belong to their authors and are never copied into this repository. Nothing
    in them is executed: only XAML and JSON files are checked out, and the converter reads them as data.

.PARAMETER WorkFolder
    Where to put the downloaded projects and the results. Default: a folder in the temp directory.

.PARAMETER Corpus
    The list of projects. Default: corpus.csv next to this script.

.PARAMETER Baseline
    A page-hashes.csv from an earlier run. Every page of this run is compared with it byte for byte,
    and the summary lists the pages that changed, by kind (state machine, flowchart, sequence, ...).
    Each run writes its own page-hashes.csv to the work folder; keep a copy to compare later runs with.

.EXAMPLE
    pwsh -File .\tests\compatibility\Invoke-CompatibilityRun.ps1

.EXAMPLE
    pwsh -File .\tests\compatibility\Invoke-CompatibilityRun.ps1 -Baseline .\page-hashes-v0.1.0.csv
#>
[CmdletBinding()]
param(
    [string]$WorkFolder = (Join-Path ([System.IO.Path]::GetTempPath()) 'uipath-to-drawio-compatibility'),
    [string]$Corpus = (Join-Path $PSScriptRoot 'corpus.csv'),
    [string]$Baseline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$converter = Join-Path $repoRoot 'src\Convert-UiPathToDrawio.ps1'
$testScript = Join-Path $repoRoot 'tests\Test-Converter.ps1'
$sources = Join-Path $WorkFolder 'projects'
$outputs = Join-Path $WorkFolder 'output'
foreach ($d in @($sources, $outputs)) { [void](New-Item -ItemType Directory -Force -Path $d) }

# Reuse the diagram checks from the test script, without running its tests.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($testScript, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Get-StyleNumber', 'Get-ArrowProblems', 'Get-CellInfo', 'Get-Label', 'Read-Drawio', 'Get-PageHashes', 'Get-FrameProblems') -contains $f.Name) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

function Get-Section {
    # The entries under one heading of a conversion report.
    param([string]$Report, [string]$Heading)
    $m = [regex]::Match($Report, '(?ms)^' + [regex]::Escape($Heading) + '[^\r\n]*\r?\n-+\r?\n(.*?)(\r?\n\r?\n|\z)')
    if (-not $m.Success) { return @() }
    return @($m.Groups[1].Value -split '\r?\n' | Where-Object { $_ -and $_.Trim() -ne 'None' -and $_ -notmatch '^  (These are not|Where these appear)' } | ForEach-Object { $_.Trim() })
}

function Get-Repository {
    # Shallow, sparse fetch of one commit: only .xaml and project.json files are checked out.
    # Folders are named after the commit, not the repository, to stay within Windows' path-length limit.
    param([string]$Name, [string]$Commit)
    $dir = Join-Path $sources $Commit.Substring(0, 12)
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
        if ((& git -C $dir rev-parse HEAD 2>$null) -eq $Commit) { return $dir }
    }
    else {
        [void](New-Item -ItemType Directory -Force -Path $dir)
        & git -C $dir init --quiet
        & git -C $dir config core.longpaths true
        & git -C $dir remote add origin "https://github.com/$Name.git"
        & git -C $dir sparse-checkout set --no-cone '*.xaml' '*.XAML' 'project.json' '**/project.json' 2>$null
    }
    & git -C $dir -c protocol.version=2 fetch --quiet --depth 1 --filter=blob:none origin $Commit 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    & git -C $dir checkout --quiet --force FETCH_HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $dir
}

function ConvertFrom-GitPath {
    # Git prints a path with non-ASCII characters in quotes, with each UTF-8 byte as an octal escape
    # ("App_\354\213\244..."). Decoding that here keeps the result independent of the console's code
    # page, which otherwise garbles such names when PowerShell reads Git's output.
    param([string]$Text)
    if (-not $Text.StartsWith('"')) { return $Text }
    $inner = $Text.Substring(1, $Text.Length - 2)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $inner.Length) {
        $c = $inner[$i]
        if ($c -eq '\' -and $i + 1 -lt $inner.Length) {
            $next = $inner[$i + 1]
            if ($next -match '[0-7]' -and $i + 3 -lt $inner.Length + 1) {
                $bytes.Add([Convert]::ToByte($inner.Substring($i + 1, 3), 8)); $i += 4; continue
            }
            $map = @{ 'n' = 10; 't' = 9; '"' = 34; '\' = 92 }
            if ($map.ContainsKey([string]$next)) { $bytes.Add([byte]$map[[string]$next]); $i += 2; continue }
        }
        foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$c)) { $bytes.Add($b) }
        $i++
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Test-Download {
    # Confirms the folder holds exactly the pinned commit, and that every .xaml and project.json file
    # that commit contains is on disk. A checkout can drop files without failing, for example when a
    # path is too long for Windows, so this is checked rather than assumed.
    param([string]$Dir, [string]$Commit)
    $head = (& git -C $Dir rev-parse HEAD 2>$null)
    if ($head -ne $Commit) { return @{ Complete = $false; Expected = 0; Missing = 0; Problem = "checked out $head instead of the pinned commit" } }
    $expected = @(& git -C $Dir -c core.quotepath=on ls-tree -r --name-only HEAD 2>$null | ForEach-Object { ConvertFrom-GitPath $_ } | Where-Object { $_ -match '(\.xaml|(^|/)project\.json)$' })
    $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Dir ($_ -replace '/', '\'))) })
    $problem = ''
    if ($missing.Count -gt 0) { $problem = "incomplete download: $($missing.Count) of $($expected.Count) files missing, for example $($missing[0])" }
    return @{ Complete = ($missing.Count -eq 0); Expected = $expected.Count; Missing = $missing.Count; Problem = $problem }
}

$rows = @(Import-Csv -LiteralPath $Corpus)
$results = New-Object System.Collections.Generic.List[object]
$pageHashes = New-Object System.Collections.Generic.List[object]    # every page of the PowerShell 7 output
$i = 0
foreach ($p in $rows) {
    $i++
    $id = ($p.Repository -replace '/', '__') + '__' + (($p.ProjectPath -replace '/', '_') -replace '_?project\.json$', '')
    $row = [ordered]@{
        Id = $id; Repository = $p.Repository; ProjectPath = $p.ProjectPath; Commit = $p.Commit
        StudioVersion = $p.StudioVersion; TargetFramework = $p.TargetFramework; ExpressionLanguage = $p.ExpressionLanguage; OutputType = $p.OutputType
        Fetched = $false; Complete = $false; MissingFromDownload = 0; XamlFiles = 0; Exit7 = ''; Exit51 = ''; Seconds7 = ''; Seconds51 = ''; Error = ''
        SameIn51And7 = ''; Workflows = 0; StateMachines = 0; Flowcharts = 0; SummaryOnly = 0; SequencePages = 0; ActivitiesTotal = 0; ActivitiesDrawn = 0; FullyDrawn = 0; Decisions = ''; TryCatches = 0; NotExpanded = ''; StudioLayout = 0; AutoLayout = 0
        Missing = 0; Outside = 0; RunTime = 0; UnrecognisedTypes = ''; Warnings = 0; Unreadable = 0; NotWorkflows = 0; SkippedFolders = 0
        CheckProblems = 0; CheckDetails = ''
    }
    $short = '{0:000}' -f $i     # output folder name; kept short for the same path-length reason
    $row.Id = "$short $id"
    Write-Host ('[{0}/{1}] {2}' -f $i, $rows.Count, $p.Repository)
    $dir = Get-Repository $p.Repository $p.Commit
    if ($null -eq $dir) { $row.Error = 'could not fetch the listed commit'; $results.Add([pscustomobject]$row); continue }
    $row.Fetched = $true
    $download = Test-Download $dir $p.Commit
    $row.Complete = $download.Complete
    $row.MissingFromDownload = $download.Missing
    if (-not $download.Complete) {
        # Still converted, so the run shows what happens, but flagged: its figures are not comparable.
        $row.Error = $download.Problem
        Write-Warning ("{0}: {1}" -f $p.Repository, $download.Problem)
    }
    $projectDir = Join-Path $dir (Split-Path -Parent ($p.ProjectPath -replace '/', '\'))
    $row.XamlFiles = @(Get-ChildItem -LiteralPath $projectDir -Recurse -Filter *.xaml -File -ErrorAction SilentlyContinue).Count

    foreach ($shell in @('pwsh', 'powershell')) {
        $tag = if ($shell -eq 'pwsh') { '7' } else { '51' }
        $out = Join-Path $outputs "$short\$tag"
        # Start from an empty folder, so files from an earlier run can never be counted as this run's.
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $console = & $shell -NoProfile -ExecutionPolicy Bypass -File $converter -Path $projectDir -OutputPath $out 2>&1 | ForEach-Object { "$_" }
        $watch.Stop()
        $row["Exit$tag"] = $LASTEXITCODE
        $row["Seconds$tag"] = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
        if ($LASTEXITCODE -ne 0 -and -not $row.Error) { $row.Error = (($console | Where-Object { $_ -notmatch '^(Wrote|See the report)' }) -join ' | ') }
    }

    $out7 = Join-Path $outputs "$short\7"
    $out51 = Join-Path $outputs "$short\51"
    $diagrams = @(Get-ChildItem -LiteralPath $out7 -Filter *.drawio -ErrorAction SilentlyContinue)
    $same = $true
    foreach ($f in $diagrams) {
        $other = Join-Path $out51 $f.Name
        if (-not (Test-Path -LiteralPath $other) -or (Get-FileHash -LiteralPath $f.FullName).Hash -ne (Get-FileHash -LiteralPath $other).Hash) { $same = $false }
    }
    $row.SameIn51And7 = $same
    foreach ($f in $diagrams) {
        foreach ($pg in (Get-PageHashes $f.FullName)) {
            $pageHashes.Add([pscustomobject]@{ Project = $short; File = $f.Name; Page = $pg.Page; Kind = $pg.Kind; Hash = $pg.Hash })
        }
    }

    $report = ''
    $reportFile = @(Get-ChildItem -LiteralPath $out7 -Filter *.conversion-report.txt -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($reportFile) {
        $report = [System.IO.File]::ReadAllText($reportFile.FullName)
        $workflows = @(Get-Section $report 'Workflows converted')
        $row.Workflows = $workflows.Count
        $row.StateMachines = @($workflows | Where-Object { $_ -match ' - state machine:' }).Count
        $row.Flowcharts = @($workflows | Where-Object { $_ -match ' - flowchart:' }).Count
        $row.SummaryOnly = @($workflows | Where-Object { $_ -match 'summary page only' }).Count
        $row.SequencePages = @($workflows | Where-Object { $_ -match ' - sequence: ' }).Count
        # Each workflow line ends "Activities drawn: N of M." (activities below the top-level one).
        foreach ($w in $workflows) {
            $m = [regex]::Match($w, 'Activities drawn: (\d+) of (\d+)\.')
            if (-not $m.Success) { continue }
            $row.ActivitiesDrawn += [int]$m.Groups[1].Value
            $row.ActivitiesTotal += [int]$m.Groups[2].Value
            if ($m.Groups[1].Value -eq $m.Groups[2].Value -and $w -notmatch 'summary page only') { $row.FullyDrawn++ }
        }
        # Sequence pages: "N decisions drawn with their branches (If x3, Switch)" and
        # "N activities holding others not expanded (TryCatch x2, ...)". Kept as "Type=count; ..." lists.
        $decisions = @{}
        $opaque = @{}
        foreach ($w in $workflows) {
            foreach ($pair in @(@('drawn with (?:its|their) branches \(([^)]*)\)', $decisions), @('holding others not expanded \(([^)]*)\)', $opaque))) {
                $m = [regex]::Match($w, $pair[0])
                if (-not $m.Success) { continue }
                foreach ($part in $m.Groups[1].Value.Split(',')) {
                    $x = [regex]::Match($part.Trim(), '^(.*?)(?: x(\d+))?$')
                    $count = 1
                    if ($x.Groups[2].Success) { $count = [int]$x.Groups[2].Value }
                    $pair[1][$x.Groups[1].Value] = $count + [int]$pair[1][$x.Groups[1].Value]
                }
            }
        }
        foreach ($w in $workflows) {
            $m = [regex]::Match($w, '(\d+) Try Catch(?:es)? drawn with Try, Catch and Finally regions')
            if ($m.Success) { $row.TryCatches += [int]$m.Groups[1].Value }
        }
        $row.Decisions = (@($decisions.Keys | Sort-Object | ForEach-Object { $_ + '=' + $decisions[$_] }) -join '; ')
        $row.NotExpanded = (@($opaque.Keys | Sort-Object | ForEach-Object { $_ + '=' + $opaque[$_] }) -join '; ')
        $row.StudioLayout = @($workflows | Where-Object { $_ -match 'layout saved in Studio' }).Count
        $row.AutoLayout = @($workflows | Where-Object { $_ -match 'laid out automatically' }).Count
        $row.Missing = @(Get-Section $report 'Invoked workflows not found').Count
        $row.Outside = @(Get-Section $report 'Invoked files outside the project folder').Count
        $row.RunTime = @(Get-Section $report 'File names set at run time').Count
        # Activity types from other libraries or packages: the lines "Type (package) - n, in ..." under "Activities by source".
        $row.UnrecognisedTypes = (@(Get-Section $report 'Activities by source') | Where-Object { $_ -match '^\S+ \([^)]*\) - \d+, in ' } | ForEach-Object { ($_ -split ' ')[0] } | Sort-Object -Unique) -join ' '
        $row.Warnings = @(Get-Section $report 'Warnings').Count
        $row.Unreadable = @(Get-Section $report 'Files that could not be read').Count
        $row.NotWorkflows = @(Get-Section $report 'Files that are not workflows').Count
        $row.SkippedFolders = @(Get-Section $report 'Folders skipped').Count
    }

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($f in $diagrams) {
        try {
            $d = Read-Drawio $f.FullName
            foreach ($dg in $d.Doc.SelectNodes('/mxfile/diagram')) {
                $ids = @{}
                foreach ($c in $dg.SelectNodes('mxGraphModel/root/*')) {
                    $cid = $c.GetAttribute('id')
                    if ($ids.ContainsKey($cid)) { $problems.Add("duplicate id $cid") }
                    $ids[$cid] = $true
                }
                foreach ($c in $dg.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]')) {
                    if (-not $ids.ContainsKey($c.GetAttribute('source')) -or -not $ids.ContainsKey($c.GetAttribute('target'))) { $problems.Add('arrow to a missing shape') }
                }
                foreach ($g in $dg.SelectNodes('.//mxGeometry | .//mxPoint')) {
                    foreach ($a in @('x', 'y', 'width', 'height')) {
                        $v = $g.GetAttribute($a)
                        if ($v -and $v -notmatch '^-?\d+(\.\d+)?$') { $problems.Add("geometry $a=$v") }
                    }
                }
                # Arrow checks apply to automatic layout only; Studio's own routes are copied as they are.
                $name = $dg.GetAttribute('name')
                if ($name -eq 'Project map' -or $report -match ('(?m)^  ' + [regex]::Escape($name) + '( \[main\])? - .*laid out automatically')) {
                    foreach ($pr in (Get-ArrowProblems $dg)) { $problems.Add("$name`: $pr") }
                }
                # Sequence pages: shapes inside their frames, none overlapping, arrows straight down.
                if ($report -match ('(?m)^  ' + [regex]::Escape($name) + '( \[main\])? - sequence: ')) {
                    foreach ($pr in (Get-FrameProblems $dg)) { $problems.Add("$name`: $pr") }
                }
            }
        }
        catch { $problems.Add('not well-formed: ' + $_.Exception.Message) }
    }
    $row.CheckProblems = $problems.Count
    $row.CheckDetails = (@($problems | Select-Object -First 5) -join ' | ')
    $results.Add([pscustomobject]$row)
}

$csvOptions = @{ LiteralPath = (Join-Path $WorkFolder 'results.csv'); Encoding = 'UTF8' }
if ($PSVersionTable.PSVersion.Major -lt 6) { $csvOptions.NoTypeInformation = $true }   # the default from PowerShell 6 on
$results | Export-Csv @csvOptions
$csvOptions.LiteralPath = (Join-Path $WorkFolder 'page-hashes.csv')
$pageHashes | Export-Csv @csvOptions

# Only complete downloads that converted in both versions count towards the totals below.
$ok = @($results | Where-Object { $_.Complete -and $_.Exit7 -eq 0 -and $_.Exit51 -eq 0 })
$sum = { param($name) [int](($ok | Measure-Object -Property $name -Sum).Sum) }
$kinds = {
    # Totals of a "Type=count; Type=count" column across projects, largest first.
    param($name)
    $all = @{}
    foreach ($r in $ok) {
        foreach ($part in ([string]$r.$name).Split(';')) {
            if (-not $part.Trim()) { continue }
            $kv = $part.Trim().Split('=')
            $all[$kv[0]] = [int]$kv[1] + [int]$all[$kv[0]]
        }
    }
    $total = 0
    foreach ($v in $all.Values) { $total += $v }
    $list = @($all.Keys | Sort-Object @{ Expression = { -$all[$_] } }, @{ Expression = { $_ } } | ForEach-Object { $_ + ' ' + $all[$_] })
    if ($list.Count -eq 0) { return '0' }
    return "$total (" + ($list -join ', ') + ')'
}
$incomplete = @($results | Where-Object { $_.Fetched -and -not $_.Complete })
$lines = @(
    "Projects listed: $($results.Count); fetched: $(@($results | Where-Object Fetched).Count); complete downloads: $(@($results | Where-Object Complete).Count)"
    "Incomplete downloads (excluded from the totals): $($incomplete.Count)$(if ($incomplete.Count) { ' - ' + (($incomplete | ForEach-Object { $_.Repository }) -join ', ') })"
    "Converted in both PowerShell versions: $($ok.Count)"
    "Failures: $(@($results | Where-Object { $_.Complete -and -not ($_.Exit7 -eq 0 -and $_.Exit51 -eq 0) }).Count)"
    "Identical output in 5.1 and 7: $(@($results | Where-Object { $_.SameIn51And7 -eq $true }).Count)"
    "Workflows: $(& $sum 'Workflows'); state machines drawn: $(& $sum 'StateMachines'); flowcharts drawn: $(& $sum 'Flowcharts'); summary only: $(& $sum 'SummaryOnly')"
    "Sequence pages (steps drawn top to bottom): $(& $sum 'SequencePages')"
    "Activities drawn: $(& $sum 'ActivitiesDrawn') of $(& $sum 'ActivitiesTotal') ($(if ((& $sum 'ActivitiesTotal') -gt 0) { [Math]::Round(100.0 * (& $sum 'ActivitiesDrawn') / (& $sum 'ActivitiesTotal'), 1) } else { 0 })%); workflows with every activity drawn: $(& $sum 'FullyDrawn')"
    "Decisions drawn with their branches: $(& $kinds 'Decisions')"
    "Try Catches drawn with their regions: $(& $sum 'TryCatches')"
    "Activities holding others, not expanded: $(& $kinds 'NotExpanded')"
    "Studio layout used: $(& $sum 'StudioLayout'); automatic layout: $(& $sum 'AutoLayout')"
    "Invoked files missing: $(& $sum 'Missing'); outside the project: $(& $sum 'Outside'); set at run time: $(& $sum 'RunTime')"
    "Unreadable files: $(& $sum 'Unreadable'); not workflows: $(& $sum 'NotWorkflows'); folders skipped: $(& $sum 'SkippedFolders'); warnings: $(& $sum 'Warnings')"
    "Diagram check problems: $(& $sum 'CheckProblems')"
)
if ($Baseline) {
    # Byte-for-byte comparison of every page with the earlier run, keyed by project, file and page.
    $old = @{}
    foreach ($b in @(Import-Csv -LiteralPath $Baseline)) { $old[$b.Project + '|' + $b.File + '|' + $b.Page] = $b }
    $seen = @{}
    $changed = @{}
    $same = 0
    foreach ($pg in $pageHashes) {
        $k = $pg.Project + '|' + $pg.File + '|' + $pg.Page
        $seen[$k] = $true
        if (-not $old.ContainsKey($k)) { $changed['new ' + $pg.Kind] = 1 + [int]$changed['new ' + $pg.Kind]; continue }
        if ($old[$k].Hash -eq $pg.Hash -and $old[$k].Kind -eq $pg.Kind) { $same++ }
        else {
            $what = $old[$k].Kind
            if ($old[$k].Kind -ne $pg.Kind) { $what = $old[$k].Kind + ' -> ' + $pg.Kind }
            $changed[$what] = 1 + [int]$changed[$what]
        }
    }
    foreach ($k in $old.Keys) { if (-not $seen.ContainsKey($k)) { $changed['gone ' + $old[$k].Kind] = 1 + [int]$changed['gone ' + $old[$k].Kind] } }
    $detail = (@($changed.Keys | Sort-Object | ForEach-Object { $_ + ': ' + $changed[$_] }) -join '; ')
    if (-not $detail) { $detail = 'none' }
    $lines += "Pages compared with the baseline: $($pageHashes.Count); identical: $same; changed: $detail"
}
[System.IO.File]::WriteAllText((Join-Path $WorkFolder 'summary.txt'), ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
$lines | ForEach-Object { Write-Host $_ }
Write-Host "Results: $(Join-Path $WorkFolder 'results.csv')"
