<#
.SYNOPSIS
Creates a Zerto VPG for the given migration group

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
Version: 1.2
History:
    1.0 Initial create
    1.1 Dynamic Datastores
    1.2 Validation of rights to NSM/VPG files, Zerto rights


#>

#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Migration Type")]  [ValidateSet('Mig','DR','FP')] [string] $MigrationType,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Source Server")] [String] $ZertoSourceServer,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Zerto Source Server Port")] [int] $ZertoSourceServerPort = 9669,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Source User")] [String] $ZertoUser,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Commit VPG")] [Switch] $CommitVPG,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)
#Add-Type -TypeDefinition "public enum VPGMigrationType { MigVPG, DRVPG, FPVPG }"

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

$ScriptVersion = "1.2"
$MinZertoModuleVersion = [Version]"0.9.13"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

#This downloads the ZertoModule from PowerShell Gallery - you may need to run this first
#Install-Module -Name ZertoModule

#AutoImport doesn't work for Script modules
#Import-Module ZertoModule
Import-Module C:\Scripts\Zerto\ZertoModule\ZertoModule.psd1
If ((get-module -Name 'ZertoModule') -eq $null ) {
    throw "Could not find ZertoModule - please install it first via 'Install-Module -Name ZertoModule'"
    Return
}
If ( (Get-Module 'ZertoModule').Version -lt $MinZertoModuleVersion ) {
    throw "You must use at least ZertoModule $MinZertoModuleVersion.  Please upgrade with 'Update-Module ZertoModule'"
    Return
}

#Log Into Zerto
Set-Item ENV:ZertoServer $ZertoSourceServer
Set-Item ENV:ZertoPort $ZertoSourceServerPort
Set-ZertoAuthToken -ZertoUser $ZertoUser

Try {
    Get-ZertoLocalSite
} catch {
    throw "Cound not log onto ZertoServer at '$ZertoSourceServer'"
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

if ($MigrationType -eq  'Mig') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.MigVPG -eq $GroupName}
} elseif ($MigrationType -eq 'DR') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.DRVPG -eq $GroupName}
} elseif ($MigrationType -eq 'FP') {
    $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.FPVPG -eq $GroupName}
}
If ( ($NSMData -eq $null) -or ($NSMData.Count -eq 0) ) { throw "No VM's for VPG Group '$GroupName'" }

$VPGName = $VPGData.ZertoVPG
If ([string]::IsNullOrEmpty( $VPGData.ZertoReplicationPriority) ) {
   $Priority = 'Medium'
} else { 
   $Priority = $VPGData.ZertoReplicationPriority
}
$RecoverySiteName = $VPGData.ZertoRecoverySiteName
$RecoverySiteID = Get-ZertoSiteID -ZertoSiteName ($RecoverySiteName)

$HostClusterName  = $VPGData.ZertoHostClusterName
$HostClusterID = Get-ZertoSiteHostClusterID -ZertoSiteIdentifier $RecoverySiteID -HostClusterName $HostClusterName

$DatastoreClusterName = $VPGData.ZertoDatastoreClusterName
$DatastoreClusterID  = Get-ZertoSiteDatastoreClusterID -ZertoSiteIdentifier $RecoverySiteID -DatastoreClusterName $DatastoreClusterName

$DatastoreName =  Get-Datastore -RecoverySiteName $RecoverySiteName -ZertoDatastoreClusterName $DatastoreClusterName
$DatastoreID  = Get-ZertoSiteDatastoreID -ZertoSiteIdentifier $RecoverySiteID -DatastoreName $DatastoreName

$Network = $VPGData.ZertoFailoverNetwork
$NetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier $RecoverySiteID -NetworkName $Network

$TestNetwork = $VPGData.ZertoTestNetwork
$TestNetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier $RecoverySiteID -NetworkName $TestNetwork

$DefaultFolder = $VPGData.ZertoRecoveryFolder
$DefaultFolderID = Get-ZertoSiteFolderID -ZertoSiteIdentifier $RecoverySiteID -FolderName $DefaultFolder

#Display some VPG Information

Write-Host "Creating VPG '$VPGName' with destination '$RecoverySiteName'"
Write-Host "  Cluster:`t`t`t $HostClusterName"
Write-Host "  DatastoreCluster:`t $DatastoreClusterName"
Write-Host "  Datastore:`t`t $DatastoreName"
Write-Host "  Network:`t`t`t $Network"
Write-Host "  TestNetwork:`t`t $TestNetwork"
Write-Host "  DefaultFolder:`t $DefaultFolder"


#Create our array of VMs'
$AllVMS = @()
$NSMData | ForEach-Object {
    $VMName =  $_.Name

    Write-Host "Adding VM: " $VMName
    Write-Host "  IPAddress`t`t" $_.($MigrationType + 'EventIPAddress')
    Write-Host "  SubnetMask`t" $_.($MigrationType + 'EventSubnetMask')
    Write-Host "  Gateway`t`t" $_.($MigrationType + 'EventGateway')
    Write-Host "  DNS1`t`t`t" $_.($MigrationType + 'EventDNS1')
    Write-Host "  DNS2`t`t`t" $_.($MigrationType + 'EventDNS2')
    Write-Host "  DNSSuffix`t`t" $_.DNSSuffix

    #Throw on error - 
    try {
        if ( [System.String]::IsNullOrEmpty( $_.($MigrationType + 'TestIPAddress') ) ) {
            $IP = New-ZertoVPGFailoverIPAddress -NICName 'Network adapter 1' `
                                        -IPAddress  $_.($MigrationType + 'EventIPAddress') `
                                        -SubnetMask $_.($MigrationType + 'EventSubnetMask') `
                                        -Gateway    $_.($MigrationType + 'EventGateway') `
                                        -DNS1       $_.($MigrationType + 'EventDNS1') `
                                        -DNS2       $_.($MigrationType + 'EventDNS2') `
                                        -DNSSuffix  $_.DNSSuffix
        } else {
            Write-Host "  Test IPAddress:`t`t" $_.($MigrationType + 'TestIPAddress')
            Write-Host "  Test SubnetMask:`t" $_.($MigrationType + 'TestSubnetMask')
            Write-Host "  Test Gateway:`t`t" $_.($MigrationType + 'TestGateway')
            Write-Host "  Test DNS1:`t`t`t" $_.($MigrationType + 'TestDNS1')
            Write-Host "  Test DNS2:`t`t`t" $_.($MigrationType + 'TestDNS2')
            Write-Host "  Test DNSSuffix:`t`t" $_.DNSSuffix

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
    } catch {
        Throw ("***ERROR with $VMName : " + $Error[0])
    }
       
    #Override Network
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride') ) ) {
        $OverrideNetwork =  $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride')
        Write-Host "  *** Overriding Network to: $OverrideNetwork"
        $IP.NetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier (Get-ZertoSiteID -ZertoSiteName ($RecoverySiteName)) `
                            -NetworkName ( $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride'))
    }
    #if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoTestNetworkOverride') ) ) {
    #    $OverrideTestNetwork =  $_.($MigrationType + 'VPG:ZertoTestNetworkOverride')
    #    Write-Host "  *** Overriding Test Network to: $OverrideTestNetwork"
    #    $IP.TestNetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier (Get-ZertoSiteID -ZertoSiteName ($RecoverySiteName)) `
    #                        -NetworkName ( $_.($MigrationType + 'VPG:ZertoTestNetworkOverride'))
    #}

    #Set our datastore based off of $VPGData.ZertoRecoverySiteName
    $VMDatastore = Get-Datastore -RecoverySiteName $RecoverySiteName -ZertoDatastoreClusterName $DatastoreClusterName
    Write-Host "  VM Datastore:`t $VMDatastore"

    $Recovery = New-ZertoVPGVMRecovery -FolderIdentifier $DefaultFolderID `
                         -DatastoreIdentifier (Get-ZertoSiteDatastoreID -ZertoSiteIdentifier $RecoverySiteID -DatastoreName $VMDatastore) 

    #Override folder
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') ) ) {
        $OverrideFolder =  ( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') )
        Write-Host "  *** Overriding Folder to: $OverrideFolder"
        $Recovery.FolderIdentifier = Get-ZertoSiteFolderID  -ZertoSiteIdentifier $RecoverySiteID -FolderName $OverrideFolder
    }

    $VM = New-ZertoVPGVirtualMachine -VMName $_.Name  -VPGFailoverIPAddress $IP -VPGVMRecovery $Recovery 
    $AllVMS += $VM
}

Write-Host ("Adding " + $AllVMS.Count + " VMs")


# Create our VPG
If (-not $CommitVPG) {
    Add-ZertoVPG -Priority $Priority  `
                -VPGName $VPGName `
                -RecoverySiteName $RecoverySiteName `
                -ClusterName  $HostClusterName `
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
                -ClusterName  $HostClusterName `
                -FailoverNetwork  $Network  `
                -TestNetwork $TestNetwork `
                -DatastoreName $DatastoreName `
                -JournalUseDefault $true `
                -Folder $DefaultFolder `
                -VPGVirtualMachines $AllVMS
}
