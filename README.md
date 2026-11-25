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
- Hybrid-joined Cloud PCs need extra rules to DCs (88, 389, 445, 135, 49152-65535, 464, 636, 3268) — not included.
- Other line-of-business apps on non-80/443 ports will break (by design). Pilot first.
- Revert: unassign/delete the profile, or set `DefaultOutboundAction` = 0.
