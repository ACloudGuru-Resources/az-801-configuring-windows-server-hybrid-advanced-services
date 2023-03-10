param(
    $UserName,
    $Password,
    $ParentVHDPath,
    $VHDLink,
    $VM,
    $IP = '10.2.1.2',
    $Prefix = '24',
    $DefaultGateway = '10.2.1.1',
    $DNSServers = @('168.63.129.16')
)
# Set the Error Action Preference
$ErrorActionPreference = 'Stop'

# Configure Logging
$AllUsersDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
$LogFile = Join-Path -Path $AllUsersDesktop -ChildPath "$($VM)-Labsetup.log" 

function Write-Log ($Entry, $Path = $LogFile) {
    Add-Content -Path $LogFile -Value "$((Get-Date).ToShortDateString()) $((Get-Date).ToShortTimeString()): $($Entry)" 
} 
function Wait-VMReady ($VM)
{
    while ((Get-VM $VM | Select-Object -ExpandProperty Heartbeat) -notlike "Ok*") {
        Start-Sleep -Seconds 1
    }
}
function Wait-VMPowerShellReady ($VM, $Credential)
{
    while (-not (Invoke-Command -ScriptBlock {Get-ComputerInfo} -VMName $VM -Credential $Credential -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
    }
}

#Start a stopwatch to measure the deployment time
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Find Windows VHDs
$urls = @(
    'https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019'
)

# Loop through the urls, search for VHD download links and add to totalfound array and display number of downloads
$totalfound = foreach ($url in $urls) {
    try {
        $content = Invoke-WebRequest -Uri $url -ErrorAction Stop
        $downloadlinks = $content.links | Where-Object { `
                $_.'aria-label' -match 'Download' `
                -and $_.'aria-label' -match 'VHD'
        }
        $count = $DownloadLinks.href.Count
        $totalcount += $count
        Write-Log -Entry "Processing $url, Found $count Download(s)..."
        foreach ($DownloadLink in $DownloadLinks) {
            [PSCustomObject]@{
                Name   = $DownloadLink.'aria-label'.Replace('Download ', '')
                Tag    = $DownloadLink.'data-bi-tags'.Split('"')[3].split('-')[0]
                Format = $DownloadLink.'data-bi-tags'.Split('-')[1].ToUpper()
                Link   = $DownloadLink.href
            }
            Write-Log -Entry "Found VHD Image"
        }
    }
    catch {
        Write-Log -Entry "$url is not accessible"
        return
    }
}

# Download Information to pass to Create-VM.ps1
$VHDLink = $totalfound.Link
$VHDName = $totalfound.Name.Split('-')[0]
$VHDName = $VHDName.Replace(' ', '-')
$ParentVHDPath = "C:\Users\Public\Documents\$VHDName.vhd"

#Detect if Hyper-V is installed
if ((Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online).State -ne 'Enabled') {
    Write-Log -Entry "Hyper-V Role and/or required PowerShell module is not installed, please install before running this script..."
    return
}
else {
    Write-Log -Entry "Hyper-V Role is installed, continuing..."
}

# Download VHDLink
try {
    Invoke-WebRequest -Uri "$VHDLink" -OutFile "$ParentVHDPath"
    Write-Log -Entry "Successful Download - $ParentVHDPath"
}
catch {
    Write-Log -Entry "Failed to Download - $ParentVHDPath"
}

# Import Hyper-V Module
try{
    Import-Module Hyper-V
    Write-Log -Entry "Imported Hyper-V Module Successfully"
}
catch{
    Write-Log -Entry "Failed to Import Hyper-V Module"
}

# Wait for Hyper-V
while (-not(Get-VMHost -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 5
}

# Create NAT Virtual Switch
Write-Log -Entry "VM Creation Start"
try{
    if (-not(Get-VMSwitch -Name "InternalvSwitch" -ErrorAction SilentlyContinue)) {
        Write-Log -Entry "Create Virtual Switch Start"
        New-VMSwitch -Name 'InternalvSwitch' -SwitchType 'Internal'
        New-NetNat -Name LocalNAT -InternalIPInterfaceAddressPrefix '10.2.1.0/24'
        Get-NetAdapter "vEthernet (InternalvSwitch)" | New-NetIPAddress -IPAddress 10.2.1.1 -AddressFamily IPv4 -PrefixLength 24
        Write-Log -Entry "Create Virtual Switch Success"
    }
} catch {
    Write-Log -Entry "Create Virtual Switch Failed. Please contact Support."
    Write-Log $_
    Exit
}

# Create VHD
try {
    Write-Log -Entry "Create VHD Start"
    New-VHD -ParentPath "$ParentVHDPath" -Path "C:\Temp\$($VM).vhd" -Differencing
    Write-Log -Entry "Create VHD Success"
} catch {
    Write-Log -Entry "Create VHD Failed. Please contact support."
    Exit
}

# Download Answer File 
try {
    Write-Log -Entry "Download Answer File Start"
    New-Item -Path "C:\Temp\$($VM)" -ItemType Directory -ErrorAction SilentlyContinue
    $AnswerFilePath = "C:\Temp\$($VM)\unattend.xml"
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/linuxacademy/az-801-configuring-windows-server-hybrid-advanced-services/main/13%20-%20Migrate%20On-Premises%20Servers%20to%20Azure/testbicep/unattend.xml" -OutFile $AnswerFilePath
    Write-Log -Entry "Download Answer File Success"
}
catch {
    Write-Log -Entry "Download Answer File Failed. Please contact Support."
    Exit
}

# Update Answer File
try {
    Write-Log -Entry "Update Answer File Start"
    # Inject ComputerName into Answer File
    (Get-Content $AnswerFilePath) -Replace '%COMPUTERNAME%', "$($VM)" | Set-Content $AnswerFilePath

    # Inject Password into Answer File
    (Get-Content $AnswerFilePath) -Replace '%LABPASSWORD%', "$($Password)" | Set-Content $AnswerFilePath
    Write-Log -Entry "Update Answer File Success"
}
catch {
    Write-Log -Entry "Update Answer File Failed. Please contact Support."
    Exit
}

# Inject Answer File into VHD
try {
    Write-Log -Entry "Inject Answer File into VHD Start"
    $Volume = Mount-VHD -Path "C:\Temp\$($VM).vhd" -PassThru | Get-Disk | Get-Partition | Get-Volume
    New-Item "$($Volume.DriveLetter):\Windows" -Name "Panther" -ItemType Directory -ErrorAction "SilentlyContinue"
    Copy-Item $AnswerFilePath "$($Volume.DriveLetter):\Windows\Panther\unattend.xml"
    Write-Log -Entry "Inject Answer File into VHD Success"
}
catch {
    Write-Log -Entry "Inject Answer File into VHD Failed. Please contact Support."
    Exit
}

# Dismount the VHD
try {
    Write-Log -Entry "Dismount VHD Start"
    Dismount-VHD -Path "C:\Temp\$($VM).vhd"
    Write-Log -Entry "Dismount VHD Success"
}
catch {
    Write-Log -Entry "Dismount VHD Failed. Please contact Support."
    Exit
}

# Create and Start VM
try {
    Write-Log -Entry "Create and Start VM Start"
    # Create Virtual Machine
    New-VM -Name "$($VM)" -Generation 1 -MemoryStartupBytes 2GB -VHDPath "C:\Temp\$($VM).vhd" -SwitchName 'InternalvSwitch'
    Set-VMProcessor "$($VM)" -Count 2
    Set-VMProcessor "$($VM)" -ExposeVirtualizationExtensions $true

    # Ensure Enhanced Session Mode is enabled on the host and VM
    Set-VMhost -EnableEnhancedSessionMode $true
    Set-VM -VMName "$($VM)" -EnhancedSessionTransportType HvSocket

    # Start the VM
    Start-VM -VMName "$($VM)" 
    Write-Log -Entry "Create and Start VM Success"
}
catch {
    Write-Log -Entry "Create and Start VM Failed. Please contact Support."
    Exit
}


# Wait for the VM to be ready, rename-VM and configure IP Addressing
try {
    Write-Log -Entry "VM Customization Start"
    # Generate Credentials
    $SecurePassword = ConvertTo-SecureString "$($Password)" -AsPlainText -Force
    [pscredential]$Credential = New-Object System.Management.Automation.PSCredential ($UserName, $SecurePassword)

    # Wait for the VM to be ready
    Wait-VMReady -VM $VM

    # Wait for Unattend to run
    Wait-VMPowerShellReady -VM $VM -Credential $Credential

    # Configure IP addresssing
    # IP
    Invoke-Command -ScriptBlock {New-NetIPAddress -IPAddress $using:IP -PrefixLength $using:Prefix -InterfaceAlias (Get-NetIPInterface -InterfaceAlias "*Ethernet*" -AddressFamily IPv4 | Select-Object -Expand InterfaceAlias) -DefaultGateway $using:DefaultGateway | Out-Null} -VMName $VM -Credential $Credential
    # DNS
    Invoke-Command -ScriptBlock {Set-DnsClientServerAddress -InterfaceAlias (Get-NetIPInterface -InterfaceAlias "*Ethernet*" -AddressFamily IPv4 | Select-Object -Expand InterfaceAlias) -ServerAddresses $using:DNSServers | Out-Null} -VMName $VM -Credential $Credential
    
    # Rename VM
    Invoke-Command -ScriptBlock {Rename-Computer -NewName $using:VM -Restart:$false} -VMName $VM -Credential $Credential

    # Restart VM
    Restart-VM -Name "$($VM)" -Force
    
    Write-Log -Entry "VM Customization Success"
}
catch {
    Write-Log -Entry "VM Customization Failed. Please contact Support."
    Exit
}

Wait-VMReady -VM $VM

#The end, stop stopwatch and display the time that it took to deploy
$stopwatch.Stop()
$hours = $stopwatch.Elapsed.Hours
$minutes = $stopwatch.Elapsed.Minutes
$seconds = $stopwatch.Elapsed.Seconds

Write-Log -Entry "Deployment Completed Successfully - Deployment Time in HH:MM:SS format - $hours:$minutes:$seconds"