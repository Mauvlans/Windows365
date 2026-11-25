# Windows365

Intune-deployable configuration for Windows 365 Cloud PCs.

## intune/firewall — Outbound default-deny

`W365-Firewall-OutboundDeny.json` is a Graph `windows10CustomConfiguration` (Firewall CSP OMA-URIs). It sets **DefaultOutboundAction = Block** on Domain/Private/Public profiles and allows only:

- TCP 80 — HTTP, Azure WireServer/IMDS
- TCP 443 — HTTPS (RD broker/gateway, Intune, Entra, W365 service, M365)
- UDP/TCP 53 — DNS (without it, 80/443 are useless)
- TCP 5671 — W365 provisioning/health (IoT Hub AMQP)
- TCP 1688 — KMS activation (Azure KMS IPs only)
- UDP 123 — NTP (token/Kerberos clock skew)
- TCP 32526 — Azure guest agent → 168.63.129.16
- UDP 3478 — RDP Shortpath TURN → 51.5.0.0/16 (optional; falls back to 443)

Sources: [W365 network requirements](https://learn.microsoft.com/windows-365/enterprise/requirements-network), [AVD session host endpoints](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint), [Azure KMS](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/custom-routes-enable-kms-activation).

### Deploy
```powershell
./intune/firewall/Deploy-W365FirewallPolicy.ps1 -GroupId <pilot-group-id>
```
Or manually: Intune → Devices → Configuration → Create → Windows 10+ → Templates → Custom, add the OMA-URIs from the JSON.

### Caveats
- Windows Firewall rules are port-based, not FQDN-based. "443 to anywhere" is the real security boundary; for FQDN allow-listing use Azure Firewall / SWG.
- Hybrid-joined Cloud PCs: also deploy `W365-Firewall-HybridJoin-DCs.json` after replacing `REPLACE_WITH_DC_IPS` with your DC IPs (comma-separated). Allows 88, 464, 389, 636, 3268-3269, 445, 135, 49152-65535 to DCs only. Deploy it with `-PolicyPath`.
- Other line-of-business apps on non-80/443 ports will break (by design). Pilot first.
- Revert: unassign/delete the profile, or set `DefaultOutboundAction` = 0.

## intune/app-control — App Control for Business (WDAC)

`Build-W365AppControlPolicy.ps1` builds a base policy on a Windows admin machine from Microsoft's built-in **AllowMicrosoft** example, then uploads it as an Intune custom profile (`./Vendor/MSFT/ApplicationControl/Policies/{GUID}/Policy`).

What it allows:
- Everything Microsoft-signed: Windows, M365 Apps, Teams, Edge, the Remote Desktop and Windows 365 components, Defender and the Intune agents
- Apps installed by Intune, via the **managed installer** option (enable it in Intune → Endpoint security → App Control for Business → Managed installer)
- Optionally, apps with a good Microsoft Intelligent Security Graph reputation (`-UseISG`)
- Supplemental policies, so you can add per-app exceptions later

Rollout:
1. `./intune/app-control/Build-W365AppControlPolicy.ps1 -Upload -GroupId <pilot>` creates an **audit** build. Nothing is blocked; violations are only logged.
2. Run `Get-W365AppControlAuditEvents.ps1` on the pilot Cloud PCs (by hand or as an Intune remediation) to see what *would* be blocked.
3. Add a supplemental policy for any legitimate app that shows up.
4. `-Enforce -Upload -GroupId <pilot>` creates a separate enforced profile. Unassign the audit profile, then widen the assignment.

To revert: unassign the profile. Option 16 (update without reboot) is set, but a policy *removal* only fully clears after a reboot.

## intune/scope-tags — Make Cloud PCs visible to scoped Intune admins

Problem: newly provisioned Cloud PCs arrive in Intune with no scope tag, so admins who can only see certain scope tags can't see them.

`New-W365CloudPCScopeTagGroup.ps1` fixes this in three steps:
1. Creates (or reuses) the Entra dynamic device group **W365 - All Cloud PCs (Dynamic)** with the rule `(device.deviceModel -startsWith "Cloud PC")`. That matches every model string, including `Cloud PC Enterprise …`, Frontline and `Cloud PC for Agents`.
2. Finds your Intune scope tag. Pass `-CreateScopeTag` to create it if it doesn't exist.
3. Auto-assigns the scope tag to the group, which is the same as Tenant admin → Roles → Scope tags → Assignments. It merges with the tag's existing group assignments instead of replacing them.

```powershell
./intune/scope-tags/New-W365CloudPCScopeTagGroup.ps1 -ScopeTagName '<tag>' -WhatIf
./intune/scope-tags/New-W365CloudPCScopeTagGroup.ps1 -ScopeTagName '<tag>'
```
Requirements:
- Entra ID P1
- An account with Group.ReadWrite.All and DeviceManagementRBAC.ReadWrite.All

Things to know:
- **Timing.** Dynamic group membership and tag propagation can take minutes to hours.
- **Admin visibility.** The scoped admin's Intune role assignment must include this tag. If that role assignment's *Scope (Groups)* is limited to specific groups, add this group there too.
- **Revert.** Remove the group from the scope tag's Assignments, then delete the group.
