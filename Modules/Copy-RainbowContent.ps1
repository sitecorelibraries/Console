#Requires -Modules SPE
 
function Copy-RainbowContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject]$SourceSession,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject]$DestinationSession,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootId,

        [switch]$Recurse,

        [switch]$RemoveNotInSource,

        [ValidateSet("SkipExisting", "Overwrite", "CompareRevision")]
        [string]$CopyBehavior,

        [switch]$CheckDependencies,

        [switch]$Detailed
    )

    function Write-Message {
        param(
            [string]$Message,
            [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::White,
            [switch]$Hide
        )

        if(!$Hide) {
            Write-Host $Message -ForegroundColor $ForegroundColor
        }
    }
   
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $recurseChildren = $Recurse.IsPresent
    $skipExisting = $CopyBehavior -eq "SkipExisting"
    $compareRevision = $CopyBehavior -eq "CompareRevision"
    $overwrite = $CopyBehavior -eq "Overwrite"
    $bulkCopy = $true

    $dependencyScript = {
        $dependencies = Get-ChildItem -Path "$($AppPath)\bin" -Include "Unicorn.*","Rainbow.*" -Recurse | 
            Select-Object -ExpandProperty Name
        
        $result = $true
        if($dependencies -contains "Unicorn.dll" -and $dependencies -contains "Rainbow.dll") {
            $result = $result -band $true
        } else {
            $result = $result -band $false
        }

        if($result) {
            $result = $result -band (@(Get-Command -Noun "RainbowYaml").Count -gt 0)
        }

        $result
    }

    if($CheckDependencies) {
        Write-Message "Verifying connection with remote servers"
        if(-not(Test-RemoteConnection -Session $SourceSession -Quiet)) {
            Write-Message "- Unable to connect to $($SourceSession.Connection[0].BaseUri)"
            return
        }
        if(-not(Test-RemoteConnection -Session $DestinationSession -Quiet)) {
            Write-Message "Unable to connect to $($DestinationSession.Connection[0].BaseUri)"
            return
        }
        Write-Message "Verifying both systems have Rainbow and Unicorn" -Hide:(!$Detailed)
        $isReady = Invoke-RemoteScript -ScriptBlock $dependencyScript -Session $SourceSession

        if($isReady) {
            $isReady = Invoke-RemoteScript -ScriptBlock $dependencyScript -Session $DestinationSession
        }

        if(!$isReady) {
            Write-Message "- Missing required installation of Rainbow and Unicorn" -Hide:(!$Detailed)
            return
        } else {
            Write-Message "- Verification complete" -Hide:(!$Detailed)
        }
    }

    if($bulkCopy) {
        $checkIsMediaScript = {
            $rootId = "{ROOT_ID}"
            $db = Get-Database -Name "master"
            $item = $db.GetItem($rootId)
            if($item) {
                $item.Paths.Path.StartsWith("/sitecore/media library/")
            } else {
                $false
            }
        }
        $checkIsMediaScript = [scriptblock]::Create($checkIsMediaScript.ToString().Replace("{ROOT_ID}", $RootId))
        $bulkCopy = !(Invoke-RemoteScript -ScriptBlock $checkIsMediaScript -Session $SourceSession)
    }

    Write-Message "[Running] Transfer from $($SourceSession.Connection[0].BaseUri) to $($DestinationSession.Connection[0].BaseUri)" -ForegroundColor Green
    Write-Message "[Options] RootId = $($RootId); CopyBehavior = $($CopyBehavior); Recurse = $($Recurse); RemoveNotInSource = $($RemoveNotInSource)"

    class ShallowItem {
        [string]$ItemId
        [string]$RevisionId
        [string]$ParentId
    }

    $compareScript = {
        $rootId = "{ROOT_ID}"
        $recurseChildren = [bool]::Parse("{RECURSE_CHILDREN}")
        Import-Function -Name Invoke-SqlCommand
        $connection = [Sitecore.Configuration.Settings]::GetConnectionString("master")

        $revisionFieldId = "{8CDC337E-A112-42FB-BBB4-4143751E123F}"
        if($recurseChildren) {
            $query = "
                WITH [ContentQuery] AS (SELECT [ID], [Name], [ParentID] FROM [dbo].[Items] WHERE ID='$($rootId)' UNION ALL SELECT  i.[ID], i.[Name], i.[ParentID] FROM [dbo].[Items] i INNER JOIN [ContentQuery] ci ON ci.ID = i.[ParentID])
                SELECT cq.[ID], vf.[Value] AS [Revision], cq.[ParentID] FROM [ContentQuery] cq INNER JOIN dbo.[VersionedFields] vf ON cq.[ID] = vf.[ItemId] WHERE vf.[FieldId] = '$($revisionFieldId)' AND vf.[Language] != '' AND vf.[Version] = (SELECT MAX(vf2.[Version]) FROM dbo.[VersionedFields] vf2 WHERE vf2.[ItemId] = cq.[Id])
            "
        } else {
            $query = "
                WITH [ContentQuery] AS (SELECT [ID], [Name], [ParentID] FROM [dbo].[Items] WHERE ID='$($rootId)')
                SELECT cq.[ID], vf.[Value] AS [Revision], cq.[ParentID] FROM [ContentQuery] cq INNER JOIN dbo.[VersionedFields] vf ON cq.[ID] = vf.[ItemId] WHERE vf.[FieldId] = '$($revisionFieldId)' AND vf.[Language] != '' AND vf.[Version] = (SELECT MAX(vf2.[Version]) FROM dbo.[VersionedFields] vf2 WHERE vf2.[ItemId] = cq.[Id])
            "
        }
        $records = Invoke-SqlCommand -Connection $connection -Query $query
        if($records) {
            $itemIds = $records | ForEach-Object { "I:{$($_.ID)}+R:{$($_.Revision)}+P:{$($_.ParentID)}" }
            $itemIds -join "|"
        }
    }
    $compareScript = [scriptblock]::Create($compareScript.ToString().Replace("{ROOT_ID}", $RootId).Replace("{RECURSE_CHILDREN}", $recurseChildren))

    Write-Message "- Querying item list from source"
    $s1 = [System.Diagnostics.Stopwatch]::StartNew()
    $sourceTree = [System.Collections.Generic.Dictionary[string,[System.Collections.Generic.List[ShallowItem]]]]([StringComparer]::OrdinalIgnoreCase)
    $sourceTree.Add($RootId, [System.Collections.Generic.List[ShallowItem]]@())
    $sourceRecordsString = Invoke-RemoteScript -Session $SourceSession -ScriptBlock $compareScript -Raw
    if([string]::IsNullOrEmpty($sourceRecordsString)) {
        Write-Message "- No items found in source"
        return
    }
    
    $sourceItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
    $sourceItemRevisionLookup = @{}
    foreach($sourceRecord in $sourceRecordsString.Split("|".ToCharArray(), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $shallowItem = [ShallowItem]@{
            "ItemId"=$sourceRecord.Substring(2,38)
            "RevisionId"=$sourceRecord.Substring(43,38)
            "ParentId"=$sourceRecord.Substring(84,38)
        }
        if($sourceItemsHash.Contains($shallowItem.ItemId)) {
            Write-Message " - Detected duplicate item $($shallowItem.ItemId)" -ForegroundColor Yellow
            Write-Message "  - Revision $($shallowItem.RevisionId)" -ForegroundColor Yellow
            Write-Message "  - Revision $($sourceItemRevisionLookup[$shallowItem.ItemId])" -ForegroundColor Yellow
        }
        $sourceItemsHash.Add($shallowItem.ItemId) > $null
        $sourceItemRevisionLookup[$shallowItem.ItemId] = $shallowItem.RevisionId
        if(!$sourceTree.ContainsKey($shallowItem.ItemId)) {
            $sourceTree[$shallowItem.ItemId] = [System.Collections.Generic.List[ShallowItem]]@()
        }
        $childCollection = $sourceTree[$shallowItem.ParentId]
        if(!$childCollection) {
            $childCollection = [System.Collections.Generic.List[ShallowItem]]@()
        }
        $childCollection.Add($shallowItem) > $null
        $sourceTree[$shallowItem.ParentId] = $childCollection
    }
    $sourceShallowItemsCount = $sourceItemsHash.Count
    $s1.Stop()
    Write-Message " - Found $($sourceShallowItemsCount) item(s) in $($s1.ElapsedMilliseconds / 1000) seconds"

    $skipItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
    $destinationItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
    $destinationItemRevisionLookup = @{}
    if(!$overwrite -or $RemoveNotInSource) {
        Write-Message "- Querying item list from destination"
        $d1 = [System.Diagnostics.Stopwatch]::StartNew()
        $destinationRecordsString = Invoke-RemoteScript -Session $DestinationSession -ScriptBlock $compareScript -Raw
        
        if(![string]::IsNullOrEmpty($destinationRecordsString)) {
            foreach($destinationRecord in $destinationRecordsString.Split("|".ToCharArray(), [System.StringSplitOptions]::RemoveEmptyEntries)) {
                $shallowItem = [ShallowItem]@{
                    "ItemId"=$destinationRecord.Substring(2,38)
                    "RevisionId"=$destinationRecord.Substring(43,38)
                    "ParentId"=$destinationRecord.Substring(84,38)
                }
                if($destinationItemsHash.Contains($shallowItem.ItemId)) {
                    Write-Message " - Detected duplicate item $($shallowItem.ItemId)" -ForegroundColor Yellow
                    Write-Message "  - Revision $($shallowItem.RevisionId)" -ForegroundColor Yellow
                    Write-Message "  - Revision $($destinationItemRevisionLookup[$shallowItem.ItemId])" -ForegroundColor Yellow
                }
                $destinationItemsHash.Add($shallowItem.ItemId) > $null
                $destinationItemRevisionLookup[$shallowItem.ItemId] = $shallowItem.RevisionId
                if(($compareRevision -and $sourceItemRevisionLookup[$shallowItem.ItemId] -eq $shallowItem.RevisionId) -or
                    ($skipExisting -and $sourceTree.ContainsKey($shallowItem.ItemId))) {
                    $skipItemsHash.Add($shallowItem.ItemId) > $null
                }            
            }
        }
        $destinationShallowItemsCount = $destinationItemsHash.Count
        $d1.Stop()
        Write-Message " - Found $($destinationShallowItemsCount) item(s) in $($d1.ElapsedMilliseconds / 1000) seconds"
    }

    $pullCounter = 0
    $pushCounter = 0
    $errorCounter = 0
    $updateCounter = 0
    
    function New-PowerShellRunspace {
        param(
            [System.Management.Automation.Runspaces.RunspacePool]$Pool,
            [scriptblock]$ScriptBlock,
            [PSCustomObject]$Session,
            [object[]]$Arguments
        )
        
        $runspace = [PowerShell]::Create()
        $runspace.AddScript($ScriptBlock) > $null
        $runspace.AddArgument($Session) > $null
        foreach($argument in $Arguments) {
            $runspace.AddArgument($argument) > $null
        }
        $runspace.RunspacePool = $pool

        $runspace
    }

    $sourceScript = {
        param(
            $Session,
            [string]$ItemIdListString
        )

        $script = {
            $sd = New-Object Sitecore.SecurityModel.SecurityDisabler
            $builder = New-Object System.Text.StringBuilder

            $db = Get-Database -Name "master"
            $itemIdList = $itemIdListString.Split("|".ToCharArray(), [System.StringSplitOptions]::RemoveEmptyEntries)
            foreach($itemId in $itemIdList) {
                $item = $db.GetItem([ID]$itemId)

                $itemYaml = $item | ConvertTo-RainbowYaml  
                $builder.Append($itemYaml) > $null
                $builder.Append("<#item#>") > $null
            }

            $builder.ToString()
            $sd.Dispose() > $null  
        }

        $scriptString = $script.ToString()
        $scriptString = "`$itemIdListString = '$($ItemIdListString)';`n" + $scriptString
        $script = [scriptblock]::Create($scriptString)

        Invoke-RemoteScript -ScriptBlock $script -Session $Session -Raw
    }

    $destinationScript = {
        param(
            $Session,
            [string]$Yaml,
            [hashtable]$RevisionLookup
        )

        $rainbowYaml = $Yaml
        # The '__Revision' field and IDs in Unicorn/Rainbow yaml are stored without curly braces.
        # Trimming it here to simplify the logic running on the remote server.
        $revisionLookupString = New-Object System.Text.StringBuilder
        $revisionLookupString.Append("@{") > $null
        foreach($key in $RevisionLookup.Keys) {
            $revisionLookupString.Append("`"$($key.TrimStart('{').TrimEnd('}'))`"=`"$($RevisionLookup[$key].TrimStart('{').TrimEnd('}'))`";") > $null
        }
        $revisionLookupString.Append("}") > $null

        $script = {
            $sd = New-Object Sitecore.SecurityModel.SecurityDisabler
            $ed = New-Object Sitecore.Data.Events.EventDisabler
            $buc = New-Object Sitecore.Data.BulkUpdateContext

            $rainbowYamlBytes = [System.Convert]::FromBase64String($rainbowYamlBase64)
            $rainbowYaml = [System.Text.Encoding]::UTF8.GetString($rainbowYamlBytes)
            $rainbowItems = $rainbowYaml -split '<#item#>' | Where-Object { ![string]::IsNullOrEmpty($_) } | ConvertFrom-RainbowYaml

            $totalItems = $rainbowItems.Count
            $importedItems = 0
            $errorCount = 0
            $errorMessages = New-Object System.Text.StringBuilder
            $rainbowItems | ForEach-Object {
                $currentRainbowItem = $_
                $itemId = "$($currentRainbowItem.Id)"             
                try {
                    Import-RainbowItem -Item $currentRainbowItem
                                       
                    if($revisionLookup.ContainsKey($itemId)) {                    
                        $db = Get-Database -Name "master"
                        $currentItem = $db.GetItem($itemId)
                        $currentItem.Editing.BeginEdit()
                        $currentItem.Fields["__Revision"].Value = $revisionLookup[$itemId]
                        $currentItem.Editing.EndEdit($false, $true)
                    } else {
                        $errorCount++
                        $errorMessages.Append("No matching item found in lookup table.") > $null
                        $errorMessages.Append("$($itemId)") > $null
                    }
                    $importedItems++
                } catch {
                    $errorCount++
                    Write-Log "Importing $($itemId) failed with error $($Error[0].Exception.Message)"
                    Write-Log ($currentRainbowItem | Select-Object -Property Id,ParentId,Path | ConvertTo-Json)
                    $errorMessages.Append("$($itemId) Failed") > $null
                }
            } > $null

            $buc.Dispose() > $null
            $ed.Dispose() > $null
            $sd.Dispose() > $null

            "{ TotalItems: $($totalItems), ImportedItems: $($importedItems), ErrorCount: $($errorCount), ErrorMessages: '$($errorMessages.ToString())' }"
        }

        $scriptString = $script.ToString()
        $trueFalseHash = @{$true="`$true";$false="`$false"}
        $rainbowYamlBytes = [System.Text.Encoding]::UTF8.GetBytes($rainbowYaml)
        $scriptString = "`$rainbowYamlBase64 = '$([System.Convert]::ToBase64String($rainbowYamlBytes))';`n`$revisionLookup = $($revisionLookupString.ToString());" + $scriptString
        $script = [scriptblock]::Create($scriptString)

        Invoke-RemoteScript -ScriptBlock $script -Session $Session -Raw
    }

    $pushedLookup = @{}
    $pullPool = [RunspaceFactory]::CreateRunspacePool(1, 2)
    $pullPool.Open()
    $pullRunspaces = [System.Collections.ArrayList]@()
    $pushPool = [RunspaceFactory]::CreateRunspacePool(1, 4)
    $pushPool.Open()
    $pushRunspaces = [System.Collections.ArrayList]@()

    class QueueItem {
        [string]$ItemId
        [string]$Yaml
        [hashtable]$RevisionLookup
    }

    Write-Message "Spinning up jobs to transfer content" -Hide:(!$Detailed)
    
    $processedItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
    $skippedItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
    $pullQueue = [System.Collections.Generic.Queue[ShallowItem]]@()
    $pullQueue.Enqueue([ShallowItem]@{"ItemId"=$RootId;"ParentId"=""})
    $pullLookup = @{}

    $keepProcessing = $true
    while($keepProcessing) {
        Write-Progress -Activity "Transfer of $($RootId) from $($SourceSession.Connection[0].BaseUri) to $($DestinationSession.Connection[0].BaseUri)" -Status "Pull $($pullCounter), Push $($pushCounter)" -PercentComplete ([Math]::Min(($updateCounter + $skippedItemsHash.Count) * 100 / $sourceShallowItemsCount, 100))
        while($pullQueue.Count -gt 0) {
            $itemIdList = [System.Collections.ArrayList]@()
            $pullQueueItem = $pullQueue.Dequeue()
            $itemId = $pullQueueItem.ItemId
            $parentId = $pullQueueItem.ParentId
            $processedItemsHash.Add($itemId) > $null
            if(($skipExisting -and $skipItemsHash.Contains($itemId)) -or 
                ($compareRevision -and $destinationItemsHash.Contains($itemId) -and 
                    $sourceItemRevisionLookup[$itemId] -eq $destinationItemRevisionLookup[$itemId])) {
                Write-Message "[Skip] $($itemId)" -ForegroundColor Cyan -Hide:(!$Detailed)
                $skippedItemsHash.Add($itemId) > $null
            } else {
                $itemIdList.Add($itemId) > $null
                $pushedLookup.Add($itemId, [System.Collections.ArrayList]@()) > $null
            }

            if($bulkCopy) {
                $childItems = $sourceTree[$itemId]
                foreach($childItem in $childItems) {
                    $childId = $childItem.ItemId
                    $processedItemsHash.Add($childId) > $null
                    if($skipExisting -and $skipItemsHash.Contains($childId) -or 
                        ($compareRevision -and $destinationItemsHash.Contains($childId) -and $sourceItemRevisionLookup[$childId] -eq $destinationItemRevisionLookup[$childId])) {
                        Write-Message "[Skip] $($childId)" -ForegroundColor Cyan -Hide:(!$Detailed)
                        $skippedItemsHash.Add($childId) > $null
                    } else {
                        $itemIdList.Add($childId) > $null
                        $pushedLookup.Add($childId, [System.Collections.ArrayList]@()) > $null
                    }

                    $grandchildItems = $sourceTree[$childId]
                    foreach($grandchildItem in $grandchildItems) {
                        $grandchildId = $grandchildItem.ItemId
                        $processedItemsHash.Add($grandchildId) > $null
                        if($skipExisting -and $skipItemsHash.Contains($grandchildId) -or 
                            ($compareRevision -and $destinationItemsHash.Contains($grandchildId) -and $sourceItemRevisionLookup[$grandchildId] -eq $destinationItemRevisionLookup[$grandchildId])) {
                            Write-Message "[Skip] $($grandchildId)" -ForegroundColor Cyan -Hide:(!$Detailed)
                            $skippedItemsHash.Add($grandchildId) > $null
                        } else {
                            $itemIdList.Add($grandchildId) > $null
                            $pushedLookup.Add($grandchildId, [System.Collections.ArrayList]@()) > $null
                        }
                    }
                }
            }

            if($itemIdList.Count -gt 0) {
                $pullLookup[$itemId] = $itemIdList
                Write-Message "[Pull] $($itemId)" -ForegroundColor Green -Hide:(!$Detailed)
                $runspaceProps = @{
                    ScriptBlock = $sourceScript
                    Pool = $pullPool
                    Session = $SourceSession
                    Arguments = @(($itemIdList -join "|"))
                }
                $runspace = New-PowerShellRunspace @runspaceProps
                $pullRunspaces.Add([PSCustomObject]@{
                    Operation = "Pull"
                    Pipe = $runspace
                    Status = $runspace.BeginInvoke()
                    Id = $itemId
                    ParentId = $parentId
                    Time = [datetime]::Now
                }) > $null
            } else {
                $runspaceProps = @{
                    ScriptBlock = {}
                    Pool = $pullPool
                    Session = $SourceSession
                    Arguments = @()
                }
                $runspace = New-PowerShellRunspace @runspaceProps
                $pullRunspaces.Add([PSCustomObject]@{
                    Skip = $true
                    Operation = "Pull"
                    Pipe = $runspace
                    Status = [PSCustomObject]@{"IsCompleted"=$true}
                    Id = $itemId
                    ParentId = $parentId
                    Time = [datetime]::Now
                }) > $null
            }
        }

        $currentRunspaces = $pushRunspaces.ToArray() + $pullRunspaces.ToArray()
        foreach($currentRunspace in $currentRunspaces) {
            if(!$currentRunspace.Status.IsCompleted) { continue }
            
            $skipped = $currentRunspace.Skip
            $response = & { 
                if($skipped) { $null }
                else { $currentRunspace.Pipe.EndInvoke($currentRunspace.Status) }
            }
            if(!$skipped) {
                if($currentRunspace.Operation -eq "Pull") {
                    [System.Threading.Interlocked]::Increment([ref] $pullCounter) > $null
                } elseif ($currentRunspace.Operation -eq "Push") {
                    [System.Threading.Interlocked]::Increment([ref] $pushCounter) > $null
                }
                Write-Message "[$($currentRunspace.Operation)] $($currentRunspace.Id) completed" -ForegroundColor Gray -Hide:(!$Detailed)
                Write-Message "- Processed in $(([datetime]::Now - $currentRunspace.Time))" -ForegroundColor Gray -Hide:(!$Detailed)
            }

            if($currentRunspace.Operation -eq "Pull") {                
                if($skipped -or (![string]::IsNullOrEmpty($response) -and [regex]::IsMatch($response,"^---"))) {               
                    $yaml = $response
                    $revisionLookup = @{}
                    $pulledIdList = $pullLookup[$currentRunspace.Id]
                    foreach($pulledItemId in $pulledIdList) {
                        $revisionLookup.Add($pulledItemId, $sourceItemRevisionLookup[$pulledItemId]) > $null
                    }

                    if($bulkCopy) {
                        foreach($child in $sourceTree[$currentRunspace.Id]) {
                            foreach($grandchild in $sourceTree[$child.ItemId]) {
                                foreach($greatgrandchild in $sourceTree[$grandchild.ItemId]) {                                    
                                    $pullQueue.Enqueue($greatgrandchild) > $null
                                }
                            }
                        }
                    } else {
                        foreach($child in $sourceTree[$currentRunspace.Id]) {
                            $pullQueue.Enqueue($child) > $null
                        }
                    }
                    if($pushedLookup.Contains($currentRunspace.ParentId)) {
                        Write-Message "[Queue] $($currentRunspace.Id)" -ForegroundColor Cyan -Hide:(!$Detailed)
                        $pushedLookup[$currentRunspace.ParentId].Add([QueueItem]@{"ItemId"=$currentRunspace.Id;"Yaml"=$yaml;"RevisionLookup"=$revisionLookup;}) > $null
                    } else {
                        if(!$skipped) {                 
                            Write-Message "[Push] $($currentRunspace.Id)" -ForegroundColor Gray -Hide:(!$Detailed)
                            $runspaceProps = @{
                                ScriptBlock = $destinationScript
                                Pool = $pushPool
                                Session = $DestinationSession
                                Arguments = @($yaml,$revisionLookup)
                            }
                            $runspace = New-PowerShellRunspace @runspaceProps  
                            $pushRunspaces.Add([PSCustomObject]@{
                                Operation = "Push"
                                Pipe = $runspace
                                Status = $runspace.BeginInvoke()
                                Id = $currentRunspace.Id
                                ParentId = $currentRunspace.ParentId
                                Time = [datetime]::Now
                            }) > $null
                        }
                    }
                }

                $currentRunspace.Pipe.Dispose()
                $pullRunspaces.Remove($currentRunspace)
            }

            if($currentRunspace.Operation -eq "Push") {
                if(![string]::IsNullOrEmpty($response)) {
                    $feedback = $response | ConvertFrom-Json
                    Write-Message "- Imported $($feedback.ImportedItems)/$($feedback.TotalItems)" -ForegroundColor Gray -Hide:(!$Detailed)
                    1..$feedback.ImportedItems | ForEach-Object { [System.Threading.Interlocked]::Increment([ref] $updateCounter) > $null }
                    if($feedback.ErrorCount -gt 0) {
                        [System.Threading.Interlocked]::Increment([ref] $errorCounter) > $null
                        Write-Message "- Errored $($feedback.ErrorCount)" -ForegroundColor Red -Hide:(!$Detailed)
                        Write-Message " - $($feedback.ErrorMessages)" -ForegroundColor Red -Hide:(!$Detailed)
                    }
                }

                $queuedItems = [System.Collections.ArrayList]@()
                if($pushedLookup.ContainsKey($currentRunspace.Id)) {
                    $queuedItems.AddRange($pushedLookup[$currentRunspace.Id])
                    $pushedLookup.Remove($currentRunspace.Id) > $null
                }
                
                if($bulkCopy) {
                    foreach($child in $sourceTree[$currentRunspace.Id]) {
                        $queuedChildItems = $pushedLookup[$child.ItemId]
                        if($queuedChildItems.Count -gt 0) {
                            $queuedItems.AddRange($queuedChildItems) > $null
                        }
                        $pushedLookup.Remove($child.ItemId) > $null
                        foreach($grandChild in $sourceTree[$child.ItemId]) {
                            $queuedGrandchildItems = $pushedLookup[$grandChild.ItemId]
                            if($queuedGrandchildItems.Count -gt 0) {
                                $queuedItems.AddRange($queuedGrandchildItems) > $null
                            }
                            $pushedLookup.Remove($grandChild.ItemId) > $null
                        }
                    }
                }
                if($queuedItems.Count -gt 0) {
                    foreach($queuedItem in $queuedItems) {
                        $itemId = $queuedItem.ItemId
                        Write-Message "[Dequeue] $($itemId)" -ForegroundColor Cyan -Hide:(!$Detailed)
                        Write-Message "[Push] $($itemId)" -ForegroundColor Green -Hide:(!$Detailed)
                        $runspaceProps = @{
                            ScriptBlock = $destinationScript
                            Pool = $pushPool
                            Session = $DestinationSession
                            Arguments = @($queuedItem.Yaml,$queuedItem.RevisionLookup)
                        }

                        $runspace = New-PowerShellRunspace @runspaceProps  
                        $pushRunspaces.Add([PSCustomObject]@{
                            Operation = "Push"
                            Pipe = $runspace
                            Status = $runspace.BeginInvoke()
                            Id = $itemId
                            ParentId = $currentRunspace.Id
                            Time = [datetime]::Now
                        }) > $null
                    }
                }
                
                $currentRunspace.Pipe.Dispose()
                $pushRunspaces.Remove($currentRunspace)
            }
        }

        $keepProcessing = ($pullQueue.Count -gt 0 -or $pullRunspaces.Count -gt 0 -or $pushRunspaces.Count -gt 0)
    }

    $pullPool.Close() 
    $pullPool.Dispose()
    $pushPool.Close() 
    $pushPool.Dispose()

    if($RemoveNotInSource) {
        $removeItemsHash = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
        $removeItemsHash.UnionWith($destinationItemsHash)
        $removeItemsHash.ExceptWith($sourceItemsHash)

        if($removeItemsHash.Count -gt 0) {
            Write-Message "- Removing items from destination not in source"
            $itemsNotInSource = $removeItemsHash -join "|"
            $removeNotInSourceScript = {
                $sd = New-Object Sitecore.SecurityModel.SecurityDisabler
                $ed = New-Object Sitecore.Data.Events.EventDisabler
                $itemsNotInSource = "{ITEM_IDS}"
                $itemsNotInSourceIds = ($itemsNotInSource).Split("|", [System.StringSplitOptions]::RemoveEmptyEntries)
                $db = Get-Database -Name "master"
                foreach($itemId in $itemsNotInSourceIds) {
                    $db.GetItem($itemId) | Remove-Item -Recurse -ErrorAction 0
                }
                $ed.Dispose() > $null
                $sd.Dispose() > $null
            }
            $removeNotInSourceScript = [scriptblock]::Create($removeNotInSourceScript.ToString().Replace("{ITEM_IDS}", $itemsNotInSource))
            Invoke-RemoteScript -ScriptBlock $removeNotInSourceScript -Session $DestinationSession -Raw
            Write-Message " - Removed $($removeItemsHash.Count) item(s) from the destination"
        }
    }

    $watch.Stop()
    $totalSeconds = $watch.ElapsedMilliseconds / 1000
    Write-Message "[Done] Completed in $($totalSeconds) seconds" -ForegroundColor Green
    Write-Progress -Activity "[Done] Completed in $($totalSeconds) seconds" -Completed
    if($processedItemsHash.Count -gt 0) {
        Write-Message "- Processed count: $($processedItemsHash.Count)"
        Write-Message " - Update count: $($updateCounter)"
        Write-Message " - Skip count: $($skippedItemsHash.Count)"
        Write-Message " - Error count: $($errorCounter)"
        Write-Message " - Pull count: $($pullCounter)"
        Write-Message " - Push count: $($pushCounter)"
    }
}
