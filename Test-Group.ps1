<#
.SYNOPSIS
Tests the VPG and NSM lists for a given migration group

.DESCRIPTION
The Test-Group.ps1 script tests a migration group VPG's entries in the NSM

.PARAMETER GroupName 
Name of the Zerto VPG Migration Group.  Typically in the form Group01-CHAPDA or Group01-DENPDA

.PARAMETER MigrationType 
The migration type:
    MIG -> initial migration from FP to CHA/DEN 
    FP -> Migration back from CHA/DEN to FP as our parachute replication
    DR -> end state DR from CHAPDA to DENPDA


.PARAMETER Ver
Displays the version number and exits

.EXAMPLE 
#This DOES NOT commit the VPG

.\Test-Group.ps1 -GroupName 'GROUP01-CHAPDA' -MigrationType Mig 

.NOTES
Author: Chris Lewis
Date: 2017-03-17
Version: 1.2
History:
    1.0 Initial create
    1.1 Added used IP check
    1.2 Added better layout for test results
    1.3 Added Folder 
#>

#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Migration Type")]  [ValidateSet('Mig','DR','FP')] [string] $MigrationType,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)

function Get-Datastore {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Recovery Site Name")] [String] $RecoverySiteName,
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Recovery Site Name")] [String] $ZertoDatastoreClusterName

        )
    #Guess at our datastore
    switch ($RecoverySiteName) {
        'CHAPDA' {
            #Cluster s/b 'CHAPDA3Z_MNA01'
            $IDRange = 01..16
            $DatastoreName = $ZertoDatastoreClusterName + (Get-Random -InputObject $IDRange).ToString("_00")
        }
        'DENPDA' {
            #Cluster s/b 'DENPDA3Z_MNA01'
            $IDRange = 01..16
            $DatastoreName = $ZertoDatastoreClusterName + (Get-Random -InputObject $IDRange).ToString("_00")
        }
        'DENPDB' {
            #Cluster s/b 'DENPDB3Z_MNA01'
            $IDRange = 01..08
            $DatastoreName = $ZertoDatastoreClusterName + (Get-Random -InputObject $IDRange).ToString("_00")
        }
        'Zerto-IL1' {
            #Cluster s/b 'IL1VSP1_DUS_PRD_ZERTO_FAILBACK'
            if ($ZertoDatastoreClusterName -eq 'IL1VSP1_DUS_PRD_ZERTO_FAILBACK') {
                $DSArray = ('IL1VSP1_PRD_LD10BE_CP1_P1-6',
                            'IL1VSP1_PRD_LD10BD_CP2_P1-6',
                            'IL1VSP1_PRD_LD10BC_CP1_P0-6',
                            'IL1VSP1_PRD_LD10BB_CP2_P0-6',
                            'IL1VSP1_PRD_LD10BA_CP2_P0-6' )
                $DatastoreName = $DSArray | Get-Random
            } else {
                #throw "Invalid IL1 Cluster"
            }
        }
        default {
            throw "Invalid Remote Site"
        }
    }
    return $DatastoreName
}

$ScriptVersion = "1.3"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

$NSMSource = '\\nuveen.com\Departments\EO\Logs\Servers\NSM.csv'
$VPGSource = '\\nuveen.com\Departments\EO\Logs\Servers\ZertoVPGs.csv'

If ( -not (Test-Path $NSMSource) ) {
    throw "Cound not find NSMSource at '$NSMSource'"
    Return
}
If ( -not (Test-Path $VPGSource) ) {
    throw "Cound not find VPGSource at '$VPGSource'"
    Return
}

$VPGData = Import-Csv -Path $VPGSource | Where-Object {$_.ZertoVPG -eq $GroupName}
If ($VPGData -eq $null) { throw "Invalid VPG Group Name" }

#This VPG's NSM
Switch ($MigrationType) {
    'Mig' { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.MigVPG -eq $GroupName} }
    'DR'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.DRVPG -eq $GroupName} }
    'FP'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.FPVPG -eq $GroupName} }
    Default {throw "Invalid Migration Type '$MigrationType'"}
}
If ( ($NSMData -eq $null) -or ($NSMData.Count -eq 0) ) { throw "No VM's for VPG Group '$GroupName'" }

$FullNSM = Import-Csv -Path $NSMSource

$VPGName = $VPGData.ZertoVPG
If ([string]::IsNullOrEmpty( $VPGData.ZertoReplicationPriority) ) {
   $Priority = 'Medium'
} else { 
   $Priority = $VPGData.ZertoReplicationPriority
}
$RecoverySiteName = $VPGData.ZertoRecoverySiteName
$HostClusterName  = $VPGData.ZertoHostClusterName
$DatastoreClusterName = $VPGData.ZertoDatastoreClusterName
$DatastoreName =  Get-Datastore -RecoverySiteName $RecoverySiteName -ZertoDatastoreClusterName $DatastoreClusterName
$Network = $VPGData.ZertoFailoverNetwork
$TestNetwork = $VPGData.ZertoTestNetwork
$DefaultFolder = $VPGData.ZertoRecoveryFolder

#Display some VPG Information
$VPGErrors = 0
Write-Host "Creating VPG '$VPGName' with destination '$RecoverySiteName'"
Write-Host -NoNewline "  Cluster:`t`t`t $HostClusterName"
if ( [System.String]::IsNullOrEmpty( $HostClusterName ) ) { Write-Host -ForegroundColor Red "  *** Invalid HostClusterName $HostClusterName"; $VPGErrors++} else {Write-host ""}
Write-Host -NoNewline "  DatastoreCluster:`t $DatastoreClusterName"
if ( [System.String]::IsNullOrEmpty( $DatastoreClusterName ) ) { Write-Host -ForegroundColor Red "  *** Invalid DatastoreClusterName $DatastoreClusterName"; $VPGErrors++} else {Write-host ""}
Write-Host -NoNewline "  Datastore:`t`t $DatastoreName"
if ( [System.String]::IsNullOrEmpty( $DatastoreName ) ) { Write-Host -ForegroundColor Red "  *** Invalid DatastoreName $DatastoreName"; $VPGErrors++} else {Write-host ""}
Write-Host -NoNewline "  Network:`t`t`t $Network"
if ( [System.String]::IsNullOrEmpty( $Network ) ) { Write-Host -ForegroundColor Red "  *** Invalid Network $Network"; $VPGErrors++} else {Write-host ""}
Write-Host -NoNewline "  TestNetwork:`t`t $TestNetwork"
if ( [System.String]::IsNullOrEmpty( $TestNetwork ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestNetwork $TestNetwork"; $VPGErrors++} else {Write-host ""}
Write-Host -NoNewline "  DefaultFolder:`t $DefaultFolder"
if ( [System.String]::IsNullOrEmpty( $DefaultFolder ) ) { Write-Host -ForegroundColor Red "  *** Invalid HostClusterName $DefaultFolder"; $VPGErrors++} else {Write-host ""}

#Create our array of VMs'
$VMCount = 0
$VMErrors = 0
$NSMData | ForEach-Object {
    $ThisVM = $_  #Switch breaks $_
    $VMName =  $ThisVM.Name

    Switch ($MigrationType) {
        'Mig' { 
            $IPAddress = $ThisVM.($MigrationType + 'EventIPAddress')
            $SubnetMask = $ThisVM.($MigrationType + 'EventSubnetMask')
            $Gateway = $ThisVM.($MigrationType + 'EventGateway')
            $DNS1 = $ThisVM.($MigrationType + 'EventDNS1')
            $DNS2 = $ThisVM.($MigrationType + 'EventDNS2')
            $TestIPAddress = $ThisVM.($MigrationType + 'TestIPAddress')
            $TestSubnetMask = $ThisVM.($MigrationType + 'TestSubnetMask')
            $TestGateway = $ThisVM.($MigrationType + 'TestGateway')
            $TestDNS1 = $ThisVM.($MigrationType + 'TestDNS1')
            $TestDNS2 = $ThisVM.($MigrationType + 'TestDNS2')
         }
        'DR'  { 
            $IPAddress = $ThisVM.($MigrationType + 'EventIPAddress')
            $SubnetMask = $ThisVM.($MigrationType + 'EventSubnetMask')
            $Gateway = $ThisVM.($MigrationType + 'EventGateway')
            $DNS1 = $ThisVM.($MigrationType + 'EventDNS1')
            $DNS2 = $ThisVM.($MigrationType + 'EventDNS2')
            $TestIPAddress = $ThisVM.($MigrationType + 'TestIPAddress')
            $TestSubnetMask = $ThisVM.($MigrationType + 'TestSubnetMask')
            $TestGateway = $ThisVM.($MigrationType + 'TestGateway')
            $TestDNS1 = $ThisVM.($MigrationType + 'TestDNS1')
            $TestDNS2 = $ThisVM.($MigrationType + 'TestDNS2')
         }
        'FP'  { 
            $IPAddress = $ThisVM.($MigrationType + 'FailbackIPAddress')
            $SubnetMask = $ThisVM.($MigrationType + 'FailbackSubnetMask')
            $Gateway = $ThisVM.($MigrationType + 'FailbackGateway')
            $DNS1 = $ThisVM.($MigrationType + 'FailbackDNS1')
            $DNS2 = $ThisVM.($MigrationType + 'FailbackDNS2')
            $TestIPAddress = $Null
            $TestSubnetMask = $Null
            $TestGateway = $Null
            $TestDNS1 = $Null
            $TestDNS2 = $Null
         }
    }

    $DNSSuffix = $_.DNSSuffix
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') ) ) {
        $OverrideFolder =  ( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') )
    } else {
        $OverrideFolder = [string]::Empty
    }
    Write-Host "Adding VM: " $VMName
    Write-Host -NoNewline "  IPAddress`t`t" $IPAddress
    if ( [System.String]::IsNullOrEmpty( $IPAddress ) ) { Write-Host -ForegroundColor Red "  *** Invalid IPAddress $IPAddress"; $VMErrors++} else {Write-host ""}
    Write-Host -NoNewline "  SubnetMask`t" $SubnetMask
    if ( [System.String]::IsNullOrEmpty( $SubnetMask ) ) { Write-Host -ForegroundColor Red "  *** Invalid SubnetMask $SubnetMask"; $VMErrors++} else {Write-host ""}
    Write-Host -NoNewline "  Gateway`t`t" $Gateway
    if ( [System.String]::IsNullOrEmpty( $Gateway ) ) { Write-Host -ForegroundColor Red "  *** Invalid Gateway $Gateway"; $VMErrors++} else {Write-host ""}
    Write-Host -NoNewline "  DNS1`t`t`t" $DNS1
    if ( [System.String]::IsNullOrEmpty( $DNS1 ) ) { Write-Host -ForegroundColor Red "  *** Invalid DNS1 $DNS1"; $VMErrors++} else {Write-host ""}
    Write-Host -NoNewline "  DNS2`t`t`t" $DNS2
    if ( [System.String]::IsNullOrEmpty( $DNS2 ) ) { Write-Host -ForegroundColor Red "  *** Invalid DNS2 $DNS2"; $VMErrors++} else {Write-host ""}
    Write-Host -NoNewline "  DNSSuffix`t`t" $DNSSuffix
    if ( [System.String]::IsNullOrEmpty( $DNSSuffix ) ) { Write-Host -ForegroundColor Red "  *** Invalid DNSSuffix $DNSSuffix"; $VMErrors++} else {Write-host ""}
    Write-Host "  OverrideFolder`t`t" $OverrideFolder

    if ( -not [System.String]::IsNullOrEmpty( $TestIPAddress ) ) {
        Write-Host -NoNewline "  Test IPAddress:`t`t" $TestIPAddress
        if ( [System.String]::IsNullOrEmpty( $TestIPAddress ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestIPAddress $TestIPAddress"; $VMErrors++} else {Write-host ""}
        Write-Host -NoNewline "  Test SubnetMask:`t" $TestSubnetMask
        if ( [System.String]::IsNullOrEmpty( $TestSubnetMask ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestSubnetMask $TestSubnetMask"; $VMErrors++} else {Write-host ""}
        Write-Host -NoNewline "  Test Gateway:`t`t" $TestGateway
        if ( [System.String]::IsNullOrEmpty( $TestGateway ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestGateway $TestGateway"; $VMErrors++} else {Write-host ""}
        Write-Host -NoNewline "  Test DNS1:`t`t`t" $TestDNS1
        if ( [System.String]::IsNullOrEmpty( $TestDNS1 ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestDNS1 $TestDNS1"; $VMErrors++} else {Write-host ""}
        Write-Host -NoNewline "  Test DNS2:`t`t`t" $TestDNS2
        if ( [System.String]::IsNullOrEmpty( $TestDNS2 ) ) { Write-Host -ForegroundColor Red "  *** Invalid TestDNS2 $TestDNS2"; $VMErrors++} else {Write-host ""}
        Write-Host -NoNewline "  Test DNSSuffix:`t`t" $DNSSuffix
        if ( [System.String]::IsNullOrEmpty( $DNSSuffix ) ) { Write-Host -ForegroundColor Red "  *** Invalid DNSSuffix $DNSSuffix"; $VMErrors++} else {Write-host ""}
    }

    #Check our IP 
    $NewIPAddress = $_.($MigrationType + 'EventIPAddress')
    $AnyDupeInNSM = $FullNSM.Where( { ($_.($MigrationType + 'EventIPAddress') -eq "$NewIPAddress") -and
                                       ($_.Name -NE "$VMname") } ) 
    if ( $AnyDupeInNSM.Count -gt 0 ) {
        Write-Host -ForegroundColor Red "  *** ERROR - '$MigrationType' IPAddress also exists in server " $AnyDupeInNSM[0].Name
        $VMErrors++
    }
       
    #Override Network
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride') ) ) {
        $OverrideNetwork =  $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride')
        Write-Host "  * Overriding Network to: $OverrideNetwork"
    }
    #if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoTestNetworkOverride') ) ) {
    #    $OverrideTestNetwork =  $_.($MigrationType + 'VPG:ZertoTestNetworkOverride')
    #    Write-Host "  *** Overriding Test Network to: $OverrideTestNetwork"
    #}

    #Set our datastore based off of $VPGData.ZertoRecoverySiteName
    $VMDatastore = Get-Datastore -RecoverySiteName $RecoverySiteName -ZertoDatastoreClusterName $DatastoreClusterName
    Write-Host "  VM Datastore:`t $VMDatastore"

    #Override folder
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') ) ) {
        $OverrideFolder =  ( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') )
        Write-Host "  * Overriding Folder to: $OverrideFolder"
    }
    $VMCount++
}

if ($VPGErrors -gt 0) {
    Write-Host -ForegroundColor Red "`n**********************************************"
    Write-Host -ForegroundColor Red "*** VPG has $VPGErrors errors"
    Write-Host -ForegroundColor Red "**********************************************"
}

if ($VMErrors -gt 0) {
    Write-Host -ForegroundColor Red "`n**********************************************"
    Write-Host -ForegroundColor Red "*** $VMCount VMs for this group with $VMErrors errors"
    Write-Host -ForegroundColor Red "**********************************************"
} else {
    Write-Host "`n$VMCount VMs for this group"
}
