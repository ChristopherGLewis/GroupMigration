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
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "Zerto Source User")] [String] $ZertoUser,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "vCenter Source User")] [String] $vCenterSourceUser,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "vCenter Dest User")] [String] $vCenterDestUser,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Commit VPG")] [Switch] $CommitVPG,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)
#Add-Type -TypeDefinition "public enum VPGMigrationType { MigVPG, DRVPG, FPVPG }"

function Get-ZertoServer {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Site Name")] [String] $ZertoSiteName  
    )
    #Get our Zerto Server based off site name
    switch ($ZertoSiteName) {
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
            throw "Invalid Zerto Site Name"
        }
    }
    return $SourceServer
}

function Get-vCenterServer {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Site Name")] [String] $ZertoSiteName
    )
    #Get our dest vCenter based of Dest site name
    switch ($ZertoSiteName) {
        'CHAPDA' {
            $vCenterServer = "CHAPDA3VI05.ad.tiaa-cref.org"
        }
        'DENPDA' {
            $vCenterServer = "DENPDA3VI05.ad.tiaa-cref.org"
        }
        'DENPDB' {
            $vCenterServer = "DENPDB3VI07.ad.tiaa-cref.org"
        }
        'Zerto-IL1' {
            $vCenterServer = "IL1vc.nuveen.com"
        }
        default {
            throw "Invalid Site"
        }
    }
    return $vCenterServer
}

Function Load-DatatoreHash {
    param (
        [parameter(Mandatory = $true, ParameterSetName = 'Default', HelpMessage = "Recovery Site Name")]    [String] $RecoverySiteName
    )

    #Load our datastore choices 
    $DatastoreHash = @{}
    switch ($RecoverySiteName) {
        'CHAPDA' {
            $DatastoreCluster = 'CHAPDA3Z_MNA01'
        }
        'DENPDA' {
            $DatastoreCluster = 'DENPDA3Z_MNA01'
        }
        'DENPDB' {
            $DatastoreCluster = 'DENPDB3Z_MNA01'
        }
        'Zerto-IL1' {
            $DatastoreCluster = 'IL1VSP1_DUS_PRD_ZERTO_FAILBACK'
        }
        default {
            throw "Invalid Remote Site"
        }
    }

    #Get all our cluster members
    Get-DatastoreCluster -Name $DatastoreCluster | Get-Datastore | 
        ForEach-Object { 
            $DatastoreHash.Add($_.Name, $_.FreeSpaceGB)
        }

    #Note this doesn't sort, we'll have to add ($DatastoreHash.GetEnumerator() | sort value -Descending | select -First 1).Name
    #to get the most free
    Return $DatastoreHash
}

function Get-DatastoreMostFree {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Datastore Hash")] [Hashtable] $DatastoreHash
    )

    #Pick our datastore
    $MostFree = ($DatastoreHash.GetEnumerator() | sort value -Descending | select -First 1).Name
     
    return $MostFree
}

function Get-DatastoreRandom {
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

Function Write-DatastoreTable {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Datastore Hash")] [Hashtable] $DatastoreHash
    )
    Write-Host "Datastore Table:"
    Write-Host "Name                 FreeSpace"
    Write-Host "-------------------- ---------"
    $DatastoreHash.GetEnumerator() | Sort-Object Name | ForEach-Object{  Write-Host  ("{0,-20} {1,9:f2}" -f $_.Name , $_.value)  } 
    Write-Host ""
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

#Read our VPG List
$VPGSource = '\\nuveen.com\Departments\EO\Logs\Servers\ZertoVPGs.csv'
If ( -not (Test-Path $VPGSource) ) {
    throw "Cound not find VPGSource at '$VPGSource'"
    Return
}
#Load the VPG List to get our VPG before NSM.  This allows authentication faster
$VPGData = Import-Csv -Path $VPGSource | Where-Object {$_.ZertoVPG -eq $GroupName}
If ($VPGData -eq $null) { throw "Invalid VPG Group Name" }
$VPGSourceSiteName = $VPGData.ZertoSourceSiteName
If ( ( [String]::IsNullOrEmpty( $VPGSourceSiteName ) ) ) { throw "No Source Site name found for VPG Group '$GroupName'" }
$VPGRecoverySiteName = $VPGData.ZertoRecoverySiteName
If ( ( [String]::IsNullOrEmpty( $VPGRecoverySiteName ) ) ) { throw "No Recovery Site name found for VPG Group '$GroupName'" }

#Log Into Zerto
$ZertoSourceServer =  (Get-ZertoServer -ZertoSiteName  $VPGSourceSiteName)
$ZertoSourceServerPort = 9669

Set-Item ENV:ZertoServer $ZertoSourceServer 
Set-Item ENV:ZertoPort  $ZertoSourceServerPort
Set-ZertoAuthToken -ZertoUser $ZertoUser

Try {
    $LocalSite = Get-ZertoLocalSite
} catch {
    throw "Could not log onto ZertoServer at '$ZertoSourceServer'"
    Return
}

#Log into vCenter Source
$vCenterSourceServer = Get-vCenterServer -ZertoSiteName $VPGSourceSiteName
try {
    Connect-VIServer -Server $vCenterSourceServer -Credential (Get-Credential -Message "Enter account for SOURCE vCenter: $vCenterSourceServer" -UserName $vCenterSourceUser) | Out-Null
} catch {
    throw "Invalid login to '$vCenterSourceServer'"
    Return
}

#Log into vCenter Dest
$vCenterDestServer = Get-vCenterServer -ZertoSiteName  $VPGRecoverySiteName
try {
    Connect-VIServer -Server $vCenterDestServer -Credential (Get-Credential -Message "Enter account for DEST vCenter: $vCenterDestServer" -UserName $vCenterDestUser) | Out-Null
} catch {
    throw "Invalid login to '$vCenterDestServer'"
    Return
}

$NSMSource = '\\nuveen.com\Departments\EO\Logs\Servers\NSM.csv'
If ( -not (Test-Path $NSMSource) ) {
    throw "Could not find NSMSource at '$NSMSource'"
    Return
}

#Load our NSM based off our Group Name
Switch ($MigrationType) {
    'Mig' { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.MigVPG -eq $GroupName} }
    'DR'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.DRVPG -eq $GroupName} }
    'FP'  { $NSMData = Import-Csv -Path $NSMSource | Where-Object {$_.FPVPG -eq $GroupName} }
    Default {throw "Invalid Migration Type '$MigrationType'"}
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

$DatastoreHash = Load-DatatoreHash -RecoverySiteName $RecoverySiteName

$DatastoreName = Get-DatastoreMostFree -DatastoreHash $DatastoreHash
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

Write-DatastoreTable -DatastoreHash $DatastoreHash

#Create our array of VMs'
$AllVMS = @()
$NSMData | ForEach-Object {
    $ThisVM = $_  #Switch breaks $_
    $VMName =  $ThisVM.Name
    $VMSize = (Get-VM -Name $VMName  -Server $vCenterSourceServer | Get-HardDisk -Server $vCenterSourceServer | Measure-Object CapacityGB -Sum).Sum

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
    Write-Host "  IPAddress`t" $IPAddress
    Write-Host "  SubnetMask`t" $SubnetMask
    Write-Host "  Gateway`t" $Gateway
    Write-Host "  DNS1`t`t" $DNS1
    Write-Host "  DNS2`t`t" $DNS2
    Write-Host "  DNSSuffix`t" $DNSSuffix

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
            Write-Host "  Test IPAddress:`t" $TestIPAddress
            Write-Host "  Test SubnetMask:`t" $TestSubnetMask
            Write-Host "  Test Gateway:`t" $TestGateway
            Write-Host "  Test DNS1:`t`t" $TestDNS1
            Write-Host "  Test DNS2:`t`t" $TestDNS2
            Write-Host "  Test DNSSuffix:`t" $DNSSuffix

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
    #    Write-Host "  *** Overriding Test Network to: $OverrideTestNetwork"
    #    $IP.TestNetworkID = Get-ZertoSiteNetworkID -ZertoSiteIdentifier (Get-ZertoSiteID -ZertoSiteName ($RecoverySiteName)) `
    #                        -NetworkName ( $_.($MigrationType + 'VPG:ZertoTestNetworkOverride'))
    #}

    $VMDatastoreName = Get-DatastoreMostFree -DatastoreHash $DatastoreHash
    #Resize Table
    $DatastoreHash[$VMDatastoreName] = $DatastoreHash[$VMDatastoreName] - $VMSize
    If ($DatastoreHash[$VMDatastoreName] -lt 1000) {
        Write-Host -ForegroundColor Red " **** WARNING - Datastore $VMDatastoreName is at" $DatastoreHash[$VMDatastoreName]
    }
    Write-Host "  VM Disk Size:`t $VMSize"
    Write-Host "  VM Datastore:`t $VMDatastoreName"

    $Recovery = New-ZertoVPGVMRecovery -FolderIdentifier $DefaultFolderID `
                         -DatastoreIdentifier (Get-ZertoSiteDatastoreID -ZertoSiteIdentifier $RecoverySiteID -DatastoreName $VMDatastoreName) 

    #Override folder
    if ( -not [System.String]::IsNullOrEmpty( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') ) ) {
        $OverrideFolder =  ( $_.($MigrationType + 'VPG:ZertoRecoveryFolderOverride') )
        Write-Host -ForegroundColor yellow "  *** Overriding Folder to: $OverrideFolder"
        $Recovery.FolderIdentifier = Get-ZertoSiteFolderID  -ZertoSiteIdentifier $RecoverySiteID -FolderName $OverrideFolder
    }

    $VM = New-ZertoVPGVirtualMachine -VMName $_.Name  -VPGFailoverIPAddress $IP -VPGVMRecovery $Recovery 
    $AllVMS += $VM
}

Write-Host ("Adding " + $AllVMS.Count + " VMs")

Write-Host ("--Errors after this point are Zerto errors, ie 'VM was not found' indicates Zerto can't find the server in that site") -ForegroundColor Cyan

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



Disconnect-VIServer -Server $vCenterSourceServer  -Force -Confirm:$false 
Disconnect-VIServer -Server $vCenterDestServer -Force -Confirm:$false 