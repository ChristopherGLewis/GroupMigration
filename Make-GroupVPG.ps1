#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Migration Type")]  [ValidateSet('Mig','DR','FP')] [string] $MigrationType,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Source Server")] [String] $ZertoSourceServer,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Zerto Source Server Port")] [int] $ZertoSourceServerPort = 9669,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Source User")] [String] $ZertoUser,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "DumpJSON use -DumpJson:`$False to bypass")] [Switch] $DumpJson = $True,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $ver
)
#Add-Type -TypeDefinition "public enum VPGMigrationType { MigVPG, DRVPG, FPVPG }"

$ScriptVersion = "1.0"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

#AutoImport doesn't work for Script modules
Import-Module ZertoModule
#This downloads the ZertoModule from PowerShell Gallery
#Install-Module -Name ZertoModule

$NSMSource = '\\nuveen.com\Departments\EO\Logs\Servers\NSM.csv'
#$VPGSource = '\\nuveen.com\Departments\EO\Logs\Servers\ZertoVPGs.csv'
$VPGSource = 'C:\Users\lewish\Documents\TIAA Work\Groups\ZertoVPGs.csv'

$VPGData = Import-Csv -Path $VPGSource | Where-Object {$_.ZertoVPG -eq $GroupName}
If ($VPGData -eq $null) { throw "Invalid VPG Group Name" }

if ($MigrationType -eq  'Mig') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.MigVPG -eq $GroupName}
} elseif ($MigrationType -eq 'DR') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.DRVPG -eq $GroupName}
} elseif ($MigrationType -eq 'FP') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.FPVPG -eq $GroupName}
}
If ( ($NSMData -eq $null) -or ($NSMData.Count -eq 0) ) { throw "No VM's for VPG Group '$GroupName'" }

#Log Into Zerto
Set-Item ENV:ZertoServer $ZertoSourceServer
Set-Item ENV:ZertoPort $ZertoSourceServerPort
Set-ZertoAuthToken -ZertoUser $ZertoUser

#Create our array of VMs'
$AllVMS = @()
$NSMData | ForEach-Object {
    #Check for Test IP
    if ( [System.String]::IsNullOrEmpty( $_.($MigrationType + 'TestIPAddress') ) ) {
        $IP = New-ZertoVPGFailoverIPAddress -NICName 'Network adapter 1' `
                                    -IPAddress  $_.($MigrationType + 'EventIPAddress') `
                                    -SubnetMask $_.($MigrationType + 'EventSubnetMask') `
                                    -Gateway    $_.($MigrationType + 'EventGateway') `
                                    -DNS1       $_.($MigrationType + 'EventDNS1') `
                                    -DNS2       $_.($MigrationType + 'EventDNS2') `
                                    -DNSSuffix  $_.DNSSuffix
    } else {
        $IP = New-ZertoVPGFailoverIPAddress -NICName 'Network adapter 1' `
                                    -IPAddress  $_.($MigrationType + 'EventIPAddress') `
                                    -SubnetMask $_.($MigrationType + 'EventSubnetMask') `
                                    -Gateway    $_.($MigrationType + 'EventGateway') `
                                    -DNS1       $_.($MigrationType + 'EventDNS1') `
                                    -DNS2       $_.($MigrationType + 'EventDNS2') `
                                    -DNSSuffix  $_.DNSSuffix `
                                    -TestIPAddress  $_.($MigrationType + 'TestIPAddress') `
                                    -TestSubnetMask $_.($MigrationType + 'TestSubnetMask') `
                                    -TestGateway    $_.($MigrationType + 'TestGateway') `
                                    -TestDNS1       $_.($MigrationType + 'TestDNS1') `
                                    -TestDNS2       $_.($MigrationType + 'TestDNS2') `
                                    -TestDNSSuffix  $_.DNSSuffix
    }

    $VM = New-ZertoVPGVirtualMachine -VMName $_.Name  -VPGFailoverIPAddress $IP
    $AllVMS += $VM
}

Write-Host ("Adding " + $AllVMS.Count + " VMs")

$VPGName = $VPGData.ZertoVPG
If ([string]::IsNullOrEmpty( $VPGData.ZertoReplicationPriority) ) {
   $Priority = 'Medium'
} else { 
   $Priority = $VPGData.ZertoReplicationPriority
}
$RecoverySiteName = $VPGData.ZertoRecoverySiteName
$HostCluster  = $VPGData.ZertoHostClusterName
$DatastoreClusterName = $VPGData.ZertoDatastoreClusterName
#Guess at our Datastore - we should probably 
$DatastoreName = $VPGData.ZertoDatastoreClusterName + '_03' 
$Network = $VPGData.ZertoFailoverNetwork
$TestNetwork = $VPGData.ZertoTestNetwork
$DefaultFolder = $VPGData.ZertoRecoveryFolder


Write-Host "Creating VPG '$VPGName' with destination '$RecoverySiteName'"
Write-Host "  Cluster:`t`t`t $HostCluster"
Write-Host "  DatastoreCluster:`t $DatastoreClusterName"
Write-Host "  Datastore:`t`t $DatastoreName"
Write-Host "  Network:`t`t`t $Network"
Write-Host "  TestNetwork:`t`t $TestNetwork"
Write-Host "  DefaultFolder:`t $DefaultFolder"

# 
If ($DumpJson) {
    Add-ZertoVPG -Priority $Priority  `
                -VPGName $VPGName `
                -RecoverySiteName $RecoverySiteName `
                -ClusterName  $HostCluster `
                -FailoverNetwork  $Network  `
                -TestNetwork $TestNetwork `
                -DatastoreName $DatastoreName `
                -JournalUseDefault $true `
                -Folder $DefaultFolder `
                -VPGVirtualMachines $AllVMS `
                -DumpJSON
} else {
    Add-ZertoVPG -Priority $Priority  `
                -VPGName $VPGName `
                -RecoverySiteName $RecoverySiteName `
                -ClusterName  $HostCluster `
                -FailoverNetwork  $Network  `
                -TestNetwork $TestNetwork `
                -DatastoreName $DatastoreName `
                -JournalUseDefault $true `
                -Folder $DefaultFolder `
                -VPGVirtualMachines $AllVMS
}
