<#
.SYNOPSIS
Removes Zerto VPG's from FP

.DESCRIPTION
The Remove-InitalVPGsFromFP.ps1 - removes VPGs that are from FP to <DEST>.  Run as part of the HbH after the migration

.PARAMETER GroupName 
Name of the Zerto VPG Migration Group.  Can be wildcarded - *group02*

.PARAMETER ZertoUser   
User for the Zerto source server


.PARAMETER Commit
Switch to commit the VPG.  Without this switch, the script just processes without creating the VPG.  It does dump the 
REST API Json for diagnostics

.PARAMETER Ver
Displays the version number and exits

.EXAMPLE 
#This DOES NOT commit the VPG Remove
.\Remove-InitalVPGsFromFP.ps1 -ZertoUser 'nuveen\e_lewiCG' 

.EXAMPLE 
#This commits the VPG
.\Remove-InitalVPGsFromFP.ps1 -ZertoUser 'nuveen\e_lewiCG' -Commit

.NOTES
Author: Chris Lewis
Date: 2017-05-24
Version: 1.0
History:
    1.0 Initial create
#>

#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $false, ParameterSetName = 'Default', HelpMessage = "Zerto Source User")] [String] $ZertoUser,
    [parameter(Mandatory = $False, ParameterSetName = 'Default', HelpMessage = "Commit VPG Remove")] [Switch] $Commit,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)


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

Connect-ZertoZVM -ZertoServer (Get-ZertoServer -ZertoSiteName 'Zerto-IL1')  -ZertoUser $ZertoUser

#Get matching VPGS
$VPGS =  Get-ZertoVPG | Where-Object {$_.VpgName -like $GroupName }

if ($Commit) {
    If ($VPGs.Count -eq 0 ) {
        Write-Host -ForegroundColor Yellow 'No matching VPGS'
    } Else {
        #Commit remove
        Write-Host -ForegroundColor Cyan 'Removing VPG :'
        $VPGs | ForEach-Object { 
            Write-Host -ForegroundColor Cyan 'Removing VPG :' $_.VpgName
            Remove-ZertoVPG -ZertoVpgIdentifier $_.VpgIdentifier 
        }
    }
} else {
    
    If ($VPGs.Count -eq 0 ) {
        Write-Host -ForegroundColor Yellow 'No matching VPGS'
    } Else {
        #Show what would be removed
        Write-Host -ForegroundColor Cyan 'VPGs to be removed:'
        $VPGs | ForEach-Object { Write-Host $_.VpgName}
    }
}