$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(
    Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $root 'Public') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $root 'Private') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File
)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) {
        throw ("PowerShell syntax error in {0}: {1}" -f $file.Name, $errors[0].Message)
    }
}
Write-Host ("Passed: parsed {0} PowerShell files." -f $files.Count)
