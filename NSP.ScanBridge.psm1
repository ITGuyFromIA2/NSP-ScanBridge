# One function per file.
foreach ($folder in 'Private', 'Public') {
    $directory = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $directory)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File | Sort-Object Name) { . $file.FullName }
}
