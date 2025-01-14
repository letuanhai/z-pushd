﻿$safehome = if ([String]::IsNullOrWhiteSpace($Env:HOME)) { $env:USERPROFILE } else { $Env:HOME } 
$cdHistory = Join-Path -Path $safehome -ChildPath '\.cdHistory'

<#
.SYNOPSIS
Tracks your most used directories, based on 'frecency'. This is done by storing your CD command history and ranking it over time.

.DESCRIPTION
After a short learning phase, z will take you to the most 'frecent' directory that matches the regex given on the command line.

.PARAMETER JumpPath
A un-escaped regular expression of the directory name to jump to. Character escaping will be done internally.

.PARAMETER Option
Frecency - Match by frecency (default)
Rank - Match by rank only
Time - Match by recent access only

.PARAMETER OnlyCurrentDirectory
Restrict matches to subdirectories of the current directory

.PARAMETER Listfiles
List only, don't navigate to the directory

.PARAMETER Remove
Remove the current directory from the datafile

.PARAMETER Clean
Clean up all history entries that cannot be resolved

.NOTES
Current PowerShell implementation is very crude and does not yet support all of the options of the original z bash script.
Although tracking of frequently used directories is obtained through the continued use of the "cd" command, the Windows registry is also scanned for frequently accessed paths.

.LINK
https://github.com/letuanhai/z

.EXAMPLE
CD to the most frecent directory matching 'foo'
z foo

.EXAMPLE
CD to the most recently accessed directory matching 'foo'
z foo -o Time
#>
function z {
    param(
        [Parameter(Position = 0)]
        [string]
        ${JumpPath},

        [ValidateSet("Time", "T", "Frecency", "F", "Rank", "R")]
        [Alias('o')]
        [string]
        $Option = 'Frecency',

        [Alias('c')]
        [switch]
        $OnlyCurrentDirectory = $null,

        [Alias('l')]
        [switch]
        $ListFiles = $null,

        [Alias('x')]
        [switch]
        $Remove = $null,

        [Alias('d')]
        [switch]
        $Clean = $null

        # [Alias('p')]
        # [switch]
        # $Push = $false
    )

    if (((-not $Clean) -and (-not $Remove) -and (-not $ListFiles)) -and [string]::IsNullOrWhiteSpace($JumpPath)) { Get-Help z; return; }

    # If a valid path is passed in to z, treat it like the normal cd command
    if (-not $ListFiles -and -not [string]::IsNullOrWhiteSpace($JumpPath) -and (Test-Path $JumpPath)) {
        # if ($Push) {
        pushdX $JumpPath
        # }
        # else {
        #     cdX $JumpPath
        # }
        return;
    }

    if ((Test-Path $cdHistory)) {
        if ($Remove) {
            Save-CdCommandHistory $Remove
        }
        elseif ($Clean) {
            Cleanup-CdCommandHistory
        }
        else {

            # This causes conflicts with the -Remove parameter. Not sure whether to remove registry entry.
            #$mruList = Get-MostRecentDirectoryEntries

            $providerRegex = $null

            If ($OnlyCurrentDirectory) {
                $providerRegex = (Get-FormattedLocation).replace('\', '\\')
                if (-not $providerRegex.EndsWith('\\')) {
                    $providerRegex += '\\'
                }
                $providerRegex += '.*?'
            }
            else {
                $providerRegex = Get-CurrentSessionProviderDrives ((Get-PSProvider).Drives | Select-Object -ExpandProperty Name)
            }

            $list = @()

            $global:history |
            Where-Object { Get-DirectoryEntryMatchPredicate -path $_.Path -jumpPath $JumpPath -ProviderRegex $providerRegex } | Get-ArgsFilter -Option $Option |
            ForEach-Object { if ($ListFiles -or (Test-Path $_.Path.FullName)) { $list += $_ } }

            if ($ListFiles) {

                $newList = $list | ForEach-Object { New-Object PSObject -Property  @{Rank = $_.Rank; Path = $_.Path.FullName; LastAccessed = [DateTime]$_.Time } }
                Format-Table -InputObject $newList -AutoSize

            }
            else {

                if ($list.Length -eq 0) {
                    # It's not found in the history file, perhaps it's still a valid directory. Let's check.
                    if ((Test-Path $JumpPath)) {
                        # if ($Push) {
                        pushdX $JumpPath
                        # }
                        # else {
                        #     cdX $JumpPath
                        # }
                    }
                    else {
                        Write-Host "$JumpPath Not found"
                    }

                }
                else {
                    if ($list.Length -gt 1) {
                        $entry = $list | Sort-Object -Descending { $_.Score } | Select-Object -First 1

                    }
                    else {
                        $entry = $list[0]
                    }

                    # if ($Push) {
                    Push-Location $entry.Path.FullName
                    # }
                    # else {
                    #     Set-Location $entry.Path.FullName
                    # }
                    Save-CdCommandHistory $Remove
                }
            }
        }
    }
    else {
        Save-CdCommandHistory $Remove
    }
}

function pushdX {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsTransactions = $true, HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=113370')]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]
        ${Path},

        [Parameter(ParameterSetName = 'LiteralPath', ValueFromPipelineByPropertyName = $true)]
        [Alias('PSPath')]
        [string]
        ${LiteralPath},

        [switch]
        ${PassThru},

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [string]
        ${StackName})

    begin {
        try {
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }
            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Push-Location', [System.Management.Automation.CommandTypes]::Cmdlet)
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
    }

    process {
        try {
            $steppablePipeline.Process($_)
            Save-CdCommandHistory # Build up the DB.
        }
        catch {
            throw
        }
    }

    end {
        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }
    }
}

function popdX {
    [CmdletBinding(SupportsTransactions = $true, HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=113369')]
    param(
        [switch]
        ${PassThru},

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [string]
        ${StackName})

    begin {
        try {
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }
            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Management\Pop-Location', [System.Management.Automation.CommandTypes]::Cmdlet)
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
    }

    process {
        try {
            $steppablePipeline.Process($_)
        }
        catch {
            throw
        }
    }

    end {
        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }
    }
    <#
    .ForwardHelpTargetName Microsoft.PowerShell.Management\Pop-Location
    .ForwardHelpCategory Cmdlet
    #>
}

<#
.SYNOPSIS
Get the locations in the location stacks used by z, cd, pushd.

.DESCRIPTION
To store location history, this module provided wrapper for aliases commonly used for directory navigation: cd, pushd, popd.
This module also uses Push-Location under the hood for all navigation commands (z, cd, pushd) to store the current
navigation history (in the default unamed location stack).
Due to the way Powershell work, all the location stacks used by commands in this module is not accessible to outside commands.
(This may be due to them being on different *runspace*. See: https://go.microsoft.com/fwlink/?LinkID=113321#notes)
This command allow you access the location used by commands from this module.

.PARAMETER StackName
Specifies, as a string array, the named location stacks. Enter one or more location stack names.
If omitted, show the default unamed stack.

.EXAMPLE
Get the locations in location stack a and b
> zz -StackName a, b
#>
function zz {
    [CmdletBinding(SupportsTransactions = $true, HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113321')]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [string[]]
        ${StackName}
        )

    begin {
        try {
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }

            $PSBoundParameters['Stack'] = $true
            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Management\Get-Location', [System.Management.Automation.CommandTypes]::Cmdlet)
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
    }

    process {
        try {
            $steppablePipeline.Process($_)
        }
        catch {
            throw
        }
    }

    end {
        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }
    }
}

# A wrapper function around the existing Set-Location Cmdlet.
function cdX {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsTransactions = $true, HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=113397')]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]
        ${Path},

        [Parameter(ParameterSetName = 'LiteralPath', Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('PSPath')]
        [string]
        ${LiteralPath},

        [switch]
        ${PassThru},

        [Parameter(ParameterSetName = 'Stack', ValueFromPipelineByPropertyName = $true)]
        [string]
        ${StackName})

    begin {
        $outBuffer = $null
        if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
            $PSBoundParameters['OutBuffer'] = 1
        }

        $PSBoundParameters['ErrorAction'] = 'Stop'

        $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Set-Location', [System.Management.Automation.CommandTypes]::Cmdlet)
        $scriptCmd = { & $wrappedCmd @PSBoundParameters }

        $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
        $steppablePipeline.Begin($PSCmdlet)
    }

    process {
        $steppablePipeline.Process($_)

        Save-CdCommandHistory # Build up the DB.
    }

    end {
        $steppablePipeline.End()
    }
}

function Get-DirectoryEntryMatchPredicate {
    Param(
        [Parameter(
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        $Path,

        [Parameter(
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [string] $JumpPath,

        $ProviderRegex
    )

    if ($null -ne $Path) {

        $null = .{
            $providerMatches = [System.Text.RegularExpressions.Regex]::Match($Path.FullName, $ProviderRegex).Success
        }

        if ($providerMatches) {
            
            # Allows matching of entire names. Remove the first two characters, added by PowerShell when the user presses the TAB key.
            if ($JumpPath.StartsWith('.\')) {
                $JumpPath = $JumpPath.Substring(2).TrimEnd('\')
            }

            [System.Text.RegularExpressions.Regex]::Match($Path.Name, [System.Text.RegularExpressions.Regex]::Escape($JumpPath), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Success
        }
    }
}

function Get-CurrentSessionProviderDrives([System.Collections.ArrayList] $ProviderDrives) {

    if ($IsLinux -Or $IsMacOS) {
        # Always only '/' which needs escaped to work in a regex
        '\/'
    }
    elseif ($ProviderDrives -ne $null -and $ProviderDrives.Length -gt 0) {
        Get-ProviderDrivesRegex $ProviderDrives
    }
    else {

        # The FileSystemProvider supports \\ and X:\ paths.
        # An ideal solution would be to ask the provider if a path is supported.
        # Supports drives such as C:\ and also UNC \\
        if ((Get-Location).Provider.ImplementingType.Name -eq 'FileSystemProvider') {
            '(?i)^(((' + [String]::Concat( ((Get-Location).Provider.Drives.Name | ForEach-Object { $_ + '|' }) ).TrimEnd('|') + '):\\)|(\\{1,2})).*?'
        }
        else {
            Get-ProviderDrivesRegex (Get-Location).Provider.Drives
        }
    }
}

function Get-ProviderDrivesRegex([System.Collections.ArrayList] $ProviderDrives) {
    
    # UNC paths get special treatment. Allows one to 'z foo -ProviderDrives \\' and specify '\\' as the drive.
    if ($ProviderDrives -contains '\\') {
        $ProviderDrives.('\\')
    }

    if ($ProviderDrives.Count -eq 0) {
        '(?i)^(\\{1,2}).*?'
    }
    else {
        $uncRootPathRegex = '|(\\{1,2})'
        '(?i)^((' + [String]::Concat( ($ProviderDrives | ForEach-Object { $_ + '|' }) ).TrimEnd('|') + '):\\)' + $uncRootPathRegex + '.*?'
    }
}

function Get-Frecency($rank, $time) {

    # Last access date/time
    $dx = (Get-Date).Subtract((New-Object System.DateTime -ArgumentList $time)).TotalSeconds

    if ( $dx -lt 3600 ) { return $rank * 4 }

    if ( $dx -lt 86400 ) { return $rank * 2 }

    if ( $dx -lt 604800 ) { return $rank / 2 }

    return $rank / 4
}

function Cleanup-CdCommandHistory() {

    try {

        for ($i = 0; $i -lt $global:history.Length; $i++) {

            $line = $global:history[$i]

            if ($null -ne $line) {
                $testDir = $line.Path.FullName
                if (-not [string]::IsNullOrWhiteSpace($testDir) -and !(Test-Path $testDir)) {
                    $global:history[$i] = $null
                    Write-Host "Removed inaccessible path $testDir" -ForegroundColor Yellow
                }
            }
        }
        Remove-Old-History
        WriteHistoryToDisk
    }
    catch {
        Write-Host $_.Exception.ToString() -ForegroundColor Red
    }
}


function Remove-Old-History() {
    if ($global:history.Length -gt 1000) {
        $global:history | Where-Object { $_ -ne $null } | ForEach-Object { $i = 0 } {

            $lineObj = $_
            $lineObj.Rank = $lineObj.Rank * 0.99

            # If it's been accessed in the last 14 days it can stay
            # or
            # If it's rank is greater than 20 and been accessed in the last 30 days it can stay
            if ($lineObj.Age -lt 1209600 -or ($lineObj.Rank -ge 5 -and $lineObj.Age -lt 2592000)) {
                #$global:history[$i] = ConvertTo-DirectoryEntry (ConvertTo-TextualHistoryEntry $lineObj.Rank $lineObj.Path.FullName $lineObj.Time)
            }
            else {
                Write-Host "Removing old item: Rank:" $lineObj.Rank "Age:" ($lineObj.Age / 60 / 60) "Path:" $lineObj.Path.FullName -ForegroundColor Yellow
                $global:history[$i] = $null
            }
            $i++;
        }
    }
}


function Save-CdCommandHistory($removeCurrentDirectory = $false) {

    $currentDirectory = Get-FormattedLocation

    try {

        $foundDirectory = $false
        $runningTotal = 0

        for ($i = 0; $i -lt $global:history.Length; $i++) {

            $line = $global:history[$i]

            $canIncreaseRank = $true;

            $rank = $line.Rank;

            if (-not $foundDirectory) {

                $rank = $line.Rank

                if ($line.Path.FullName -eq $currentDirectory) {

                    $foundDirectory = $true

                    if ($removeCurrentDirectory) {
                        $canIncreaseRank = $false
                        $global:history[$i] = $null
                        Write-Host "Removed entry $currentDirectory" -ForegroundColor Green

                    }
                    else {
                        $rank++
                        Update-HistoryEntryUsageTime $global:history[$i]
                    }
                }
            }

            if ($canIncreaseRank) {
                $runningTotal += $rank
            }
        }

        if (-not $foundDirectory -and $removeCurrentDirectory) {
            Write-Host "Current directory not found in CD history data file" -ForegroundColor Red
        }
        else {

            if (-not $foundDirectory) {
                Save-HistoryEntry 1 $currentDirectory
                $runningTotal += 1
            }
            Remove-Old-History
        }

        WriteHistoryToDisk

    }
    catch {
        Write-Host $_.Exception.ToString() -ForegroundColor Red
    }
}

function WriteHistoryToDisk() {
    $newList = GetAllHistoryAsText $global:history
    Set-Content -Value $newList -Path $cdHistory -Encoding UTF8
}

function GetAllHistoryAsText($history) {
    return $history | Where-Object { $_ -ne $null } | ForEach-Object { ConvertTo-TextualHistoryEntry $_.Rank $_.Path.FullName $_.Time }
}

function Get-FormattedLocation() {
    if ((Get-Location).Provider.ImplementingType.Name -eq 'FileSystemProvider' -and (Get-Location).Path.Contains('FileSystem::\\')) {
        Get-Location | Select-Object -ExpandProperty ProviderPath # The registry provider does return a path which z understands. In other words, I'm too lazy.
    }
    else {
        Get-Location | Select-Object -ExpandProperty Path
    }
}

function Format-Rank($rank) {
    return $rank.ToString("000#.00", [System.Globalization.CultureInfo]::InvariantCulture);
}

function Save-HistoryEntry($rank, $directory) {
    $entry = ConvertTo-TextualHistoryEntry $rank $directory
    $global:history += ConvertTo-DirectoryEntry $entry
}

function Update-HistoryEntryUsageTime($historyEntry) {
    $historyEntry.Rank++
    $historyEntry.Time = (Get-Date).Ticks
}

function ConvertTo-TextualHistoryEntry($rank, $directory, $lastAccessedTicks) {
    if ($null -eq $lastAccessedTicks) {
        $lastAccessedTicks = (Get-Date).Ticks
    }

    (Format-Rank $rank) + $lastAccessedTicks + $directory
}

function ConvertTo-DirectoryEntry {
    Param(
        [Parameter(
            Position = 0,
            Mandatory = $true,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [String]$line
    )

    Process {

        $null = .{

            $pathValue = $line.Substring(25)

            try {
                $fileName = [System.IO.Path]::GetFileName($pathValue);
                
                # GetFileName() does not work with registry paths
                if ($fileName -eq '') {
                    $lastPathSeparator = $pathValue.LastIndexOf('\');
                    if ($lastPathSeparator -ge 0) {
                        $pathValue = $pathValue.TrimEnd('\');
                        $fileName = $pathValue.Substring( + 1);
                    }
                }
            }
            catch [System.ArgumentException] { }

            $time = [long]::Parse($line.Substring(7, 18), [Globalization.CultureInfo]::InvariantCulture)
        }

        @{
            Rank = GetRankFromLine $line;
            Time = $time;
            Path = @{ Name = $fileName; FullName = $pathValue };
            Age  = (Get-Date).Subtract((New-Object System.DateTime -ArgumentList $time)).TotalSeconds;
        }
    }
}

function GetRankFromLine([String]$line) {
    $null = .{ $rankStr = $line.Substring(0, 7) }
    [double]::Parse($rankStr, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-MostRecentDirectoryEntries {

    $mruEntries = (Get-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths | ForEach-Object { $item = $_; $_.GetValueNames() | ForEach-Object { $item.GetValue($_) } })

    $mruEntries | ForEach-Object { ConvertTo-TextualHistoryEntry 1 $_ }
}

function Get-ArgsFilter {
    Param(
        [Parameter(ValueFromPipeline = $true)]
        [Hashtable]$historyEntry,

        [string]
        $Option = 'Frecency'
    )

    Process {

        if ($Option -in ('Frecency', 'F')) {
            $_['Score'] = (Get-Frecency $_.Rank $_.Time);
        }
        elseif ($Option -in ('Time', 'T')) {
            $_['Score'] = $_.Time;
        }
        elseif ($Option -in ('Rank', 'R')) {
            $_['Score'] = $_.Rank;
        }

        return $_;
    }
}

<#

.ForwardHelpTargetName Set-Location
.ForwardHelpCategory Cmdlet

#>

# Get cdHistory and hydrate a in-memory collection
$global:history = @()
if ((Test-Path -Path $cdHistory)) {
    $global:history += Get-Content -Path $cdHistory -Encoding UTF8 | Where-Object { (-not [String]::IsNullOrWhiteSpace($_)) } | ConvertTo-DirectoryEntry
}

# $orig_cd = (Get-Alias -Name 'cd').Definition
# $orig_pushd = (Get-Alias -Name 'pushd').Definition
# $orig_popd = (Get-Alias -Name 'popd').Definition
# $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
#     set-item alias:cd -value $orig_cd
#     set-item alias:pushd -value $orig_pushd
#     set-item alias:popd -value $orig_popd
# }

#Override the existing CD command with the wrapper in order to log 'cd' commands.
# Set-item alias:cd -Value 'pushdX'
# Set-item alias:pushd -Value 'pushdX'
# Set-item alias:popd -Value 'popdX'

Set-Alias -Name pushd -Value pushdX -Force -Option AllScope -Scope Global
Set-Alias -Name cd -Value pushdX -Force -Option AllScope -Scope Global
Set-Alias -Name popd -Value popdX -Force -Option AllScope -Scope Global

Export-ModuleMember -Function z, cdX, pushdX, popdX, zz -Alias cd, pushd, popd

# Tab Completion
$completion_RunningService = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $global:history | Sort-Object { $_.Rank } -Descending | Where-Object { $_.Path.Name -like "*$wordToComplete*" } |
    ForEach-Object { New-Object System.Management.Automation.CompletionResult ("'{0}'" -f $_.Path.FullName), $_.Path.FullName, 'ParameterName', ('{0} ({1})' -f $_.Path.Name, $_.Path.FullName) }
}

if (-not $global:options) { $global:options = @{CustomArgumentCompleters = @{}; NativeArgumentCompleters = @{} } }

$global:options['CustomArgumentCompleters']['z:JumpPath'] = $Completion_RunningService

$function:tabexpansion2 = $function:tabexpansion2 -replace 'End(\r\n|\n){', 'End { if ($null -ne $options) { $options += $global:options} else {$options = $global:options}'