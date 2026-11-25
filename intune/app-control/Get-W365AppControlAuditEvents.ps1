<#
.SYNOPSIS
  Run on a Cloud PC (or via Intune remediation) during audit mode: lists what WOULD have been blocked.
  Event 3076 = would block (audit), 3077 = blocked (enforced), 8028/8029 = script/MSI equivalents.
#>
param([int]$Hours = 72)
$since = (Get-Date).AddHours(-$Hours)
$events = foreach ($log in 'Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-AppLocker/MSI and Script') {
    Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 3076,3077,8028,8029; StartTime = $since } -ErrorAction SilentlyContinue
}
$events | ForEach-Object {
    $x = [xml]$_.ToXml(); $d = @{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
    [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; File = if ($d['File Name']) { $d['File Name'] } else { $d['FilePath'] }; Process = $d['Process Name'] }
} | Sort-Object File -Unique | Format-Table -AutoSize
