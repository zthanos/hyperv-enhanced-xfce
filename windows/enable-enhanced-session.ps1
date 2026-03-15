Write-Host "Checking Hyper-V Enhanced Session Mode..."

$vmhost = Get-VMHost

if ($vmhost.EnableEnhancedSessionMode -eq $false) {
    Write-Host "Enabling Enhanced Session Mode"
    Set-VMHost -EnableEnhancedSessionMode $true
}
else {
    Write-Host "Enhanced Session Mode already enabled"
}

Write-Host ""
Write-Host "VM status:"
Get-VM | Select Name,State,EnhancedSessionTransportType