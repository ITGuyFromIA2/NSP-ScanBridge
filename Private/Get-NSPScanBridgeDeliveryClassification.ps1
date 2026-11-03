function Get-NSPScanBridgeDeliveryClassification {
    <#
    .SYNOPSIS
        Classifies one delivery lifecycle as DirectExclusive, DirectReadable, TempRename, Hybrid or Unknown.
    .DESCRIPTION
        Evidence comes from samples taken while the file was still changing. A shared-read open that
        the writer refused points to an exclusive writer; one it allowed points to a readable writer.
        Uncertain evidence stays Unknown or Hybrid rather than being forced into a class.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lifecycle)
    $evidence=New-Object System.Collections.Generic.List[string]
    $mid=@($Lifecycle.MidWrite)
    $rename=$Lifecycle.Rename
    $confidenceFor={ param([int]$Count) if($Count -ge 3){'High'}elseif($Count -ge 1){'Medium'}else{'Low'} }
    if ($rename -and $rename.FromExtension -ine '.pdf' -and $rename.ToExtension -ieq '.pdf') {
        $underTemp=@($mid | Where-Object { $_.Extension -ine '.pdf' })
        $afterRename=@($mid | Where-Object { $_.Extension -ieq '.pdf' })
        $evidence.Add(('Renamed {0} -> .pdf ({1}).' -f $rename.FromExtension,$rename.Method))
        if ($afterRename.Count) {
            $evidence.Add(('{0} change sample(s) after the rename.' -f $afterRename.Count))
            return [pscustomobject]@{Class='Hybrid';Confidence='Low';Evidence=@($evidence)}
        }
        if ($underTemp.Count) { $evidence.Add(('{0} sample(s) while growing under the temporary name.' -f $underTemp.Count)) }
        else { $evidence.Add('No growth seen under the temporary name; the write was shorter than one sample.') }
        $confidence=if($rename.Method -eq 'Watcher' -and $underTemp.Count){'High'}elseif($rename.Method -eq 'Watcher' -or $underTemp.Count){'Medium'}else{'Low'}
        return [pscustomobject]@{Class='TempRename';Confidence=$confidence;Evidence=@($evidence)}
    }
    if ($rename -and $rename.FromExtension -ieq '.pdf' -and $rename.ToExtension -ieq '.pdf') {
        # The temporary name already matches the worker's *.pdf filter, so it is visible while written.
        $evidence.Add(('Renamed {0} -> {1} ({2}): the temporary name already ends in .pdf, so the worker can see it while it is written.' -f $rename.FromExtension,$rename.ToExtension,$rename.Method))
        return [pscustomobject]@{Class='Hybrid';Confidence='Low';Evidence=@($evidence)}
    }
    if ($rename) { $evidence.Add(('Renamed {0} -> {1}; not a temporary-to-PDF rename.' -f $rename.FromExtension,$rename.ToExtension)) }
    $direct=@($mid | Where-Object { $_.Extension -ieq '.pdf' -and $_.Shared -in @('Available','Unavailable') })
    if (-not $direct.Count) {
        $evidence.Add('No sample while the file was changing; it appeared at its final size, or the write was shorter than one sample.')
        return [pscustomobject]@{Class='Unknown';Confidence='Low';Evidence=@($evidence)}
    }
    $allowed=@($direct | Where-Object Shared -eq 'Available').Count
    $refused=@($direct | Where-Object { $_.Shared -eq 'Unavailable' -and $_.SharedError -in @('SharingViolation','LockViolation') }).Count
    $other=$direct.Count-$allowed-$refused
    $evidence.Add(('While writing: shared read allowed {0}, refused by sharing {1}, other errors {2}.' -f $allowed,$refused,$other))
    if ($other) {
        $evidence.Add('A probe failed for a reason other than sharing (for example access denied); permissions limit what can be inferred.')
        return [pscustomobject]@{Class='Unknown';Confidence='Low';Evidence=@($evidence)}
    }
    if ($refused -and -not $allowed) { return [pscustomobject]@{Class='DirectExclusive';Confidence=(& $confidenceFor $refused);Evidence=@($evidence)} }
    if ($allowed -and -not $refused) { return [pscustomobject]@{Class='DirectReadable';Confidence=(& $confidenceFor $allowed);Evidence=@($evidence)} }
    $evidence.Add('Shared read alternated between allowed and refused; the writer may close and reopen between writes.')
    [pscustomobject]@{Class='Hybrid';Confidence='Low';Evidence=@($evidence)}
}
