<#
.SYNOPSIS
Tests the VPG and NSM lists for a  given migration group

.DESCRIPTION
The Make-GroupVPG.ps1 script creates a VPG for a given migration group.  The Script reads the VPG from the VPGList and then 
processes each VM in the NSM to grab destination IP information.

.PARAMETER GroupName 
Name of the Zerto VPG Migration Group.  Typically in the form Group01-CHAPDA or Group01-DENPDA

.PARAMETER MigrationType 
The migration type:
    MIG -> initial migration from FP to CHA/DEN 
    FP -> Migration back from CHA/DEN to FP as our parachute replication
    DR -> end state DR from CHAPDA to DENPDA

.PARAMETER ZertoSourceServer  
FQDN of the Zerto Source Server

.PARAMETER ZertoUser   
User for the Zerto source server

.PARAMETER ZertoSourceServerPort 
Zerto Source Server port - defaults to 9669

.PARAMETER CommitVPG
Switch to commit the VPG.  Without this switch, the script just processes without creating the VPG.  It does dump the 
REST API Json for diagnostics

.PARAMETER Ver
Displays the version number and exits

.EXAMPLE 
#This DOES NOT commit the VPG

.\Make-GroupVPG.ps1 -GroupName 'GROUP01-CHAPDA' `
                    -MigrationType Mig `
                    -ZertoSourceServer 'il1zerto.nuveen.com' `
                    -ZertoUser 'nuveen\e_lewiCG'

.EXAMPLE 
#This commits the VPG

.\Make-GroupVPG.ps1 -GroupName 'GROUP01-CHAPDA' `
                    -MigrationType Mig `
                    -ZertoSourceServer 'il1zerto.nuveen.com' `
                    -ZertoUser 'nuveen\e_lewiCG' `
                    -CommitVPG

.NOTES
Author: Chris Lewis
Date: 2017-03-02
Version: 1.1
History:
    1.0 Initial create

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
                throw "Invalid IL1 Cluster"
            }
        }
        default {
            throw "Invalid Remote Site"
        }
    }
    return $DatastoreName
}


$ScriptVersion = "1.1"

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
If ( -not (Test-Path $NSMSource) ) {
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

Write-Host "Creating VPG '$VPGName' with destination '$RecoverySiteName'"
Write-Host "  Cluster:`t`t`t $HostClusterName"
Write-Host "  DatastoreCluster:`t $DatastoreClusterName"
Write-Host "  Datastore:`t`t $DatastoreName"
Write-Host "  Network:`t`t`t $Network"
Write-Host "  TestNetwork:`t`t $TestNetwork"
Write-Host "  DefaultFolder:`t $DefaultFolder"


#Create our array of VMs'
$VMCount = 0
$VMErrors = 0
$NSMData | ForEach-Object {
    $VMName =  $_.Name

    Write-Host "`nAdding VM: " $VMName
    Write-Host "  IPAddress`t`t" $_.($MigrationType + 'EventIPAddress')
    Write-Host "  SubnetMask`t" $_.($MigrationType + 'EventSubnetMask')
    Write-Host "  Gateway`t`t" $_.($MigrationType + 'EventGateway')
    Write-Host "  DNS1`t`t`t" $_.($MigrationType + 'EventDNS1')
    Write-Host "  DNS2`t`t`t" $_.($MigrationType + 'EventDNS2')
    Write-Host "  DNSSuffix`t`t" $_.DNSSuffix

    #Check our IP 
    $NewIPAddress = $_.($MigrationType + 'EventIPAddress')
    $AnyDupeInNSM = $FullNSM.Where( { ($_.($MigrationType + 'EventIPAddress') -eq "$NewIPAddress") -and
                                       ($_.Name -NE "$VMname") } ) 
    if ( $AnyDupeInNSM.Count -gt 0 ) {
        Write-Host "  *** ERROR - '$MigrationType' IPAddress also exists in server " $AnyDupeInNSM[0].Name
        $VMErrors++
    }

    #Throw on error - 
    try {
        if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'TestIPAddress') ) ) {
            Write-Host "  Test IPAddress:`t`t" $_.($MigrationType + 'TestIPAddress')
            Write-Host "  Test SubnetMask:`t" $_.($MigrationType + 'TestSubnetMask')
            Write-Host "  Test Gateway:`t`t" $_.($MigrationType + 'TestGateway')
            Write-Host "  Test DNS1:`t`t`t" $_.($MigrationType + 'TestDNS1')
            Write-Host "  Test DNS2:`t`t`t" $_.($MigrationType + 'TestDNS2')
            Write-Host "  Test DNSSuffix:`t`t" $_.DNSSuffix
        }
    } catch {
        Throw ("***ERROR with $VMName : " + $Error[0])
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

if ($VMErrors -gt 0) {
    Write-Host "`n**********************************************"
    Write-Host "*** $VMCount VMs for this group with $VMErrors errors"
    Write-Host "**********************************************"
} else {
    Write-Host "`n$VMCount VMs for this group"
}
