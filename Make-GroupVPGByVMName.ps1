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

.PARAMETER ZertoUser   
User for the Zerto source server

.PARAMETER ZertoSourceServerPort 
Zerto Source Server port - defaults to 9669

.PARAMETER VMName
Name of single VM in the above VPG to create VPGByBVMName 

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
Version: 1.3
History:
    1.0 Initial create
    1.1 Dynamic Datastores
    1.2 Validation of rights to NSM/VPG files, Zerto rights
    1.3 Switched to use SourceSite from VPG Table
#>

#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Migration Type")]  [ValidateSet('Mig','DR','FP')] [string] $MigrationType,
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Source Server")] [String] $ZertoSourceServer,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Zerto Source Server Port")] [int] $ZertoSourceServerPort = 9669,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "Zerto Source User")] [String] $ZertoUser,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "VMName list")] [String[]] $VMList,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Commit VPG")] [Switch] $CommitVPG,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)
#Add-Type -TypeDefinition "public enum VPGMigrationType { MigVPG, DRVPG, FPVPG }"

function Get-SourceServer {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Source Site Name")] [String] $SourceSiteName
    )
    #Guess at our datastore
    switch ($SourceSiteName) {
        'CHAPDA' {
            $SourceServer = "chapda3zvm01.ad.tiaa-cref.org"
        }
        'DENPDA' {
            $SourceServer = "denpda3zvm01.ad.tiaa-cref.org"
        }
        'DENPDB' {
            $SourceServer = "denpdb3zvm01.ad.tiaa-cref.org"
        }
        'Zerto-IL1' {
            $SourceServer = "il1zerto.nuveen.com"
        }
        default {
            throw "Invalid Source Site"
        }
    }
    return $SourceServer
}

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

$ScriptVersion = "1.3"
$MinZertoModuleVersion = [Version]"0.9.13"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

#This downloads the ZertoModule from PowerShell Gallery - you may need to run this first
#Install-Module -Name ZertoModule

#AutoImport doesn't work for Script modules
Import-Module ZertoModule
#Import-Module C:\Scripts\Zerto\ZertoModule\ZertoModule.psd1
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
    $LocalSite = Get-ZertoLocalSite
} catch {
    throw "Could not log onto ZertoServer at '$ZertoSourceServer'"
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

#Load the VPG List to get our VPG before NSM.  This allows authentication faster
$VPGData = Import-Csv -Path $VPGSource | Where-Object {$_.ZertoVPG -eq $GroupName}
If ($VPGData -eq $null) { throw "Invalid VPG Group Name" }

$VPGSourceSiteName = $VPGData.ZertoSourceSiteName
If ( ( [String]::IsNullOrEmpty( $VPGSourceSiteName ) ) ) { throw "No Source Site name found for VPG Group '$GroupName'" }


#Load our NSM based off our Group Name
Switch ($MigrationType) {
    'Mig' { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.MigVPG -eq $GroupName} }
    'DR'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.DRVPG -eq $GroupName} }
    'FP'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.FPVPG -eq $GroupName} }
    Default {throw "Invalid Migration Type '$MigrationType'"}
}
If ( ($NSMData -eq $null) -or ($NSMData.Count -eq 0) ) { throw "No VM's for VPG Group '$GroupName'" }

#Filter by VMList
If ( $VMList ) { $NSMData = $NSMData | Where-Object { $_.Name -in $VMList } }

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
Write-Host "Creating VPG '$VPGName' with source '$VPGSourceSiteName' destination '$RecoverySiteName'"
if ( $VPGSourceSiteName -eq  $RecoverySiteName) { 
    Write-Host -ForegroundColor Red "  *** Source and Destination cannot be the same"
    Throw ("*** Source and Destination cannot be the same")
} 
Write-Host "  SourceServer:`t`t $VPGSourceServer"
Write-Host "  Cluster:`t`t`t $HostClusterName"
Write-Host "  DatastoreCluster:`t $DatastoreClusterName"
Write-Host "  Datastore:`t`t $DatastoreName"
Write-Host "  Network:`t`t`t $Network"
Write-Host "  TestNetwork:`t`t $TestNetwork"
Write-Host "  DefaultFolder:`t $DefaultFolder"

#Create our array of VMs'
#$AllVMS = @()
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

    Write-Host "Adding VM: " $VMName
    Write-Host "  IPAddress:`t" $IPAddress
    Write-Host "  SubnetMask:`t" $SubnetMask
    Write-Host "  Gateway:`t`t" $Gateway
    Write-Host "  DNS1:`t`t`t" $DNS1
    Write-Host "  DNS2:`t`t`t" $DNS2
    Write-Host "  DNSSuffix:`t" $DNSSuffix

    #Throw on error - 
    try {
        if ( [System.String]::IsNullOrEmpty( $TestIPAddress ) ) {
            $IP = New-ZertoVPGFailoverIPAddress -NICName 'Network adapter 1' `
                                        -IPAddress  $IPAddress `
                                        -SubnetMask $SubnetMask `
                                        -Gateway    $Gateway `
                                        -DNS1       $DNS1 `
                                        -DNS2       $DNS2 `
                                        -DNSSuffix  $DNSSuffix
        } else {
            Write-Host "  Test IPAddress:`t`t" $TestIPAddress
            Write-Host "  Test SubnetMask:`t" $TestSubnetMask
            Write-Host "  Test Gateway:`t`t" $TestGateway
            Write-Host "  Test DNS1:`t`t`t" $TestDNS1
            Write-Host "  Test DNS2:`t`t`t" $TestDNS2
            Write-Host "  Test DNSSuffix:`t`t" $DNSSuffix

            $IP = New-ZertoVPGFailoverIPAddress -NICName 'Network adapter 1' `
                                        -IPAddress  $IPAddress `
                                        -SubnetMask $SubnetMask `
                                        -Gateway    $Gateway `
                                        -DNS1       $DNS1 `
                                        -DNS2       $DNS2 `
                                        -DNSSuffix  $DNSSuffix `
                                        -TestIPAddress  $TestIPAddress `
                                        -TestSubnetMask $TestSubnetMask `
                                        -TestGateway    $TestGateway `
                                        -TestDNS1       $TestDNS1 `
                                        -TestDNS2       $TestDNS2 `
                                        -TestDNSSuffix  $DNSSuffix
        }
    } catch {
        Throw ("***ERROR with $VMName : " + $Error[0])
    }
       
    #Override Network
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride') ) ) {
        $OverrideNetwork =  $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride')
        Write-Host -ForegroundColor yellow "  *** Overriding Network to: $OverrideNetwork"
        $IP.NetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier (Get-ZertoSiteID -ZertoSiteName ($RecoverySiteName)) `
                            -NetworkName ( $_.($MigrationType + 'VPG:ZertoFailoverNetworkOverride'))
    }
    #if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoTestNetworkOverride') ) ) {
    #    $OverrideTestNetwork =  $_.($MigrationType + 'VPG:ZertoTestNetworkOverride')
    #    Write-Host -ForegroundColor yellow "  *** Overriding Test Network to: $OverrideTestNetwork"
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
        Write-Host -ForegroundColor yellow "  *** Overriding Folder to: $OverrideFolder"
        $Recovery.FolderIdentifier = Get-ZertoSiteFolderID  -ZertoSiteIdentifier $RecoverySiteID -FolderName $OverrideFolder
    }

    $VM = New-ZertoVPGVirtualMachine -VMName $_.Name  -VPGFailoverIPAddress $IP -VPGVMRecovery $Recovery 
    #$AllVMS += $VM

    Write-Host ("Creating VPG By VMName " + $_.Name)
    Write-Host ("-- The next error could be a Zerto error, ie 'VM was not found' indicates Zerto can't find the server in that site") -ForegroundColor Cyan

    # Create our VPG
    If (-not $CommitVPG) {
        try {
            $Result = Add-ZertoVPG -Priority $Priority  `
                        -VPGName ($VPGName + "-" +  $_.Name) `
                        -RecoverySiteName $RecoverySiteName `
                        -ClusterName  $HostClusterName `
                        -FailoverNetwork  $Network  `
                        -TestNetwork $TestNetwork `
                        -DatastoreName $DatastoreName `
                        -JournalUseDefault:$true `
                        -Folder $DefaultFolder `
                        -VPGVirtualMachines $VM `
                        -DumpJSON

        } catch {
            Write-Host "Error creating VPG"
        }
    } else {
        try {
            $Result = Add-ZertoVPG -Priority $Priority  `
                        -VPGName ($VPGName + "-" +  $_.Name) `
                        -RecoverySiteName $RecoverySiteName `
                        -ClusterName  $HostClusterName `
                        -FailoverNetwork  $Network  `
                        -TestNetwork $TestNetwork `
                        -DatastoreName $DatastoreName `
                        -JournalUseDefault:$true `
                        -Folder $DefaultFolder `
                        -VPGVirtualMachines $VM 
        } catch {
            Write-Host "Error creating VPG"
        }
    }
}
