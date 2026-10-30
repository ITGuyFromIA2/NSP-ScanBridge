@{
 RootModule = 'NSP.ScanBridge.psm1'
 ModuleVersion = '0.1.0'
 GUID = 'f18f448f-c735-4b80-a503-95a5f7098fd9'
 Author = 'Network Systems Plus'
 CompanyName = 'Network Systems Plus'
 Description = 'Unattended scanner to SharePoint ingestion.'
 PowerShellVersion = '5.1'
 FunctionsToExport = @('Get-NSPScanBridgeHealth', 'Invoke-NSPScanBridge', 'Test-NSPScanBridgeFileReady', 'Test-NSPScanBridgeHealth', 'Send-NSPScanBridgeAlert')
 CmdletsToExport = @()
 VariablesToExport = @()
 AliasesToExport = @()
 PrivateData = @{ PSData = @{ Tags = @('NSP','SharePoint','Scanner'); ProjectUri = 'https://github.com/ITGuyFromIA2/NSP-ScanBridge' } }
}
