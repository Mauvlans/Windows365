<#
.SYNOPSIS
  Creates an Entra dynamic device group containing every Windows 365 Cloud PC and auto-assigns
  an Intune scope tag to it, so scoped Intune admins can see newly provisioned Cloud PCs.

.DESCRIPTION
  Problem: Cloud PCs land in Intune with no scope tag, so admins scoped to a tag can't see them.
  Fix:     Intune scope tags can be auto-assigned to devices through device groups
           (Tenant administration > Roles > Scope tags > <tag> > Assignments).
           A dynamic group on deviceModel "Cloud PC*" catches every Cloud PC as it provisions.

  - Reuse-first: existing group / scope tag with the same name is reused, not duplicated.
  - Existing scope tag assignments are MERGED (the Graph assign action replaces the whole list).
  - Requires Entra ID P1 for dynamic groups. Membership evaluation can take minutes to hours.

.EXAMPLE
  ./New-W365CloudPCScopeTagGroup.ps1 -ScopeTagName 'Contoso-W365' -WhatIf
  ./New-W365CloudPCScopeTagGroup.ps1 -ScopeTagName 'Contoso-W365'
  ./New-W365CloudPCScopeTagGroup.ps1 -ScopeTagName 'Contoso-W365' -CreateScopeTag
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ScopeTagName,
    [string]$GroupName = 'W365 - All Cloud PCs (Dynamic)',
    [string]$MembershipRule = '(device.deviceModel -startsWith "Cloud PC")',
    [switch]$CreateScopeTag
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force }
Connect-MgGraph -Scopes 'Group.ReadWrite.All','DeviceManagementRBAC.ReadWrite.All' -NoWelcome
$g = 'https://graph.microsoft.com'

# 1. Dynamic device group
$safe = $GroupName.Replace("'", "''")
$group = (Invoke-MgGraphRequest GET "$g/v1.0/groups?`$filter=displayName eq '$safe'").value | Select-Object -First 1
if ($group) {
    Write-Warning "Group '$GroupName' exists ($($group.id)); reusing. Rule: $($group.membershipRule)"
} elseif ($PSCmdlet.ShouldProcess($GroupName, 'Create dynamic device group')) {
    $body = @{
        displayName                   = $GroupName
        description                   = 'All Windows 365 Cloud PCs. Used to auto-assign Intune scope tags. Source: github.com/Mauvlans/Windows365'
        mailEnabled                   = $false
        mailNickname                  = ('w365-cloudpcs-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        securityEnabled               = $true
        groupTypes                    = @('DynamicMembership')
        membershipRule                = $MembershipRule
        membershipRuleProcessingState = 'On'
    } | ConvertTo-Json
    $group = Invoke-MgGraphRequest POST "$g/v1.0/groups" -Body $body -ContentType 'application/json'
    Write-Host "Created group $($group.id)"
}

# 2. Scope tag
$tags = (Invoke-MgGraphRequest GET "$g/beta/deviceManagement/roleScopeTags").value
$tag  = $tags | Where-Object displayName -eq $ScopeTagName | Select-Object -First 1
if (-not $tag) {
    if (-not $CreateScopeTag) { throw "Scope tag '$ScopeTagName' not found. Existing: $($tags.displayName -join ', '). Use -CreateScopeTag to create it." }
    if ($PSCmdlet.ShouldProcess($ScopeTagName, 'Create scope tag')) {
        $tag = Invoke-MgGraphRequest POST "$g/beta/deviceManagement/roleScopeTags" -ContentType 'application/json' `
            -Body (@{ displayName = $ScopeTagName; description = 'Windows 365 Cloud PCs' } | ConvertTo-Json)
        Write-Host "Created scope tag $($tag.id)"
    }
}

# 3. Auto-assign scope tag to the group (merge with existing assignments)
if ($tag -and $group) {
    $existing = (Invoke-MgGraphRequest GET "$g/beta/deviceManagement/roleScopeTags/$($tag.id)/assignments").value
    $ids = @($existing | ForEach-Object { $_.target.groupId } | Where-Object { $_ })
    if ($ids -contains $group.id) {
        Write-Host "Scope tag already assigned to group."
    } elseif ($PSCmdlet.ShouldProcess("$ScopeTagName -> $GroupName", 'Assign scope tag')) {
        $ids += $group.id
        $assign = @{ assignments = @($ids | ForEach-Object { @{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $_ } } }) } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest POST "$g/beta/deviceManagement/roleScopeTags/$($tag.id)/assign" -Body $assign -ContentType 'application/json' | Out-Null
    }

    # 4. Read back from the authority
    $after = (Invoke-MgGraphRequest GET "$g/beta/deviceManagement/roleScopeTags/$($tag.id)/assignments").value
    $grp   = Invoke-MgGraphRequest GET "$g/v1.0/groups/$($group.id)?`$select=displayName,membershipRule,membershipRuleProcessingState"
    $count = (Invoke-MgGraphRequest GET "$g/v1.0/groups/$($group.id)/members/`$count" -Headers @{ ConsistencyLevel = 'eventual' })
    Write-Host "Group: $($grp.displayName) | rule: $($grp.membershipRule) | state: $($grp.membershipRuleProcessingState) | members now: $count"
    Write-Host "Scope tag '$ScopeTagName' assigned groups: $(@($after.target.groupId) -join ', ')"
}
