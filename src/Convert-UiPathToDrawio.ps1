<#
.SYNOPSIS
    Converts UiPath workflow files (.xaml) into editable draw.io diagrams (.drawio).

.DESCRIPTION
    Reads one UiPath workflow file, or every workflow in a UiPath project folder, and writes a diagram
    file (.drawio) you can open and edit in draw.io (app.diagrams.net, the desktop app, or the
    VS Code "Draw.io Integration" extension). It also writes a conversion report.

    Version 1 draws:
      - state machines: states, transitions, and the workflows each state invokes;
      - flowcharts: steps, decisions, switches and the start node;
      - a project map: which workflow invokes which (when given a project folder).
    Positions come from the layout Studio saved in the file, where there is one.
    Other workflows (for example sequences) get a summary page listing the workflows they invoke.

    The XAML is read as data only: nothing in it is run or evaluated. Conditions, expressions
    and file names worked out at run time are left out unless -IncludeDetails is given.

.PARAMETER Path
    A .xaml file, or a UiPath project folder.

.PARAMETER OutputPath
    The folder to write to. Default: the folder that contains the input, so the diagram is
    written next to the .xaml file or next to the project folder.

.PARAMETER OnePerFile
    Write one .drawio file per workflow (plus a project map file) instead of one .drawio file
    with a page per workflow. Links between pages only work within one file, so this loses them.

.PARAMETER IncludeDetails
    Add transition conditions, decision conditions, switch expressions, file names worked out at
    run time, and the full path of invoked files outside the project. Off by default, because they
    can contain server names and data.

.PARAMETER PassThru
    Return an object listing the files written.

.EXAMPLE
    .\Convert-UiPathToDrawio.ps1 -Path .\Main.xaml

.EXAMPLE
    .\Convert-UiPathToDrawio.ps1 -Path C:\UiPath\MyProcess -OutputPath C:\Diagrams\MyProcess
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$OutputPath,

    [switch]$OnePerFile,

    [switch]$IncludeDetails,

    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:XamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'

# Namespaces whose elements are never activities (XAML language, WPF types, markup compatibility).
$script:NonActivityNs = @(
    'http://schemas.microsoft.com/winfx/2006/xaml',
    'http://schemas.microsoft.com/winfx/2006/xaml/presentation',
    'http://schemas.openxmlformats.org/markup-compatibility/2006'
)

# Elements that carry a DisplayName or IdRef but are not activities: workflow structure, expressions
# (C# projects give every expression an IdRef), and the items of a Multiple Assign.
$script:StructuralNames = @(
    'State', 'Transition', 'FlowStep', 'Catch', 'ActivityAction', 'ActivityFunc',
    'CSharpValue', 'CSharpReference', 'VisualBasicValue', 'VisualBasicReference', 'Literal', 'AssignOperation'
)

# Where an activity comes from, judged by its XML namespace: UiPath's own packages, Windows Workflow
# Foundation (part of .NET), or anything else: the project's own libraries or third-party packages.
# The converter does not interpret what any activity does; this only tells the reader where it is from.
function Get-ActivitySource {
    param([string]$Namespace)
    if ($Namespace -match '^http://schemas\.uipath\.com/' -or $Namespace -match '^clr-namespace:UiPath[.;]' -or $Namespace -match ';\s*assembly=UiPath\.') { return 'UiPath' }
    if ($Namespace -eq 'http://schemas.microsoft.com/netfx/2009/xaml/activities' -or $Namespace -match '^clr-namespace:(System\.Activities|Microsoft\.VisualBasic\.Activities|Microsoft\.CSharp\.Activities)[.;]') { return 'WorkflowFoundation' }
    return 'Other'
}

function Get-ActivityPackage {
    # The package (assembly) an activity comes from, as named in its namespace.
    param([string]$Namespace)
    $m = [regex]::Match($Namespace, ';\s*assembly=([^;]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    if ([string]::IsNullOrEmpty($Namespace)) { return '(no namespace)' }
    return $Namespace
}

function Test-CountsAsActivity {
    # The elements counted as activities: real activities carry a display name or a layout ID;
    # property elements, XAML markup, expressions and structural elements do not count.
    param($Element)
    $ln = $Element.get_LocalName()
    if ($ln.Contains('.')) { return $false }
    if ($script:NonActivityNs -contains $Element.get_NamespaceURI()) { return $false }
    if ($script:StructuralNames -contains $ln) { return $false }
    return ($null -ne (Get-Attr $Element 'DisplayName') -or $null -ne (Get-Attr $Element 'WorkflowViewState.IdRef' 'Any'))
}

# draw.io styles. Labels are plain text (no html=1), so they need no HTML escaping.
$script:Style = @{
    Title          = 'text;fontSize=16;fontStyle=1;align=left;verticalAlign=top;'
    Note           = 'text;fontSize=11;fontColor=#666666;align=left;verticalAlign=top;'
    BackLink       = 'text;fontSize=11;fontColor=#0050ef;align=left;verticalAlign=top;fontStyle=4;'
    Start          = 'ellipse;fillColor=#d5e8d4;strokeColor=#82b366;fontStyle=1;'
    State          = 'rounded=1;arcSize=12;fillColor=#dae8fc;strokeColor=#6c8ebf;fontStyle=1;'
    StateCard      = 'swimlane;rounded=1;arcSize=12;startSize=28;fontStyle=1;fillColor=#dae8fc;strokeColor=#6c8ebf;swimlaneFillColor=#ffffff;collapsible=0;'
    FinalState     = 'rounded=1;arcSize=12;fillColor=#f8cecc;strokeColor=#b85450;strokeWidth=3;fontStyle=1;'
    FinalStateCard = 'swimlane;rounded=1;arcSize=12;startSize=28;fontStyle=1;fillColor=#f8cecc;strokeColor=#b85450;strokeWidth=3;swimlaneFillColor=#ffffff;collapsible=0;'
    Step           = 'rounded=1;fillColor=#ffffff;strokeColor=#6c8ebf;'
    StepCard       = 'swimlane;rounded=1;startSize=28;fontStyle=1;fillColor=#f5f5f5;strokeColor=#666666;swimlaneFillColor=#ffffff;collapsible=0;'
    CollapsedCard  = 'swimlane;rounded=1;startSize=28;fontStyle=1;dashed=1;fillColor=#f5f5f5;strokeColor=#666666;swimlaneFillColor=#ffffff;collapsible=0;'
    SequenceFrame  = 'swimlane;rounded=0;startSize=26;fontStyle=1;fillColor=#eef3f8;strokeColor=#7a96b5;swimlaneFillColor=#fbfcfd;collapsible=0;'
    Invoke         = 'shape=process;size=0.04;fillColor=#e1d5e7;strokeColor=#9673a6;'
    InvokeMissing  = 'shape=process;size=0.04;dashed=1;fillColor=#ffffff;strokeColor=#b85450;fontColor=#b85450;'
    InvokeComputed = 'shape=process;size=0.04;dashed=1;fillColor=#ffffff;strokeColor=#999999;fontColor=#666666;'
    Unknown        = 'rounded=0;dashed=1;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;'
    Decision       = 'rhombus;fillColor=#fff2cc;strokeColor=#d6b656;'
    Switch         = 'rhombus;fillColor=#ffe6cc;strokeColor=#d79b00;'
    LabelBelow     = 'labelPosition=center;verticalLabelPosition=bottom;align=center;verticalAlign=top;labelBackgroundColor=#ffffff;'
    LabelBelowRight = 'labelPosition=right;verticalLabelPosition=bottom;align=left;verticalAlign=top;labelBackgroundColor=#ffffff;'
    Row            = 'rounded=1;fillColor=#ffffff;strokeColor=#9673a6;fontSize=11;align=left;spacingLeft=6;'
    RowMissing     = 'rounded=1;dashed=1;fillColor=#ffffff;strokeColor=#b85450;fontColor=#b85450;fontSize=11;align=left;spacingLeft=6;'
    RowComputed    = 'rounded=1;dashed=1;fillColor=#ffffff;strokeColor=#999999;fontColor=#666666;fontSize=11;align=left;spacingLeft=6;'
    RowPlain       = 'text;fontSize=11;fontColor=#666666;align=left;spacingLeft=6;'
    Workflow       = 'rounded=1;fillColor=#dae8fc;strokeColor=#6c8ebf;'
    MainWorkflow   = 'rounded=1;fillColor=#dae8fc;strokeColor=#6c8ebf;strokeWidth=3;fontStyle=1;'
    BrokenWorkflow = 'rounded=1;fillColor=#f8cecc;strokeColor=#b85450;'
    Edge           = 'endArrow=block;endFill=1;rounded=1;fontSize=11;labelBackgroundColor=#ffffff;strokeColor=#555555;'
}

# What each node and row is (its role) decides how it is drawn. The graph builders only say what a
# thing is; these lookups are the one place that turns that into a draw.io style.
$script:RoleStyle = @{
    'start'           = $script:Style.Start
    'state'           = $script:Style.State
    'state|Card'      = $script:Style.StateCard
    'finalState'      = $script:Style.FinalState
    'finalState|Card' = $script:Style.FinalStateCard
    'step'            = $script:Style.Step
    'step|Card'       = $script:Style.StepCard
    'invoke'          = $script:Style.Invoke
    'invokeMissing'   = $script:Style.InvokeMissing
    'invokeComputed'  = $script:Style.InvokeComputed
    'otherActivity'   = $script:Style.Unknown
    'collapsed|Card'  = $script:Style.CollapsedCard
    'sequence|Frame'  = $script:Style.SequenceFrame
    'decision'        = $script:Style.Decision
    'switch'          = $script:Style.Switch
    'workflow'        = $script:Style.Workflow
    'mainWorkflow'    = $script:Style.MainWorkflow
    'brokenWorkflow'  = $script:Style.BrokenWorkflow
    'notWorkflow'     = $script:Style.Unknown
}
$script:RowStyle = @{
    'linked'   = $script:Style.Row
    'missing'  = $script:Style.RowMissing
    'computed' = $script:Style.RowComputed
    'plain'    = $script:Style.RowPlain
}

function Get-NodeStyle {
    # A node's draw.io style, from its role and shape. Card variants have their own entries.
    param($Node)
    $style = $script:RoleStyle[$Node.Role + '|' + $Node.Kind]
    if ($null -eq $style) { $style = $script:RoleStyle[$Node.Role] }
    if ($null -eq $style) { throw "No style for role '$($Node.Role)'." }
    if ($Node.LabelSide -eq 'Below') { $style += $script:Style.LabelBelow }
    elseif ($Node.LabelSide -eq 'BelowRight') { $style += $script:Style.LabelBelowRight }
    return $style
}

function Get-RowStyle {
    param($Row)
    return $script:RowStyle[$Row.Status]
}

$script:CardHeader = 28
$script:RowHeight = 22
$script:RowGap = 4
# The converter's version, shown in each conversion report so a report can be matched to a release.
$script:ToolVersion = '0.1.0'
# A row of the project map wider than this (in pixels) is wrapped onto several rows.
$script:MapRowWidth = 1600

# ---------------------------------------------------------------------------
# Reading XAML. Elements are matched by local name, never by namespace prefix.
#
# XML properties are read through .NET's accessors ($node.get_LocalName(), .get_Attributes() ...),
# never as $node.LocalName. PowerShell lets an attribute or child element with the same name hide the
# real property: UiPath's Get XML Node Attributes activity has an "Attributes" property, so
# $element.Attributes returned that text instead of the attribute list, and the conversion failed.
# ---------------------------------------------------------------------------

function Get-ChildElement {
    param($Parent, [string]$LocalName)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Parent) { return ,$list }
    foreach ($n in $Parent.get_ChildNodes()) {
        if ($n.get_NodeType() -ne [System.Xml.XmlNodeType]::Element) { continue }
        if ([string]::IsNullOrEmpty($LocalName) -or $n.get_LocalName() -eq $LocalName) { $list.Add($n) }
    }
    return ,$list
}

function Get-Attr {
    # Namespace: 'None' = unqualified attribute, 'Xaml' = the XAML language namespace (x:), 'Any' = any.
    param($Element, [string]$LocalName, [string]$Namespace = 'None')
    if ($null -eq $Element -or $null -eq $Element.get_Attributes()) { return $null }
    foreach ($a in $Element.get_Attributes()) {
        if ($a.get_LocalName() -ne $LocalName) { continue }
        if ($Namespace -eq 'Any') { return $a.Value }
        if ($Namespace -eq 'Xaml' -and $a.get_NamespaceURI() -eq $script:XamlNs) { return $a.Value }
        if ($Namespace -eq 'None' -and [string]::IsNullOrEmpty($a.get_NamespaceURI())) { return $a.Value }
    }
    return $null
}

function Get-ReferenceName {
    # Reads the name out of a markup extension such as "{x:Reference __ReferenceID1}".
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $m = [regex]::Match($Value, '^\s*\{\s*(?:\w+:)?Reference\s+(?:Name\s*=\s*)?([^\s}]+)\s*\}\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-SameNode {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    return [object]::ReferenceEquals($A, $B)
}

function Get-NearestAncestor {
    param($Element, [string[]]$LocalNames)
    $p = $Element.get_ParentNode()
    while ($null -ne $p -and $p.get_NodeType() -eq [System.Xml.XmlNodeType]::Element) {
        if ($LocalNames -contains $p.get_LocalName()) { return $p }
        $p = $p.get_ParentNode()
    }
    return $null
}

function Test-IsXamlReference {
    param($Element)
    return ($Element.get_LocalName() -eq 'Reference' -and $Element.get_NamespaceURI() -eq $script:XamlNs)
}

function Test-IsXamlElement {
    # True for an element of the XAML language itself, such as x:Reference, x:Key or x:Null.
    param($Element, [string]$LocalName)
    return ($Element.get_LocalName() -eq $LocalName -and $Element.get_NamespaceURI() -eq $script:XamlNs)
}

function Get-ReferenceText {
    # The name inside <x:Reference>name</x:Reference>. Only the element's own text counts: a switch
    # case can be written <x:Reference>name<x:Key>case</x:Key></x:Reference>, and InnerText would
    # glue the key onto the name.
    param($Element)
    $name = Get-Attr $Element 'Name'
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name.Trim() }
    $text = ''
    foreach ($n in $Element.get_ChildNodes()) {
        if ($n.get_NodeType() -eq [System.Xml.XmlNodeType]::Text -or $n.get_NodeType() -eq [System.Xml.XmlNodeType]::CDATA) { $text += $n.Value }
    }
    return $text.Trim()
}

function Get-XamlKey {
    # The x:Key of an element (a switch case), written as an attribute or as an <x:Key> child.
    # Returns $null when there is none. A null key reads "(null)" and an empty one "(empty)",
    # as in Studio's designer.
    param($Element)
    $key = Get-Attr $Element 'Key' 'Xaml'
    if ($null -eq $key) {
        foreach ($c in (Get-ChildElement $Element 'Key')) {
            if (-not (Test-IsXamlElement $c 'Key')) { continue }
            $key = $c.get_InnerText().Trim()
            foreach ($inner in (Get-ChildElement $c 'Null')) {
                if (Test-IsXamlElement $inner 'Null') { $key = '{x:Null}' }
            }
        }
    }
    if ($null -eq $key) { return $null }
    if ($key -match '^\s*\{\s*(?:\w+:)?Null\s*\}\s*$') { return '(null)' }
    if ($key -eq '') { return '(empty)' }
    return $key
}

function New-Link {
    # Written: the workflow has something in this slot.
    # Element: the node it leads to, or $null when it leads nowhere we can find.
    # Name:    the reference name, when the link was written as a reference.
    return @{ Written = $false; Element = $null; Name = $null }
}

function Resolve-NodeElement {
    # An element in a link slot is either the target itself (written inline) or a reference to it.
    param($Element, $NameMap)
    $link = New-Link
    if ($null -eq $Element) { return $link }
    if (Test-IsXamlElement $Element 'Null') { return $link }
    $link.Written = $true
    if (Test-IsXamlReference $Element) {
        $link.Name = Get-ReferenceText $Element
        if ($link.Name -and $NameMap.ContainsKey($link.Name)) { $link.Element = $NameMap[$link.Name] }
        return $link
    }
    $link.Element = $Element
    return $link
}

function Resolve-Target {
    # Follows a link written either as an attribute ({x:Reference name}) or as a property element.
    param($Owner, [string]$AttributeName, [string]$PropertyName, $NameMap)
    $value = Get-Attr $Owner $AttributeName
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $link = New-Link
        if ($value -match '^\s*\{\s*(?:\w+:)?Null\s*\}\s*$') { return $link }
        $link.Written = $true
        $link.Name = Get-ReferenceName $value
        if ($link.Name -and $NameMap.ContainsKey($link.Name)) { $link.Element = $NameMap[$link.Name] }
        if (-not $link.Name) { $link.Name = $value.Trim() }
        return $link
    }
    foreach ($p in (Get-ChildElement $Owner $PropertyName)) {
        foreach ($c in (Get-ChildElement $p)) {
            return (Resolve-NodeElement $c $NameMap)
        }
    }
    return (New-Link)
}

function Get-ActivityChild {
    # The first child that is an activity: not a property element (Name.Property) and not x: markup.
    param($Element)
    foreach ($c in (Get-ChildElement $Element)) {
        if ($c.get_LocalName().Contains('.')) { continue }
        if ($c.get_NamespaceURI() -eq $script:XamlNs) { continue }
        return $c
    }
    return $null
}

function Get-PropertyText {
    # Value of an attribute, or the text of the matching property element (e.g. Transition.Condition).
    param($Element, [string]$AttributeName, [string]$PropertyName)
    $v = Get-Attr $Element $AttributeName
    if ($null -ne $v) { return $v.Trim() }
    foreach ($p in (Get-ChildElement $Element $PropertyName)) { return $p.get_InnerText().Trim() }
    return $null
}

function Get-DisplayName {
    param($Element, [string]$Default)
    $d = Get-Attr $Element 'DisplayName'
    if ([string]::IsNullOrWhiteSpace($d)) { return $Default }
    return $d.Trim()
}

function Read-XmlFile {
    # Reads the file as UTF-8 and parses it with DTDs and external resolution switched off.
    param([string]$FullPath)
    $text = [System.IO.File]::ReadAllText($FullPath, [System.Text.Encoding]::UTF8)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stringReader = New-Object System.IO.StringReader($text)
    $reader = [System.Xml.XmlReader]::Create($stringReader, $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
    }
    finally {
        $reader.Close()
    }
    return $doc
}

# ---------------------------------------------------------------------------
# Studio's saved layout (ViewState)
#   Older files: a WorkflowViewStateService.ViewState child on the element itself.
#   Newer files: WorkflowViewState.IdRef on the element, and a ViewStateData entry with that Id
#                inside WorkflowViewState.ViewStateManager at the end of the file.
# ---------------------------------------------------------------------------

function New-ViewStateMap {
    param($Doc)
    $map = @{}
    foreach ($d in $Doc.SelectNodes("//*[local-name()='ViewStateData']")) {
        $id = Get-Attr $d 'Id'
        if (-not $id) { continue }
        foreach ($c in (Get-ChildElement $d 'WorkflowViewStateService.ViewState')) { $map[$id] = $c }
    }
    return $map
}

function Get-ViewState {
    # Returns a hashtable of ViewState key -> text (for example ShapeLocation -> "240,30").
    param($Element, $Map)
    $result = @{}
    if ($null -eq $Element) { return $result }
    $holder = $null
    foreach ($c in (Get-ChildElement $Element 'WorkflowViewStateService.ViewState')) { $holder = $c }
    if ($null -eq $holder) {
        $id = Get-Attr $Element 'WorkflowViewState.IdRef' 'Any'
        if (-not $id) {
            foreach ($c in (Get-ChildElement $Element 'WorkflowViewState.IdRef')) { $id = $c.get_InnerText().Trim() }
        }
        if ($id -and $Map.ContainsKey($id)) { $holder = $Map[$id] }
    }
    if ($null -eq $holder) { return $result }
    foreach ($e in $holder.SelectNodes('.//*')) {
        $k = Get-Attr $e 'Key' 'Xaml'
        if ($k) { $result[$k] = $e.get_InnerText().Trim() }
    }
    return $result
}

function Get-ViewStateText {
    # A text entry from a ViewState (for example a decision's TrueLabel), or the default when the
    # entry is missing or blank.
    param($ViewState, [string]$Key, [string]$Default)
    if ($ViewState.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($ViewState[$Key])) { return $ViewState[$Key] }
    return $Default
}

function ConvertTo-Number {
    param([string]$Text)
    # A saved layout value. NaN, infinity and absurdly large numbers can only come from a damaged
    # file; treat them as missing, so the diagram falls back to automatic layout.
    $n = 0.0
    if (-not [double]::TryParse($Text.Trim(), [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$n)) { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or [Math]::Abs($n) -gt 1000000) { return $null }
    return $n
}

function ConvertTo-PointList {
    # "x1,y1 x2,y2 ..." -> list of @(x, y)
    param([string]$Text)
    $points = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,$points }
    foreach ($token in ($Text.Trim() -split '\s+')) {
        $xy = $token -split ','
        if ($xy.Count -ne 2) { continue }
        $x = ConvertTo-Number $xy[0]
        $y = ConvertTo-Number $xy[1]
        if ($null -eq $x -or $null -eq $y) { continue }
        $points.Add(@($x, $y))
    }
    return ,$points
}

function Get-StudioRect {
    # Position and size saved by Studio, or $null.
    param($ViewState, [double]$DefaultWidth, [double]$DefaultHeight)
    if (-not $ViewState.ContainsKey('ShapeLocation')) { return $null }
    $loc = ConvertTo-PointList $ViewState['ShapeLocation']
    if ($loc.Count -ne 1) { return $null }
    $w = $DefaultWidth
    $h = $DefaultHeight
    if ($ViewState.ContainsKey('ShapeSize')) {
        $size = ConvertTo-PointList $ViewState['ShapeSize']
        if ($size.Count -eq 1 -and $size[0][0] -gt 0 -and $size[0][1] -gt 0) {
            $w = $size[0][0]
            $h = $size[0][1]
        }
    }
    return @{ X = $loc[0][0]; Y = $loc[0][1]; W = $w; H = $h }
}

function Get-StudioPoints {
    param($ViewState, [string[]]$Keys)
    foreach ($k in $Keys) {
        if ($ViewState.ContainsKey($k)) {
            $pts = ConvertTo-PointList $ViewState[$k]
            if ($pts.Count -ge 2) { return ,$pts }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Workflows and the workflows they invoke
# ---------------------------------------------------------------------------

function ConvertTo-WorkflowKey {
    param([string]$RelativePath)
    return $RelativePath.ToLowerInvariant()
}

function Get-InvokeInfo {
    param($InvokeElement, [string]$ProjectRoot)
    $raw = Get-PropertyText $InvokeElement 'WorkflowFileName' 'InvokeWorkflowFile.WorkflowFileName'
    if ($null -eq $raw) { $raw = '' }
    # A literal file name ends in .xaml and has no expression brackets or quotes. Anything else is
    # worked out at run time, so it can't be linked.
    $computed = ($raw -eq '' -or $raw.StartsWith('[') -or $raw.Contains('"') -or -not $raw.ToLowerInvariant().EndsWith('.xaml'))
    $rel = $raw.Replace('/', '\')
    $outside = $false
    if (-not $computed) {
        # Work the path out as text only. The file name comes from the workflow, so it is never
        # handed to anything that touches the disk or the network until it is known to lie inside
        # the project folder. (System.IO.Path methods are also avoided: on Windows PowerShell 5.1
        # they throw on characters such as | < > that a workflow can contain.)
        $rootWithSlash = $ProjectRoot.TrimEnd('\') + '\'
        if ($rel.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($rootWithSlash.Length)
        }
        elseif ($rel -match '^(?:[A-Za-z]:|\\)') {
            $outside = $true        # another drive, another folder, or a network path
        }
        if (-not $outside) {
            # Tidy the path: drop "." and empty parts, and let ".." step back up one folder.
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($part in $rel.Split('\')) {
                if ($part -eq '' -or $part -eq '.') { continue }
                if ($part -eq '..') {
                    if ($parts.Count -eq 0) { $outside = $true; break }
                    $parts.RemoveAt($parts.Count - 1)
                    continue
                }
                $parts.Add($part)
            }
            if (-not $outside) { $rel = $parts -join '\' }
        }
    }
    $leaf = $rel
    $slash = $rel.LastIndexOf('\')
    if ($slash -ge 0) { $leaf = $rel.Substring($slash + 1) }
    return @{
        Element     = $InvokeElement
        Raw         = $raw
        Computed    = $computed
        Outside     = $outside      # a literal path that leads out of the project folder
        Rel         = $rel
        Leaf        = $leaf
        Key         = (ConvertTo-WorkflowKey $rel)
        DisplayName = (Get-DisplayName $InvokeElement 'Invoke Workflow File')
        Exists      = $false
    }
}

function Get-OutsideText {
    # How to show an invoked file that lies outside the project. The full path can name a server
    # or a user, so by default only the file name is shown.
    param($Invoke, $Context)
    if ($Context.IncludeDetails) { return $Invoke.Rel }
    return $Invoke.Leaf
}

function Get-ReadErrorText {
    # Why a file could not be read, without quoting its content or the local path. .NET's own
    # messages do both: an XML error quotes the text it choked on, and a file error names the path.
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.Xml.XmlException]) {
            if ($e.LineNumber -gt 0) { return 'not well-formed XML (line ' + $e.LineNumber + ', position ' + $e.LinePosition + ')' }
            return 'not well-formed XML'
        }
        if ($e -is [System.UnauthorizedAccessException]) { return 'access denied' }
        if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) { return 'file not found' }
        if ($e -is [System.IO.IOException]) { return 'the file could not be read (it may be locked by another program)' }
        if ($e -is [System.Text.DecoderFallbackException]) { return 'the file is not valid text' }
        $e = $e.InnerException
    }
    return 'the file could not be read (' + $Exception.GetType().Name + ')'
}

function Read-Workflow {
    param([string]$FullPath, [string]$RelativePath, [string]$ProjectRoot)
    $wf = @{
        FullPath      = $FullPath
        Rel           = $RelativePath
        Key           = (ConvertTo-WorkflowKey $RelativePath)
        Name          = [System.IO.Path]::GetFileNameWithoutExtension($FullPath)
        Doc           = $null
        Error         = $null
        Root          = $null
        Kind          = 'Unknown'
        KindLabel     = 'unknown'
        Invokes       = (New-Object System.Collections.Generic.List[object])
        Activities    = @{}         # "source|type" -> source, type, package and how often it is used
        ActivityCount = 0           # activities below the top-level one
        NotDrawn      = 0           # how many of those the diagram does not show
        Collapsed     = 0           # sequence pages: activities holding others, drawn as one box each
        Summary       = ''
        IsMain        = $false
        TopElement    = ''          # for a file that is not a workflow: what its top element is
    }
    try {
        $wf.Doc = Read-XmlFile $FullPath
    }
    catch {
        $wf.Error = Get-ReadErrorText $_.Exception
        $wf.KindLabel = 'could not be read'
        return $wf
    }

    $class = Get-Attr $wf.Doc.DocumentElement 'Class' 'Xaml'
    if ($class) { $wf.Name = $class }

    # A workflow file's top element is <Activity>, holding one activity (sometimes inside an
    # Activity.Implementation element). A file whose top element is itself a known activity is drawn
    # from that. Anything else is some other kind of XML, and is reported rather than guessed at.
    $top = $wf.Doc.DocumentElement
    if ($top.get_LocalName() -eq 'Activity') {
        $wf.Root = Get-ActivityChild $top
        if ($null -eq $wf.Root) {
            foreach ($impl in (Get-ChildElement $top 'Activity.Implementation')) { $wf.Root = Get-ActivityChild $impl }
        }
    }
    elseif ((Get-ActivitySource $top.get_NamespaceURI()) -ne 'Other') {
        $wf.Root = $top
    }
    else {
        $wf.Kind = 'NotWorkflow'
        $wf.KindLabel = 'not a workflow'
        $wf.TopElement = $top.get_LocalName()
        return $wf
    }
    if ($null -eq $wf.Root) {
        $wf.Kind = 'Empty'
        $wf.KindLabel = 'empty'
    }
    else {
        switch ($wf.Root.get_LocalName()) {
            'StateMachine' { $wf.Kind = 'StateMachine'; $wf.KindLabel = 'state machine' }
            'Flowchart' { $wf.Kind = 'Flowchart'; $wf.KindLabel = 'flowchart' }
            default { $wf.Kind = 'Other'; $wf.KindLabel = $wf.Root.get_LocalName().ToLowerInvariant() }
        }
        if ($wf.Kind -eq 'Other' -and $wf.Root.get_LocalName() -eq 'Sequence' -and (Get-ActivitySource $wf.Root.get_NamespaceURI()) -eq 'WorkflowFoundation') {
            $wf.Kind = 'Sequence'
            $wf.KindLabel = 'sequence'
        }
    }

    foreach ($inv in $wf.Doc.SelectNodes("//*[local-name()='InvokeWorkflowFile']")) {
        $wf.Invokes.Add((Get-InvokeInfo $inv $ProjectRoot))
    }

    # Inventory of activities, by type and source, for the report.
    foreach ($e in $wf.Doc.SelectNodes('//*')) {
        if ((Test-SameNode $e $top) -and $top.get_LocalName() -eq 'Activity') { continue }   # the file's wrapper, not an activity
        if (-not (Test-CountsAsActivity $e)) { continue }
        $ns = $e.get_NamespaceURI()
        $source = Get-ActivitySource $ns
        $key = $source + '|' + $e.get_LocalName()
        if (-not $wf.Activities.ContainsKey($key)) {
            $wf.Activities[$key] = @{ Source = $source; Type = $e.get_LocalName(); Package = (Get-ActivityPackage $ns); Count = 0 }
        }
        $wf.Activities[$key].Count++
        if (-not (Test-SameNode $e $wf.Root)) { $wf.ActivityCount++ }     # activities below the top-level one
    }
    return $wf
}

# ---------------------------------------------------------------------------
# Graph model shared by state machines, flowcharts and the project map
# ---------------------------------------------------------------------------

# Which drawn node stands for which XML element. Looking a node up here, rather than scanning the
# list, keeps big workflows fast. XML elements are compared by identity, and each belongs to one
# file, so one map serves every page.
$script:NodeByElement = New-Object 'System.Collections.Generic.Dictionary[object,object]'

function New-Node {
    param([string]$Key, [string]$Kind, [string]$Label, [string]$Role, $Element = $null)
    $node = @{
        Key     = $Key
        Kind    = $Kind      # shape: Start, Box, Card, Decision, Switch
        Label   = $Label
        Role    = $Role      # what it is: state, step, invoke, decision ... (see $script:RoleStyle)
        LabelSide = $null    # decisions on Studio layouts: where the text goes, Below or BelowRight
        Element = $Element
        Rows    = (New-Object System.Collections.Generic.List[object])
        Link    = $null
        Studio  = $null
        X       = 0.0
        Y       = 0.0
        W       = 0.0
        H       = 0.0
    }
    if ($null -ne $Element) { $script:NodeByElement[$Element] = $node }
    return $node
}

function New-Edge {
    param([string]$From, [string]$To, [string]$Label)
    return @{
        From         = $From
        To           = $To
        Label        = $Label
        StudioPoints = $null
        Back         = $false
        Style        = ''
        Points       = $null
        LabelX       = $null    # where the label sits along the arrow, -1 (source) to 1 (target); $null = middle
        LabelDx      = 0.0      # how far the label is moved sideways from the arrow, in pixels
        # Used by the automatic layout while it routes the arrow:
        Route        = ''
        Order        = 0
        LaneX        = 0.0
        ApproachX    = 0.0
        EntryFrac    = 0.5
        LabelSlot    = 0
        LeaveTrack   = 0
        EnterTrack   = 0
    }
}

function Get-PolylineLength {
    # Total length of a path given as a list of @(x, y) points.
    param($Points)
    $length = 0.0
    for ($i = 1; $i -lt $Points.Count; $i++) {
        $dx = $Points[$i][0] - $Points[$i - 1][0]
        $dy = $Points[$i][1] - $Points[$i - 1][1]
        $length += [Math]::Sqrt($dx * $dx + $dy * $dy)
    }
    return $length
}

function New-Row {
    param([string]$Text, [string]$Status, [string]$Link)
    # Status: linked, missing, computed (set at run time or outside the project) or plain.
    return @{ Text = $Text; Status = $Status; Link = $Link }
}

function New-InvokeRow {
    param($Invoke, $Context, [string]$Suffix)
    if ($Invoke.Computed) {
        $text = '(file name set at run time)'
        if ($Context.IncludeDetails -and $Invoke.Raw) { $text = 'Run-time file name: ' + $Invoke.Raw }
        return (New-Row ($text + $Suffix) 'computed' $null)
    }
    if ($Invoke.Outside) {
        return (New-Row ((Get-OutsideText $Invoke $Context) + ' (outside the project)' + $Suffix) 'computed' $null)
    }
    if (-not $Invoke.Exists) {
        return (New-Row ($Invoke.Rel + ' (missing)' + $Suffix) 'missing' $null)
    }
    $link = $null
    if ($Context.PageIds.ContainsKey($Invoke.Key)) { $link = 'data:page/id,' + $Context.PageIds[$Invoke.Key] }
    return (New-Row ($Invoke.Rel + $Suffix) 'linked' $link)
}

function Get-InvokeRole {
    # The role of a step that invokes a workflow, from the state of its target.
    param($Row)
    switch ($Row.Status) {
        'missing' { return 'invokeMissing' }
        'computed' { return 'invokeComputed' }
    }
    return 'invoke'
}

function Add-UniqueRow {
    param($Node, $Row)
    foreach ($r in $Node.Rows) { if ($r.Text -eq $Row.Text) { return } }
    $Node.Rows.Add($Row)
}

function Find-NodeByElement {
    # The node for an element, or $null when the element has no node in this graph.
    param($Nodes, $Element)
    if ($null -eq $Element) { return $null }
    $node = $null
    if (-not $script:NodeByElement.TryGetValue($Element, [ref]$node)) { return $null }
    if (-not $Nodes.Contains($node)) { return $null }
    return $node
}

# ---------------------------------------------------------------------------
# State machines
# ---------------------------------------------------------------------------

function Get-StateMachineGraph {
    param($Workflow, $Machine, $Context)
    $vsMap = $Context.ViewStateMap
    $nodes = New-Object System.Collections.Generic.List[object]
    $edges = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]

    # States that belong to this machine (not to a state machine nested inside one of its states).
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Machine.SelectNodes(".//*[local-name()='State']")) {
        if (Test-SameNode (Get-NearestAncestor $s @('StateMachine')) $Machine) { $states.Add($s) }
    }
    $nameMap = @{}
    foreach ($s in $states) {
        $n = Get-Attr $s 'Name' 'Xaml'
        if ($n) { $nameMap[$n] = $s }
    }

    $start = New-Node 'start' 'Start' 'Start' 'start' $Machine
    $machineVs = Get-ViewState $Machine $vsMap
    $start.Studio = Get-StudioRect $machineVs 60 75
    $nodes.Add($start)

    $i = 0
    foreach ($s in $states) {
        $i++
        $isFinal = ((Get-Attr $s 'IsFinal') -eq 'True')
        $role = 'state'
        if ($isFinal) { $role = 'finalState' }
        $node = New-Node ('s' + $i) 'Box' (Get-DisplayName $s 'State') $role $s
        $node.Studio = Get-StudioRect (Get-ViewState $s $vsMap) 160 80
        $nodes.Add($node)
    }

    # Invoked workflows: each belongs to the nearest state (Entry/Exit) or transition (Action/Trigger) of this machine.
    foreach ($inv in $Workflow.Invokes) {
        $owner = $null
        $p = $inv.Element.get_ParentNode()
        while ($null -ne $p -and $p.get_NodeType() -eq [System.Xml.XmlNodeType]::Element) {
            if (Test-SameNode $p $Machine) { break }
            if ($p.get_LocalName() -eq 'State' -or $p.get_LocalName() -eq 'Transition') {
                if (Test-SameNode (Get-NearestAncestor $p @('StateMachine')) $Machine) { $owner = $p; break }
            }
            $p = $p.get_ParentNode()
        }
        if ($null -eq $owner) { continue }
        $suffix = ''
        $stateEl = $owner
        if ($owner.get_LocalName() -eq 'Transition') {
            $suffix = ' (on "' + (Get-DisplayName $owner 'transition') + '")'
            $stateEl = Get-NearestAncestor $owner @('State')
        }
        $node = Find-NodeByElement $nodes $stateEl
        if ($null -ne $node) { Add-UniqueRow $node (New-InvokeRow $inv $Context $suffix) }
    }
    foreach ($n in $nodes) {
        if ($n.Rows.Count -gt 0) { $n.Kind = 'Card' }
    }

    # Initial state
    $initial = Resolve-Target $Machine 'InitialState' 'StateMachine.InitialState' $nameMap
    $initialNode = $null
    if ($null -ne $initial.Element) { $initialNode = Find-NodeByElement $nodes $initial.Element }
    if ($null -ne $initialNode) {
        $e = New-Edge 'start' $initialNode.Key ''
        $e.StudioPoints = Get-StudioPoints $machineVs @('ConnectorLocation')
        $edges.Add($e)
    }
    elseif ($initial.Written) {
        $warnings.Add('The initial state points at something that is not a state of this state machine; the start arrow is not drawn.')
    }
    else {
        $warnings.Add('No initial state found.')
    }

    # Transitions sit inside their source state's State.Transitions.
    $transitionCount = 0
    foreach ($s in $states) {
        $sourceNode = Find-NodeByElement $nodes $s
        foreach ($holder in (Get-ChildElement $s 'State.Transitions')) {
            foreach ($t in (Get-ChildElement $holder 'Transition')) {
                $transitionCount++
                $name = Get-DisplayName $t ''
                $target = Resolve-Target $t 'To' 'Transition.To' $nameMap
                $targetNode = $null
                if ($null -ne $target.Element) { $targetNode = Find-NodeByElement $nodes $target.Element }
                if ($null -eq $targetNode) {
                    $warnings.Add('Transition "' + $name + '" from state "' + $sourceNode.Label + '" has no target state; not drawn.')
                    continue
                }
                $label = $name
                if ($Context.IncludeDetails) {
                    $cond = Get-PropertyText $t 'Condition' 'Transition.Condition'
                    if ($cond) {
                        if ($label) { $label = $label + "`n" + $cond } else { $label = $cond }
                    }
                }
                $e = New-Edge $sourceNode.Key $targetNode.Key $label
                $e.StudioPoints = Get-StudioPoints (Get-ViewState $t $vsMap) @('ConnectorLocation')
                $edges.Add($e)
            }
        }
    }

    $summary = (Format-Count $states.Count 'state' 'states') + ', ' + (Format-Count $transitionCount 'transition' 'transitions')
    return @{ Nodes = $nodes; Edges = $edges; StartKeys = @('start'); Warnings = $warnings; Summary = $summary }
}

# ---------------------------------------------------------------------------
# Flowcharts
# ---------------------------------------------------------------------------

function Get-StepLabel {
    param($Activity)
    $type = $Activity.get_LocalName()
    return (Get-DisplayName $Activity $type)
}

function Get-FlowchartGraph {
    param($Workflow, $Chart, $Context)
    $vsMap = $Context.ViewStateMap
    $invokeByElement = New-Object 'System.Collections.Generic.Dictionary[object,object]'
    foreach ($inv in $Workflow.Invokes) { $invokeByElement[$inv.Element] = $inv }
    $nodes = New-Object System.Collections.Generic.List[object]
    $edges = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]

    $flowNames = @('FlowStep', 'FlowDecision', 'FlowSwitch')
    $elements = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Chart.SelectNodes(".//*[local-name()='FlowStep' or local-name()='FlowDecision' or local-name()='FlowSwitch']")) {
        if (Test-SameNode (Get-NearestAncestor $e @('Flowchart')) $Chart) { $elements.Add($e) }
    }
    $nameMap = @{}
    foreach ($e in $elements) {
        $n = Get-Attr $e 'Name' 'Xaml'
        if ($n) { $nameMap[$n] = $e }
    }

    $start = New-Node 'start' 'Start' 'Start' 'start' $Chart
    $chartVs = Get-ViewState $Chart $vsMap
    $start.Studio = Get-StudioRect $chartVs 60 75
    $nodes.Add($start)

    $i = 0
    foreach ($e in $elements) {
        $i++
        $key = 'n' + $i
        $vs = Get-ViewState $e $vsMap
        switch ($e.get_LocalName()) {
            'FlowStep' {
                $act = Get-ActivityChild $e
                if ($null -eq $act) {
                    $node = New-Node $key 'Box' '(empty step)' 'step' $e
                }
                elseif ($act.get_LocalName() -eq 'InvokeWorkflowFile') {
                    $inv = $null
                    [void]$invokeByElement.TryGetValue($act, [ref]$inv)
                    $row = New-InvokeRow $inv $Context ''
                    $node = New-Node $key 'Box' ((Get-StepLabel $act) + "`n" + $row.Text) (Get-InvokeRole $row) $e
                    $node.Link = $row.Link
                }
                elseif ((Get-ActivitySource $act.get_NamespaceURI()) -eq 'Other') {
                    # From the project's own library or a third-party package: shown with its type, dashed.
                    $node = New-Node $key 'Box' ((Get-StepLabel $act) + "`n[" + $act.get_LocalName() + ']') 'otherActivity' $e
                }
                else {
                    $label = Get-StepLabel $act
                    if ($act.get_LocalName() -eq 'Flowchart' -or $act.get_LocalName() -eq 'StateMachine') {
                        $label = $label + ' (nested ' + $act.get_LocalName().ToLowerInvariant() + ')'
                        $warnings.Add('Step "' + (Get-StepLabel $act) + '" holds a nested ' + $act.get_LocalName().ToLowerInvariant() + '; it is not expanded in version 1.')
                    }
                    $node = New-Node $key 'Box' $label 'step' $e
                }
                $node.Studio = Get-StudioRect $vs 200 52
            }
            'FlowDecision' {
                $label = Get-DisplayName $e 'Decision'
                if ($Context.IncludeDetails) {
                    $cond = Get-PropertyText $e 'Condition' 'FlowDecision.Condition'
                    if ($cond) { $label = $label + "`n" + $cond }
                }
                $node = New-Node $key 'Decision' $label 'decision' $e
                $node.Studio = Get-StudioRect $vs 70 70
            }
            'FlowSwitch' {
                $label = Get-DisplayName $e 'Switch'
                if ($Context.IncludeDetails) {
                    $expr = Get-PropertyText $e 'Expression' 'FlowSwitch.Expression'
                    if ($expr) { $label = $label + "`n" + $expr }
                }
                $node = New-Node $key 'Switch' $label 'switch' $e
                $node.Studio = Get-StudioRect $vs 70 70
            }
        }
        $nodes.Add($node)
    }

    # Invoked workflows inside a step's activity (for example a Sequence) are listed on the step.
    foreach ($inv in $Workflow.Invokes) {
        $owner = $null
        $p = $inv.Element.get_ParentNode()
        while ($null -ne $p -and $p.get_NodeType() -eq [System.Xml.XmlNodeType]::Element) {
            if (Test-SameNode $p $Chart) { break }
            if ($p.get_LocalName() -eq 'FlowStep' -and (Test-SameNode (Get-NearestAncestor $p @('Flowchart')) $Chart)) { $owner = $p; break }
            $p = $p.get_ParentNode()
        }
        if ($null -eq $owner) { continue }
        if (Test-SameNode (Get-ActivityChild $owner) $inv.Element) { continue }
        $node = Find-NodeByElement $nodes $owner
        if ($null -ne $node) { Add-UniqueRow $node (New-InvokeRow $inv $Context '') }
    }
    foreach ($n in $nodes) {
        if ($n.Rows.Count -gt 0 -and $n.Kind -eq 'Box') {
            $n.Kind = 'Card'
            $n.Role = 'step'
        }
    }

    function Add-FlowEdge {
        # $What names the link for the warning, for example 'next step' or 'case "North"'.
        param($FromNode, $Link, [string]$Label, $Points, [string]$What)
        if (-not $Link.Written) { return }
        $from = @(([string]$FromNode.Label) -split "`n")[0]
        if ($null -eq $Link.Element) {
            $warnings.Add('The ' + $What + ' of "' + $from + '" points at "' + $Link.Name + '", which does not exist; not drawn.')
            return
        }
        $toNode = Find-NodeByElement $nodes $Link.Element
        if ($null -eq $toNode) {
            $warnings.Add('The ' + $What + ' of "' + $from + '" points at something that is not a step of this flowchart; not drawn.')
            return
        }
        $edge = New-Edge $FromNode.Key $toNode.Key $Label
        $edge.StudioPoints = $Points
        $edges.Add($edge)
    }

    $startLink = Resolve-Target $Chart 'StartNode' 'Flowchart.StartNode' $nameMap
    if ($startLink.Written) {
        Add-FlowEdge $start $startLink '' (Get-StudioPoints $chartVs @('ConnectorLocation')) 'first step'
    }
    else {
        $warnings.Add('No start node found.')
    }

    foreach ($e in $elements) {
        $node = Find-NodeByElement $nodes $e
        $vs = Get-ViewState $e $vsMap
        switch ($e.get_LocalName()) {
            'FlowStep' {
                Add-FlowEdge $node (Resolve-Target $e 'Next' 'FlowStep.Next' $nameMap) '' (Get-StudioPoints $vs @('ConnectorLocation')) 'next step'
            }
            'FlowDecision' {
                # Studio keeps the branch labels in the decision's ViewState, not as attributes:
                #   <x:String x:Key="TrueLabel">Yes</x:String>
                $trueLabel = Get-ViewStateText $vs 'TrueLabel' 'True'
                $falseLabel = Get-ViewStateText $vs 'FalseLabel' 'False'
                Add-FlowEdge $node (Resolve-Target $e 'True' 'FlowDecision.True' $nameMap) $trueLabel (Get-StudioPoints $vs @('TrueConnector')) 'True branch'
                Add-FlowEdge $node (Resolve-Target $e 'False' 'FlowDecision.False' $nameMap) $falseLabel (Get-StudioPoints $vs @('FalseConnector')) 'False branch'
            }
            'FlowSwitch' {
                # A case is a child with an x:Key, written as an attribute or as an <x:Key> child element.
                # The child is the target step itself, or an x:Reference to it:
                #   <FlowStep x:Key="North" ...>            <x:Reference x:Key="North">name</x:Reference>
                #   <FlowStep ...><x:Key>North</x:Key>...   <x:Reference>name<x:Key>North</x:Key></x:Reference>
                $caseHolders = New-Object System.Collections.Generic.List[object]
                $caseHolders.Add($e)
                foreach ($c in (Get-ChildElement $e 'FlowSwitch.Cases')) { $caseHolders.Add($c) }
                foreach ($holder in $caseHolders) {
                    foreach ($c in (Get-ChildElement $holder)) {
                        if ($c.get_LocalName().Contains('.')) { continue }          # property elements, such as FlowSwitch.Default
                        if (Test-IsXamlElement $c 'Key') { continue }         # this switch's own key, when it is itself a case
                        $caseKey = Get-XamlKey $c
                        if ($null -eq $caseKey) {
                            if ((Test-IsXamlReference $c) -or $flowNames -contains $c.get_LocalName()) {
                                $warnings.Add('A case of switch "' + $node.Label + '" has no key, so its branch is not drawn.')
                            }
                            continue
                        }
                        Add-FlowEdge $node (Resolve-NodeElement $c $nameMap) $caseKey (Get-StudioPoints $vs @(($caseKey + 'Connector'))) ('case "' + $caseKey + '"')
                    }
                }
                # The default branch's label lives in the ViewState too (the WF designer's DefaultCaseDisplayName).
                $defaultLabel = Get-ViewStateText $vs 'DefaultCaseDisplayName' 'Default'
                Add-FlowEdge $node (Resolve-Target $e 'Default' 'FlowSwitch.Default' $nameMap) $defaultLabel (Get-StudioPoints $vs @('Default')) 'default branch'
            }
        }
    }

    $steps = 0; $decisions = 0; $switches = 0
    $drawn = 0      # activities the diagram shows: each step's own activity, each decision and switch
    foreach ($e in $elements) {
        switch ($e.get_LocalName()) {
            'FlowStep' { $steps++; $act = Get-ActivityChild $e; if ($null -ne $act -and (Test-CountsAsActivity $act)) { $drawn++ } }
            'FlowDecision' { $decisions++; if (Test-CountsAsActivity $e) { $drawn++ } }
            'FlowSwitch' { $switches++; if (Test-CountsAsActivity $e) { $drawn++ } }
        }
    }
    $summary = (Format-Count $steps 'step' 'steps') + ', ' + (Format-Count $decisions 'decision' 'decisions') + ', ' + (Format-Count $switches 'switch' 'switches')
    return @{ Nodes = $nodes; Edges = $edges; StartKeys = @('start'); Warnings = $warnings; Summary = $summary; DrawnActivities = $drawn }
}

# ---------------------------------------------------------------------------
# Sequences
# ---------------------------------------------------------------------------
# A sequence runs its activities one after another, in the order written. The page draws it as a frame
# with its activities stacked top to bottom and joined by arrows. A sequence inside it is a frame of
# its own. Version 1 expands nothing else: any other activity that holds activities (If, Try Catch,
# loops, scopes, and containers from other packages) is drawn as one dashed box saying what it is and
# how many activities it holds, and listing the workflows invoked inside it. Nothing is guessed about
# what such an activity does with its contents.

$script:MaxSequenceDepth = 8     # sequences nested deeper than this are collapsed, not drawn
$script:FrameHeader = 26
$script:SequencePad = 20
$script:SequenceGap = 30

function Get-ActivityChildren {
    # Every child element that is an activity: not a property element (Name.Property), not markup.
    param($Element)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in (Get-ChildElement $Element)) {
        if ($c.get_LocalName().Contains('.')) { continue }
        if ($script:NonActivityNs -contains $c.get_NamespaceURI()) { continue }
        $list.Add($c)
    }
    return , $list
}

function Get-InsideCount {
    # How many activities an element holds, not counting itself.
    param($Element)
    $count = 0
    foreach ($d in $Element.SelectNodes('.//*')) { if (Test-CountsAsActivity $d) { $count++ } }
    return $count
}

function Get-SequenceItem {
    # What the sequence page draws for one activity: a frame (a sequence, with its activities), a box
    # (one activity, or an invoked workflow), or a dashed card (an activity holding others, not expanded).
    param($Element, [int]$Depth, $Context, $InvokeByElement)
    $type = $Element.get_LocalName()
    $source = Get-ActivitySource $Element.get_NamespaceURI()
    $item = @{
        Element = $Element; Type = $type; Source = $source; Label = (Get-StepLabel $Element)
        Shape = 'Box'; Role = 'step'; Link = $null; Children = $null; Rows = $null
        Inside = 0; Reason = ''; Counts = (Test-CountsAsActivity $Element)
        X = 0.0; Y = 0.0; W = 0.0; H = 0.0
    }
    $isSequence = ($type -eq 'Sequence' -and $source -eq 'WorkflowFoundation')
    if ($isSequence -and $Depth -le $script:MaxSequenceDepth) {
        $children = Get-ActivityChildren $Element
        if ($children.Count -eq 0) {
            $item.Label = $item.Label + "`n(empty sequence)"
            return $item
        }
        $item.Shape = 'Frame'
        $item.Role = 'sequence'
        $item.Children = New-Object System.Collections.Generic.List[object]
        foreach ($c in $children) { $item.Children.Add((Get-SequenceItem $c ($Depth + 1) $Context $InvokeByElement)) }
        return $item
    }
    if ($type -eq 'InvokeWorkflowFile' -and $source -eq 'UiPath') {
        $inv = $null
        if ($InvokeByElement.TryGetValue($Element, [ref]$inv)) {
            $row = New-InvokeRow $inv $Context ''
            $item.Label = $item.Label + "`n" + $row.Text
            $item.Role = Get-InvokeRole $row
            $item.Link = $row.Link
            return $item
        }
    }
    $inside = Get-InsideCount $Element
    if ($inside -gt 0 -or $isSequence) {
        $item.Shape = 'Card'
        $item.Role = 'collapsed'
        $item.Inside = $inside
        $activities = Format-Count $inside 'activity' 'activities'
        $suffix = ''
        if ($isSequence) {
            $item.Reason = 'depth'
            $text = 'Nested too deep to draw: ' + $activities + ' inside'
        }
        elseif ($type -eq 'CommentOut' -and $source -eq 'UiPath') {
            $item.Reason = 'commented out'
            $text = $activities + ' commented out (not run)'
            $suffix = ' (commented out)'
        }
        elseif ($source -eq 'Other') {
            $item.Reason = 'other package'
            $text = '[' + $type + '] from another package: ' + $activities + ' inside, not drawn'
        }
        else {
            $item.Reason = 'not expanded'
            $text = '[' + $type + '] ' + $activities + ' inside, not drawn in version 1'
        }
        $item.Rows = New-Object System.Collections.Generic.List[object]
        $item.Rows.Add((New-Row $text 'plain' $null))
        foreach ($el in $Element.SelectNodes(".//*[local-name()='InvokeWorkflowFile']")) {
            $inv = $null
            if (-not $InvokeByElement.TryGetValue($el, [ref]$inv)) { continue }
            $row = New-InvokeRow $inv $Context $suffix
            $seen = $false
            foreach ($r in $item.Rows) { if ($r.Text -eq $row.Text) { $seen = $true } }
            if (-not $seen) { $item.Rows.Add($row) }
        }
        return $item
    }
    if ($source -eq 'Other') {
        $item.Role = 'otherActivity'
        $item.Label = $item.Label + "`n[" + $type + ']'
    }
    return $item
}

function Set-SequenceLayout {
    # Sizes every item and places each frame's items centred, top to bottom, relative to the frame.
    param($Item)
    if ($Item.Shape -ne 'Frame') {
        $rows = @()
        if ($null -ne $Item.Rows) { $rows = $Item.Rows }
        $kind = 'Box'
        if ($Item.Shape -eq 'Card') { $kind = 'Card' }
        $size = Measure-Node @{ Kind = $kind; Label = $Item.Label; Rows = $rows } $false
        $Item.W = $size.W
        $Item.H = $size.H
        return
    }
    $widest = 0.0
    $height = 0.0
    foreach ($c in $Item.Children) {
        Set-SequenceLayout $c
        if ($c.W -gt $widest) { $widest = $c.W }
        $height += $c.H
    }
    $height += $script:SequenceGap * ($Item.Children.Count - 1)
    $Item.W = [Math]::Max([Math]::Max($widest + 2 * $script:SequencePad, (Get-TextSize $Item.Label 7.5 16).W + 40), 160)
    $Item.H = $script:FrameHeader + 2 * $script:SequencePad + $height
    $y = $script:FrameHeader + $script:SequencePad
    foreach ($c in $Item.Children) {
        $c.X = ($Item.W - $c.W) / 2
        $c.Y = $y
        $y += $c.H + $script:SequenceGap
    }
}

function Add-SequenceItem {
    # Writes an item, and for a frame everything inside it, as cells nested in their containers, so
    # moving a frame in draw.io moves its contents. Arrows join each activity to the next.
    param($Page, $Item, [string]$ParentId)
    $id = Add-Vertex $Page $Item.Label (Get-NodeStyle @{ Role = $Item.Role; Kind = $Item.Shape; LabelSide = $null }) $Item.X $Item.Y $Item.W $Item.H $ParentId $Item.Link
    if ($Item.Shape -eq 'Card') {
        $y = $script:CardHeader + $script:RowGap
        foreach ($r in $Item.Rows) {
            [void](Add-Vertex $Page $r.Text (Get-RowStyle $r) 8 $y ($Item.W - 16) $script:RowHeight $id $r.Link)
            $y += $script:RowHeight + $script:RowGap
        }
    }
    if ($Item.Shape -eq 'Frame') {
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($c in $Item.Children) { $ids.Add((Add-SequenceItem $Page $c $id)) }
        $style = $script:Style.Edge + 'edgeStyle=none;exitX=0.5;exitY=1;exitDx=0;exitDy=0;entryX=0.5;entryY=0;entryDx=0;entryDy=0;'
        for ($i = 1; $i -lt $ids.Count; $i++) { [void](Add-EdgeCell $Page '' $style $ids[$i - 1] $ids[$i] $null $null 0 $id) }
    }
    return $id
}

function Get-SequenceStats {
    # Counts for the report, over every item below the top-level sequence.
    param($Item, $Stats)
    foreach ($c in $Item.Children) {
        if ($c.Counts) { $Stats.Drawn++ }
        switch ($c.Shape) {
            'Frame' { $Stats.Sequences++; Get-SequenceStats $c $Stats }
            'Card' {
                $Stats.Collapsed++
                $Stats.Inside += $c.Inside
                $label = $c.Type
                if ($c.Reason -eq 'commented out') { $label = 'commented out' }
                if ($c.Reason -eq 'depth') { $label = 'nested too deep' }
                $Stats.Kinds[$label] = 1 + [int]$Stats.Kinds[$label]
            }
            default { $Stats.Boxes++ }
        }
    }
}

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

function Get-TextSize {
    # Rough size of a plain-text label: average character width times the longest line.
    param([string]$Text, [double]$CharWidth, [double]$LineHeight)
    $lines = @(([string]$Text) -split "`n")
    $longest = 0
    foreach ($l in $lines) { if ($l.Length -gt $longest) { $longest = $l.Length } }
    return @{ W = $longest * $CharWidth; H = $lines.Count * $LineHeight }
}

function Measure-Node {
    # Smallest size that fits the node's text.
    param($Node, [bool]$LabelBelow)
    switch ($Node.Kind) {
        'Start' { return @{ W = 60.0; H = 60.0 } }
        'Card' {
            $title = Get-TextSize $Node.Label 7.5 16
            $w = $title.W + 40
            foreach ($r in $Node.Rows) {
                $t = Get-TextSize $r.Text 6.6 14
                if ($t.W + 36 -gt $w) { $w = $t.W + 36 }
            }
            if ($w -lt 160) { $w = 160 }
            $h = $script:CardHeader + $script:RowGap + $Node.Rows.Count * ($script:RowHeight + $script:RowGap) + 6
            return @{ W = $w; H = $h }
        }
        { $_ -eq 'Decision' -or $_ -eq 'Switch' } {
            if ($LabelBelow) { return @{ W = 70.0; H = 70.0 } }
            $t = Get-TextSize $Node.Label 7 16
            $w = [Math]::Max(110, $t.W * 1.5 + 30)
            $h = [Math]::Max(70, $t.H * 1.8 + 20)
            return @{ W = $w; H = $h }
        }
        default {
            $t = Get-TextSize $Node.Label 7 16
            return @{ W = [Math]::Max(120, $t.W + 30); H = [Math]::Max(44, $t.H + 22) }
        }
    }
}

function Test-HasStudioLayout {
    # Studio's layout is used only when every node (apart from the start marker) has a saved position.
    param($Graph)
    $count = 0
    foreach ($n in $Graph.Nodes) {
        if ($n.Kind -eq 'Start') { continue }
        $count++
        if ($null -eq $n.Studio) { return $false }
    }
    return ($count -gt 0)
}

function Get-Fraction {
    param([double]$Value, [double]$Origin, [double]$Size)
    if ($Size -le 0) { return 0.5 }
    $f = ($Value - $Origin) / $Size
    if ($f -lt 0) { $f = 0 }
    if ($f -gt 1) { $f = 1 }
    return [Math]::Round($f, 3)
}

function Set-StudioLayout {
    # Stretches Studio's whole picture (one factor across, one down) so boxes grow to fit their
    # text but keep their places, and Studio's connector routes stay straight and still line up.
    param($Graph, [double]$Left, [double]$Top)
    $nodes = $Graph.Nodes
    $byKey = @{}
    foreach ($n in $nodes) { $byKey[$n.Key] = $n }

    # A start marker without a saved position goes to the left of the node it points at.
    $start = $byKey['start']
    if ($null -ne $start -and $null -eq $start.Studio) {
        foreach ($e in $Graph.Edges) {
            if ($e.From -eq 'start' -and $null -ne $byKey[$e.To].Studio) {
                $t = $byKey[$e.To].Studio
                $start.Studio = @{ X = $t.X - 110; Y = $t.Y + $t.H / 2 - 30; W = 60.0; H = 60.0 }
            }
        }
        if ($null -eq $start.Studio) { $start.Studio = @{ X = 0.0; Y = 0.0; W = 60.0; H = 60.0 } }
        foreach ($e in $Graph.Edges) { if ($e.From -eq 'start') { $e.StudioPoints = $null } }
    }

    $sx = 1.0
    $sy = 1.0
    foreach ($n in $nodes) {
        if ($n.Kind -ne 'Box' -and $n.Kind -ne 'Card') { continue }
        $need = Measure-Node $n $true
        $sx = [Math]::Max($sx, $need.W / $n.Studio.W)
        $sy = [Math]::Max($sy, $need.H / $n.Studio.H)
    }
    $sx = [Math]::Min([Math]::Ceiling($sx * 20) / 20, 4.0)
    $sy = [Math]::Min([Math]::Ceiling($sy * 20) / 20, 4.0)

    $minX = [double]::MaxValue; $minY = [double]::MaxValue
    foreach ($n in $nodes) {
        $minX = [Math]::Min($minX, $n.Studio.X)
        $minY = [Math]::Min($minY, $n.Studio.Y)
    }
    foreach ($e in $Graph.Edges) {
        if ($null -eq $e.StudioPoints) { continue }
        foreach ($p in $e.StudioPoints) {
            $minX = [Math]::Min($minX, $p[0])
            $minY = [Math]::Min($minY, $p[1])
        }
    }
    $offsetX = $Left - $minX * $sx
    $offsetY = $Top - $minY * $sy

    foreach ($n in $nodes) {
        $n.X = $n.Studio.X * $sx + $offsetX
        $n.Y = $n.Studio.Y * $sy + $offsetY
        $n.W = $n.Studio.W * $sx
        $n.H = $n.Studio.H * $sy
        if ($n.Kind -eq 'Start') {
            # Studio's start marker includes its label; draw a circle centred in the same place.
            $d = [Math]::Min($n.W, $n.H)
            $n.X = $n.X + ($n.W - $d) / 2
            $n.Y = $n.Y + ($n.H - $d) / 2
            $n.W = $d
            $n.H = $d
        }
        if ($n.Kind -eq 'Decision' -or $n.Kind -eq 'Switch') { $n.LabelSide = 'Below' }
    }

    foreach ($e in $Graph.Edges) {
        if ($null -eq $e.StudioPoints) {
            $e.Style = $script:Style.Edge + 'edgeStyle=orthogonalEdgeStyle;'
            continue
        }
        $src = $byKey[$e.From].Studio
        $dst = $byKey[$e.To].Studio
        $first = $e.StudioPoints[0]
        $last = $e.StudioPoints[$e.StudioPoints.Count - 1]
        $style = $script:Style.Edge + 'edgeStyle=none;'
        $style += 'exitX=' + (Format-Number (Get-Fraction $first[0] $src.X $src.W)) + ';exitY=' + (Format-Number (Get-Fraction $first[1] $src.Y $src.H)) + ';exitDx=0;exitDy=0;'
        $style += 'entryX=' + (Format-Number (Get-Fraction $last[0] $dst.X $dst.W)) + ';entryY=' + (Format-Number (Get-Fraction $last[1] $dst.Y $dst.H)) + ';entryDx=0;entryDy=0;'
        $e.Style = $style
        $points = New-Object System.Collections.Generic.List[object]
        for ($k = 1; $k -lt $e.StudioPoints.Count - 1; $k++) {
            $p = $e.StudioPoints[$k]
            $points.Add(@(($p[0] * $sx + $offsetX), ($p[1] * $sy + $offsetY)))
        }
        $e.Points = $points
        $path = New-Object System.Collections.Generic.List[object]
        foreach ($p in $e.StudioPoints) { $path.Add(@(($p[0] * $sx + $offsetX), ($p[1] * $sy + $offsetY))) }
        $e.Path = $path
    }

    # A decision's text goes below the diamond, as in Studio. Where an arrow meets the diamond's
    # bottom point it would run straight through that text, so the text moves to the lower right.
    foreach ($n in $nodes) {
        if ($n.Kind -ne 'Decision' -and $n.Kind -ne 'Switch') { continue }
        $n.LabelSide = 'Below'
        foreach ($e in $Graph.Edges) {
            if ($null -eq $e.Path) { continue }
            $ends = @()
            if ($e.From -eq $n.Key) { $ends += , $e.Path[0] }
            if ($e.To -eq $n.Key) { $ends += , $e.Path[$e.Path.Count - 1] }
            foreach ($pt in $ends) {
                if ([Math]::Abs($pt[0] - ($n.X + $n.W / 2)) -le $n.W * 0.15 -and $pt[1] -ge $n.Y + $n.H * 0.9) { $n.LabelSide = 'BelowRight' }
            }
        }
    }
    Set-ClearLabelPlaces $Graph
    return @{ X = $sx; Y = $sy }
}

function Set-ClearLabelPlaces {
    # Studio layout only. draw.io puts an arrow's label halfway along it. Where Studio's routes run
    # close together, labels can land on each other, on a box or on a decision's text. Each label that
    # would is moved along its own arrow to the first clear place, trying points further and further
    # from the middle. Arrows and boxes stay where Studio put them, and a label already in a clear
    # place is left alone.
    param($Graph)
    $taken = New-Object System.Collections.Generic.List[object]
    foreach ($n in $Graph.Nodes) {
        $taken.Add(@($n.X, $n.Y, $n.W, $n.H))
        if (($n.Kind -eq 'Decision' -or $n.Kind -eq 'Switch') -and -not [string]::IsNullOrEmpty($n.Label)) {
            $t = Get-TextSize $n.Label 7 16
            if ($n.LabelSide -eq 'BelowRight') { $taken.Add(@(($n.X + $n.W), ($n.Y + $n.H), $t.W, $t.H)) }
            else { $taken.Add(@(($n.X + ($n.W - $t.W) / 2), ($n.Y + $n.H), $t.W, $t.H)) }
        }
    }
    $fractions = @(0.5, 0.42, 0.58, 0.34, 0.66, 0.26, 0.74, 0.18, 0.82)
    foreach ($e in $Graph.Edges) {
        if ([string]::IsNullOrEmpty($e.Label) -or $null -eq $e.Path -or $e.Path.Count -lt 2) { continue }
        $size = Get-TextSize $e.Label 6.6 14
        $w = $size.W + 6
        $h = $size.H + 2
        $total = Get-PolylineLength $e.Path
        if ($total -le 0) { continue }
        $best = $null
        $bestOverlap = [double]::MaxValue
        foreach ($f in $fractions) {
            # The point f of the way along the path.
            $want = $f * $total
            $cx = $e.Path[0][0]; $cy = $e.Path[0][1]
            for ($i = 1; $i -lt $e.Path.Count; $i++) {
                $a = $e.Path[$i - 1]; $b = $e.Path[$i]
                $len = Get-PolylineLength @($a, $b)
                if ($want -le $len -or $i -eq $e.Path.Count - 1) {
                    $k = 0.0
                    if ($len -gt 0) { $k = [Math]::Min(1.0, $want / $len) }
                    $cx = $a[0] + ($b[0] - $a[0]) * $k
                    $cy = $a[1] + ($b[1] - $a[1]) * $k
                    break
                }
                $want -= $len
            }
            $rect = @(($cx - $w / 2), ($cy - $h / 2), $w, $h)
            $overlap = 0.0
            foreach ($o in $taken) {
                $ox = [Math]::Min($rect[0] + $rect[2], $o[0] + $o[2]) - [Math]::Max($rect[0], $o[0])
                $oy = [Math]::Min($rect[1] + $rect[3], $o[1] + $o[3]) - [Math]::Max($rect[1], $o[1])
                if ($ox -gt 0 -and $oy -gt 0) { $overlap += $ox * $oy }
            }
            if ($overlap -lt $bestOverlap) { $bestOverlap = $overlap; $best = @{ F = $f; Rect = $rect } }
            if ($overlap -eq 0) { break }
        }
        if ($best.F -ne 0.5) { $e.LabelX = 2 * $best.F - 1 }
        $taken.Add($best.Rect)
    }
}

function Set-AutoLayout {
    # Simple layered layout, top to bottom. Layers come from the longest path from the start
    # (ignoring edges that loop back); nodes in a layer keep the order they were reached in.
    # MaxRowWidth above 0 turns on the compact form used for project maps (see below).
    param($Graph, [double]$Left, [double]$Top, [double]$GapX = 50, [double]$GapY = 70, [double]$MaxRowWidth = 0)
    $nodes = $Graph.Nodes
    $byKey = @{}
    $out = @{}
    foreach ($n in $nodes) {
        $byKey[$n.Key] = $n
        $out[$n.Key] = New-Object System.Collections.Generic.List[object]
        $size = Measure-Node $n $false
        $n.W = $size.W
        $n.H = $size.H
    }
    foreach ($e in $Graph.Edges) {
        $e.Style = $script:Style.Edge + 'edgeStyle=orthogonalEdgeStyle;'
        if ($byKey.ContainsKey($e.From) -and $byKey.ContainsKey($e.To)) { $out[$e.From].Add($e) }
    }

    # Depth-first search without recursion: discovery order, finishing order, and back edges.
    $visited = @{}
    $onStack = @{}
    $discovery = @{}
    $finished = New-Object System.Collections.Generic.List[string]
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Graph.StartKeys) { if ($byKey.ContainsKey($k)) { $roots.Add($k) } }
    foreach ($n in $nodes) { $roots.Add($n.Key) }
    foreach ($r in $roots) {
        if ($visited.ContainsKey($r)) { continue }
        $stack = New-Object System.Collections.Generic.List[object]
        $visited[$r] = $true; $onStack[$r] = $true; $discovery[$r] = $discovery.Count
        $stack.Add(@{ Key = $r; Index = 0 })
        while ($stack.Count -gt 0) {
            $frame = $stack[$stack.Count - 1]
            $outs = $out[$frame.Key]
            if ($frame.Index -lt $outs.Count) {
                $e = $outs[$frame.Index]
                $frame.Index++
                $v = $e.To
                if ($onStack.ContainsKey($v)) { $e.Back = $true }
                elseif (-not $visited.ContainsKey($v)) {
                    $visited[$v] = $true; $onStack[$v] = $true; $discovery[$v] = $discovery.Count
                    $stack.Add(@{ Key = $v; Index = 0 })
                }
            }
            else {
                $stack.RemoveAt($stack.Count - 1)
                $onStack.Remove($frame.Key)
                $finished.Add($frame.Key)
            }
        }
    }

    $layer = @{}
    foreach ($n in $nodes) { $layer[$n.Key] = 0 }
    for ($k = $finished.Count - 1; $k -ge 0; $k--) {
        $u = $finished[$k]
        foreach ($e in $out[$u]) {
            if ($e.Back) { continue }
            if ($layer[$e.To] -lt $layer[$u] + 1) { $layer[$e.To] = $layer[$u] + 1 }
        }
    }

    # Compact form, for project maps of large projects, where one layer can hold a dozen or more
    # workflows and the page grows several thousand pixels wide:
    #   1. boxes with no arrows at all go to rows of their own at the bottom;
    #   2. a layer wider than MaxRowWidth is wrapped onto several rows. Boxes that lead nowhere go
    #      first, so the boxes whose arrows carry on down sit in the last row, nearest their targets;
    #   3. an arrow that has to pass rows on its way down drops through a gap kept free in each of
    #      those rows, instead of going round the side. Arrows from one box share its gaps, like the
    #      trunk of an organisation chart. (A gap is an invisible node of no width; each arrow is
    #      laid out as a run of one-row hops and the hops are joined up again at the end.)
    # Everything stays a fixed function of the input, so the same file always gives the same page.
    $compact = ($MaxRowWidth -gt 0)
    if ($compact) {
        $linked = @{}
        $fin = @{}
        $fout = @{}
        foreach ($n in $nodes) { $fin[$n.Key] = 0; $fout[$n.Key] = 0 }
        foreach ($e in $Graph.Edges) {
            if (-not $byKey.ContainsKey($e.From) -or -not $byKey.ContainsKey($e.To)) { continue }
            $linked[$e.From] = $true
            $linked[$e.To] = $true
            if (-not $e.Back) { $fout[$e.From]++; $fin[$e.To]++ }
        }
        if ($linked.Count -gt 0) {
            $lowest = 0
            foreach ($n in $nodes) { if ($linked.ContainsKey($n.Key) -and $layer[$n.Key] -gt $lowest) { $lowest = $layer[$n.Key] } }
            foreach ($n in $nodes) { if (-not $linked.ContainsKey($n.Key)) { $layer[$n.Key] = $lowest + 1 } }
        }
        $deepest = 0
        foreach ($n in $nodes) { if ($layer[$n.Key] -gt $deepest) { $deepest = $layer[$n.Key] } }
        $newLayer = @{}
        $shift = 0
        for ($l = 0; $l -le $deepest; $l++) {
            $members = @($nodes | Where-Object { $layer[$_.Key] -eq $l } | Sort-Object { $discovery[$_.Key] })
            if ($members.Count -eq 0) { $shift--; continue }
            $width = 0.0
            foreach ($n in $members) { $width += $n.W + $GapX }
            $rowCount = [int][Math]::Ceiling($width / $MaxRowWidth)
            if ($rowCount -gt 1) {
                $members = @($members | Sort-Object { $fout[$_.Key] - $fin[$_.Key] }, { $discovery[$_.Key] })
            }
            else { $rowCount = 1 }
            $perRow = [int][Math]::Ceiling($members.Count / $rowCount)
            for ($i = 0; $i -lt $members.Count; $i++) {
                $newLayer[$members[$i].Key] = $l + $shift + [int][Math]::Floor($i / $perRow)
            }
            $shift += [int][Math]::Ceiling($members.Count / $perRow) - 1
        }
        foreach ($n in $nodes) { $layer[$n.Key] = $newLayer[$n.Key] }
    }

    # The arrows the router lays out: the graph's own, with long ones split into hops in compact form.
    $work = New-Object System.Collections.Generic.List[object]
    $chains = New-Object System.Collections.Generic.List[object]
    $allNodes = New-Object System.Collections.Generic.List[object]
    foreach ($n in $nodes) { $allNodes.Add($n) }
    $above = @{}       # gap key -> the box or gap directly above it
    $hopByKey = @{}
    foreach ($e in $Graph.Edges) {
        $long = ($compact -and $byKey.ContainsKey($e.From) -and $byKey.ContainsKey($e.To) -and -not $e.Back -and $layer[$e.To] -gt $layer[$e.From] + 1)
        if (-not $long) { $work.Add($e); continue }
        $hops = New-Object System.Collections.Generic.List[object]
        $prev = $e.From
        for ($l = $layer[$e.From] + 1; $l -lt $layer[$e.To]; $l++) {
            $gapKey = '|gap|' + $e.From + '|' + $l
            if (-not $byKey.ContainsKey($gapKey)) {
                $gap = New-Node $gapKey 'Gap' '' ''
                $byKey[$gapKey] = $gap
                $layer[$gapKey] = $l
                $above[$gapKey] = $prev
                $discovery[$gapKey] = $discovery.Count
                $allNodes.Add($gap)
                $hop = New-Edge $prev $gapKey ''
                $hopByKey[$gapKey] = $hop
                $work.Add($hop)
            }
            $hops.Add($hopByKey[$gapKey])
            $prev = $gapKey
        }
        $hop = New-Edge $prev $e.To $e.Label
        $work.Add($hop)
        $hops.Add($hop)
        $chains.Add(@{ Edge = $e; Hops = $hops })
    }
    $nodes = $allNodes

    $maxLayer = 0
    foreach ($n in $nodes) { if ($layer[$n.Key] -gt $maxLayer) { $maxLayer = $layer[$n.Key] } }
    # Group the nodes into layers in one pass; in each layer, keep the order they were reached in.
    # A gap goes at the same relative place across its row as the box or gap above it.
    $byLayer = @{}
    for ($l = 0; $l -le $maxLayer; $l++) { $byLayer[$l] = New-Object System.Collections.Generic.List[object] }
    foreach ($n in $nodes) { $byLayer[$layer[$n.Key]].Add($n) }
    $rows = New-Object System.Collections.Generic.List[object]
    $place = @{}
    for ($l = 0; $l -le $maxLayer; $l++) {
        $real = @($byLayer[$l] | Where-Object { $_.Kind -ne 'Gap' } | Sort-Object { $discovery[$_.Key] })
        $gaps = @($byLayer[$l] | Where-Object { $_.Kind -eq 'Gap' })
        $row = $real
        if ($gaps.Count -gt 0) {
            $items = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $real.Count; $i++) { $items.Add(@{ Node = $real[$i]; At = ($i + 0.5) / $real.Count; Tie = 0; Seq = $i }) }
            foreach ($g in $gaps) { $items.Add(@{ Node = $g; At = $place[$above[$g.Key]]; Tie = 1; Seq = $discovery[$g.Key] }) }
            $row = @($items | Sort-Object { $_.At }, { $_.Tie }, { $_.Seq } | ForEach-Object { $_.Node })
        }
        for ($i = 0; $i -lt $row.Count; $i++) { $place[$row[$i].Key] = ($i + 0.5) / $row.Count }
        $rows.Add($row)
    }

    # Across: each layer centred under the widest one.
    $maxWidth = 0.0
    foreach ($row in $rows) {
        $w = 0.0
        foreach ($n in $row) { $w += $n.W }
        if ($row.Count -gt 1) { $w += $GapX * ($row.Count - 1) }
        if ($w -gt $maxWidth) { $maxWidth = $w }
    }
    foreach ($row in $rows) {
        if ($row.Count -eq 0) { continue }
        $w = 0.0
        foreach ($n in $row) { $w += $n.W }
        $w += $GapX * ($row.Count - 1)
        $x = $Left + ($maxWidth - $w) / 2
        foreach ($n in $row) { $n.X = $x; $x += $n.W + $GapX }
    }

    # Every arrow gets a fixed path through the gaps between layers, so no arrow crosses a box:
    #   Down   to the next layer: down out of the source, across, and down into the target;
    #   Right  further down: across to a lane on the right, down past the layers between, back in;
    #   Left   back up: across to a lane on the left, up, and back in from above;
    #   Self   to itself: a small loop on the right-hand side.
    # Each run across a gap gets a track of its own, and arrows arriving at one box enter at
    # different points, so no two arrows lie on top of each other. A label sits on the last stretch,
    # just above the box its arrow leads to; labels arriving at one box are stacked.
    $valid = New-Object System.Collections.Generic.List[object]
    foreach ($e in $work) {
        if (-not $byKey.ContainsKey($e.From) -or -not $byKey.ContainsKey($e.To)) { continue }
        $ls = $layer[$e.From]
        $lt = $layer[$e.To]
        if ($e.From -eq $e.To) { $e.Route = 'Self' }
        elseif (-not $e.Back -and $lt -eq $ls + 1) { $e.Route = 'Down' }
        elseif (-not $e.Back -and $lt -gt $ls + 1) { $e.Route = 'Right' }
        else { $e.Route = 'Left' }
        $e.Order = $valid.Count
        $valid.Add($e)
    }

    # Lanes on the left need room: move everything right to make it.
    $leftRoutes = 0
    foreach ($e in $valid) { if ($e.Route -eq 'Left') { $leftRoutes++ } }
    if ($leftRoutes -gt 0) { foreach ($n in $nodes) { $n.X += 30 + 14 * $leftRoutes } }

    $layerMinX = @{}
    $layerMaxR = @{}
    foreach ($n in $nodes) {
        $l = $layer[$n.Key]
        if (-not $layerMinX.ContainsKey($l) -or $n.X -lt $layerMinX[$l]) { $layerMinX[$l] = $n.X }
        if (-not $layerMaxR.ContainsKey($l) -or $n.X + $n.W -gt $layerMaxR[$l]) { $layerMaxR[$l] = $n.X + $n.W }
    }
    $rightLane = 0
    $leftLane = 0
    foreach ($e in $valid) {
        if ($e.Route -ne 'Right' -and $e.Route -ne 'Left') { continue }
        $lo = [Math]::Min($layer[$e.From], $layer[$e.To])
        $hi = [Math]::Max($layer[$e.From], $layer[$e.To])
        if ($e.Route -eq 'Right') {
            $xr = [double]::MinValue
            for ($l = $lo; $l -le $hi; $l++) { $xr = [Math]::Max($xr, $layerMaxR[$l]) }
            $e.LaneX = $xr + 30 + 14 * $rightLane
            $rightLane++
        }
        else {
            $xl = [double]::MaxValue
            for ($l = $lo; $l -le $hi; $l++) { $xl = [Math]::Min($xl, $layerMinX[$l]) }
            $e.LaneX = $xl - 30 - 14 * $leftLane
            $leftLane++
        }
    }

    # Where each arrow enters its target. Diamonds, circles and the like are entered at the top point;
    # boxes are entered at evenly spaced points along the top, ordered by where the arrows come from.
    $incoming = @{}
    foreach ($n in $nodes) { $incoming[$n.Key] = New-Object System.Collections.Generic.List[object] }
    foreach ($e in $valid) {
        if ($e.Route -eq 'Self') { continue }
        if ($e.Route -eq 'Down') { $e.ApproachX = $byKey[$e.From].X + $byKey[$e.From].W / 2 } else { $e.ApproachX = $e.LaneX }
        $incoming[$e.To].Add($e)
    }
    $labelSlots = @{}
    for ($l = 0; $l -le $maxLayer; $l++) { $labelSlots[$l] = 0 }
    foreach ($n in $nodes) {
        $list = @($incoming[$n.Key] | Sort-Object { $_.ApproachX }, { $_.Order })
        $pointed = ($n.Kind -eq 'Start' -or $n.Kind -eq 'Decision' -or $n.Kind -eq 'Switch')
        $slot = 0
        for ($i = 0; $i -lt $list.Count; $i++) {
            $e = $list[$i]
            if ($pointed) { $e.EntryFrac = 0.5 } else { $e.EntryFrac = ($i + 1) / ($list.Count + 1) }
            $e.LabelSlot = $slot
            if (-not [string]::IsNullOrEmpty($e.Label)) { $slot++ }
        }
        if ($slot -gt $labelSlots[$layer[$n.Key]]) { $labelSlots[$layer[$n.Key]] = $slot }
    }

    # Tracks across each gap. Gap g lies below layer g; gap -1 is above layer 0. Arrows leaving a
    # layer get the upper tracks, arrows arriving at the next layer the lower ones.
    $tracks = @{}
    for ($g = -1; $g -le $maxLayer; $g++) { $tracks[$g] = 0 }
    $sourceTrack = @{}
    foreach ($e in $valid) {
        $g = $layer[$e.From]
        if ($e.Route -eq 'Down') {
            if (-not $sourceTrack.ContainsKey($e.From)) { $sourceTrack[$e.From] = $tracks[$g]; $tracks[$g]++ }
            $e.LeaveTrack = $sourceTrack[$e.From]
        }
        elseif ($e.Route -ne 'Self') {
            $e.LeaveTrack = $tracks[$g]
            $tracks[$g]++
        }
    }
    foreach ($e in $valid) {
        if ($e.Route -ne 'Right' -and $e.Route -ne 'Left') { continue }
        $g = $layer[$e.To] - 1
        $e.EnterTrack = $tracks[$g]
        $tracks[$g]++
    }

    # Down: gaps tall enough for their tracks plus the stacked labels above the next layer.
    $trackStep = 14.0
    $labelStep = 20.0
    $gapHeight = @{}
    for ($g = -1; $g -le $maxLayer; $g++) {
        $room = 0.0
        if ($g + 1 -le $maxLayer -and $labelSlots[$g + 1] -gt 0) { $room = $labelStep * $labelSlots[$g + 1] + 14 }
        $needed = $trackStep * ($tracks[$g] + 1) + $room
        if ($g -eq -1 -or $g -eq $maxLayer) {
            if ($tracks[$g] -eq 0) { $gapHeight[$g] = 0.0 } else { $gapHeight[$g] = $needed }
        }
        else {
            $gapHeight[$g] = [Math]::Max($GapY, $needed)
        }
    }
    $layerBottom = @{}
    $y = $Top + $gapHeight[-1]
    for ($l = 0; $l -le $maxLayer; $l++) {
        $row = $rows[$l]
        $h = 0.0
        foreach ($n in $row) { if ($n.H -gt $h) { $h = $n.H } }
        foreach ($n in $row) { $n.Y = $y + ($h - $n.H) / 2 }
        $layerBottom[$l] = $y + $h
        $y += $h + $gapHeight[$l]
    }

    # The paths themselves.
    foreach ($e in $valid) {
        $s = $byKey[$e.From]
        $t = $byKey[$e.To]
        $sx = $s.X + $s.W / 2
        $sBottom = $s.Y + $s.H
        if ($e.Route -eq 'Self') {
            $loops = @($valid | Where-Object { $_.Route -eq 'Self' -and $_.From -eq $e.From })
            $i = [Array]::IndexOf($loops, $e)
            $k = $loops.Count
            $rx = $s.X + $s.W
            if ($s.Kind -eq 'Start' -or $s.Kind -eq 'Decision' -or $s.Kind -eq 'Switch') {
                # Out of the right point, round, and back in at the top point.
                $d = 24 + 14 * $i
                $above = $s.Y - 12 - 8 * $i
                $cy = $s.Y + $s.H / 2
                $poly = @(@($rx, $cy), @(($rx + $d), $cy), @(($rx + $d), $above), @($sx, $above), @($sx, $s.Y))
                $constraint = 'exitX=1;exitY=0.5;entryX=0.5;entryY=0;'
            }
            else {
                # Each loop on its own band of the right-hand side.
                $a = ($i + 0.3) / $k
                $b = ($i + 0.7) / $k
                $d = 24.0
                $poly = @(@($rx, ($s.Y + $s.H * $a)), @(($rx + $d), ($s.Y + $s.H * $a)), @(($rx + $d), ($s.Y + $s.H * $b)), @($rx, ($s.Y + $s.H * $b)))
                $constraint = 'exitX=1;exitY=' + (Format-Number $a) + ';entryX=1;entryY=' + (Format-Number $b) + ';'
            }
            $labelAt = (Get-PolylineLength @($poly[0], $poly[1])) + (Get-PolylineLength @($poly[1], $poly[2])) / 2
            # Put the label outside the loop, so a wide label does not cover the box.
            $e.LabelDx = (Get-TextSize $e.Label 6.6 14).W / 2 + 6
        }
        else {
            $ex = $t.X + $t.W * $e.EntryFrac
            $leaveY = $layerBottom[$layer[$e.From]] + $trackStep * ($e.LeaveTrack + 1)
            if ($e.Route -eq 'Down') {
                $poly = @(@($sx, $sBottom), @($sx, $leaveY), @($ex, $leaveY), @($ex, $t.Y))
            }
            else {
                $g = $layer[$e.To] - 1
                $gapTop = $Top
                if ($g -ge 0) { $gapTop = $layerBottom[$g] }
                $enterY = $gapTop + $trackStep * ($e.EnterTrack + 1)
                $poly = @(@($sx, $sBottom), @($sx, $leaveY), @($e.LaneX, $leaveY), @($e.LaneX, $enterY), @($ex, $enterY), @($ex, $t.Y))
            }
            $constraint = 'exitX=0.5;exitY=1;entryX=' + (Format-Number $e.EntryFrac) + ';entryY=0;'
            # On the last stretch, a little above the target; further up for each label stacked below it.
            $last = $poly.Count - 1
            $finalLength = Get-PolylineLength @($poly[$last - 1], $poly[$last])
            $fromEnd = [Math]::Min(18 + $labelStep * $e.LabelSlot, [Math]::Max(0.0, $finalLength - 4))
            $labelAt = (Get-PolylineLength $poly) - $fromEnd
        }
        # Drop repeated points (an arrow straight down has no corners).
        $clean = New-Object System.Collections.Generic.List[object]
        foreach ($pt in $poly) {
            if ($clean.Count -gt 0) {
                $prev = $clean[$clean.Count - 1]
                if ([Math]::Abs($prev[0] - $pt[0]) -lt 0.01 -and [Math]::Abs($prev[1] - $pt[1]) -lt 0.01) { continue }
            }
            $clean.Add($pt)
        }
        $poly = $clean.ToArray()
        $e.Style = $script:Style.Edge + 'edgeStyle=none;' + $constraint + 'exitDx=0;exitDy=0;entryDx=0;entryDy=0;'
        $points = New-Object System.Collections.Generic.List[object]
        for ($p = 1; $p -lt $poly.Count - 1; $p++) { $points.Add($poly[$p]) }
        $e.Points = $points
        $total = Get-PolylineLength $poly
        if (-not [string]::IsNullOrEmpty($e.Label) -and $total -gt 0) {
            # draw.io places a label at (x + 1) / 2 of the way along the arrow, with x from -1 to 1.
            $e.LabelX = 2 * $labelAt / $total - 1
        }
        $e.Poly = $poly
        $e.LabelAt = $labelAt
    }

    # Compact form: join each long arrow's hops into one path. A point where two hops meet, or where
    # the path just carries straight on, is dropped.
    foreach ($c in $chains) {
        $e = $c.Edge
        $joined = New-Object System.Collections.Generic.List[object]
        $before = 0.0
        for ($h = 0; $h -lt $c.Hops.Count; $h++) {
            $hop = $c.Hops[$h]
            if ($h -lt $c.Hops.Count - 1) { $before += Get-PolylineLength $hop.Poly }
            foreach ($pt in $hop.Poly) {
                if ($joined.Count -gt 0) {
                    $prev = $joined[$joined.Count - 1]
                    if ([Math]::Abs($prev[0] - $pt[0]) -lt 0.01 -and [Math]::Abs($prev[1] - $pt[1]) -lt 0.01) { continue }
                }
                if ($joined.Count -ge 2) {
                    $a = $joined[$joined.Count - 2]
                    $b = $joined[$joined.Count - 1]
                    $straight = (([Math]::Abs($a[0] - $b[0]) -lt 0.01 -and [Math]::Abs($b[0] - $pt[0]) -lt 0.01) -or ([Math]::Abs($a[1] - $b[1]) -lt 0.01 -and [Math]::Abs($b[1] - $pt[1]) -lt 0.01))
                    if ($straight) { $joined.RemoveAt($joined.Count - 1) }
                }
                $joined.Add($pt)
            }
        }
        $last = $c.Hops[$c.Hops.Count - 1]
        $e.Route = 'Down'
        $e.Style = $script:Style.Edge + 'edgeStyle=none;exitX=0.5;exitY=1;entryX=' + (Format-Number $last.EntryFrac) + ';entryY=0;exitDx=0;exitDy=0;entryDx=0;entryDy=0;'
        $points = New-Object System.Collections.Generic.List[object]
        for ($p = 1; $p -lt $joined.Count - 1; $p++) { $points.Add($joined[$p]) }
        $e.Points = $points
        $total = Get-PolylineLength $joined
        if (-not [string]::IsNullOrEmpty($e.Label) -and $total -gt 0) { $e.LabelX = 2 * ($before + $last.LabelAt) / $total - 1 }
    }
}

# ---------------------------------------------------------------------------
# draw.io output
# ---------------------------------------------------------------------------

function Format-Count {
    param([int]$Count, [string]$Singular, [string]$Plural)
    if ($Count -eq 1) { return '1 ' + $Singular }
    return '' + $Count + ' ' + $Plural
}

function Format-Number {
    # Rounds to 2 decimal places so that Windows PowerShell 5.1 (.NET Framework) and PowerShell 7 (.NET)
    # write the same digits. The two runtimes round a double such as 0.465 differently, and also turn
    # doubles into decimals differently, so go through the 15-digit text form (which both write the same)
    # and round that as a decimal.
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return '0' }
    if ([Math]::Abs($Value) -ge 1e15) { return $Value.ToString('0', $script:Invariant) }
    $exact = [decimal]::Parse($Value.ToString('G15', $script:Invariant), [System.Globalization.NumberStyles]::Float, $script:Invariant)
    $rounded = [Math]::Round($exact, 2, [System.MidpointRounding]::AwayFromZero)
    return $rounded.ToString('0.##', $script:Invariant)
}

function New-Page {
    param([string]$Id, [string]$Name)
    return @{ Id = $Id; Name = $Name; Cells = (New-Object System.Collections.Generic.List[object]); NextId = 2 }
}

function New-CellId {
    param($Page)
    $id = $Page.Id + '-' + $Page.NextId
    $Page.NextId++
    return $id
}

function Add-Vertex {
    param($Page, [string]$Label, [string]$Style, [double]$X, [double]$Y, [double]$W, [double]$H, [string]$Parent = '1', [string]$Link = $null)
    $id = New-CellId $Page
    $Page.Cells.Add(@{ Id = $id; Edge = $false; Label = $Label; Style = $Style; Parent = $Parent; X = $X; Y = $Y; W = $W; H = $H; Link = $Link; Source = $null; Target = $null; Points = $null; LabelX = $null; LabelDx = 0.0 })
    return $id
}

function Add-EdgeCell {
    param($Page, [string]$Label, [string]$Style, [string]$Source, [string]$Target, $Points, $LabelX = $null, [double]$LabelDx = 0, [string]$Parent = '1')
    $id = New-CellId $Page
    $Page.Cells.Add(@{ Id = $id; Edge = $true; Label = $Label; Style = $Style; Parent = $Parent; X = 0; Y = 0; W = 0; H = 0; Link = $null; Source = $Source; Target = $Target; Points = $Points; LabelX = $LabelX; LabelDx = $LabelDx })
    return $id
}

function Add-GraphToPage {
    param($Page, $Graph)
    $cellIds = @{}
    foreach ($n in $Graph.Nodes) {
        $id = Add-Vertex $Page $n.Label (Get-NodeStyle $n) $n.X $n.Y $n.W $n.H '1' $n.Link
        $cellIds[$n.Key] = $id
        if ($n.Kind -eq 'Card') {
            $y = $script:CardHeader + $script:RowGap
            foreach ($r in $n.Rows) {
                [void](Add-Vertex $Page $r.Text (Get-RowStyle $r) 8 $y ($n.W - 16) $script:RowHeight $id $r.Link)
                $y += $script:RowHeight + $script:RowGap
            }
        }
    }
    foreach ($e in $Graph.Edges) {
        if (-not $cellIds.ContainsKey($e.From) -or -not $cellIds.ContainsKey($e.To)) { continue }
        [void](Add-EdgeCell $Page $e.Label $e.Style $cellIds[$e.From] $cellIds[$e.To] $e.Points $e.LabelX $e.LabelDx)
    }
}

function Add-PageHeader {
    param($Page, [string]$Title, $Context)
    [void](Add-Vertex $Page $Title $script:Style.Title 40 16 ((Get-TextSize $Title 10 20).W + 20) 30)
    if ($Context.MapPageId) {
        [void](Add-Vertex $Page 'Back to project map' $script:Style.BackLink 40 44 160 20 '1' ('data:page/id,' + $Context.MapPageId))
    }
}

function Write-DrawioFile {
    param($Pages, [string]$FilePath)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Entitize
    $w = [System.Xml.XmlWriter]::Create($FilePath, $settings)
    try {
        $w.WriteStartElement('mxfile')
        $w.WriteAttributeString('host', 'uipath-to-drawio')
        foreach ($page in $Pages) {
            $w.WriteStartElement('diagram')
            $w.WriteAttributeString('id', $page.Id)
            $w.WriteAttributeString('name', (ConvertTo-XmlSafeText $page.Name))
            $w.WriteStartElement('mxGraphModel')
            foreach ($pair in @(@('dx', '1200'), @('dy', '800'), @('grid', '1'), @('gridSize', '10'), @('guides', '1'),
                    @('tooltips', '1'), @('connect', '1'), @('arrows', '1'), @('fold', '1'), @('page', '1'),
                    @('pageScale', '1'), @('pageWidth', '1169'), @('pageHeight', '827'), @('math', '0'), @('shadow', '0'))) {
                $w.WriteAttributeString($pair[0], $pair[1])
            }
            $w.WriteStartElement('root')
            $w.WriteStartElement('mxCell'); $w.WriteAttributeString('id', '0'); $w.WriteEndElement()
            $w.WriteStartElement('mxCell'); $w.WriteAttributeString('id', '1'); $w.WriteAttributeString('parent', '0'); $w.WriteEndElement()
            foreach ($c in $page.Cells) {
                $linked = -not [string]::IsNullOrEmpty($c.Link)
                if ($linked) {
                    # A link lives on a UserObject wrapper; the label moves there too.
                    $w.WriteStartElement('UserObject')
                    $w.WriteAttributeString('label', (ConvertTo-XmlSafeText ([string]$c.Label)))
                    $w.WriteAttributeString('link', (ConvertTo-XmlSafeText $c.Link))
                    $w.WriteAttributeString('id', $c.Id)
                    $w.WriteStartElement('mxCell')
                }
                else {
                    $w.WriteStartElement('mxCell')
                    $w.WriteAttributeString('id', $c.Id)
                    $w.WriteAttributeString('value', (ConvertTo-XmlSafeText ([string]$c.Label)))
                }
                $w.WriteAttributeString('style', $c.Style)
                if ($c.Edge) {
                    $w.WriteAttributeString('edge', '1')
                    $w.WriteAttributeString('parent', $c.Parent)
                    $w.WriteAttributeString('source', $c.Source)
                    $w.WriteAttributeString('target', $c.Target)
                    $w.WriteStartElement('mxGeometry')
                    if ($null -ne $c.LabelX) { $w.WriteAttributeString('x', (Format-Number $c.LabelX)) }
                    $w.WriteAttributeString('relative', '1')
                    $w.WriteAttributeString('as', 'geometry')
                    if ($null -ne $c.Points -and $c.Points.Count -gt 0) {
                        $w.WriteStartElement('Array')
                        $w.WriteAttributeString('as', 'points')
                        foreach ($p in $c.Points) {
                            $w.WriteStartElement('mxPoint')
                            $w.WriteAttributeString('x', (Format-Number $p[0]))
                            $w.WriteAttributeString('y', (Format-Number $p[1]))
                            $w.WriteEndElement()
                        }
                        $w.WriteEndElement()
                    }
                    if ($c.LabelDx -ne 0) {
                        $w.WriteStartElement('mxPoint')
                        $w.WriteAttributeString('x', (Format-Number $c.LabelDx))
                        $w.WriteAttributeString('y', '0')
                        $w.WriteAttributeString('as', 'offset')
                        $w.WriteEndElement()
                    }
                    $w.WriteEndElement()
                }
                else {
                    $w.WriteAttributeString('vertex', '1')
                    $w.WriteAttributeString('parent', $c.Parent)
                    $w.WriteStartElement('mxGeometry')
                    $w.WriteAttributeString('x', (Format-Number $c.X))
                    $w.WriteAttributeString('y', (Format-Number $c.Y))
                    $w.WriteAttributeString('width', (Format-Number $c.W))
                    $w.WriteAttributeString('height', (Format-Number $c.H))
                    $w.WriteAttributeString('as', 'geometry')
                    $w.WriteEndElement()
                }
                $w.WriteEndElement()
                if ($linked) { $w.WriteEndElement() }
            }
            $w.WriteEndElement() # root
            $w.WriteEndElement() # mxGraphModel
            $w.WriteEndElement() # diagram
        }
        $w.WriteEndElement() # mxfile
    }
    finally {
        $w.Close()
    }
}

# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

function New-WorkflowPage {
    param($Workflow, [string]$PageId, $Context)
    $page = New-Page $PageId $Workflow.Rel
    Add-PageHeader $page ($Workflow.Rel + '  (' + $Workflow.KindLabel + ')') $Context
    $top = 70.0
    $left = 40.0

    if ($Workflow.Error) {
        [void](Add-Vertex $page ("This file could not be read.`nSee the conversion report.") $script:Style.BrokenWorkflow $left $top 260 60)
        $Workflow.Summary = 'could not be read'
        return $page
    }
    if ($Workflow.Kind -eq 'NotWorkflow') {
        $text = "This file is not a UiPath workflow.`nIts top element is <" + $Workflow.TopElement + '>, not <Activity>.'
        [void](Add-Vertex $page $text $script:Style.Unknown $left $top 320 60)
        $Workflow.Summary = 'not a workflow (top element <' + $Workflow.TopElement + '>); nothing drawn.'
        return $page
    }

    $Context.ViewStateMap = New-ViewStateMap $Workflow.Doc
    if ($Workflow.Kind -eq 'StateMachine' -or $Workflow.Kind -eq 'Flowchart') {
        if ($Workflow.Kind -eq 'StateMachine') { $graph = Get-StateMachineGraph $Workflow $Workflow.Root $Context }
        else { $graph = Get-FlowchartGraph $Workflow $Workflow.Root $Context }
        if (Test-HasStudioLayout $graph) {
            $scale = Set-StudioLayout $graph $left $top
            $layoutText = 'layout saved in Studio'
            if ($scale.X -gt 1 -or $scale.Y -gt 1) {
                $layoutText += ' (stretched x' + (Format-Number $scale.X) + ' across and x' + (Format-Number $scale.Y) + ' down to fit the text)'
            }
        }
        else {
            Set-AutoLayout $graph $left $top
            $layoutText = 'no saved layout for every element, so laid out automatically'
        }
        Add-GraphToPage $page $graph
        # A state machine draws none of the activities inside its states; a flowchart draws each step's own activity.
        $drawnActivities = 0
        if ($graph.ContainsKey('DrawnActivities')) { $drawnActivities = $graph.DrawnActivities }
        $Workflow.NotDrawn = [Math]::Max(0, $Workflow.ActivityCount - $drawnActivities)
        $Workflow.Summary = $Workflow.KindLabel + ': ' + $graph.Summary + '. Layout: ' + $layoutText + '.'
        foreach ($w in $graph.Warnings) { $Context.Warnings.Add($Workflow.Rel + ': ' + $w) }
        return $page
    }

    if ($Workflow.Kind -eq 'Sequence') {
        $invokeByElement = New-Object 'System.Collections.Generic.Dictionary[object,object]'
        foreach ($inv in $Workflow.Invokes) { $invokeByElement[$inv.Element] = $inv }
        $root = Get-SequenceItem $Workflow.Root 1 $Context $invokeByElement
        Set-SequenceLayout $root
        $root.X = $left
        $root.Y = $top
        [void](Add-SequenceItem $page $root '1')
        $stats = @{ Drawn = 0; Sequences = 0; Boxes = 0; Collapsed = 0; Inside = 0; Kinds = @{} }
        if ($root.Shape -eq 'Frame') { Get-SequenceStats $root $stats }
        $Workflow.NotDrawn = [Math]::Max(0, $Workflow.ActivityCount - $stats.Drawn)
        $text = 'sequence: ' + (Format-Count ($stats.Boxes + $stats.Collapsed + $stats.Sequences) 'step' 'steps') + ' drawn top to bottom'
        if ($stats.Sequences -gt 0) { $text += ', including ' + (Format-Count $stats.Sequences 'nested sequence' 'nested sequences') }
        if ($stats.Collapsed -gt 0) {
            $kinds = @($stats.Kinds.Keys | Sort-Object | ForEach-Object { if ($stats.Kinds[$_] -gt 1) { $_ + ' x' + $stats.Kinds[$_] } else { $_ } })
            $text += '; ' + (Format-Count $stats.Collapsed 'activity' 'activities') + ' holding others not expanded (' + ($kinds -join ', ') + ')'
        }
        $Workflow.Summary = $text + '.'
        $Workflow.Collapsed = $stats.Collapsed
        return $page
    }

    # Anything else: a summary card listing the workflows the file invokes.
    $rootLabel = 'Empty workflow'
    if ($null -ne $Workflow.Root) { $rootLabel = Get-DisplayName $Workflow.Root $Workflow.Root.get_LocalName() }
    $node = New-Node 'root' 'Card' $rootLabel 'step' $Workflow.Root
    foreach ($inv in $Workflow.Invokes) { Add-UniqueRow $node (New-InvokeRow $inv $Context '') }
    if ($node.Rows.Count -eq 0) { $node.Rows.Add((New-Row 'Invokes no other workflows' 'plain' $null)) }
    $size = Measure-Node $node $false
    $node.X = $left; $node.Y = $top; $node.W = $size.W; $node.H = $size.H
    $graph = @{ Nodes = @($node); Edges = @() }
    Add-GraphToPage $page $graph
    $kind = 'workflow'
    if ($null -ne $Workflow.Root) { $kind = $Workflow.KindLabel }
    $note = 'Version 1 does not draw the steps inside a ' + $kind + '. This page lists the workflows it invokes.'
    [void](Add-Vertex $page $note $script:Style.Note $left ($top + $size.H + 16) 600 20)
    $Workflow.NotDrawn = $Workflow.ActivityCount
    $Workflow.Summary = $Workflow.KindLabel + ': summary page only (' + (Format-Count $Workflow.Invokes.Count 'invoked workflow' 'invoked workflows') + ' listed).'
    return $page
}

function New-ProjectMapPage {
    param($Workflows, [string]$PageId, [string]$ProjectName, $Context, [bool]$LinkPages)
    $page = New-Page $PageId 'Project map'
    [void](Add-Vertex $page ('Project map: ' + $ProjectName) $script:Style.Title 40 16 ((Get-TextSize ('Project map: ' + $ProjectName) 10 20).W + 20) 30)
    if ($LinkPages) {
        [void](Add-Vertex $page 'Each box links to its workflow''s page. Arrows show which workflow invokes which.' $script:Style.Note 40 44 600 20)
    }
    else {
        [void](Add-Vertex $page 'Arrows show which workflow invokes which.' $script:Style.Note 40 44 600 20)
    }

    $nodes = New-Object System.Collections.Generic.List[object]
    $edges = New-Object System.Collections.Generic.List[object]
    $nodeByKey = @{}
    $i = 0
    foreach ($wf in $Workflows) {
        $i++
        $role = 'workflow'
        if ($wf.IsMain) { $role = 'mainWorkflow' }
        if ($wf.Error) { $role = 'brokenWorkflow' }
        if ($wf.Kind -eq 'NotWorkflow') { $role = 'notWorkflow' }
        $node = New-Node ('w' + $i) 'Box' ($wf.Rel + "`n(" + $wf.KindLabel + ')') $role
        if ($LinkPages -and $Context.PageIds.ContainsKey($wf.Key)) { $node.Link = 'data:page/id,' + $Context.PageIds[$wf.Key] }
        $nodes.Add($node)
        $nodeByKey[$wf.Key] = $node
    }

    $edgeCount = @{}
    $edgeOrder = New-Object System.Collections.Generic.List[string]
    $incoming = @{}
    $c = 0
    foreach ($wf in $Workflows) {
        $from = $nodeByKey[$wf.Key]
        foreach ($inv in $wf.Invokes) {
            if ($inv.Computed) {
                $c++
                $label = '(file name set at run time)'
                if ($Context.IncludeDetails -and $inv.Raw) { $label = 'Run-time file name:' + "`n" + $inv.Raw }
                $target = New-Node ('c' + $c) 'Box' $label 'invokeComputed'
                $nodes.Add($target)
            }
            elseif ($inv.Outside) {
                # Keyed apart from the project's own workflows; "|" cannot appear in a file name.
                $outsideKey = 'outside|' + $inv.Key
                if (-not $nodeByKey.ContainsKey($outsideKey)) {
                    $label = (Get-OutsideText $inv $Context) + "`n(outside the project)"
                    $nodeByKey[$outsideKey] = New-Node ('o' + $nodes.Count) 'Box' $label 'invokeComputed'
                    $nodes.Add($nodeByKey[$outsideKey])
                }
                $target = $nodeByKey[$outsideKey]
            }
            elseif ($nodeByKey.ContainsKey($inv.Key)) {
                $target = $nodeByKey[$inv.Key]
            }
            else {
                $target = New-Node ('m' + $nodes.Count) 'Box' ($inv.Rel + "`n(missing)") 'invokeMissing'
                if ($inv.Exists) {
                    $target.Label = $inv.Rel + "`n(not converted)"
                    $target.Role = 'invokeComputed'
                }
                $nodes.Add($target)
                $nodeByKey[$inv.Key] = $target
            }
            $pair = $from.Key + '|' + $target.Key
            if ($edgeCount.ContainsKey($pair)) { $edgeCount[$pair]++ }
            else { $edgeCount[$pair] = 1; $edgeOrder.Add($pair) }
            $incoming[$target.Key] = $true
        }
    }
    foreach ($pair in $edgeOrder) {
        $parts = $pair.Split('|')
        $label = ''
        if ($edgeCount[$pair] -gt 1) { $label = 'x' + $edgeCount[$pair] }
        $edges.Add((New-Edge $parts[0] $parts[1] $label))
    }

    $startKeys = New-Object System.Collections.Generic.List[string]
    foreach ($wf in $Workflows) { if ($wf.IsMain) { $startKeys.Add($nodeByKey[$wf.Key].Key) } }
    foreach ($n in $nodes) { if (-not $incoming.ContainsKey($n.Key)) { $startKeys.Add($n.Key) } }
    $graph = @{ Nodes = $nodes; Edges = $edges; StartKeys = $startKeys }
    Set-AutoLayout $graph 40 90 40 60 -MaxRowWidth $script:MapRowWidth
    Add-GraphToPage $page $graph
    return $page
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

function Get-ReportText {
    param($Workflows, [string]$InputPath, $OutputFiles, $Context, [string]$ProjectName)
    $nl = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    function Add-Heading {
        param($Builder, [string]$Text)
        [void]$Builder.Append($nl + $Text + $nl + ('-' * $Text.Length) + $nl)
    }
    [void]$sb.Append('uipath-to-drawio conversion report' + $nl)
    [void]$sb.Append('==================================' + $nl + $nl)
    # Names only, never full paths: a report gets shared, and a full path names the user's account and folders.
    [void]$sb.Append('Input:    ' + (Split-Path -Leaf $InputPath) + $nl)
    if ($ProjectName) { [void]$sb.Append('Project:  ' + $ProjectName + $nl) }
    foreach ($f in $OutputFiles) { [void]$sb.Append('Output:   ' + (Split-Path -Leaf $f) + $nl) }
    [void]$sb.Append('Version:  ' + $script:ToolVersion + $nl)
    [void]$sb.Append('Created:  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm', $script:Invariant) + $nl)
    if ($Context.IncludeDetails) {
        [void]$sb.Append('Details:  included (conditions, expressions and run-time file names are shown)' + $nl)
    }
    else {
        [void]$sb.Append('Details:  left out. Use -IncludeDetails to add conditions, expressions and run-time file names.' + $nl)
    }

    Add-Heading $sb ('Workflows converted (' + $Workflows.Count + ')')
    foreach ($wf in $Workflows) {
        $mark = ''
        if ($wf.IsMain) { $mark = ' [main]' }
        $drawnText = ''
        if (-not $wf.Error -and $wf.Kind -ne 'NotWorkflow' -and $wf.Kind -ne 'Empty') {
            $drawnText = ' Activities drawn: ' + ($wf.ActivityCount - $wf.NotDrawn) + ' of ' + $wf.ActivityCount + '.'
        }
        [void]$sb.Append('  ' + $wf.Rel + $mark + ' - ' + $wf.Summary + $drawnText + $nl)
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $computed = New-Object System.Collections.Generic.List[string]
    $outside = New-Object System.Collections.Generic.List[string]
    $bySource = @{}     # "source|type" -> totals across all workflows
    $unread = New-Object System.Collections.Generic.List[string]
    $notDrawn = New-Object System.Collections.Generic.List[string]
    foreach ($wf in $Workflows) {
        if ($wf.Error) { $unread.Add('  ' + $wf.Rel + ': ' + $wf.Error) }
        foreach ($inv in $wf.Invokes) {
            if ($inv.Computed) {
                $line = '  ' + $wf.Rel + ': "' + $inv.DisplayName + '"'
                if ($Context.IncludeDetails) { $line += ' -> ' + $inv.Raw }
                $computed.Add($line)
            }
            elseif ($inv.Outside) {
                $line = '  ' + (Get-OutsideText $inv $Context) + ' - invoked from ' + $wf.Rel
                if (-not $outside.Contains($line)) { $outside.Add($line) }
            }
            elseif (-not $inv.Exists) {
                $line = '  ' + $inv.Rel + ' - invoked from ' + $wf.Rel
                if (-not $missing.Contains($line)) { $missing.Add($line) }
            }
        }
        foreach ($a in $wf.Activities.Values) {
            $key = $a.Source + '|' + $a.Type
            if (-not $bySource.ContainsKey($key)) { $bySource[$key] = @{ Source = $a.Source; Type = $a.Type; Packages = @{}; Files = New-Object System.Collections.Generic.List[string]; Count = 0 } }
            $bySource[$key].Count += $a.Count
            $bySource[$key].Packages[$a.Package] = $true
            if (-not $bySource[$key].Files.Contains($wf.Rel)) { $bySource[$key].Files.Add($wf.Rel) }
        }
        $activities = Format-Count $wf.NotDrawn 'activity' 'activities'
        if ($wf.Kind -eq 'Other') { $notDrawn.Add('  ' + $wf.Rel + ' (' + $wf.KindLabel + '): ' + $activities + ' not drawn; the page lists the workflows it invokes.') }
        if ($wf.Kind -eq 'StateMachine' -and $wf.NotDrawn -gt 0) { $notDrawn.Add('  ' + $wf.Rel + ' (state machine): ' + $activities + ' inside states not drawn; each state lists the workflows it invokes.') }
        if ($wf.Kind -eq 'Sequence' -and $wf.NotDrawn -gt 0) {
            $where = 'the ' + $wf.Collapsed + ' activities drawn as dashed boxes, which list the workflows invoked inside them.'
            if ($wf.Collapsed -eq 1) { $where = 'the activity drawn as a dashed box, which lists the workflows invoked inside it.' }
            $notDrawn.Add('  ' + $wf.Rel + ' (sequence): ' + $activities + ' not drawn; they are inside ' + $where)
        }
        if ($wf.Kind -eq 'Flowchart' -and $wf.NotDrawn -gt 0) { $notDrawn.Add('  ' + $wf.Rel + ' (flowchart): ' + $activities + ' inside steps not drawn; a step holding a sequence lists the workflows it invokes.') }
    }

    Add-Heading $sb ('Invoked workflows not found (' + $missing.Count + ')')
    if ($missing.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $missing) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb ('Invoked files outside the project folder (' + $outside.Count + ')')
    [void]$sb.Append('  These are not looked up, so they are never marked missing.')
    if (-not $Context.IncludeDetails) { [void]$sb.Append(' Only the file name is shown; use -IncludeDetails for the full path.') }
    [void]$sb.Append($nl)
    if ($outside.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $outside) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb ('File names set at run time, so not linked (' + $computed.Count + ')')
    if ($computed.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $computed) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb 'Activities by source'
    [void]$sb.Append('  Activities are grouped by the package they come from. The converter does not interpret what any' + $nl)
    [void]$sb.Append('  activity does. Counted: activities with a display name or a layout ID.' + $nl)
    $sourceNames = [ordered]@{ UiPath = 'UiPath packages'; WorkflowFoundation = 'Workflow Foundation (part of .NET)'; Other = 'Other libraries and packages' }
    foreach ($source in $sourceNames.Keys) {
        $entries = @($bySource.Values | Where-Object { $_.Source -eq $source } | Sort-Object @{ Expression = { -$_.Count } }, @{ Expression = { $_.Type } })
        $uses = 0
        foreach ($e in $entries) { $uses += $e.Count }
        [void]$sb.Append('  ' + $sourceNames[$source] + ': ' + (Format-Count $uses 'use' 'uses') + ' of ' + (Format-Count $entries.Count 'activity type' 'activity types') + $nl)
        if ($entries.Count -eq 0) { continue }
        if ($source -eq 'Other') {
            # Listed one by one: these come from the project's own libraries or from third-party packages,
            # and are the activities the converter knows least about.
            [void]$sb.Append('    From the project''s own libraries or third-party packages. Flowchart and sequence steps using them' + $nl)
            [void]$sb.Append('    are drawn as dashed boxes showing the activity type.' + $nl)
            foreach ($e in $entries) {
                $packages = (@($e.Packages.Keys) | Sort-Object) -join ', '
                # At most five file names, so a type used across a large project stays on one readable line.
                $files = @($e.Files)
                $where = ($files | Select-Object -First 5) -join ', '
                if ($files.Count -gt 5) { $where += ' and ' + ($files.Count - 5) + ' more' }
                [void]$sb.Append('    ' + $e.Type + ' (' + $packages + ') - ' + $e.Count + ', in ' + $where + $nl)
            }
        }
        else {
            # A compact list of every type and how often it is used, wrapped at about 100 characters.
            $line = '    '
            foreach ($e in $entries) {
                $item = $e.Type + ' (' + $e.Count + ')'
                if ($line.Length -gt 4 -and ($line.Length + $item.Length + 2) -gt 100) { [void]$sb.Append($line.TrimEnd(',', ' ') + $nl); $line = '    ' }
                $line += $item + ', '
            }
            [void]$sb.Append($line.TrimEnd(',', ' ') + $nl)
        }
    }

    Add-Heading $sb ('Not drawn in version 1')
    if ($notDrawn.Count -eq 0) { [void]$sb.Append('  Nothing' + $nl) } else { foreach ($l in $notDrawn) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb ('Warnings (' + $Context.Warnings.Count + ')')
    if ($Context.Warnings.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $Context.Warnings) { [void]$sb.Append('  ' + $l + $nl) } }

    Add-Heading $sb ('Files that could not be read (' + $unread.Count + ')')
    if ($unread.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $unread) { [void]$sb.Append($l + $nl) } }

    $notWorkflows = @($Workflows | Where-Object { $_.Kind -eq 'NotWorkflow' })
    Add-Heading $sb ('Files that are not workflows (' + $notWorkflows.Count + ')')
    if ($notWorkflows.Count -eq 0) { [void]$sb.Append('  None' + $nl) }
    else { foreach ($wf in $notWorkflows) { [void]$sb.Append('  ' + $wf.Rel + ': top element is <' + $wf.TopElement + '>, not <Activity>' + $nl) } }

    Add-Heading $sb ('Folders skipped (' + $Context.SkippedFolders.Count + ')')
    if ($Context.SkippedFolders.Count -eq 0) { [void]$sb.Append('  None' + $nl) }
    else { foreach ($f in $Context.SkippedFolders) { [void]$sb.Append('  ' + $f.Rel + ': ' + $f.Reason + $nl) } }

    Add-Heading $sb ('Files that could not be written (' + $Context.WriteErrors.Count + ')')
    if ($Context.WriteErrors.Count -eq 0) { [void]$sb.Append('  None' + $nl) }
    else { foreach ($f in $Context.WriteErrors) { [void]$sb.Append('  ' + $f.Name + ': ' + $f.Reason + $nl) } }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Stop-WithError {
    # Ends the run with a plain one-line message and exit code 1, for problems the user can fix
    # (a wrong path, a locked file), instead of PowerShell's script-line error display.
    param([string]$Message)
    $Host.UI.WriteErrorLine($Message)
    exit 1
}

function Get-SafeFileName {
    # A name that is safe as a file name: no characters Windows rejects, and at most 80 characters,
    # so a deep folder path flattened into a name cannot push the full path past Windows' limit.
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { [string]$_ } }
    $safe = (-join $chars).Trim()
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80).TrimEnd(' ', '.') }
    $safe = $safe.TrimEnd('.')
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'diagram' }
    return $safe
}

function Get-WorkflowFiles {
    # Every .xaml file in the project folder and its subfolders. Skipped, without stopping:
    #   - folders whose name starts with "." (.local, .settings, .objects ...), which are Studio's own;
    #   - links to other folders (junctions, symbolic links), which can lead outside or loop;
    #   - folders that can't be read, which are listed in $Skipped with the reason.
    param([string]$Root, $Skipped)
    $found = New-Object System.Collections.Generic.List[object]
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        try {
            $items = @(Get-ChildItem -LiteralPath $dir -ErrorAction Stop)
        }
        catch {
            if ($dir -eq $Root) { Stop-WithError ('Cannot read the folder ' + $Root + ': ' + (Get-ReadErrorText $_.Exception)) }
            $Skipped.Add(@{ Rel = $dir.Substring($Root.TrimEnd('\').Length).TrimStart('\'); Reason = (Get-ReadErrorText $_.Exception) })
            continue
        }
        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                if ($item.Name.StartsWith('.')) { continue }
                # Only real links count. OneDrive and other cloud folders carry the same ReparsePoint
                # flag as links, so check the kind of link instead.
                if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
                    $Skipped.Add(@{ Rel = $item.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\'); Reason = 'a link to another folder, not followed' })
                    continue
                }
                $pending.Push($item.FullName)
            }
            elseif ($item.Extension -eq '.xaml' -and -not $item.Name.StartsWith('~')) {
                $found.Add($item)
            }
        }
    }
    return , $found
}

function ConvertTo-XmlSafeText {
    # Replaces characters XML cannot hold (control characters, lone surrogates) with U+FFFD, so a
    # stray character in, say, a project name cannot stop the diagram from being written.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text -notmatch '[\p{Cc}\p{Cs}\p{Cn}]') { return $Text }     # quick check; the loop below decides
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ([char]::IsHighSurrogate($c) -and $i + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
            [void]$sb.Append($c).Append($Text[$i + 1])
            $i++
        }
        elseif ([System.Xml.XmlConvert]::IsXmlChar($c)) { [void]$sb.Append($c) }
        else { [void]$sb.Append([char]0xFFFD) }
    }
    return $sb.ToString()
}

function Get-WriteErrorText {
    # Why a file could not be written, in plain words and without the local path.
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.UnauthorizedAccessException]) { return 'access denied (is the file read-only, or the folder protected?)' }
        if ($e -is [System.IO.PathTooLongException]) { return 'the full path is too long for Windows' }
        if ($e -is [System.IO.DirectoryNotFoundException]) { return 'the output folder is missing' }
        if ($e -is [System.IO.IOException]) { return 'the file is in use by another program, or the disk is full' }
        $e = $e.InnerException
    }
    return 'the file could not be written (' + $Exception.GetType().Name + ')'
}

function Save-File {
    # Writes a file safely: first to a temporary file in the same folder, then copied into place.
    # If anything fails, the temporary file is removed and any existing file is left as it was,
    # so a failure never leaves a half-written diagram behind. (File.Replace is not used: PowerShell
    # passes $null to .NET as an empty string, which Replace rejects.)
    param([string]$Target, [scriptblock]$Writer)
    $temp = Join-Path (Split-Path -Parent $Target) ('~' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        & $Writer $temp
        [System.IO.File]::Copy($temp, $Target, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
    }
}

function Find-ProjectRoot {
    # The nearest folder at or above the file's folder that has a project.json, else the file's folder.
    param([string]$StartFolder)
    $dir = New-Object System.IO.DirectoryInfo($StartFolder)
    while ($null -ne $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'project.json')) { return $dir.FullName }
        $dir = $dir.Parent
    }
    return $StartFolder
}

function Read-ProjectJson {
    param([string]$Root)
    $file = Join-Path $Root 'project.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-JsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return [string]$prop.Value
}

if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    Stop-WithError "Path not found: $Path"
}
$inputItem = Get-Item -LiteralPath $Path
$isProject = $inputItem.PSIsContainer
if (-not $isProject -and $inputItem.Extension -ne '.xaml') {
    Stop-WithError "Expected a .xaml file or a UiPath project folder: $Path"
}

if ($isProject) {
    $projectRoot = $inputItem.FullName.TrimEnd('\')
    if ($projectRoot.EndsWith(':')) { $projectRoot += '\' }     # a drive root keeps its backslash
}
else {
    $projectRoot = Find-ProjectRoot $inputItem.DirectoryName
}
$projectJson = Read-ProjectJson $projectRoot
$projectName = Get-JsonValue $projectJson 'name'
if ([string]::IsNullOrWhiteSpace($projectName)) { $projectName = Split-Path -Leaf $projectRoot }
$mainKey = Get-JsonValue $projectJson 'main'
if ([string]::IsNullOrWhiteSpace($mainKey)) { $mainKey = 'Main.xaml' }
$mainKey = ConvertTo-WorkflowKey ($mainKey.Replace('/', '\'))

if (-not $OutputPath) {
    if ($isProject) { $OutputPath = Split-Path -Parent $inputItem.FullName } else { $OutputPath = $inputItem.DirectoryName }
    if ([string]::IsNullOrEmpty($OutputPath)) { Stop-WithError 'Give -OutputPath when converting a whole drive: there is no folder next to it to write to.' }
}
if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath) }
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

$context = @{
    IncludeDetails = [bool]$IncludeDetails
    PageIds        = @{}
    MapPageId      = $null
    ViewStateMap   = @{}
    Warnings       = (New-Object System.Collections.Generic.List[string])
    SkippedFolders = (New-Object System.Collections.Generic.List[object])
    WriteErrors    = (New-Object System.Collections.Generic.List[object])
}

# Collect files.
$files = New-Object System.Collections.Generic.List[object]
if ($isProject) {
    foreach ($f in (Get-WorkflowFiles $projectRoot $context.SkippedFolders)) {
        $files.Add(@{ Full = $f.FullName; Rel = $f.FullName.Substring($projectRoot.TrimEnd('\').Length).TrimStart('\') })
    }
    foreach ($s in $context.SkippedFolders) { Write-Warning ('Skipped the folder ' + $s.Rel + ': ' + $s.Reason) }
}
else {
    $full = $inputItem.FullName
    $rootWithSlash = $projectRoot.TrimEnd('\') + '\'
    if ($full.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($rootWithSlash.Length) }
    else { $rel = $inputItem.Name }
    $files.Add(@{ Full = $full; Rel = $rel })
}
if ($files.Count -eq 0) { Stop-WithError "No .xaml files found in $Path" }

# Main workflow first, then the rest by path.
$workflows = New-Object System.Collections.Generic.List[object]
# Sort-Object follows the language settings, and Windows PowerShell 5.1 and PowerShell 7 order
# characters such as - _ \ differently. A plain character-by-character sort gives the same page
# order, and the same file names with -OnePerFile, everywhere.
$byRel = @{}
foreach ($f in $files) { $byRel[$f.Rel] = $f }
$rels = [string[]]@($files | ForEach-Object { $_.Rel })
[System.Array]::Sort($rels, [System.StringComparer]::OrdinalIgnoreCase)
$sorted = New-Object System.Collections.Generic.List[object]
foreach ($rel in $rels) { if ((ConvertTo-WorkflowKey $rel) -eq $mainKey) { $sorted.Add($byRel[$rel]) } }
foreach ($rel in $rels) { if ((ConvertTo-WorkflowKey $rel) -ne $mainKey) { $sorted.Add($byRel[$rel]) } }
foreach ($f in $sorted) {
    $wf = Read-Workflow $f.Full $f.Rel $projectRoot
    if ($wf.Key -eq $mainKey) { $wf.IsMain = $true }
    $workflows.Add($wf)
    if ($wf.Error) { Write-Warning ('Could not read ' + $f.Rel + ': ' + $wf.Error) }
}

$known = @{}
foreach ($wf in $workflows) { $known[$wf.Key] = $wf }
foreach ($wf in $workflows) {
    foreach ($inv in $wf.Invokes) {
        # Only a path inside the project folder is ever looked up. Paths that lead elsewhere
        # (another folder, another drive, a network share) are reported, never touched.
        if ($inv.Computed -or $inv.Outside) { continue }
        if ($known.ContainsKey($inv.Key)) { $inv.Exists = $true; continue }
        try {
            $inv.Exists = [bool](Test-Path -LiteralPath ($projectRoot.TrimEnd('\') + '\' + $inv.Rel) -PathType Leaf)
        }
        catch {
            $inv.Exists = $false    # a name the file system rejects cannot be an existing file
        }
    }
}

$outputFiles = New-Object System.Collections.Generic.List[string]
$baseName = Get-SafeFileName $projectName
if (-not $isProject) { $baseName = Get-SafeFileName ([System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name)) }

function Save-Diagram {
    # Writes one .drawio file. A failure is recorded for the report, and the other files still get written.
    param($Pages, [string]$Name)
    $target = Join-Path $OutputPath ($Name + '.drawio')
    try {
        Save-File $target { param($p) Write-DrawioFile $Pages $p }
        $outputFiles.Add($target)
    }
    catch {
        $reason = Get-WriteErrorText $_.Exception
        $context.WriteErrors.Add(@{ Name = ($Name + '.drawio'); Reason = $reason })
        Write-Warning ('Could not write ' + $Name + '.drawio: ' + $reason)
    }
}

if ($isProject -and -not $OnePerFile) {
    # One file: project map first, then a page per workflow, linked to each other.
    $context.MapPageId = 'map'
    $i = 0
    foreach ($wf in $workflows) { $i++; $context.PageIds[$wf.Key] = 'wf' + $i }
    $pages = New-Object System.Collections.Generic.List[object]
    $pages.Add($null)
    foreach ($wf in $workflows) { $pages.Add((New-WorkflowPage $wf $context.PageIds[$wf.Key] $context)) }
    $pages[0] = New-ProjectMapPage $workflows 'map' $projectName $context $true
    Save-Diagram $pages $baseName
}
else {
    # One file per workflow. Pages in different files can't link to each other.
    # Every output file gets its own name, so one workflow's diagram can never overwrite another's.
    # File names on Windows ignore letter case, so the check does too. The map's name is taken first.
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $mapName = Get-SafeFileName ($baseName + ' - project map')
    if ($isProject) { [void]$usedNames.Add($mapName) }
    foreach ($wf in $workflows) {
        if ($isProject) {
            $name = Get-SafeFileName ([System.IO.Path]::ChangeExtension($wf.Rel, $null).TrimEnd('.').Replace('\', '_'))
        }
        else {
            $name = $baseName       # a single file is named after the file, wherever it sits in its project
        }
        $unique = $name
        $suffix = 2
        while (-not $usedNames.Add($unique)) {
            $unique = $name + '_' + $suffix
            $suffix++
        }
        Save-Diagram @(New-WorkflowPage $wf 'wf1' $context) $unique
    }
    if ($isProject) {
        Save-Diagram @(New-ProjectMapPage $workflows 'map' $projectName $context $false) $mapName
    }
}

# The report is written last, so it can list anything that went wrong while writing the diagrams.
$reportPath = Join-Path $OutputPath ($baseName + '.conversion-report.txt')
$reportText = Get-ReportText $workflows $inputItem.FullName $outputFiles $context $(if ($isProject) { $projectName } else { $null })
try {
    Save-File $reportPath { param($p) [System.IO.File]::WriteAllText($p, $reportText, (New-Object System.Text.UTF8Encoding($false))) }
}
catch {
    Stop-WithError ('Could not write the conversion report ' + (Split-Path -Leaf $reportPath) + ': ' + (Get-WriteErrorText $_.Exception))
}

foreach ($f in $outputFiles) { Write-Host ('Wrote ' + $f) }
Write-Host ('Wrote ' + $reportPath)
$otherTypes = @{}
foreach ($wf in $workflows) { foreach ($a in $wf.Activities.Values) { if ($a.Source -eq 'Other') { $otherTypes[$a.Type] = $true } } }
if ($context.Warnings.Count -gt 0 -or $otherTypes.Count -gt 0) {
    Write-Host ('See the report for ' + $context.Warnings.Count + ' warning(s) and ' + $otherTypes.Count + ' activity type(s) from other libraries or packages.')
}

if ($PassThru) {
    [pscustomobject]@{
        DrawioFiles    = $outputFiles.ToArray()
        ReportFile     = $reportPath
        Workflows      = $workflows.Count
        Warnings       = $context.Warnings.ToArray()
        SkippedFolders = @($context.SkippedFolders | ForEach-Object { $_.Rel })
        WriteErrors    = @($context.WriteErrors | ForEach-Object { $_.Name })
    }
}

if ($context.WriteErrors.Count -gt 0) {
    # Everything else was written, including the report; still end with an error so scripts notice.
    Stop-WithError ('Could not write ' + $context.WriteErrors.Count + ' diagram file(s); everything else was written. See ' + (Split-Path -Leaf $reportPath) + '.')
}
