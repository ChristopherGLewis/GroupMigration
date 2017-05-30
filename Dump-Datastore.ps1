<#
.SYNOPSIS
Dumps the datastore table for a given vCenter

.DESCRIPTION
The Make-GroupVPG.ps1 script creates a VPG for a given migration group.  The Script reads the VPG from the VPGList and then 
processes each VM in the NSM to grab destination IP information.


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
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Zerto Site Name ")] [ValidateSet('Zerto-IL1','CHAPDA','DENPDA','DENPDB')] [String] $ZertoSiteName,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "vCenter Source User")] [String] $vCenterSourceUser,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "vCenter Dest User")] [String] $vCenterDestUser,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)

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

Function Write-DatastoreTable {
    param (
        [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "Datastore Hash")] [Hashtable] $DatastoreHash
    )
    Write-Host "Datastore Table:"
    Write-Host "Name                    Value"
    Write-Host "-------------------- --------"
    $DatastoreHash.GetEnumerator() | Sort-Object Name | ForEach-Object{  Write-Host  ("{0,-20} {1,8:f2}" -f $_.Name , $_.value)  } 
    Write-Host ""
}

$ScriptVersion = "1.0"
$MinZertoModuleVersion = [Version]"0.9.13"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

#Import PowerCLI
Import-Module VMware.VimAutomation.Core


#Log into vCenter Source
$vCenterSourceServer = Get-vCenterServer -ZertoSiteName $ZertoSiteName
try {
    Connect-VIServer -Server $vCenterSourceServer -Credential (Get-Credential -Message "Enter account for SOURCE vCenter: $vCenterSourceServer" -UserName $vCenterSourceUser) | Out-Null
} catch {
    throw "Invalid login to '$vCenterSourceServer'"
    Return
}

$DatastoreHash = Load-DatatoreHash -RecoverySiteName $ZertoSiteName

Write-DatastoreTable -DatastoreHash $DatastoreHash


Disconnect-VIServer -Server $vCenterSourceServer  -Force -Confirm:$false 
