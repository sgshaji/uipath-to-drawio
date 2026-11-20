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

# Elements that carry a DisplayName or IdRef but are structure, not activities.
$script:StructuralNames = @('State', 'Transition', 'FlowStep', 'Catch', 'ActivityAction', 'ActivityFunc')

# Activity types the converter knows. Anything else is listed in the report as not recognised.
$script:KnownActivities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
@(
    # Workflow structure
    'Sequence', 'Flowchart', 'FlowDecision', 'FlowSwitch', 'StateMachine', 'InvokeWorkflowFile',
    'If', 'IfElseIf', 'Switch', 'TryCatch', 'Throw', 'Rethrow', 'TerminateWorkflow', 'While', 'DoWhile',
    'ForEach', 'ParallelForEach', 'ForEachRow', 'InterruptibleWhile', 'InterruptibleDoWhile', 'Parallel',
    'Pick', 'PickBranch', 'Break', 'Continue', 'RetryScope', 'Delay', 'Assign', 'MultipleAssign',
    'Comment', 'CommentOut', 'LogMessage', 'WriteLine', 'AddLogFields', 'RemoveLogFields', 'ShouldStop',
    'InvokeCode', 'InvokeMethod', 'InvokeProcess', 'AddToCollection', 'RemoveFromCollection',
    'ClearCollection', 'ExistsInCollection', 'MessageBox', 'InputDialog', 'KillProcess', 'StartProcess',
    # Files and data
    'ReadTextFile', 'WriteTextFile', 'AppendLine', 'CopyFile', 'MoveFile', 'DeleteFileX', 'PathExists',
    'CreateDirectory', 'BuildDataTable', 'AddDataRow', 'RemoveDataRow', 'FilterDataTable', 'SortDataTable',
    'LookupDataTable', 'JoinDataTables', 'MergeDataTable', 'OutputDataTable', 'ClearDataTable',
    'GenerateDataTable', 'DeserializeJson', 'SerializeJson', 'HttpClient',
    'ExcelApplicationScope', 'ExcelReadRange', 'ExcelWriteRange', 'ReadRange', 'WriteRange', 'ReadCell',
    'WriteCell', 'ExcelProcessScopeX', 'UseExcelFile',
    # Orchestrator
    'GetTransactionItem', 'SetTransactionStatus', 'AddQueueItem', 'AddTransactionItem', 'GetQueueItems',
    'GetAsset', 'GetRobotAsset', 'GetCredential', 'GetRobotCredential', 'SetAsset',
    # UI automation
    'OpenApplication', 'OpenBrowser', 'CloseApplication', 'CloseWindow', 'CloseTab', 'AttachWindow',
    'AttachBrowser', 'NavigateTo', 'UseBrowser', 'UseApplicationBrowser', 'NApplicationCard', 'Click',
    'DoubleClick', 'TypeInto', 'TypeSecureText', 'GetText', 'SetText', 'GetAttribute', 'ElementExists',
    'WaitUiElementAppear', 'WaitUiElementVanish', 'FindElement', 'SendHotkey', 'SelectItem', 'Check',
    'Hover', 'TakeScreenshot', 'HighlightElement', 'NClick', 'NTypeInto', 'NGetText', 'NCheckState',
    'NHover', 'NSelectItem', 'NKeyboardShortcuts', 'NCheck', 'NFindElement', 'NGoToUrl',
    'NNavigateBrowser', 'NCloseApplication',
    # Mail
    'SendMail', 'SendOutlookMailMessage', 'GetOutlookMailMessages', 'GetIMAPMailMessages',
    'SendSmtpMailMessage'
) | ForEach-Object { [void]$script:KnownActivities.Add($_) }

# draw.io styles. Labels are plain text (no html=1), so they need no HTML escaping.
$script:Style = @{
    Title          = 'text;fontSize=16;fontStyle=1;align=left;verticalAlign=top;'
    Note           = 'text;fontSize=11;fontColor=#666666;align=left;verticalAlign=top;'
    BackLink       = 'text;fontSize=11;fontColor=#0050ef;align=right;verticalAlign=top;fontStyle=4;'
    Start          = 'ellipse;fillColor=#d5e8d4;strokeColor=#82b366;fontStyle=1;'
    State          = 'rounded=1;arcSize=12;fillColor=#dae8fc;strokeColor=#6c8ebf;fontStyle=1;'
    StateCard      = 'swimlane;rounded=1;arcSize=12;startSize=28;fontStyle=1;fillColor=#dae8fc;strokeColor=#6c8ebf;swimlaneFillColor=#ffffff;collapsible=0;'
    FinalState     = 'rounded=1;arcSize=12;fillColor=#f8cecc;strokeColor=#b85450;strokeWidth=3;fontStyle=1;'
    FinalStateCard = 'swimlane;rounded=1;arcSize=12;startSize=28;fontStyle=1;fillColor=#f8cecc;strokeColor=#b85450;strokeWidth=3;swimlaneFillColor=#ffffff;collapsible=0;'
    Step           = 'rounded=1;fillColor=#ffffff;strokeColor=#6c8ebf;'
    StepCard       = 'swimlane;rounded=1;startSize=28;fontStyle=1;fillColor=#f5f5f5;strokeColor=#666666;swimlaneFillColor=#ffffff;collapsible=0;'
    Invoke         = 'shape=process;size=0.04;fillColor=#e1d5e7;strokeColor=#9673a6;'
    InvokeMissing  = 'shape=process;size=0.04;dashed=1;fillColor=#ffffff;strokeColor=#b85450;fontColor=#b85450;'
    InvokeComputed = 'shape=process;size=0.04;dashed=1;fillColor=#ffffff;strokeColor=#999999;fontColor=#666666;'
    Unknown        = 'rounded=0;dashed=1;fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;'
    Decision       = 'rhombus;fillColor=#fff2cc;strokeColor=#d6b656;'
    Switch         = 'rhombus;fillColor=#ffe6cc;strokeColor=#d79b00;'
    LabelBelow     = 'labelPosition=center;verticalLabelPosition=bottom;align=center;verticalAlign=top;labelBackgroundColor=#ffffff;'
    Row            = 'rounded=1;fillColor=#ffffff;strokeColor=#9673a6;fontSize=11;align=left;spacingLeft=6;'
    RowMissing     = 'rounded=1;dashed=1;fillColor=#ffffff;strokeColor=#b85450;fontColor=#b85450;fontSize=11;align=left;spacingLeft=6;'
    RowComputed    = 'rounded=1;dashed=1;fillColor=#ffffff;strokeColor=#999999;fontColor=#666666;fontSize=11;align=left;spacingLeft=6;'
    RowPlain       = 'text;fontSize=11;fontColor=#666666;align=left;spacingLeft=6;'
    Workflow       = 'rounded=1;fillColor=#dae8fc;strokeColor=#6c8ebf;'
    MainWorkflow   = 'rounded=1;fillColor=#dae8fc;strokeColor=#6c8ebf;strokeWidth=3;fontStyle=1;'
    BrokenWorkflow = 'rounded=1;fillColor=#f8cecc;strokeColor=#b85450;'
    Edge           = 'endArrow=block;endFill=1;rounded=1;fontSize=11;labelBackgroundColor=#ffffff;strokeColor=#555555;'
}

$script:CardHeader = 28
$script:RowHeight = 22
$script:RowGap = 4

# ---------------------------------------------------------------------------
# Reading XAML. Elements are matched by local name, never by namespace prefix.
# ---------------------------------------------------------------------------

function Get-ChildElement {
    param($Parent, [string]$LocalName)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Parent) { return ,$list }
    foreach ($n in $Parent.ChildNodes) {
        if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        if ([string]::IsNullOrEmpty($LocalName) -or $n.LocalName -eq $LocalName) { $list.Add($n) }
    }
    return ,$list
}

function Get-Attr {
    # Namespace: 'None' = unqualified attribute, 'Xaml' = the XAML language namespace (x:), 'Any' = any.
    param($Element, [string]$LocalName, [string]$Namespace = 'None')
    if ($null -eq $Element -or $null -eq $Element.Attributes) { return $null }
    foreach ($a in $Element.Attributes) {
        if ($a.LocalName -ne $LocalName) { continue }
        if ($Namespace -eq 'Any') { return $a.Value }
        if ($Namespace -eq 'Xaml' -and $a.NamespaceURI -eq $script:XamlNs) { return $a.Value }
        if ($Namespace -eq 'None' -and [string]::IsNullOrEmpty($a.NamespaceURI)) { return $a.Value }
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
    $p = $Element.ParentNode
    while ($null -ne $p -and $p.NodeType -eq [System.Xml.XmlNodeType]::Element) {
        if ($LocalNames -contains $p.LocalName) { return $p }
        $p = $p.ParentNode
    }
    return $null
}

function Test-IsXamlReference {
    param($Element)
    return ($Element.LocalName -eq 'Reference' -and $Element.NamespaceURI -eq $script:XamlNs)
}

function Test-IsXamlElement {
    # True for an element of the XAML language itself, such as x:Reference, x:Key or x:Null.
    param($Element, [string]$LocalName)
    return ($Element.LocalName -eq $LocalName -and $Element.NamespaceURI -eq $script:XamlNs)
}

function Get-ReferenceText {
    # The name inside <x:Reference>name</x:Reference>. Only the element's own text counts: a switch
    # case can be written <x:Reference>name<x:Key>case</x:Key></x:Reference>, and InnerText would
    # glue the key onto the name.
    param($Element)
    $name = Get-Attr $Element 'Name'
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name.Trim() }
    $text = ''
    foreach ($n in $Element.ChildNodes) {
        if ($n.NodeType -eq [System.Xml.XmlNodeType]::Text -or $n.NodeType -eq [System.Xml.XmlNodeType]::CDATA) { $text += $n.Value }
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
            $key = $c.InnerText.Trim()
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
        if ($c.LocalName.Contains('.')) { continue }
        if ($c.NamespaceURI -eq $script:XamlNs) { continue }
        return $c
    }
    return $null
}

function Get-PropertyText {
    # Value of an attribute, or the text of the matching property element (e.g. Transition.Condition).
    param($Element, [string]$AttributeName, [string]$PropertyName)
    $v = Get-Attr $Element $AttributeName
    if ($null -ne $v) { return $v.Trim() }
    foreach ($p in (Get-ChildElement $Element $PropertyName)) { return $p.InnerText.Trim() }
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
            foreach ($c in (Get-ChildElement $Element 'WorkflowViewState.IdRef')) { $id = $c.InnerText.Trim() }
        }
        if ($id -and $Map.ContainsKey($id)) { $holder = $Map[$id] }
    }
    if ($null -eq $holder) { return $result }
    foreach ($e in $holder.SelectNodes('.//*')) {
        $k = Get-Attr $e 'Key' 'Xaml'
        if ($k) { $result[$k] = $e.InnerText.Trim() }
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
        Unknown       = @{}
        ActivityCount = 0
        Summary       = ''
        IsMain        = $false
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

    $wf.Root = Get-ActivityChild $wf.Doc.DocumentElement
    if ($null -eq $wf.Root) {
        $wf.Kind = 'Empty'
        $wf.KindLabel = 'empty'
    }
    else {
        switch ($wf.Root.LocalName) {
            'StateMachine' { $wf.Kind = 'StateMachine'; $wf.KindLabel = 'state machine' }
            'Flowchart' { $wf.Kind = 'Flowchart'; $wf.KindLabel = 'flowchart' }
            default { $wf.Kind = 'Other'; $wf.KindLabel = $wf.Root.LocalName.ToLowerInvariant() }
        }
    }

    foreach ($inv in $wf.Doc.SelectNodes("//*[local-name()='InvokeWorkflowFile']")) {
        $wf.Invokes.Add((Get-InvokeInfo $inv $ProjectRoot))
    }

    # Inventory of activity types, to report the ones the converter doesn't recognise.
    foreach ($e in $wf.Doc.SelectNodes('//*')) {
        $ln = $e.LocalName
        if ($ln.Contains('.')) { continue }
        if ($script:NonActivityNs -contains $e.NamespaceURI) { continue }
        if ($script:StructuralNames -contains $ln) { continue }
        if ($null -eq (Get-Attr $e 'DisplayName') -and $null -eq (Get-Attr $e 'WorkflowViewState.IdRef' 'Any')) { continue }
        $wf.ActivityCount++
        if (-not $script:KnownActivities.Contains($ln)) {
            if ($wf.Unknown.ContainsKey($ln)) { $wf.Unknown[$ln]++ } else { $wf.Unknown[$ln] = 1 }
        }
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
    param([string]$Key, [string]$Kind, [string]$Label, [string]$Style, $Element = $null)
    $node = @{
        Key     = $Key
        Kind    = $Kind      # Start, Box, Card, Decision, Switch
        Label   = $Label
        Style   = $Style
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
    param([string]$Text, [string]$Style, [string]$Link)
    return @{ Text = $Text; Style = $Style; Link = $Link }
}

function New-InvokeRow {
    param($Invoke, $Context, [string]$Suffix)
    if ($Invoke.Computed) {
        $text = '(file name set at run time)'
        if ($Context.IncludeDetails -and $Invoke.Raw) { $text = 'Run-time file name: ' + $Invoke.Raw }
        return (New-Row ($text + $Suffix) $script:Style.RowComputed $null)
    }
    if ($Invoke.Outside) {
        return (New-Row ((Get-OutsideText $Invoke $Context) + ' (outside the project)' + $Suffix) $script:Style.RowComputed $null)
    }
    if (-not $Invoke.Exists) {
        return (New-Row ($Invoke.Rel + ' (missing)' + $Suffix) $script:Style.RowMissing $null)
    }
    $link = $null
    if ($Context.PageIds.ContainsKey($Invoke.Key)) { $link = 'data:page/id,' + $Context.PageIds[$Invoke.Key] }
    return (New-Row ($Invoke.Rel + $Suffix) $script:Style.Row $link)
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

    $start = New-Node 'start' 'Start' 'Start' $script:Style.Start $Machine
    $machineVs = Get-ViewState $Machine $vsMap
    $start.Studio = Get-StudioRect $machineVs 60 75
    $nodes.Add($start)

    $i = 0
    foreach ($s in $states) {
        $i++
        $isFinal = ((Get-Attr $s 'IsFinal') -eq 'True')
        $node = New-Node ('s' + $i) 'Box' (Get-DisplayName $s 'State') $script:Style.State $s
        if ($isFinal) { $node.Style = $script:Style.FinalState }
        $node.Studio = Get-StudioRect (Get-ViewState $s $vsMap) 160 80
        $nodes.Add($node)
    }

    # Invoked workflows: each belongs to the nearest state (Entry/Exit) or transition (Action/Trigger) of this machine.
    foreach ($inv in $Workflow.Invokes) {
        $owner = $null
        $p = $inv.Element.ParentNode
        while ($null -ne $p -and $p.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            if (Test-SameNode $p $Machine) { break }
            if ($p.LocalName -eq 'State' -or $p.LocalName -eq 'Transition') {
                if (Test-SameNode (Get-NearestAncestor $p @('StateMachine')) $Machine) { $owner = $p; break }
            }
            $p = $p.ParentNode
        }
        if ($null -eq $owner) { continue }
        $suffix = ''
        $stateEl = $owner
        if ($owner.LocalName -eq 'Transition') {
            $suffix = ' (on "' + (Get-DisplayName $owner 'transition') + '")'
            $stateEl = Get-NearestAncestor $owner @('State')
        }
        $node = Find-NodeByElement $nodes $stateEl
        if ($null -ne $node) { Add-UniqueRow $node (New-InvokeRow $inv $Context $suffix) }
    }
    foreach ($n in $nodes) {
        if ($n.Rows.Count -gt 0) {
            $n.Kind = 'Card'
            if ($n.Style -eq $script:Style.FinalState) { $n.Style = $script:Style.FinalStateCard } else { $n.Style = $script:Style.StateCard }
        }
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
    $type = $Activity.LocalName
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

    $start = New-Node 'start' 'Start' 'Start' $script:Style.Start $Chart
    $chartVs = Get-ViewState $Chart $vsMap
    $start.Studio = Get-StudioRect $chartVs 60 75
    $nodes.Add($start)

    $i = 0
    foreach ($e in $elements) {
        $i++
        $key = 'n' + $i
        $vs = Get-ViewState $e $vsMap
        switch ($e.LocalName) {
            'FlowStep' {
                $act = Get-ActivityChild $e
                if ($null -eq $act) {
                    $node = New-Node $key 'Box' '(empty step)' $script:Style.Step $e
                }
                elseif ($act.LocalName -eq 'InvokeWorkflowFile') {
                    $inv = $null
                    [void]$invokeByElement.TryGetValue($act, [ref]$inv)
                    $row = New-InvokeRow $inv $Context ''
                    $node = New-Node $key 'Box' ((Get-StepLabel $act) + "`n" + $row.Text) $script:Style.Invoke $e
                    if ($row.Style -eq $script:Style.RowMissing) { $node.Style = $script:Style.InvokeMissing }
                    if ($row.Style -eq $script:Style.RowComputed) { $node.Style = $script:Style.InvokeComputed }
                    $node.Link = $row.Link
                }
                elseif (-not $script:KnownActivities.Contains($act.LocalName)) {
                    $node = New-Node $key 'Box' ((Get-StepLabel $act) + "`n[" + $act.LocalName + ']') $script:Style.Unknown $e
                }
                else {
                    $label = Get-StepLabel $act
                    if ($act.LocalName -eq 'Flowchart' -or $act.LocalName -eq 'StateMachine') {
                        $label = $label + ' (nested ' + $act.LocalName.ToLowerInvariant() + ')'
                        $warnings.Add('Step "' + (Get-StepLabel $act) + '" holds a nested ' + $act.LocalName.ToLowerInvariant() + '; it is not expanded in version 1.')
                    }
                    $node = New-Node $key 'Box' $label $script:Style.Step $e
                }
                $node.Studio = Get-StudioRect $vs 200 52
            }
            'FlowDecision' {
                $label = Get-DisplayName $e 'Decision'
                if ($Context.IncludeDetails) {
                    $cond = Get-PropertyText $e 'Condition' 'FlowDecision.Condition'
                    if ($cond) { $label = $label + "`n" + $cond }
                }
                $node = New-Node $key 'Decision' $label $script:Style.Decision $e
                $node.Studio = Get-StudioRect $vs 70 70
            }
            'FlowSwitch' {
                $label = Get-DisplayName $e 'Switch'
                if ($Context.IncludeDetails) {
                    $expr = Get-PropertyText $e 'Expression' 'FlowSwitch.Expression'
                    if ($expr) { $label = $label + "`n" + $expr }
                }
                $node = New-Node $key 'Switch' $label $script:Style.Switch $e
                $node.Studio = Get-StudioRect $vs 70 70
            }
        }
        $nodes.Add($node)
    }

    # Invoked workflows inside a step's activity (for example a Sequence) are listed on the step.
    foreach ($inv in $Workflow.Invokes) {
        $owner = $null
        $p = $inv.Element.ParentNode
        while ($null -ne $p -and $p.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            if (Test-SameNode $p $Chart) { break }
            if ($p.LocalName -eq 'FlowStep' -and (Test-SameNode (Get-NearestAncestor $p @('Flowchart')) $Chart)) { $owner = $p; break }
            $p = $p.ParentNode
        }
        if ($null -eq $owner) { continue }
        if (Test-SameNode (Get-ActivityChild $owner) $inv.Element) { continue }
        $node = Find-NodeByElement $nodes $owner
        if ($null -ne $node) { Add-UniqueRow $node (New-InvokeRow $inv $Context '') }
    }
    foreach ($n in $nodes) {
        if ($n.Rows.Count -gt 0 -and $n.Kind -eq 'Box') {
            $n.Kind = 'Card'
            $n.Style = $script:Style.StepCard
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
        switch ($e.LocalName) {
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
                        if ($c.LocalName.Contains('.')) { continue }          # property elements, such as FlowSwitch.Default
                        if (Test-IsXamlElement $c 'Key') { continue }         # this switch's own key, when it is itself a case
                        $caseKey = Get-XamlKey $c
                        if ($null -eq $caseKey) {
                            if ((Test-IsXamlReference $c) -or $flowNames -contains $c.LocalName) {
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
    foreach ($e in $elements) {
        switch ($e.LocalName) { 'FlowStep' { $steps++ } 'FlowDecision' { $decisions++ } 'FlowSwitch' { $switches++ } }
    }
    $summary = (Format-Count $steps 'step' 'steps') + ', ' + (Format-Count $decisions 'decision' 'decisions') + ', ' + (Format-Count $switches 'switch' 'switches')
    return @{ Nodes = $nodes; Edges = $edges; StartKeys = @('start'); Warnings = $warnings; Summary = $summary }
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
        if ($n.Kind -eq 'Decision' -or $n.Kind -eq 'Switch') {
            $n.Style = $n.Style + $script:Style.LabelBelow
        }
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
    }
    return @{ X = $sx; Y = $sy }
}

function Set-AutoLayout {
    # Simple layered layout, top to bottom. Layers come from the longest path from the start
    # (ignoring edges that loop back); nodes in a layer keep the order they were reached in.
    param($Graph, [double]$Left, [double]$Top, [double]$GapX = 50, [double]$GapY = 70)
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

    $maxLayer = 0
    foreach ($n in $nodes) { if ($layer[$n.Key] -gt $maxLayer) { $maxLayer = $layer[$n.Key] } }
    # Group the nodes into layers in one pass; in each layer, keep the order they were reached in.
    $byLayer = @{}
    for ($l = 0; $l -le $maxLayer; $l++) { $byLayer[$l] = New-Object System.Collections.Generic.List[object] }
    foreach ($n in $nodes) { $byLayer[$layer[$n.Key]].Add($n) }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($l = 0; $l -le $maxLayer; $l++) {
        $rows.Add(@($byLayer[$l] | Sort-Object { $discovery[$_.Key] }))
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
    foreach ($e in $Graph.Edges) {
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
    param($Page, [string]$Label, [string]$Style, [string]$Source, [string]$Target, $Points, $LabelX = $null, [double]$LabelDx = 0)
    $id = New-CellId $Page
    $Page.Cells.Add(@{ Id = $id; Edge = $true; Label = $Label; Style = $Style; Parent = '1'; X = 0; Y = 0; W = 0; H = 0; Link = $null; Source = $Source; Target = $Target; Points = $Points; LabelX = $LabelX; LabelDx = $LabelDx })
    return $id
}

function Add-GraphToPage {
    param($Page, $Graph)
    $cellIds = @{}
    foreach ($n in $Graph.Nodes) {
        $id = Add-Vertex $Page $n.Label $n.Style $n.X $n.Y $n.W $n.H '1' $n.Link
        $cellIds[$n.Key] = $id
        if ($n.Kind -eq 'Card') {
            $y = $script:CardHeader + $script:RowGap
            foreach ($r in $n.Rows) {
                [void](Add-Vertex $Page $r.Text $r.Style 8 $y ($n.W - 16) $script:RowHeight $id $r.Link)
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
    [void](Add-Vertex $Page $Title $script:Style.Title 40 16 600 30)
    if ($Context.MapPageId) {
        [void](Add-Vertex $Page 'Back to project map' $script:Style.BackLink 640 20 160 20 '1' ('data:page/id,' + $Context.MapPageId))
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
            $w.WriteAttributeString('name', $page.Name)
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
                    $w.WriteAttributeString('label', [string]$c.Label)
                    $w.WriteAttributeString('link', $c.Link)
                    $w.WriteAttributeString('id', $c.Id)
                    $w.WriteStartElement('mxCell')
                }
                else {
                    $w.WriteStartElement('mxCell')
                    $w.WriteAttributeString('id', $c.Id)
                    $w.WriteAttributeString('value', [string]$c.Label)
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
        $Workflow.Summary = $Workflow.KindLabel + ': ' + $graph.Summary + '. Layout: ' + $layoutText + '.'
        foreach ($w in $graph.Warnings) { $Context.Warnings.Add($Workflow.Rel + ': ' + $w) }
        return $page
    }

    # Sequences and anything else: a summary card listing the workflows the file invokes.
    $rootLabel = 'Empty workflow'
    if ($null -ne $Workflow.Root) { $rootLabel = Get-DisplayName $Workflow.Root $Workflow.Root.LocalName }
    $node = New-Node 'root' 'Card' $rootLabel $script:Style.StepCard $Workflow.Root
    foreach ($inv in $Workflow.Invokes) { Add-UniqueRow $node (New-InvokeRow $inv $Context '') }
    if ($node.Rows.Count -eq 0) { $node.Rows.Add((New-Row 'Invokes no other workflows' $script:Style.RowPlain $null)) }
    $size = Measure-Node $node $false
    $node.X = $left; $node.Y = $top; $node.W = $size.W; $node.H = $size.H
    $graph = @{ Nodes = @($node); Edges = @() }
    Add-GraphToPage $page $graph
    $kind = 'workflow'
    if ($null -ne $Workflow.Root) { $kind = $Workflow.KindLabel }
    $note = 'Version 1 does not draw the steps inside a ' + $kind + '. This page lists the workflows it invokes.'
    [void](Add-Vertex $page $note $script:Style.Note $left ($top + $size.H + 16) 600 20)
    $Workflow.Summary = $Workflow.KindLabel + ': summary page only (' + (Format-Count $Workflow.Invokes.Count 'invoked workflow' 'invoked workflows') + ' listed).'
    return $page
}

function New-ProjectMapPage {
    param($Workflows, [string]$PageId, [string]$ProjectName, $Context, [bool]$LinkPages)
    $page = New-Page $PageId 'Project map'
    [void](Add-Vertex $page ('Project map: ' + $ProjectName) $script:Style.Title 40 16 600 30)
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
        $style = $script:Style.Workflow
        if ($wf.IsMain) { $style = $script:Style.MainWorkflow }
        if ($wf.Error) { $style = $script:Style.BrokenWorkflow }
        $node = New-Node ('w' + $i) 'Box' ($wf.Rel + "`n(" + $wf.KindLabel + ')') $style
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
                $target = New-Node ('c' + $c) 'Box' $label $script:Style.InvokeComputed
                $nodes.Add($target)
            }
            elseif ($inv.Outside) {
                # Keyed apart from the project's own workflows; "|" cannot appear in a file name.
                $outsideKey = 'outside|' + $inv.Key
                if (-not $nodeByKey.ContainsKey($outsideKey)) {
                    $label = (Get-OutsideText $inv $Context) + "`n(outside the project)"
                    $nodeByKey[$outsideKey] = New-Node ('o' + $nodes.Count) 'Box' $label $script:Style.InvokeComputed
                    $nodes.Add($nodeByKey[$outsideKey])
                }
                $target = $nodeByKey[$outsideKey]
            }
            elseif ($nodeByKey.ContainsKey($inv.Key)) {
                $target = $nodeByKey[$inv.Key]
            }
            else {
                $target = New-Node ('m' + $nodes.Count) 'Box' ($inv.Rel + "`n(missing)") $script:Style.InvokeMissing
                if ($inv.Exists) {
                    $target.Label = $inv.Rel + "`n(not converted)"
                    $target.Style = $script:Style.InvokeComputed
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
    Set-AutoLayout $graph 40 90 40 60
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
        [void]$sb.Append('  ' + $wf.Rel + $mark + ' - ' + $wf.Summary + $nl)
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $computed = New-Object System.Collections.Generic.List[string]
    $outside = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
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
        foreach ($k in ($wf.Unknown.Keys | Sort-Object)) {
            $unknown.Add('  ' + $k + ' - ' + $wf.Unknown[$k] + ' in ' + $wf.Rel)
        }
        if ($wf.Kind -eq 'Other') { $notDrawn.Add('  ' + $wf.Rel + ' (' + $wf.KindLabel + '): steps not drawn; the page lists the workflows it invokes.') }
        if ($wf.Kind -eq 'StateMachine') { $notDrawn.Add('  ' + $wf.Rel + ': activities inside states are not drawn; each state lists the workflows it invokes.') }
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

    Add-Heading $sb ('Activity types not recognised (' + $unknown.Count + ')')
    [void]$sb.Append('  Where these appear as a flowchart step they are drawn as a plain dashed box with the type name.' + $nl)
    if ($unknown.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $unknown) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb ('Not drawn in version 1')
    if ($notDrawn.Count -eq 0) { [void]$sb.Append('  Nothing' + $nl) } else { foreach ($l in $notDrawn) { [void]$sb.Append($l + $nl) } }

    Add-Heading $sb ('Warnings (' + $Context.Warnings.Count + ')')
    if ($Context.Warnings.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $Context.Warnings) { [void]$sb.Append('  ' + $l + $nl) } }

    Add-Heading $sb ('Files that could not be read (' + $unread.Count + ')')
    if ($unread.Count -eq 0) { [void]$sb.Append('  None' + $nl) } else { foreach ($l in $unread) { [void]$sb.Append($l + $nl) } }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { [string]$_ } }
    $safe = (-join $chars).Trim()
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'diagram' }
    return $safe
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

$inputItem = Get-Item -LiteralPath $Path
$isProject = $inputItem.PSIsContainer
if (-not $isProject -and $inputItem.Extension -ne '.xaml') {
    throw "Expected a .xaml file or a UiPath project folder: $Path"
}

if ($isProject) {
    $projectRoot = $inputItem.FullName.TrimEnd('\')
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
}
if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath) }
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

# Collect files. Folders whose name starts with "." (.local, .settings, .objects ...) are Studio's own.
$files = New-Object System.Collections.Generic.List[object]
if ($isProject) {
    foreach ($f in (Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.xaml')) {
        $rel = $f.FullName.Substring($projectRoot.Length).TrimStart('\')
        $hidden = $false
        foreach ($part in ($rel.Split('\') | Select-Object -SkipLast 1)) { if ($part.StartsWith('.')) { $hidden = $true } }
        if (-not $hidden) { $files.Add(@{ Full = $f.FullName; Rel = $rel }) }
    }
}
else {
    $full = $inputItem.FullName
    $rootWithSlash = $projectRoot.TrimEnd('\') + '\'
    if ($full.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($rootWithSlash.Length) }
    else { $rel = $inputItem.Name }
    $files.Add(@{ Full = $full; Rel = $rel })
}
if ($files.Count -eq 0) { throw "No .xaml files found in $Path" }

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

$context = @{
    IncludeDetails = [bool]$IncludeDetails
    PageIds        = @{}
    MapPageId      = $null
    ViewStateMap   = @{}
    Warnings       = (New-Object System.Collections.Generic.List[string])
}

$outputFiles = New-Object System.Collections.Generic.List[string]
$baseName = Get-SafeFileName $projectName
if (-not $isProject) { $baseName = Get-SafeFileName ([System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name)) }

if ($isProject -and -not $OnePerFile) {
    # One file: project map first, then a page per workflow, linked to each other.
    $context.MapPageId = 'map'
    $i = 0
    foreach ($wf in $workflows) { $i++; $context.PageIds[$wf.Key] = 'wf' + $i }
    $pages = New-Object System.Collections.Generic.List[object]
    $pages.Add($null)
    foreach ($wf in $workflows) { $pages.Add((New-WorkflowPage $wf $context.PageIds[$wf.Key] $context)) }
    $pages[0] = New-ProjectMapPage $workflows 'map' $projectName $context $true
    $target = Join-Path $OutputPath ($baseName + '.drawio')
    Write-DrawioFile $pages $target
    $outputFiles.Add($target)
}
else {
    # One file per workflow. Pages in different files can't link to each other.
    # Every output file gets its own name, so one workflow's diagram can never overwrite another's.
    # File names on Windows ignore letter case, so the check does too. The map's name is taken first.
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $mapName = $baseName + ' - project map'
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
        $name = $unique
        $page = New-WorkflowPage $wf 'wf1' $context
        $target = Join-Path $OutputPath ($name + '.drawio')
        Write-DrawioFile @($page) $target
        $outputFiles.Add($target)
    }
    if ($isProject) {
        $mapPage = New-ProjectMapPage $workflows 'map' $projectName $context $false
        $target = Join-Path $OutputPath ($mapName + '.drawio')
        Write-DrawioFile @($mapPage) $target
        $outputFiles.Add($target)
    }
}

$reportPath = Join-Path $OutputPath ($baseName + '.conversion-report.txt')
$reportText = Get-ReportText $workflows $inputItem.FullName $outputFiles $context $(if ($isProject) { $projectName } else { $null })
[System.IO.File]::WriteAllText($reportPath, $reportText, (New-Object System.Text.UTF8Encoding($false)))

foreach ($f in $outputFiles) { Write-Host ('Wrote ' + $f) }
Write-Host ('Wrote ' + $reportPath)
$unknownTotal = 0
foreach ($wf in $workflows) { $unknownTotal += $wf.Unknown.Count }
if ($context.Warnings.Count -gt 0 -or $unknownTotal -gt 0) {
    Write-Host ('See the report for ' + $context.Warnings.Count + ' warning(s) and ' + $unknownTotal + ' activity type(s) not recognised.')
}

if ($PassThru) {
    [pscustomobject]@{
        DrawioFiles = $outputFiles.ToArray()
        ReportFile  = $reportPath
        Workflows   = $workflows.Count
        Warnings    = $context.Warnings.ToArray()
    }
}
