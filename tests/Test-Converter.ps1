<#
.SYNOPSIS
    Tests for Convert-UiPathToDrawio.ps1. Needs nothing installed; runs in Windows PowerShell 5.1
    and PowerShell 7.

.DESCRIPTION
    Converts the made-up samples into a temporary folder, checks the .drawio files are well-formed
    draw.io files (unique ids, arrows that point at real shapes, page links that point at real
    pages, no byte-order mark) and checks what each sample should contain.

    This does not check that draw.io itself opens the files. Do that separately (see CONTEXT.md).

.PARAMETER CheckFile
    Instead of running the tests, only check that these .drawio files are well-formed. Use it on
    diagrams made from real projects, without copying those projects into the tests.

.PARAMETER UpdateBaseline
    Instead of running the tests, rewrite tests/baselines/page-hashes.txt from the current converter.
    The tests compare every state machine, flowchart and project map page made from the samples and
    fixtures with that file, byte for byte. Update it only for a change that is meant to alter those
    pages, and say why in the commit.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Test-Converter.ps1
    pwsh -File .\tests\Test-Converter.ps1

.EXAMPLE
    pwsh -File .\tests\Test-Converter.ps1 -CheckFile .\output\private\Main.drawio
#>
[CmdletBinding()]
param(
    [string[]]$CheckFile,
    [switch]$UpdateBaseline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$converter = Join-Path $repo 'src\Convert-UiPathToDrawio.ps1'
$samples = Join-Path $repo 'samples'
$fixtures = Join-Path $PSScriptRoot 'fixtures'    # made-up inputs for edge cases; see each file's comment
$baselineFile = Join-Path $PSScriptRoot 'baselines\page-hashes.txt'

$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host ('  ok    ' + $Message)
    }
    else {
        $script:Failed.Add($Message)
        Write-Host ('  FAIL  ' + $Message) -ForegroundColor Red
    }
}

function Invoke-Converter {
    param([hashtable]$Arguments)
    $Arguments['PassThru'] = $true
    # Stream 6 is Write-Host output; keep the test log readable.
    return (& $converter @Arguments 6>$null)
}

function Read-Drawio {
    param([string]$File)
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($text)
    return @{ Doc = $doc; Text = $text; HasBom = $hasBom }
}

function Get-Label {
    param($Cell)
    if ($Cell.LocalName -eq 'UserObject') { return $Cell.GetAttribute('label') }
    return $Cell.GetAttribute('value')
}

function Get-PageCells {
    # All cells on a page: mxCell elements and UserObject wrappers (which hold the id and label).
    param($Diagram)
    $cells = @()
    foreach ($n in $Diagram.SelectNodes('mxGraphModel/root/*')) { $cells += $n }
    return $cells
}

function Get-CellInfo {
    param($Cell)
    $inner = $Cell
    if ($Cell.LocalName -eq 'UserObject') { $inner = $Cell.SelectSingleNode('mxCell') }
    return @{
        Id     = $Cell.GetAttribute('id')
        Label  = (Get-Label $Cell)
        Link   = $Cell.GetAttribute('link')
        Edge   = ($inner.GetAttribute('edge') -eq '1')
        Vertex = ($inner.GetAttribute('vertex') -eq '1')
        Parent = $inner.GetAttribute('parent')
        Source = $inner.GetAttribute('source')
        Target = $inner.GetAttribute('target')
        Style  = $inner.GetAttribute('style')
        Inner  = $inner
    }
}

function Test-DrawioStructure {
    # Checks every rule a .drawio file has to meet for draw.io to open it as intended.
    param([string]$File)
    $name = Split-Path -Leaf $File
    $d = $null
    try { $d = Read-Drawio $File } catch { Assert $false "$name is well-formed XML ($($_.Exception.Message))"; return $null }
    Assert $true "$name is well-formed XML"
    Assert (-not $d.HasBom) "$name has no byte-order mark"
    Assert ($d.Doc.DocumentElement.LocalName -eq 'mxfile') "$name has <mxfile> as its root"
    Assert ($d.Doc.SelectNodes('//comment()').Count -eq 0) "$name has no XML comments"

    $diagrams = @($d.Doc.SelectNodes('/mxfile/diagram'))
    Assert ($diagrams.Count -ge 1) "$name has at least one page"
    $pageIds = @{}
    foreach ($dg in $diagrams) { $pageIds[$dg.GetAttribute('id')] = $true }
    Assert ($pageIds.Count -eq $diagrams.Count) "$name page ids are unique"

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($dg in $diagrams) {
        $page = $dg.GetAttribute('name')
        $cells = Get-PageCells $dg
        $ids = @{}
        foreach ($c in $cells) {
            $id = $c.GetAttribute('id')
            if ($ids.ContainsKey($id)) { $problems.Add("page '$page': duplicate id $id") }
            $ids[$id] = $true
        }
        if (-not $ids.ContainsKey('0') -or -not $ids.ContainsKey('1')) { $problems.Add("page '$page': missing cell 0 or 1") }
        foreach ($c in $cells) {
            $info = Get-CellInfo $c
            if ($info.Id -eq '0') { continue }
            if (-not $ids.ContainsKey($info.Parent)) { $problems.Add("page '$page': cell $($info.Id) has unknown parent '$($info.Parent)'") }
            if ($info.Edge) {
                if (-not $ids.ContainsKey($info.Source)) { $problems.Add("page '$page': edge $($info.Id) has unknown source") }
                if (-not $ids.ContainsKey($info.Target)) { $problems.Add("page '$page': edge $($info.Id) has unknown target") }
            }
            if ($info.Vertex -or $info.Edge) {
                if ($null -eq $info.Inner.SelectSingleNode('mxGeometry[@as="geometry"]')) { $problems.Add("page '$page': cell $($info.Id) has no geometry") }
            }
            if ($info.Link) {
                if ($info.Link -notmatch '^data:page/id,(.+)$') { $problems.Add("page '$page': cell $($info.Id) has an unexpected link") }
                elseif (-not $pageIds.ContainsKey($Matches[1])) { $problems.Add("page '$page': link to missing page $($Matches[1])") }
            }
        }
        foreach ($g in $dg.SelectNodes('.//mxGeometry')) {
            foreach ($a in @('x', 'y', 'width', 'height')) {
                $v = $g.GetAttribute($a)
                if ($v -and $v -notmatch '^-?\d+(\.\d+)?$') { $problems.Add("page '$page': geometry $a='$v' is not a plain number") }
            }
        }
    }
    Assert ($problems.Count -eq 0) ("$name ids, parents, arrows and page links are all valid" + $(if ($problems.Count) { ': ' + ($problems -join '; ') } else { '' }))
    return $d
}

function Get-StyleNumber {
    param([string]$Style, [string]$Name, [double]$Default)
    $m = [regex]::Match($Style, '(?:^|;)' + $Name + '=([-0-9.]+)')
    if ($m.Success) { return [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    return $Default
}

function Get-ArrowProblems {
    # Redraws every arrow on a page from the file (exit point, waypoints, entry point) and returns
    # what a reader would trip over: an arrow through a box, two arrows on one path, or a label
    # on top of another label or a box. Only meaningful for pages laid out automatically.
    param($Diagram)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $problems = New-Object System.Collections.Generic.List[string]
    $boxes = @{}
    foreach ($c in $Diagram.SelectNodes('mxGraphModel/root/*')) {
        $info = Get-CellInfo $c
        if (-not $info.Vertex -or $info.Parent -ne '1' -or $info.Style -like 'text;*') { continue }
        $g = $info.Inner.SelectSingleNode('mxGeometry')
        $boxes[$info.Id] = @{
            Label = ([string]$info.Label -split "`n")[0]
            X = [double]::Parse($g.GetAttribute('x'), $inv); Y = [double]::Parse($g.GetAttribute('y'), $inv)
            W = [double]::Parse($g.GetAttribute('width'), $inv); H = [double]::Parse($g.GetAttribute('height'), $inv)
        }
    }
    $paths = @()
    $labels = @()
    foreach ($c in $Diagram.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]')) {
        $style = $c.GetAttribute('style')
        $s = $boxes[$c.GetAttribute('source')]
        $t = $boxes[$c.GetAttribute('target')]
        $poly = @(, @(($s.X + $s.W * (Get-StyleNumber $style 'exitX' 0.5)), ($s.Y + $s.H * (Get-StyleNumber $style 'exitY' 1))))
        foreach ($p in $c.SelectNodes('mxGeometry/Array/mxPoint')) {
            $poly += , @([double]::Parse($p.GetAttribute('x'), $inv), [double]::Parse($p.GetAttribute('y'), $inv))
        }
        $poly += , @(($t.X + $t.W * (Get-StyleNumber $style 'entryX' 0.5)), ($t.Y + $t.H * (Get-StyleNumber $style 'entryY' 0)))
        $name = '"' + $s.Label + '" to "' + $t.Label + '"'
        $paths += (($poly | ForEach-Object { '{0:0.#},{1:0.#}' -f $_[0], $_[1] }) -join ' ')

        # Walk the path in 2-pixel steps; no step may fall inside a box other than its own two ends.
        $hit = @{}
        $lengths = @()
        $total = 0.0
        for ($i = 1; $i -lt $poly.Count; $i++) {
            $a = $poly[$i - 1]; $b = $poly[$i]
            $len = [Math]::Sqrt([Math]::Pow($b[0] - $a[0], 2) + [Math]::Pow($b[1] - $a[1], 2))
            $lengths += $len
            $total += $len
            $steps = [Math]::Max(1, [Math]::Ceiling($len / 2))
            for ($k = 0; $k -le $steps; $k++) {
                $px = $a[0] + ($b[0] - $a[0]) * $k / $steps
                $py = $a[1] + ($b[1] - $a[1]) * $k / $steps
                foreach ($id in $boxes.Keys) {
                    if ($id -eq $c.GetAttribute('source') -or $id -eq $c.GetAttribute('target')) { continue }
                    $r = $boxes[$id]
                    if ($px -gt $r.X + 1.5 -and $px -lt $r.X + $r.W - 1.5 -and $py -gt $r.Y + 1.5 -and $py -lt $r.Y + $r.H - 1.5) { $hit[$r.Label] = $true }
                }
            }
        }
        foreach ($h in $hit.Keys) { $problems.Add("arrow $name crosses the box `"$h`"") }

        # Where draw.io puts the label: (x + 1) / 2 of the way along the path.
        $text = $c.GetAttribute('value')
        if ([string]::IsNullOrEmpty($text) -or $total -eq 0) { continue }
        $g = $c.SelectSingleNode('mxGeometry')
        $lx = 0.0
        if ($g.GetAttribute('x')) { $lx = [double]::Parse($g.GetAttribute('x'), $inv) }
        $dist = ($lx + 1) * $total / 2
        $i = 0
        while ($i -lt $lengths.Count - 1 -and $dist -gt $lengths[$i]) { $dist -= $lengths[$i]; $i++ }
        $f = 0.0
        if ($lengths[$i] -gt 0) { $f = [Math]::Min(1.0, $dist / $lengths[$i]) }
        $cx = $poly[$i][0] + ($poly[$i + 1][0] - $poly[$i][0]) * $f
        $cy = $poly[$i][1] + ($poly[$i + 1][1] - $poly[$i][1]) * $f
        $offset = $g.SelectSingleNode('mxPoint[@as="offset"]')
        if ($null -ne $offset) {
            $cx += [double]::Parse($offset.GetAttribute('x'), $inv)
            $cy += [double]::Parse($offset.GetAttribute('y'), $inv)
        }
        $lines = @($text -split "`n")
        $longest = ($lines | Measure-Object -Property Length -Maximum).Maximum
        $w = $longest * 6.2 + 4
        $h = $lines.Count * 13 + 2
        $labels += @{ Text = $text; X = $cx - $w / 2; Y = $cy - $h / 2; W = $w; H = $h }
    }
    $seen = @{}
    foreach ($p in $paths) {
        if ($seen.ContainsKey($p)) { $problems.Add("two arrows share the path $p") }
        $seen[$p] = $true
    }
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $a = $labels[$i]
        for ($j = $i + 1; $j -lt $labels.Count; $j++) {
            $b = $labels[$j]
            if ($a.X -lt $b.X + $b.W -and $b.X -lt $a.X + $a.W -and $a.Y -lt $b.Y + $b.H -and $b.Y -lt $a.Y + $a.H) { $problems.Add("labels `"$($a.Text)`" and `"$($b.Text)`" overlap") }
        }
        foreach ($id in $boxes.Keys) {
            $r = $boxes[$id]
            if ($a.X -lt $r.X + $r.W -and $r.X -lt $a.X + $a.W -and $a.Y -lt $r.Y + $r.H -and $r.Y -lt $a.Y + $a.H) { $problems.Add("label `"$($a.Text)`" covers the box `"$($r.Label)`"") }
        }
    }
    return , $problems
}

function Get-FrameProblems {
    # For pages drawn as nested containers (sequence pages): every shape lies inside its container,
    # below the container's header; shapes in one container do not overlap; every arrow joins two
    # shapes in the same container and runs straight down from one to the next.
    param($Diagram)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $problems = New-Object System.Collections.Generic.List[string]
    $shapes = @{}
    foreach ($c in $Diagram.SelectNodes('mxGraphModel/root/*')) {
        $info = Get-CellInfo $c
        if (-not $info.Vertex) { continue }
        if ($info.Parent -eq '1' -and $info.Style -like 'text;*') { continue }    # the page's title and links
        $g = $info.Inner.SelectSingleNode('mxGeometry')
        $shapes[$info.Id] = @{
            Parent = $info.Parent; Label = ([string]$info.Label -split "`n")[0]; Style = $info.Style
            X = [double]::Parse($g.GetAttribute('x'), $inv); Y = [double]::Parse($g.GetAttribute('y'), $inv)
            W = [double]::Parse($g.GetAttribute('width'), $inv); H = [double]::Parse($g.GetAttribute('height'), $inv)
        }
    }
    $byParent = @{}
    foreach ($s in $shapes.Values) {
        if (-not $byParent.ContainsKey($s.Parent)) { $byParent[$s.Parent] = New-Object System.Collections.Generic.List[object] }
        $byParent[$s.Parent].Add($s)
        if ($shapes.ContainsKey($s.Parent)) {
            $p = $shapes[$s.Parent]
            $header = Get-StyleNumber $p.Style 'startSize' 0
            if ($s.X -lt -0.01 -or $s.Y -lt $header - 0.01 -or $s.X + $s.W -gt $p.W + 0.01 -or $s.Y + $s.H -gt $p.H + 0.01) {
                $problems.Add("`"$($s.Label)`" is not inside `"$($p.Label)`"")
            }
        }
    }
    foreach ($list in $byParent.Values) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            for ($j = $i + 1; $j -lt $list.Count; $j++) {
                $a = $list[$i]; $b = $list[$j]
                if ($a.X -lt $b.X + $b.W - 0.01 -and $b.X -lt $a.X + $a.W - 0.01 -and $a.Y -lt $b.Y + $b.H - 0.01 -and $b.Y -lt $a.Y + $a.H - 0.01) {
                    $problems.Add("`"$($a.Label)`" and `"$($b.Label)`" overlap")
                }
            }
        }
    }
    # Arrows. Each leaves the bottom middle of its source and enters the top middle of its target.
    # An arrow with no corners must run straight down. An arrow with corners (a branch) must be made
    # of horizontal and vertical runs that pass through no other shape in its container. Labels may
    # not cover a shape or another label in the same container.
    $labels = @{}
    foreach ($c in $Diagram.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]')) {
        $sid = $c.GetAttribute('source'); $tid = $c.GetAttribute('target')
        $s = $shapes[$sid]
        $t = $shapes[$tid]
        $parent = $c.GetAttribute('parent')
        $name = '"' + $s.Label + '" to "' + $t.Label + '"'
        if ($s.Parent -ne $parent -or $t.Parent -ne $parent) { $problems.Add("arrow $name leaves its container") }
        if ($t.Y -lt $s.Y + $s.H) { $problems.Add("arrow $name does not run downwards") }
        $poly = @(, @(($s.X + $s.W / 2), ($s.Y + $s.H)))
        foreach ($p in $c.SelectNodes('mxGeometry/Array/mxPoint')) { $poly += , @([double]::Parse($p.GetAttribute('x'), $inv), [double]::Parse($p.GetAttribute('y'), $inv)) }
        $poly += , @(($t.X + $t.W / 2), $t.Y)
        if ($poly.Count -eq 2) {
            if ([Math]::Abs($poly[0][0] - $poly[1][0]) -gt 0.5) { $problems.Add("arrow $name is not straight") }
        }
        $total = 0.0
        $lengths = @()
        for ($i = 1; $i -lt $poly.Count; $i++) {
            $a = $poly[$i - 1]; $b = $poly[$i]
            if ([Math]::Abs($a[0] - $b[0]) -gt 0.01 -and [Math]::Abs($a[1] - $b[1]) -gt 0.01) { $problems.Add("arrow $name has a slanted run") }
            $lengths += [Math]::Abs($a[0] - $b[0]) + [Math]::Abs($a[1] - $b[1])
            $total += $lengths[$lengths.Count - 1]
            $x1 = [Math]::Min($a[0], $b[0]); $x2 = [Math]::Max($a[0], $b[0]); $y1 = [Math]::Min($a[1], $b[1]); $y2 = [Math]::Max($a[1], $b[1])
            foreach ($o in $byParent[$parent]) {
                if ([object]::ReferenceEquals($o, $s) -or [object]::ReferenceEquals($o, $t)) { continue }
                if ($x2 -gt $o.X + 0.5 -and $x1 -lt $o.X + $o.W - 0.5 -and $y2 -gt $o.Y + 0.5 -and $y1 -lt $o.Y + $o.H - 0.5) { $problems.Add("arrow $name runs through `"$($o.Label)`"") }
            }
        }
        $text = $c.GetAttribute('value')
        if ([string]::IsNullOrEmpty($text) -or $total -eq 0) { continue }
        $lx = 0.0
        $gx = $c.SelectSingleNode('mxGeometry').GetAttribute('x')
        if ($gx) { $lx = [double]::Parse($gx, $inv) }
        $dist = ($lx + 1) * $total / 2
        $i = 0
        while ($i -lt $lengths.Count - 1 -and $dist -gt $lengths[$i]) { $dist -= $lengths[$i]; $i++ }
        $f = 0.0
        if ($lengths[$i] -gt 0) { $f = [Math]::Min(1.0, $dist / $lengths[$i]) }
        $cx = $poly[$i][0] + ($poly[$i + 1][0] - $poly[$i][0]) * $f
        $cy = $poly[$i][1] + ($poly[$i + 1][1] - $poly[$i][1]) * $f
        $w = $text.Length * 6.2 + 4
        $box = @{ Text = $text; X = $cx - $w / 2; Y = $cy - 7.5; W = $w; H = 15.0 }
        foreach ($o in $byParent[$parent]) {
            if ($box.X -lt $o.X + $o.W -and $o.X -lt $box.X + $box.W -and $box.Y -lt $o.Y + $o.H -and $o.Y -lt $box.Y + $box.H) { $problems.Add("label `"$text`" covers `"$($o.Label)`"") }
        }
        if (-not $labels.ContainsKey($parent)) { $labels[$parent] = New-Object System.Collections.Generic.List[object] }
        foreach ($l in $labels[$parent]) {
            if ($box.X -lt $l.X + $l.W -and $l.X -lt $box.X + $box.W -and $box.Y -lt $l.Y + $l.H -and $l.Y -lt $box.Y + $box.H) { $problems.Add("labels `"$text`" and `"$($l.Text)`" overlap") }
        }
        $labels[$parent].Add($box)
    }
    return , $problems
}

function Assert-CleanArrows {
    # Runs Get-ArrowProblems on every page of a file, or only the pages named.
    param([string]$File, [string]$What, [string[]]$Pages)
    $d = Read-Drawio $File
    $all = @()
    foreach ($dg in $d.Doc.SelectNodes('/mxfile/diagram')) {
        if ($Pages -and $Pages -notcontains $dg.GetAttribute('name')) { continue }
        foreach ($p in (Get-ArrowProblems $dg)) { $all += ($dg.GetAttribute('name') + ': ' + $p) }
    }
    Assert ($all.Count -eq 0) ("$What`: no arrow crosses a box, no two share a path, no label overlaps" + $(if ($all.Count) { ' -- ' + ($all -join '; ') } else { '' }))
}

function Get-AllLabels {
    param($Doc)
    $labels = @()
    foreach ($c in $Doc.SelectNodes('//mxCell[@value] | //UserObject[@label]')) { $labels += (Get-Label $c) }
    return $labels
}

function Get-EdgeLabels {
    param($Doc)
    $labels = @()
    foreach ($c in $Doc.SelectNodes('//mxCell[@edge="1"]')) { $labels += $c.GetAttribute('value') }
    return $labels
}

function Get-PageHashes {
    # One entry per page of a .drawio file: its name, what kind of page it is (from its title, for
    # example "flowchart" or "project map") and the SHA-256 of the page's text exactly as written.
    param([string]$File)
    $text = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $pages = @()
    foreach ($m in [regex]::Matches($text, '(?s)<diagram id="[^"]*" name="([^"]*)">.*?</diagram>')) {
        $kind = 'other'
        $title = [regex]::Match($m.Value, 'value="([^"]*)" style="text;fontSize=16;')
        if ($title.Success) {
            if ($title.Groups[1].Value.StartsWith('Project map: ')) { $kind = 'project map' }
            else {
                $k = [regex]::Match($title.Groups[1].Value, '\(([^()]*)\)$')
                if ($k.Success) { $kind = $k.Groups[1].Value }
            }
        }
        $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($m.Value)) | ForEach-Object { $_.ToString('x2') })
        $pages += @{ Page = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value); Kind = $kind; Hash = $hash }
    }
    return $pages
}

function Get-BaselineLines {
    # Converts every sample and fixture and lists each page as "input|file|page|kind|hash".
    param([string]$Folder)
    $inputs = New-Object System.Collections.Generic.List[object]
    foreach ($d in @('project', 'state-machine', 'flowchart')) { $inputs.Add(@{ Name = 'samples/' + $d; Path = (Join-Path $samples $d) }) }
    foreach ($f in @(Get-ChildItem -LiteralPath $fixtures | Sort-Object Name)) { $inputs.Add(@{ Name = 'fixtures/' + $f.Name; Path = $f.FullName }) }
    $lines = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($in in $inputs) {
        $i++
        $r = Invoke-Converter @{ Path = $in.Path; OutputPath = (Join-Path $Folder ('b' + $i)) }
        foreach ($f in @($r.DrawioFiles | Sort-Object)) {
            foreach ($p in (Get-PageHashes $f)) { $lines.Add(($in.Name, (Split-Path -Leaf $f), $p.Page, $p.Kind, $p.Hash) -join '|') }
        }
    }
    return , $lines
}

function Write-Result {
    Write-Host ''
    if ($script:Failed.Count -gt 0) {
        Write-Host ("$($script:Passed) passed, $($script:Failed.Count) failed") -ForegroundColor Red
        exit 1
    }
    Write-Host "$($script:Passed) passed, 0 failed" -ForegroundColor Green
    exit 0
}

if ($CheckFile) {
    foreach ($f in $CheckFile) { [void](Test-DrawioStructure (Resolve-Path -LiteralPath $f).ProviderPath) }
    Write-Result
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('uipath-to-drawio-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $work)

if ($UpdateBaseline) {
    try {
        $lines = Get-BaselineLines (Join-Path $work 'baseline')
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $baselineFile))
        [System.IO.File]::WriteAllText($baselineFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Wrote $($lines.Count) page hashes to $baselineFile"
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

try {
    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Host "Working folder: $work"

    # --- State machine ----------------------------------------------------------------------------
    Write-Host "`nState machine sample"
    $r = Invoke-Converter @{ Path = (Join-Path $samples 'state-machine\Main.xaml'); OutputPath = (Join-Path $work 'sm') }
    Assert ($r.DrawioFiles.Count -eq 1) 'writes one .drawio file'
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $labels = Get-AllLabels $d.Doc
    foreach ($s in @('Start Up', 'Fetch Next Order', 'Handle Order', 'Wrap Up')) { Assert ($labels -contains $s) "draws state '$s'" }
    $edgeLabels = Get-EdgeLabels $d.Doc
    Assert ($edgeLabels.Count -eq 8) "draws 7 transitions plus the start arrow (found $($edgeLabels.Count))"
    foreach ($t in @('Ready', 'Start-up failed', 'Order found', 'No more orders', 'Done', 'Business error', 'System error')) { Assert ($edgeLabels -contains $t) "labels transition '$t'" }
    Assert ($labels -contains 'Framework\GetNextOrder.xaml') 'lists the workflow a state invokes'
    $r2 = Invoke-Converter @{ Path = (Join-Path $samples 'state-machine'); OutputPath = (Join-Path $work 'sm-project') }
    $d2 = Test-DrawioStructure $r2.DrawioFiles[0]
    $smPage = $null
    foreach ($dg in $d2.Doc.SelectNodes('/mxfile/diagram')) { if ($dg.GetAttribute('name') -eq 'Main.xaml') { $smPage = $dg } }
    $rowLinks = @($smPage.SelectNodes('.//UserObject[@link]') | Where-Object { $_.GetAttribute('label') -like '*.xaml' }).Count
    Assert ($rowLinks -eq 6) "in a whole-project conversion, each workflow listed in a state links to its page (found $rowLinks of 6)"
    Assert ($d.Text -notmatch 'StartUpError|OrderError') 'leaves transition conditions out by default'
    $finalStyle = ''
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@value="Wrap Up"]')) { $finalStyle = $c.GetAttribute('style') }
    Assert ($finalStyle -match 'strokeWidth=3') 'draws the final state with end styling'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'layout saved in Studio') 'uses the layout saved in Studio'
    Assert ($report -match '4 states, 7 transitions') 'report counts states and transitions'

    $r = Invoke-Converter @{ Path = (Join-Path $samples 'state-machine\Main.xaml'); OutputPath = (Join-Path $work 'sm-details'); IncludeDetails = $true }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ($d.Text -match 'StartUpError Is Nothing') '-IncludeDetails adds transition conditions'

    # --- Flowchart ----------------------------------------------------------------------------------
    Write-Host "`nFlowchart sample"
    $r = Invoke-Converter @{ Path = (Join-Path $samples 'flowchart\Main.xaml'); OutputPath = (Join-Path $work 'fc') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $labels = Get-AllLabels $d.Doc
    Assert ($labels -contains 'Amount over limit?') 'draws the decision'
    Assert ($labels -contains 'Which region?') 'draws the switch'
    Assert ($labels -contains 'Read request details') 'draws a step by its display name'
    Assert ($labels -contains "Send to central team`n[RouteToQueue]") 'draws an unrecognised activity as a plain box with its type'
    $edgeLabels = Get-EdgeLabels $d.Doc
    foreach ($t in @('True', 'False', 'North', 'South', 'Default')) { Assert ($edgeLabels -contains $t) "labels branch '$t'" }
    Assert ($edgeLabels.Count -eq 11) "draws every link (found $($edgeLabels.Count), expected 11)"
    $decisionStyle = ''
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@value="Amount over limit?"]')) { $decisionStyle = $c.GetAttribute('style') }
    Assert ($decisionStyle -match '^rhombus') 'draws the decision as a diamond'
    Assert ($d.Text -notmatch 'amount &gt; 5000') 'leaves the decision condition out by default'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'RouteToQueue \(Demo\.Activities\) - 1, in Main\.xaml') 'report lists the activity from another package, with its package'
    Assert ($report -match '(?m)^  UiPath packages: \d+ uses? of \d+ activity types?') 'report counts UiPath activities'
    Assert ($report -match '(?m)^  Workflow Foundation \(part of \.NET\): \d+ uses? of \d+ activity types?') 'report counts Workflow Foundation activities'
    Assert ($report -notmatch 'not recognised') 'the report no longer calls UiPath''s own activities unrecognised'
    Assert ($report -match 'Approval\\AskManager.xaml - invoked from Main.xaml') 'report lists the missing invoked workflow'
    Assert ($report -match 'layout saved in Studio') 'uses the layout saved in Studio (older ViewState format)'

    # --- Project folder -----------------------------------------------------------------------------
    Write-Host "`nProject sample"
    $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'proj') }
    Assert ($r.DrawioFiles.Count -eq 1) 'writes one .drawio file for the project'
    Assert ((Split-Path -Leaf $r.DrawioFiles[0]) -eq 'OrderIntakeDemo.drawio') 'names the file after the project'
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $pages = @($d.Doc.SelectNodes('/mxfile/diagram') | ForEach-Object { $_.GetAttribute('name') })
    Assert ($pages.Count -eq 6) "has the project map plus 5 workflow pages (found $($pages.Count))"
    Assert ($pages[0] -eq 'Project map') 'puts the project map first'
    Assert ($pages[1] -eq 'Main.xaml') 'puts the main workflow straight after the map'
    $map = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $linked = @($map.SelectNodes('.//UserObject[@link]')).Count
    Assert ($linked -eq 5) "map links each workflow to its page (found $linked links)"
    $mapLabels = @()
    foreach ($c in $map.SelectNodes('.//mxCell[@value] | .//UserObject[@label]')) { $mapLabels += (Get-Label $c) }
    Assert ($mapLabels -contains "Steps\CheckOrder.xaml`n(missing)") 'map shows the missing workflow'
    Assert ($mapLabels -contains '(file name set at run time)') 'map shows the run-time file name without the expression'
    Assert ($d.Text -notmatch 'in_StepFolder') 'leaves the run-time expression out by default'
    $mapEdges = @($map.SelectNodes('.//mxCell[@edge="1"]')).Count
    Assert ($mapEdges -eq 7) "map draws one arrow per caller and callee pair (found $mapEdges)"
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'WarmUpCache \(Acme\.Robotics\.Activities\) - 1, in Framework\\Initialize\.xaml') 'report lists the activity from another package'
    Assert ($report -match 'ProcessOrders\.xaml \(sequence\): 3 activities not drawn; they are inside the activity drawn as a dashed box') 'report says how many activities a sequence page leaves inside boxes not expanded'
    Assert ($report -match 'ProcessOrders\.xaml - sequence: 2 steps drawn top to bottom; 1 activity holding others not expanded \(ForEach\)\. Activities drawn: 2 of 5\.') 'report describes the sequence page and counts what it draws'
    $tryProject = Join-Path $work 'try-top'
    [void](New-Item -ItemType Directory -Path $tryProject)
    [System.IO.File]::WriteAllText((Join-Path $tryProject 'Guarded.xaml'), ('<Activity x:Class="Guarded" xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:ui="http://schemas.uipath.com/workflow/activities" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' +
        '<TryCatch DisplayName="Guard"><TryCatch.Try><Sequence DisplayName="Work"><ui:InvokeWorkflowFile DisplayName="Do it" WorkflowFileName="DoIt.xaml" /></Sequence></TryCatch.Try></TryCatch></Activity>'), (New-Object System.Text.UTF8Encoding($false)))
    $r2 = Invoke-Converter @{ Path = (Join-Path $tryProject 'Guarded.xaml'); OutputPath = (Join-Path $work 'try-top-out') }
    $report2 = [System.IO.File]::ReadAllText($r2.ReportFile)
    Assert ($report2 -match 'Guarded\.xaml - trycatch: summary page only \(1 invoked workflow listed\)\. Activities drawn: 0 of 2\.') 'a top-level Try Catch still gets a summary page, and the report says nothing in it is drawn'
    Assert ($report2 -match 'Guarded\.xaml \(trycatch\): 2 activities not drawn; the page lists the workflows it invokes') 'report says how many activities a summary page does not draw'
    Assert ($report -match '(?m)^Version:  \d+\.\d+\.\d+\r?$') 'report says which version of the converter wrote it'
    Assert ($report -notmatch '(?m)^  Main\.xaml \(flowchart\):') 'a flowchart that draws all its activities gets no not-drawn line'
    Assert ($report -match 'Steps\\CheckOrder.xaml - invoked from ProcessOrders.xaml') 'report lists the missing workflow'
    Assert ($report -match 'laid out automatically') 'lays out a flowchart with no saved layout'
    Assert ($report -notmatch 'Framework\\ReadConfig.xaml - invoked') 'resolves a path written with forward slashes'

    $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'proj-details'); IncludeDetails = $true }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ($d.Text -match 'in_StepFolder') '-IncludeDetails shows the run-time expression'

    $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'proj-each'); OnePerFile = $true }
    Assert ($r.DrawioFiles.Count -eq 6) "-OnePerFile writes 5 workflow files and a map (found $($r.DrawioFiles.Count))"
    foreach ($f in $r.DrawioFiles) { [void](Test-DrawioStructure $f) }

    # --- Branch labels kept in the ViewState ----------------------------------------------------------
    Write-Host "`nBranch labels"
    $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'labels-sample') }
    $d = Read-Drawio $r.DrawioFiles[0]
    $mainPage = $null
    foreach ($dg in $d.Doc.SelectNodes('/mxfile/diagram')) { if ($dg.GetAttribute('name') -eq 'Main.xaml') { $mainPage = $dg } }
    $mainEdges = @()
    foreach ($c in $mainPage.SelectNodes('.//mxCell[@edge="1"]')) { $mainEdges += $c.GetAttribute('value') }
    Assert (($mainEdges -contains 'Yes') -and ($mainEdges -contains 'No')) 'labels the project sample''s decision Yes and No, as saved in its ViewState'
    Assert (($mainEdges -notcontains 'True') -and ($mainEdges -notcontains 'False')) 'does not fall back to True and False when labels are saved'
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'branch-labels.xaml'); OutputPath = (Join-Path $work 'labels') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $edgeLabels = Get-EdgeLabels $d.Doc
    Assert (($edgeLabels -contains 'Approve') -and ($edgeLabels -contains 'Reject')) 'reads labels from the ViewStateManager block at the end of the file'
    Assert ($edgeLabels -contains 'Rush') 'reads a label from a ViewState on the element itself'
    Assert ($edgeLabels -contains 'False') 'falls back to False when the saved label is only spaces'
    Assert ($edgeLabels -contains 'Anything else') 'labels a switch''s default branch with its saved name'
    Assert ($edgeLabels.Count -eq 7) "draws every branch once (found $($edgeLabels.Count), expected 7)"
    $flow = Test-DrawioStructure (Invoke-Converter @{ Path = (Join-Path $samples 'flowchart\Main.xaml'); OutputPath = (Join-Path $work 'labels-default') }).DrawioFiles[0]
    $flowLabels = Get-EdgeLabels $flow.Doc
    Assert (($flowLabels -contains 'True') -and ($flowLabels -contains 'Default')) 'keeps True and Default when nothing else is saved'

    # --- Arrows in the automatic layout -----------------------------------------------------------------
    Write-Host "`nArrow routing"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'arrow-routing.xaml'); OutputPath = (Join-Path $work 'arrows') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $edgeLabels = Get-EdgeLabels $d.Doc
    Assert ($edgeLabels.Count -eq 12) "draws every link, including parallel ones, a loop back and a self-loop (found $($edgeLabels.Count), expected 12)"
    Assert-CleanArrows $r.DrawioFiles[0] 'flowchart with parallel, skipping, looping and self links'
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'parallel-transitions.xaml'); OutputPath = (Join-Path $work 'arrows-sm') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $edgeLabels = Get-EdgeLabels $d.Doc
    foreach ($t in @('Form received', 'Email received', 'Call logged', 'Chat closed', 'Letter scanned', 'Retry', 'Wait a day', 'Checked', 'Next batch')) { Assert ($edgeLabels -contains $t) "draws transition '$t'" }
    Assert-CleanArrows $r.DrawioFiles[0] 'state machine with five parallel transitions and two self-transitions'
    $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'arrows-proj') }
    Assert-CleanArrows $r.DrawioFiles[0] 'project sample (map and the automatically laid out Main page)' @('Project map', 'Main.xaml')
    # Sequence pages in a project have the "Back to project map" link in their header as well.
    $seqProblems = @()
    $seqPages = 0
    foreach ($dg in (Read-Drawio $r.DrawioFiles[0]).Doc.SelectNodes('/mxfile/diagram')) {
        if ($dg.OuterXml -notmatch '\(sequence\)" style="text;fontSize=16;') { continue }
        $seqPages++
        foreach ($p in (Get-FrameProblems $dg)) { $seqProblems += ($dg.GetAttribute('name') + ': ' + $p) }
    }
    Assert ($seqPages -eq 4 -and $seqProblems.Count -eq 0) ("project sample: $seqPages sequence pages, every shape inside its frame, arrows straight down" + $(if ($seqProblems.Count) { ' -- ' + ($seqProblems -join '; ') } else { '' }))

    # A made-up large project, written here: Main invokes 14 steps; three steps invoke shared
    # workflows; a chain runs three levels deep and Main also invokes its last level directly; three
    # workflows are invoked by nothing and invoke nothing. Laid out in one row per level, its map
    # would be about 3,000 pixels wide.
    $wide = Join-Path $work 'wide-project'
    foreach ($sub in @('Steps', 'Shared', 'Deep', 'Tools')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $wide $sub)) }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $calls = [ordered]@{ 'Main.xaml' = @('Deep\LevelThree.xaml') }
    for ($i = 1; $i -le 14; $i++) { $calls['Main.xaml'] += ('Steps\ProcessStep{0:00}.xaml' -f $i) }
    for ($i = 1; $i -le 14; $i++) { $calls[('Steps\ProcessStep{0:00}.xaml' -f $i)] = @() }
    $calls['Steps\ProcessStep01.xaml'] = @('Shared\WriteAuditEntry.xaml', 'Deep\LevelTwo.xaml')
    $calls['Steps\ProcessStep02.xaml'] = @('Shared\WriteAuditEntry.xaml', 'Shared\SendSummaryMail.xaml')
    $calls['Steps\ProcessStep03.xaml'] = @('Shared\SendSummaryMail.xaml')
    $calls['Shared\WriteAuditEntry.xaml'] = @()
    $calls['Shared\SendSummaryMail.xaml'] = @()
    $calls['Deep\LevelTwo.xaml'] = @('Deep\LevelThree.xaml')
    $calls['Deep\LevelThree.xaml'] = @()
    foreach ($t in @('Tools\ResetTestData.xaml', 'Tools\ExportSettings.xaml', 'Tools\CheckEnvironment.xaml')) { $calls[$t] = @() }
    foreach ($file in $calls.Keys) {
        $body = ''
        foreach ($callee in $calls[$file]) { $body += '    <ui:InvokeWorkflowFile DisplayName="Run ' + $callee + '" WorkflowFileName="' + $callee + '" />' + "`n" }
        $xaml = '<Activity x:Class="Demo" xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:ui="http://schemas.uipath.com/workflow/activities" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' + "`n" +
            '  <Sequence DisplayName="Demo">' + "`n" + $body + '  </Sequence>' + "`n" + '</Activity>' + "`n"
        [System.IO.File]::WriteAllText((Join-Path $wide $file), $xaml, $utf8)
    }
    [System.IO.File]::WriteAllText((Join-Path $wide 'project.json'), '{ "name": "WideDemo", "main": "Main.xaml" }', $utf8)
    $pairs = 0
    foreach ($file in $calls.Keys) { $pairs += @($calls[$file]).Count }

    $r = Invoke-Converter @{ Path = $wide; OutputPath = (Join-Path $work 'wide-out') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $map = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $boxes = @{}
    foreach ($c in $map.SelectNodes('mxGraphModel/root/*')) {
        $info = Get-CellInfo $c
        if (-not $info.Vertex -or $info.Style -like 'text;*') { continue }
        $g = $info.Inner.SelectSingleNode('mxGeometry')
        $boxes[([string]$info.Label -split "`n")[0]] = @{ X = [double]::Parse($g.GetAttribute('x'), $inv); Y = [double]::Parse($g.GetAttribute('y'), $inv); W = [double]::Parse($g.GetAttribute('width'), $inv) }
    }
    Assert ($boxes.Count -eq $calls.Count) "large project map draws every workflow once (found $($boxes.Count) of $($calls.Count))"
    $arrows = @($map.SelectNodes('.//mxCell[@edge="1"]'))
    Assert ($arrows.Count -eq $pairs) "large project map draws one arrow per caller and callee pair (found $($arrows.Count) of $pairs)"
    $minX = [double]::MaxValue; $maxX = [double]::MinValue
    foreach ($b in $boxes.Values) { $minX = [Math]::Min($minX, $b.X); $maxX = [Math]::Max($maxX, $b.X + $b.W) }
    $outside = 0
    foreach ($a in $arrows) {
        foreach ($p in $a.SelectNodes('mxGeometry/Array/mxPoint')) {
            $px = [double]::Parse($p.GetAttribute('x'), $inv)
            if ($px -lt $minX - 1 -or $px -gt $maxX + 1) { $outside++ }
        }
    }
    Assert (($maxX - $minX) -le 1800) ("large project map wraps wide rows: {0:0} pixels wide" -f ($maxX - $minX))
    Assert ($outside -eq 0) "large project map: arrows that pass rows drop between boxes, not round the side ($outside points outside)"
    $lowestLinked = 0.0
    foreach ($k in $boxes.Keys) { if ($k -notlike 'Tools\*' -and $boxes[$k].Y -gt $lowestLinked) { $lowestLinked = $boxes[$k].Y } }
    $toolsBelow = @($boxes.Keys | Where-Object { $_ -like 'Tools\*' -and $boxes[$_].Y -gt $lowestLinked }).Count
    Assert ($toolsBelow -eq 3) "large project map puts workflows with no arrows below the rest ($toolsBelow of 3)"
    Assert-CleanArrows $r.DrawioFiles[0] 'large project map' @('Project map')
    $again = Invoke-Converter @{ Path = $wide; OutputPath = (Join-Path $work 'wide-out-2') }
    Assert ([System.IO.File]::ReadAllText($again.DrawioFiles[0]) -ceq $d.Text) 'large project map comes out the same every time'

    # Studio layout with crowded labels: arrows and boxes stay as saved; only labels move.
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'crowded-labels.xaml'); OutputPath = (Join-Path $work 'crowded') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ([System.IO.File]::ReadAllText($r.ReportFile) -match 'layout saved in Studio') 'crowded-labels fixture uses the layout saved in Studio'
    $styleOf = @{}
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@vertex="1"]')) { $styleOf[$c.GetAttribute('value')] = $c.GetAttribute('style') }
    Assert ($styleOf['Ready?'] -match 'labelPosition=center;verticalLabelPosition=bottom') 'decision text stays below the diamond when no arrow meets its bottom point'
    Assert ($styleOf['Checked?'] -match 'labelPosition=right;verticalLabelPosition=bottom') 'decision text moves to the lower right when an arrow meets the bottom point'
    $labelProblems = @(Get-ArrowProblems $d.Doc.SelectNodes('/mxfile/diagram')[0] | Where-Object { $_ -like 'label*' })
    Assert ($labelProblems.Count -eq 0) ('labels on side-by-side Studio routes are moved apart' + $(if ($labelProblems.Count) { ' -- ' + ($labelProblems -join '; ') } else { '' }))
    $moved = @()
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@edge="1"]')) { if ($c.SelectSingleNode('mxGeometry').GetAttribute('x')) { $moved += $c.GetAttribute('value') } }
    Assert (($moved -notcontains 'True') -and ($moved -notcontains 'False')) 'labels already in a clear place stay halfway along their arrows'
    Assert ($moved.Count -eq 1) "only the crowded label is moved (moved: $($moved -join ', '))"

    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'junk-layout.xaml'); OutputPath = (Join-Path $work 'arrows-junk') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ($d.Text -notmatch 'NaN|Infinity|E\+') 'keeps NaN, infinity and huge numbers from a damaged layout out of the diagram'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'laid out automatically') 'falls back to automatic layout when saved positions are junk'
    Assert ((Get-EdgeLabels $d.Doc).Count -eq 3) 'still draws the start arrow and both transitions'
    foreach ($f in @('branch-labels.xaml', 'switch-case-forms.xaml', 'broken-links.xaml', 'junk-layout.xaml')) {
        $r = Invoke-Converter @{ Path = (Join-Path $fixtures $f); OutputPath = (Join-Path $work ('arrows-' + $f)) }
        Assert-CleanArrows $r.DrawioFiles[0] $f
    }

    # --- Activity properties named like XML properties; expressions with layout IDs ----------------------
    Write-Host "`nProperty names and expressions"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'property-names.xaml'); OutputPath = (Join-Path $work 'property-names') }
    Assert ($r.DrawioFiles.Count -eq 1) 'converts an activity with properties named Attributes, ChildNodes, ParentNode, InnerText and so on (this crashed on a real project)'
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $labels = Get-AllLabels $d.Doc
    Assert ($labels -contains "Read nodes`n[ReadNodes]") 'still draws that activity, as an unrecognised step with its type'
    Assert ($labels -contains 'Set values') 'draws the step that holds the sequence'
    $checkStyle = ''
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@value="Check the page is open"]')) { $checkStyle = $c.GetAttribute('style') }
    Assert ($checkStyle -and $checkStyle -notmatch 'dashed=1') 'draws a UiPath activity step as an ordinary step, not as an unknown one'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    $sourceSection = [regex]::Match($report, '(?ms)^Activities by source.*?(?=\r?\n\r?\n)').Value
    Assert ($sourceSection -match 'ReadNodes \(Demo\.Activities\) - 1, in property-names\.xaml') 'lists the made-up activity under other packages'
    Assert ($sourceSection -match 'MultipleAssign \(1\)') 'lists Multiple Assign as a UiPath activity'
    Assert ($sourceSection -notmatch 'CSharpValue|CSharpReference|AssignOperation|VisualBasic') 'does not count expressions or Multiple Assign items as activities'

    # --- Switch cases in every written form -----------------------------------------------------------
    Write-Host "`nSwitch case forms"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'switch-case-forms.xaml'); OutputPath = (Join-Path $work 'switch') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $edgeLabels = Get-EdgeLabels $d.Doc
    foreach ($t in @('apple', 'banana', 'cherry', 'damson', 'elder', 'Default')) { Assert ($edgeLabels -contains $t) "draws switch branch '$t'" }
    Assert ($edgeLabels.Count -eq 7) "draws the start arrow and all 6 branches, none twice (found $($edgeLabels.Count))"
    $crateC = ''
    foreach ($c in $d.Doc.SelectNodes('//mxCell[@value="Crate C"]')) { $crateC = $c.GetAttribute('id') }
    $intoCrateC = @($d.Doc.SelectNodes('//mxCell[@edge="1"]') | Where-Object { $_.GetAttribute('target') -eq $crateC }).Count
    Assert ($crateC -and $intoCrateC -eq 3) "three cases share one target step (found $intoCrateC arrows into it)"
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Warnings \(0\)') 'gives no warnings for a well-formed switch'

    # --- Links that lead nowhere ----------------------------------------------------------------------
    Write-Host "`nBroken links"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'broken-links.xaml'); OutputPath = (Join-Path $work 'broken') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ((Get-EdgeLabels $d.Doc).Count -eq 3) 'still draws the three good links'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Warnings \(4\)') 'gives one warning per broken link, and none for a link written as x:Null'
    foreach ($ghost in @('GhostNext', 'GhostTrue', 'GhostCase', 'GhostDefault')) { Assert ($report -match ('points at "' + $ghost + '", which does not exist')) "warns about the link to $ghost" }
    Assert ($r.Warnings.Count -eq 4) 'returns the warnings with -PassThru'

    # --- Invoked file names -----------------------------------------------------------------------------
    Write-Host "`nInvoked file names"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'invoke-paths'); OutputPath = (Join-Path $work 'invoke') }
    Assert ($r.DrawioFiles.Count -eq 1) 'converts a project whose invoked file names contain | < > (this crashed Windows PowerShell 5.1)'
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $map = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $mapLabels = @()
    foreach ($c in $map.SelectNodes('.//mxCell[@value] | .//UserObject[@label]')) { $mapLabels += (Get-Label $c) }
    Assert (@($mapLabels | Where-Object { $_ -like 'Sub\Helper.xaml*' }).Count -eq 1) 'treats Sub\..\Sub\Helper.xaml, Sub\\Helper.xaml and .\.\Sub/Helper.xaml as the one file they are'
    Assert ($mapLabels -contains 'x4') 'draws one arrow for the four invokes of that file'
    Assert ($mapLabels -contains "Reports|2024.xaml`n(missing)") 'marks a name Windows rejects as missing'
    Assert ($mapLabels -contains "Remote.xaml`n(outside the project)") 'marks a network path as outside the project'
    Assert ($mapLabels -contains "Other.xaml`n(outside the project)") 'marks a path on another drive as outside the project'
    Assert ($mapLabels -contains "broken-links.xaml`n(outside the project)") 'does not look up a ..\ path, even though that file exists'
    Assert (@($mapLabels | Where-Object { $_ -like '*(not converted)*' }).Count -eq 0) 'never reports whether a file outside the project exists'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Invoked files outside the project folder \(3\)') 'report lists the three outside paths'
    Assert ($report -match 'Invoked workflows not found \(2\)') 'report lists only the two in-project names as missing'
    Assert (($d.Text + $report) -notmatch 'server\.invalid|Elsewhere') 'leaves server and folder names of outside paths out by default'
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'invoke-paths'); OutputPath = (Join-Path $work 'invoke-details'); IncludeDetails = $true }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ($d.Text -match 'server\.invalid') '-IncludeDetails shows the full outside path'

    # --- Output names -------------------------------------------------------------------------------------
    Write-Host "`nOutput names"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'name-clash'); OutputPath = (Join-Path $work 'clash'); OnePerFile = $true }
    $distinct = @($r.DrawioFiles | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    Assert ($r.DrawioFiles.Count -eq 5 -and $distinct.Count -eq 5) "-OnePerFile gives 4 clashing workflows and the map 5 different files (found $($distinct.Count))"
    $pageNames = @()
    foreach ($f in $r.DrawioFiles) {
        $d = Test-DrawioStructure $f
        foreach ($dg in $d.Doc.SelectNodes('/mxfile/diagram')) { $pageNames += $dg.GetAttribute('name') }
    }
    foreach ($p in @('A_B.xaml', 'A_B_2.xaml', 'A\B.xaml', 'Clash - project map.xaml', 'Project map')) {
        Assert (@($pageNames | Where-Object { $_ -eq $p }).Count -eq 1) "'$p' has a file of its own"
    }
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'name-clash\A\B.xaml'); OutputPath = (Join-Path $work 'clash-single') }
    Assert ((Split-Path -Leaf $r.DrawioFiles[0]) -eq 'B.drawio') 'a single file in a project subfolder is named after the file'
    Assert ((Split-Path -Leaf $r.ReportFile) -eq 'B.conversion-report.txt') 'and its report has the matching name'

    # --- Awkward input ------------------------------------------------------------------------------
    Write-Host "`nAwkward input"
    $odd = Join-Path $work 'odd-project'
    [void](New-Item -ItemType Directory -Path (Join-Path $odd '.local'))
    Copy-Item (Join-Path $samples 'flowchart\Main.xaml') (Join-Path $odd 'Main.xaml')
    Copy-Item (Join-Path $samples 'flowchart\Main.xaml') (Join-Path $odd '.local\Hidden.xaml')
    [System.IO.File]::WriteAllText((Join-Path $odd 'Broken.xaml'), "<Activity>`n  <Sequence DisplayName=`"SecretMarker`">", (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Converter @{ Path = $odd; OutputPath = (Join-Path $work 'odd-out') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $pages = @($d.Doc.SelectNodes('/mxfile/diagram') | ForEach-Object { $_.GetAttribute('name') })
    Assert ($pages -notcontains '.local\Hidden.xaml') 'skips Studio folders whose names start with a dot'
    Assert ($pages -contains 'Broken.xaml') 'still gives an unreadable file a page'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Files that could not be read \(1\)') 'report lists the unreadable file'
    Assert ($report -match 'Broken\.xaml: not well-formed XML \(line \d+, position \d+\)') 'says where the file is broken'
    Assert ($report -cnotmatch 'Sequence|SecretMarker') 'does not quote the broken file''s content'

    # The report gets shared, so it names files but never gives full paths (they name the user and folders).
    $everyReport = @(Get-ChildItem -LiteralPath $work -Recurse -Filter '*.conversion-report.txt')
    $localRoots = @($work, $repo, $env:USERPROFILE, [System.IO.Path]::GetTempPath().TrimEnd('\')) | Where-Object { $_ }
    $withPaths = @($everyReport | Where-Object { $text = [System.IO.File]::ReadAllText($_.FullName); @($localRoots | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 })
    Assert ($everyReport.Count -gt 5 -and $withPaths.Count -eq 0) "no report contains a full local path (checked $($everyReport.Count) reports$(if ($withPaths.Count) { '; found in ' + (($withPaths | ForEach-Object { $_.Name }) -join ', ') }))"
    Assert ($report -match '(?m)^Input:    odd-project\r?$') 'the report names the input folder'
    Assert ($report -match '(?m)^Output:   odd-project\.drawio\r?$') 'the report names the output file'

    $help = Get-Help $converter -Full
    Assert ($help.Synopsis -like 'Converts UiPath workflow files*') 'Get-Help shows the synopsis'
    $documented = @($help.parameters.parameter | Where-Object { $_.description })
    Assert ($documented.Count -eq 5) "Get-Help documents all five parameters (found $($documented.Count))"

    $single = Join-Path $work 'single'
    [void](New-Item -ItemType Directory -Path $single)
    Copy-Item (Join-Path $samples 'flowchart\Main.xaml') (Join-Path $single 'Main.xaml')
    $r = Invoke-Converter @{ Path = (Join-Path $single 'Main.xaml') }
    Assert ($r.DrawioFiles[0] -eq (Join-Path $single 'Main.drawio')) 'writes next to the input by default'

    # --- Robustness: unreadable folders, links, backups, files that are not workflows ------------------
    Write-Host "`nRobustness"
    $tough = Join-Path $work 'tough-project'
    foreach ($dir in @('Ok', 'Locked', 'Linked-target')) { [void](New-Item -ItemType Directory -Path (Join-Path $tough $dir)) }
    $cleanup = Join-Path $samples 'project\Framework\Cleanup.xaml'
    Copy-Item $cleanup (Join-Path $tough 'Main.xaml')
    Copy-Item $cleanup (Join-Path $tough 'Ok\Fine.xaml')
    Copy-Item $cleanup (Join-Path $tough 'Locked\Secret.xaml')
    Copy-Item $cleanup (Join-Path $tough '~Main.xaml')                 # a Studio backup of unsaved changes
    Copy-Item $cleanup (Join-Path $tough 'Linked-target\Twice.xaml')
    [void](New-Item -ItemType Junction -Path (Join-Path $tough 'Ok\Link') -Target (Join-Path $tough 'Linked-target'))
    [System.IO.File]::WriteAllText((Join-Path $tough 'Page.xaml'), '<html><head><title>Not a workflow</title></head></html>', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $tough 'Bare.xaml'), '<StateMachine xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" DisplayName="Bare"><State DisplayName="Only" /></StateMachine>', (New-Object System.Text.UTF8Encoding($false)))
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $locked = Join-Path $tough 'Locked'
    [void](& icacls $locked /deny "${me}:(OI)(CI)(RD,RX)")
    try {
        $r = Invoke-Converter @{ Path = $tough; OutputPath = (Join-Path $work 'tough-out') }
    }
    finally {
        [void](& icacls $locked /remove:d $me /T /C)
    }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $pages = @($d.Doc.SelectNodes('/mxfile/diagram') | ForEach-Object { $_.GetAttribute('name') })
    Assert ($pages -contains 'Ok\Fine.xaml') 'converts the rest of a project when one subfolder cannot be read'
    Assert ($pages -notcontains 'Locked\Secret.xaml') 'skips the folder it cannot read'
    Assert ($r.SkippedFolders -contains 'Locked') 'reports the folder it could not read'
    Assert ($pages -notcontains '~Main.xaml') 'skips Studio''s ~ backup files'
    Assert (@($pages | Where-Object { $_ -like '*Twice.xaml' }).Count -eq 1) 'does not follow a link to another folder (the linked file appears once, not twice)'
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Locked: access denied') 'report says why the folder was skipped'
    Assert ($report -match 'Ok\\Link: a link to another folder, not followed') 'report lists the link it did not follow'
    Assert ($report -match 'Page\.xaml: top element is <html>, not <Activity>') 'report says a file is not a workflow'
    Assert ($report -match 'Bare\.xaml \[?\w*\]? ?- state machine') 'draws a file whose top element is itself a state machine'
    Assert ($report -notmatch '\bActivity \(\d') 'never counts the file''s <Activity> wrapper as an activity'

    # --- Writing: re-runs, read-only files, odd names ------------------------------------------------
    $again = Join-Path $work 'rerun'
    $first = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = $again; OnePerFile = $true }
    $second = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = $again; OnePerFile = $true }
    Assert ($second.DrawioFiles.Count -eq 6 -and $second.WriteErrors.Count -eq 0) 'a second run into the same folder overwrites the earlier files'
    Assert (@(Get-ChildItem -LiteralPath $again -Filter '*.tmp' -Force).Count -eq 0) 'leaves no temporary files behind'
    $readOnly = Join-Path $again 'Main.drawio'
    [System.IO.File]::WriteAllText($readOnly, 'kept')
    (Get-Item -LiteralPath $readOnly).IsReadOnly = $true
    try {
        $r = Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = $again; OnePerFile = $true }
        $code = $LASTEXITCODE
    }
    finally {
        (Get-Item -LiteralPath $readOnly).IsReadOnly = $false
    }
    Assert ($code -eq 1) 'ends with exit code 1 when a file cannot be written'
    Assert ($r.WriteErrors -contains 'Main.drawio' -and $r.DrawioFiles.Count -eq 5) 'still writes the other files when one is read-only'
    Assert ([System.IO.File]::ReadAllText($readOnly) -eq 'kept') 'leaves the read-only file exactly as it was'
    Assert ([System.IO.File]::ReadAllText($r.ReportFile) -match 'Main\.drawio: access denied') 'report says which file could not be written, and why'
    Assert (@(Get-ChildItem -LiteralPath $again -Filter '*.tmp' -Force).Count -eq 0) 'leaves no temporary files behind after a failure'

    $odd = Join-Path $work ('odd-name-project')
    [void](New-Item -ItemType Directory -Path $odd)
    Copy-Item $cleanup (Join-Path $odd 'Main.xaml')
    [System.IO.File]::WriteAllText((Join-Path $odd 'project.json'), ('{ "name": "Bell' + [char]7 + 'Name ' + ('x' * 200) + '" }'), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Converter @{ Path = $odd; OutputPath = (Join-Path $work 'odd-name-out') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    Assert ((Split-Path -Leaf $r.DrawioFiles[0]).Length -le 90) 'keeps output file names short, however long the project name'

    # --- Sequences ----------------------------------------------------------------------------------
    Write-Host "`nSequences"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'sequences.xaml'); OutputPath = (Join-Path $work 'seq') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $page = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $frameProblems = Get-FrameProblems $page
    Assert ($frameProblems.Count -eq 0) ('sequence page: every shape inside its frame, none overlapping, arrows straight down' + $(if ($frameProblems.Count) { ' -- ' + ($frameProblems -join '; ') } else { '' }))
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'sequences\.xaml - sequence: ') 'a top-level sequence gets a sequence page, not a summary'
    Assert ($report -match 'Activities drawn: 24 of 31\.') 'report counts the activities drawn (24 of 31)'
    Assert ($report -match 'sequences\.xaml \(sequence\): 7 activities not drawn') 'report says how many activities are inside boxes not expanded (7)'
    $cells = @{}
    $byId = @{}
    foreach ($c in $page.SelectNodes('mxGraphModel/root/*')) {
        $info = Get-CellInfo $c
        if ($info.Id -eq '0' -or $info.Id -eq '1') { continue }
        $byId[$info.Id] = $info
        if ($info.Vertex) { $cells[([string]$info.Label -split "`n")[0]] = $info }
    }
    function Get-InsideOrder($FrameLabel) {
        # The first label line of each shape directly inside a frame, top to bottom. A branch block
        # (an invisible container) is named after its decision.
        $frameId = $cells[$FrameLabel].Id
        return @($byId.Values | Where-Object { $_.Vertex -and $_.Parent -eq $frameId } |
            Sort-Object { [double]::Parse($_.Inner.SelectSingleNode('mxGeometry').GetAttribute('y'), [System.Globalization.CultureInfo]::InvariantCulture) } |
            ForEach-Object {
                $l = ([string]$_.Label -split "`n")[0]
                if ($_.Style -like 'rounded=0;fillColor=none;strokeColor=none;container=1;*') {
                    $blockId = $_.Id
                    $l = @($byId.Values | Where-Object { $_.Parent -eq $blockId -and $_.Style -like 'rhombus;*' } | ForEach-Object { ([string]$_.Label -split "`n")[0] })[0]
                }
                $l
            })
    }
    $order = Get-InsideOrder 'Handle a request'
    $expectedOrder = @('Set the start time', 'Log the start', 'Prepare', 'Is it urgent?', 'Try to send', 'Old step', 'Send to the queue', 'Run as a batch', 'Level 2', 'Delay')
    Assert (($order -join '|') -eq ($expectedOrder -join '|')) "activities are drawn in the order written (found: $($order -join ', '))"
    Assert (((Get-InsideOrder 'Prepare') -join '|') -eq 'Load the settings|Empty part') 'a nested sequence is a frame holding its own activities in order'
    $arrows = @($page.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]'))
    Assert ($arrows.Count -eq 15) "one arrow from each activity to the next, and four for the If's two branches (found $($arrows.Count), expected 15)"
    Assert ($cells['Load the settings'].Label -match 'Setup\\LoadSettings\.xaml \(missing\)' -and $cells['Load the settings'].Style -match 'dashed=1') 'an invoke step names its workflow and marks it missing'
    Assert ($cells['Empty part'].Label -match '\(empty sequence\)') 'an empty sequence is drawn and says it is empty'
    $rowsOf = {
        param($Label)
        $id = $cells[$Label].Id
        @($byId.Values | Where-Object { $_.Parent -eq $id -and $_.Vertex } | ForEach-Object { [string]$_.Label })
    }
    Assert ($cells['Is it urgent?'].Style -match '^rhombus') 'an If is drawn as a decision'
    Assert ((((Get-InsideOrder 'Escalation') -join '|') -eq 'Escalate|Mark as escalated') -and $cells['Escalate'].Label -match 'Escalate\.xaml \(missing\)') 'its Then branch is drawn, with the workflow invoked inside it'
    Assert ($cells['Try to send'].Style -like 'swimlane;rounded=0;startSize=26;fontStyle=1;fillColor=#fbe9dc;*') 'a Try Catch is drawn as a frame with its regions'
    $oldRows = & $rowsOf 'Old step'
    Assert ($oldRows -contains '3 activities commented out (not run)') 'a Comment Out says its activities do not run'
    Assert ($oldRows -contains 'OldCleanup.xaml (missing) (commented out)') 'a workflow invoked inside a Comment Out is listed as commented out'
    Assert ($cells['Send to the queue'].Label -eq "Send to the queue`n[RouteToQueue]" -and $cells['Send to the queue'].Style -match 'dashed=1') 'an activity from another package is a dashed box showing its type'
    Assert ((& $rowsOf 'Run as a batch') -contains '[BatchScope] from another package: 2 activities inside, not drawn') 'a container from another package is not expanded, and says where it comes from'
    $frames = @($byId.Values | Where-Object { $_.Vertex -and $_.Style -match '^swimlane;rounded=0;startSize=26;fontStyle=1;fillColor=#eef3f8;' }).Count
    Assert ($frames -eq 11) "sequences up to the depth limit are frames (found $frames, expected 11: the top level, Prepare, Escalation, Send and Levels 2 to 8)"
    Assert ((& $rowsOf 'Level 9') -contains 'Nested too deep to draw: 2 activities inside') 'a sequence past the depth limit is collapsed and says how much it holds'
    Assert ($cells.ContainsKey('Delay') -and -not $cells.ContainsKey('Deepest step')) 'an activity with no display name is still drawn; activities inside collapsed boxes are not'
    Assert ($d.Text -notmatch '\[urgent\]') 'leaves the If condition out by default'
    $again = Invoke-Converter @{ Path = (Join-Path $fixtures 'sequences.xaml'); OutputPath = (Join-Path $work 'seq-again') }
    Assert ([System.IO.File]::ReadAllText($again.DrawioFiles[0]) -ceq $d.Text) 'a sequence page comes out the same every time'

    # --- Branching inside sequences: If, Else If, Switch -------------------------------------------
    Write-Host "`nBranching"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'branches.xaml'); OutputPath = (Join-Path $work 'branches') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $page = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $frameProblems = Get-FrameProblems $page
    Assert ($frameProblems.Count -eq 0) ('branches: every shape inside its container, no arrow through a shape, no label over a shape or label' + $(if ($frameProblems.Count) { ' -- ' + ($frameProblems -join '; ') } else { '' }))
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Activities drawn: 41 of 44\.') 'report counts the activities drawn (41 of 44)'
    Assert ($report -match '16 decisions drawn with their branches \(If x12, IfElseIf x2, Switch x2\)') 'report counts the decisions drawn, by type'
    Assert ($report -match 'branches\.xaml \(sequence\): 3 activities not drawn') 'report says how many activities are inside boxes not expanded (3)'
    $info = @{}
    foreach ($c in $page.SelectNodes('mxGraphModel/root/*')) { $ci = Get-CellInfo $c; $info[$ci.Id] = $ci }
    function Get-ShapeName($Id) {
        # How a branch's target reads: the meeting dot, the next decision, or the first line of its label.
        $t = $info[$Id]
        if ($t.Style -like 'ellipse;fillColor=#666666;*') { return 'join' }
        if ($t.Style -like 'rounded=0;fillColor=none;strokeColor=none;container=1;*') {
            $diamond = @($info.Values | Where-Object { $_.Parent -eq $Id -and $_.Style -like 'rhombus;*' })[0]
            return 'decision ' + ([string]$diamond.Label -split "`n")[0]
        }
        return ([string]$t.Label -split "`n")[0]
    }
    function Get-Branches($Decision) {
        # "label>target" for each branch of a decision, in the order the file gives them.
        $id = @($info.Values | Where-Object { $_.Style -like 'rhombus;*' -and ([string]$_.Label -split "`n")[0] -eq $Decision })[0].Id
        return (@($page.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]') | Where-Object { $_.GetAttribute('source') -eq $id } |
            ForEach-Object { $_.GetAttribute('value') + '>' + (Get-ShapeName $_.GetAttribute('target')) }) -join ', ')
    }
    Assert ((Get-Branches 'Is the order valid?') -eq 'Then>Accept, Else>Reject the order') 'an If has a Then and an Else branch, each drawn'
    Assert ((Get-Branches 'Is it large?') -eq 'Then>Ask for approval, Else>join') 'an If nested in a branch is drawn; its missing Else goes straight on'
    Assert (@($info.Values | Where-Object { ([string]$_.Label) -match '^Ask for approval\nApproval\\Ask\.xaml \(missing\)$' }).Count -eq 1) 'an invoke inside a branch names its workflow'
    Assert ((Get-Branches 'Has a discount?') -eq 'Then>join, Else>Charge full price') 'an If with no Then: its Then branch goes straight on'
    Assert ((Get-Branches 'Nothing to do?') -eq 'Then>join, Else>join') 'an If with neither branch: both go straight on'
    Assert ((Get-Branches 'Which region?') -eq 'North>Use the north team, South>South handling, West>join, East>Use the east team, Default>Unknown region') 'a Switch has one branch per case in the order written, then Default; an empty case goes straight on'
    Assert ((Get-Branches 'How many items?') -eq '1>One item, 2>Two items, Default>join') 'a Switch with no Default: its Default branch goes straight on'
    Assert ((Get-Branches 'Choose the shipping') -eq 'Then>Ship by air, Else>decision Else If') 'an Else If starts with its first condition; Else leads to the next'
    $elseIfs = @($info.Values | Where-Object { $_.Style -like 'rhombus;*' -and $_.Label -eq 'Else If' })
    $chain = @($elseIfs | ForEach-Object {
            $eid = $_.Id
            (@($page.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]') | Where-Object { $_.GetAttribute('source') -eq $eid } | ForEach-Object { $_.GetAttribute('value') + '>' + (Get-ShapeName $_.GetAttribute('target')) }) -join ', ')
        } | Sort-Object)
    Assert (($chain -join ' / ') -eq 'Then>join, Else>decision Else If / Then>Ship by sea, Else>Ship by road') "each later condition is its own decision; an empty one goes straight on, and the last Else holds the Else block (found: $($chain -join ' / '))"
    Assert ((Get-Branches 'Choose a carrier') -eq 'Then>Use carrier A, Else>join') 'an Else If with no Else block: its last Else goes straight on'
    Assert ((Get-Branches 'Level 7?') -eq 'Then>Level 8?, Else>join') 'decisions are drawn down to the depth limit'
    Assert ((@($info.Values | Where-Object { [string]$_.Label -eq 'Nested too deep to draw: 3 activities inside' })).Count -eq 1 -and -not ($info.Values | Where-Object { $_.Label -like 'Level 9?*' })) 'past the depth limit an If is one box saying how much it holds'
    Assert ((Get-Branches 'Retry needed?') -eq 'Then>Try again, Else>No retry') 'a Try Catch can sit in a branch'
    Assert ($d.Text -notmatch 'order\.IsValid|order\.Region|order\.Weight') 'leaves conditions and switch expressions out by default'
    $joins = @($info.Values | Where-Object { $_.Style -like 'ellipse;fillColor=#666666;*' }).Count
    Assert ($joins -eq 18) "every decision's branches meet again at one dot (found $joins, expected 18: one for each decision, including both Else If links)"
    $rd = Invoke-Converter @{ Path = (Join-Path $fixtures 'branches.xaml'); OutputPath = (Join-Path $work 'branches-details'); IncludeDetails = $true }
    $dd = Read-Drawio $rd.DrawioFiles[0]
    Assert ($dd.Text -match 'Is the order valid\?&#xA;\[order\.IsValid\]' -and $dd.Text -match 'Which region\?&#xA;\[order\.Region\]' -and $dd.Text -match 'Else If&#xA;\[order\.IsCoastal\]') '-IncludeDetails adds conditions and switch expressions as text, without evaluating them'
    Assert ((Get-FrameProblems $dd.Doc.SelectNodes('/mxfile/diagram')[0]).Count -eq 0) '-IncludeDetails: the larger decisions still fit without overlaps'
    $again = Invoke-Converter @{ Path = (Join-Path $fixtures 'branches.xaml'); OutputPath = (Join-Path $work 'branches-again') }
    Assert ([System.IO.File]::ReadAllText($again.DrawioFiles[0]) -ceq $d.Text) 'a page with branches comes out the same every time'

    # --- Try Catch inside sequences ----------------------------------------------------------------
    Write-Host "`nTry Catch"
    $r = Invoke-Converter @{ Path = (Join-Path $fixtures 'try-catch.xaml'); OutputPath = (Join-Path $work 'try-catch') }
    $d = Test-DrawioStructure $r.DrawioFiles[0]
    $page = $d.Doc.SelectNodes('/mxfile/diagram')[0]
    $frameProblems = Get-FrameProblems $page
    Assert ($frameProblems.Count -eq 0) ('try-catch: every shape inside its container, no overlaps' + $(if ($frameProblems.Count) { ' -- ' + ($frameProblems -join '; ') } else { '' }))
    $report = [System.IO.File]::ReadAllText($r.ReportFile)
    Assert ($report -match 'Activities drawn: 34 of 36\.') 'report counts the activities drawn (34 of 36)'
    Assert ($report -match '13 Try Catches drawn with Try, Catch and Finally regions') 'report counts the Try Catches drawn (13)'
    $info = @{}
    foreach ($c in $page.SelectNodes('mxGraphModel/root/*')) { $ci = Get-CellInfo $c; $info[$ci.Id] = $ci }
    function Get-Regions($Label) {
        # "header>content" for each region of a Try Catch, top to bottom; content is the first line of
        # the region's shape, or "(nothing here)".
        $tc = @($info.Values | Where-Object { $_.Vertex -and ([string]$_.Label -split "`n")[0] -eq $Label -and $_.Style -like 'swimlane;rounded=0;startSize=26;fontStyle=1;fillColor=#fbe9dc;*' })[0]
        $regions = @($info.Values | Where-Object { $_.Vertex -and $_.Parent -eq $tc.Id } | Sort-Object { [double]$_.Inner.SelectSingleNode('mxGeometry').GetAttribute('y') })
        return (@($regions | ForEach-Object {
                    $rid = $_.Id
                    $inside = @($info.Values | Where-Object { $_.Vertex -and $_.Parent -eq $rid })[0]
                    $name = ([string]$inside.Label -split "`n")[0]
                    if ($inside.Style -like 'rounded=0;fillColor=none;strokeColor=none;container=1;*') {
                        # A branch block is named after its decision.
                        $bid = $inside.Id
                        $name = ([string]@($info.Values | Where-Object { $_.Parent -eq $bid -and $_.Style -like 'rhombus;*' })[0].Label -split "`n")[0]
                    }
                    [string]$_.Label + '>' + $name
                }) -join ' / ')
    }
    $catchNote = ' (only if the Try throws one)'
    $finallyNote = 'Finally (after the Try, or a Catch that handled its exception, completes)'
    Assert ((Get-Regions 'Save the order') -eq ("Try>Save / Catch System.Exception$catchNote>Log the failure / Catch BusinessRuleException$catchNote>Handle the rule / $finallyNote>Clean up")) 'a Try Catch shows Try, each Catch with its exception type in the order written, and Finally'
    Assert ((Get-Regions 'Read the file') -eq ("Try>Read it / Catch System.IO.IOException$catchNote>(nothing here)")) 'an empty Catch says so; a missing Finally is not drawn; a .NET namespace gives the full type name'
    Assert ((Get-Regions 'Always tidy') -eq "Try>Do the work / $finallyNote>Log the end") 'a Try Catch with no Catches shows Try and Finally only'
    Assert ((Get-Regions 'Nothing to try') -eq ("Try>(nothing here) / Catch System.Exception$catchNote>Log it")) 'a missing Try is drawn as an empty Try region'
    Assert ((Get-Regions 'Call the service') -eq ("Try>Call it / Catch System.Exception$catchNote>Can we retry?")) 'a decision inside a Catch is drawn'
    $tcIds = @($info.Values | Where-Object { $_.Style -like 'swimlane;rounded=0;startSize=26;fontStyle=1;fillColor=#fbe9dc;*' } | ForEach-Object { $_.Id })
    $regionIds = @($info.Values | Where-Object { $tcIds -contains $_.Parent } | ForEach-Object { $_.Id })
    $regionArrows = @($page.SelectNodes('mxGraphModel/root/mxCell[@edge="1"]') | Where-Object { $tcIds -contains $_.GetAttribute('parent') -or $regionIds -contains $_.GetAttribute('source') -or $regionIds -contains $_.GetAttribute('target') }).Count
    Assert ($regionArrows -eq 0) "no arrow joins the regions of a Try Catch (found $regionArrows)"
    Assert (@($info.Values | Where-Object { [string]$_.Label -match '^Write to the store\nStore\\Write\.xaml \(missing\)$' }).Count -eq 1 -and @($info.Values | Where-Object { [string]$_.Label -match '^Notify the owner\nNotify\.xaml \(missing\)$' }).Count -eq 1) 'invokes inside a Try and a Catch name their workflows'
    Assert ((Get-Regions 'Check it') -eq ("Try>Run the check / Catch System.Exception$catchNote>Mark as unchecked")) 'a Try Catch inside a branch is drawn with its regions'
    Assert ((Get-Regions 'Guard 7') -eq 'Try>Guard 8') 'Try Catches are drawn down to the depth limit'
    Assert (@($info.Values | Where-Object { [string]$_.Label -eq 'Nested too deep to draw: 2 activities inside' }).Count -eq 1 -and -not @($info.Values | Where-Object { [string]$_.Label -eq 'Guard 9' }).Count) 'past the depth limit a Try Catch is one box saying how much it holds'
    $again = Invoke-Converter @{ Path = (Join-Path $fixtures 'try-catch.xaml'); OutputPath = (Join-Path $work 'try-catch-again') }
    Assert ([System.IO.File]::ReadAllText($again.DrawioFiles[0]) -ceq $d.Text) 'a page with Try Catches comes out the same every time'

    # --- Regression baseline: state machine, flowchart and project map pages, byte for byte --------
    Write-Host "`nRegression baseline"
    $protected = @('state machine', 'flowchart', 'project map')
    Assert (Test-Path -LiteralPath $baselineFile) 'the page baseline file exists (tests/baselines/page-hashes.txt)'
    if (Test-Path -LiteralPath $baselineFile) {
        $expected = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($baselineFile)) {
            $parts = $line.Split('|')
            if ($parts.Count -eq 5 -and $protected -contains $parts[3]) { $expected[($parts[0..3] -join '|')] = $parts[4] }
        }
        $actual = @{}
        foreach ($line in (Get-BaselineLines (Join-Path $work 'baseline'))) {
            $parts = $line.Split('|')
            if ($protected -contains $parts[3]) { $actual[($parts[0..3] -join '|')] = $parts[4] }
        }
        $changed = @($expected.Keys | Where-Object { $actual[$_] -ne $expected[$_] } | Sort-Object)
        $added = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)
        Assert ($expected.Count -gt 0 -and $changed.Count -eq 0) ("all $($expected.Count) state machine, flowchart and project map pages are byte-identical to the baseline" + $(if ($changed.Count) { ' -- changed or missing: ' + ($changed -join '; ') } else { '' }))
        Assert ($added.Count -eq 0) ('no state machine, flowchart or project map page appears that the baseline does not list' + $(if ($added.Count) { ' -- new: ' + ($added -join '; ') } else { '' }))
    }

    $before = @(Get-ChildItem -LiteralPath $samples -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
    [void](Invoke-Converter @{ Path = (Join-Path $samples 'project'); OutputPath = (Join-Path $work 'readonly-check') })
    $after = @(Get-ChildItem -LiteralPath $samples -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
    Assert ($null -eq (Compare-Object $before $after)) 'leaves the input folder untouched'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Result
