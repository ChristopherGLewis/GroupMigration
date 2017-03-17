<#
.SYNOPSIS
Lists VPGs 

.DESCRIPTION
The List-Groups.ps1 Lists all VPGs defined 

.NOTES
Author: Chris Lewis
Date: 2017-03-17
Version: 1.0
History:
    1.0 Initial create

#>

#Requires -Version 5.0
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
#    [parameter(Mandatory = $true,  ParameterSetName = 'Default', HelpMessage = "VPG Group Name")] [String] $GroupName,
    [parameter(Mandatory = $true,  ParameterSetName = 'Version', HelpMessage = "Version")] [Switch] $Ver
)

$ScriptVersion = "1.0"

if ( $ver) {
    Write-Host ($MyInvocation.MyCommand.Name + " - Version $ScriptVersion")
    Return
}

$VPGSource = '\\nuveen.com\Departments\EO\Logs\Servers\ZertoVPGs.csv'

If ( -not (Test-Path $VPGSource) ) {
    throw "Cound not find VPGSource at '$VPGSource'"
    Return
}

$VPGData = Import-Csv -Path $VPGSource 
return $VPGData | Select-Object ZertoVPG

