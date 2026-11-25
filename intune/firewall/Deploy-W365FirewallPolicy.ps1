<#
.SYNOPSIS
  Imports the W365 outbound default-deny firewall policy into Intune (Graph) and optionally assigns it.
.EXAMPLE
  ./Deploy-W365FirewallPolicy.ps1 -GroupId <entra-group-object-id>   # pilot group strongly recommended
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PolicyPath = (Join-Path $PSScriptRoot 'W365-Firewall-OutboundDeny.json'),
    [string]$GroupId
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force }
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -NoWelcome

$body = Get-Content $PolicyPath -Raw
$name = ($body | ConvertFrom-Json).displayName
$uri  = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations'

# Reuse-first: don't create a duplicate
$existing = (Invoke-MgGraphRequest GET "$uri`?`$filter=displayName eq '$name'").value
if ($existing) { Write-Warning "Policy '$name' already exists ($($existing[0].id)). Skipping create."; $policy = $existing[0] }
elseif ($PSCmdlet.ShouldProcess($name, 'Create Intune policy')) {
    $policy = Invoke-MgGraphRequest POST $uri -Body $body -ContentType 'application/json'
    Write-Host "Created: $($policy.id)"
}

if ($GroupId -and $policy -and $PSCmdlet.ShouldProcess($GroupId, 'Assign')) {
    $assign = @{ assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId } }) } | ConvertTo-Json -Depth 5
    Invoke-MgGraphRequest POST "$uri/$($policy.id)/assign" -Body $assign -ContentType 'application/json' | Out-Null
    Write-Host "Assigned to $GroupId"
}

# Read back from the authority
$check = Invoke-MgGraphRequest GET "$uri/$($policy.id)"
Write-Host "Verified in Intune: '$($check.displayName)' with $($check.omaSettings.Count) OMA settings"
