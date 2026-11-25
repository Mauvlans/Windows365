<#
.SYNOPSIS
  Builds a Windows 365 App Control for Business (WDAC) base policy and (optionally) uploads it to Intune.

.DESCRIPTION
  Run on a Windows 10/11 admin machine (needs the built-in ConfigCI module).
  Starts from Microsoft's shipped AllowMicrosoft example policy, so everything Microsoft-signed
  (Windows, Office/M365 Apps, Teams, Edge, Remote Desktop/W365 components, Defender, Intune agents) runs.
  Adds:
    - Managed installer (option 13): apps deployed by the Intune Management Extension are trusted.
    - Optional ISG (option 14): apps with good Microsoft Intelligent Security Graph reputation run.
    - Audit mode by default (option 3). Use -Enforce only after reviewing audit events.

  Output: W365-AppControl-<Mode>.xml + {PolicyGUID}.cip, and an Intune custom OMA-URI profile via Graph.

.EXAMPLE
  ./Build-W365AppControlPolicy.ps1                      # audit build, files only
  ./Build-W365AppControlPolicy.ps1 -Upload -GroupId <pilot-group-id>
  ./Build-W365AppControlPolicy.ps1 -Enforce -Upload -GroupId <pilot-group-id>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Enforce,
    [switch]$UseISG,
    [switch]$Upload,
    [string]$GroupId,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Run on Windows: ConfigCI cmdlets are Windows-only.' }

$mode = if ($Enforce) { 'Enforced' } else { 'Audit' }
$name = "W365 - App Control - Base ($mode)"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$xml = Join-Path $OutDir "W365-AppControl-$mode.xml"

# 1. Start from Microsoft's example (ships with Windows)
Copy-Item "$env:windir\schemas\CodeIntegrity\ExamplePolicies\AllowMicrosoft.xml" $xml -Force

# 2. Identity: fresh base policy GUID + name/version
$null = Set-CIPolicyIdInfo -FilePath $xml -PolicyName $name -ResetPolicyID
Set-CIPolicyVersion -FilePath $xml -Version '1.0.0.0'

# 3. Rule options
Set-RuleOption -FilePath $xml -Option 13              # Managed installer (Intune Management Extension)
Set-RuleOption -FilePath $xml -Option 16              # Update policy without reboot
Set-RuleOption -FilePath $xml -Option 17              # Allow supplemental policies (per-app exceptions later)
Set-RuleOption -FilePath $xml -Option 9               # Advanced boot options menu
Set-RuleOption -FilePath $xml -Option 10              # Boot audit on failure
if ($UseISG) { Set-RuleOption -FilePath $xml -Option 14 }  # Intelligent Security Graph
if ($Enforce) { Set-RuleOption -FilePath $xml -Option 3 -Delete } else { Set-RuleOption -FilePath $xml -Option 3 }

# 4. Compile
[xml]$doc = Get-Content $xml
$policyId = $doc.SiPolicy.PolicyID
$cip = Join-Path $OutDir "$policyId.cip"
ConvertFrom-CIPolicy -XmlFilePath $xml -BinaryFilePath $cip | Out-Null
Write-Host "Built $mode policy $policyId -> $cip"

if (-not $Upload) { return }

# 5. Upload as Intune custom profile (ApplicationControl CSP)
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force }
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -NoWelcome
$uri = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations'

$existing = (Invoke-MgGraphRequest GET "$uri`?`$filter=displayName eq '$name'").value
if ($existing) { Write-Warning "'$name' already exists ($($existing[0].id)); not creating a duplicate."; $policy = $existing[0] }
elseif ($PSCmdlet.ShouldProcess($name, 'Create Intune policy')) {
    $body = @{
        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
        displayName   = $name
        description   = "App Control for Business base policy $policyId ($mode). Source: github.com/Mauvlans/Windows365"
        omaSettings   = @(@{
            '@odata.type' = '#microsoft.graph.omaSettingBase64'
            displayName   = 'App Control base policy'
            omaUri        = "./Vendor/MSFT/ApplicationControl/Policies/$($policyId.Trim('{}'))/Policy"
            fileName      = "$policyId.cip"
            value         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cip))
        })
    } | ConvertTo-Json -Depth 6
    $policy = Invoke-MgGraphRequest POST $uri -Body $body -ContentType 'application/json'
    Write-Host "Created: $($policy.id)"
}

if ($GroupId -and $policy -and $PSCmdlet.ShouldProcess($GroupId, 'Assign')) {
    $a = @{ assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId } }) } | ConvertTo-Json -Depth 5
    Invoke-MgGraphRequest POST "$uri/$($policy.id)/assign" -Body $a -ContentType 'application/json' | Out-Null
    Write-Host "Assigned to $GroupId"
}
$check = Invoke-MgGraphRequest GET "$uri/$($policy.id)"
Write-Host "Verified in Intune: '$($check.displayName)' ($($check.omaSettings.Count) OMA setting)"
