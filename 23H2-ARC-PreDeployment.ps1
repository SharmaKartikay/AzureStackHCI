#####
##### Run parts from this script from a management machine in the network pointing to the HCI 23H2 nodes using their IP Addresses to curb any DNS issues as the nodes are not join to the domain.
#####

### START OF RUN ONCE SECTION ###

# Enable WinRM CredSSP and Setting Trusted Hosts to any for sending credentials when using IP Address instead of Hostname.
Enable-WSManCredSSP -Role Client -DelegateComputer * -Force
Enable-WSManCredSSP -Role Server -Force
cmd /c winrm set winrm/config/client '@{TrustedHosts="*"}'

# Supply the Local Administrator Credentials of the baremetal installed nodes.
$CREDS=(Get-Credential -Message "Local Administrator Account and Password")

# Supply the IP Addresses of the Nodes *** User Modification Required to change IP Addresses ***
$Nodes = @("10.1.1.31", "10.1.1.32", "10.1.1.33")

# Rename COmputers *** User Modification Required rename the nodes ***
Invoke-Command -Credential $CREDS -ComputerName 10.1.1.31 -ScriptBlock {Rename-Computer -NewName NODE01 -Restart}
Invoke-Command -Credential $CREDS -ComputerName 10.1.1.32 -ScriptBlock {Rename-Computer -NewName NODE02 -Restart}
Invoke-Command -Credential $CREDS -ComputerName 10.1.1.33 -ScriptBlock {Rename-Computer -NewName NODE03 -Restart}

# Enable RDP (Optional, Security baseline will disable it during deployment from Azure Portal)
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
$tsRegPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
Set-ItemProperty -Path $tsRegPath -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "$tsRegPath\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
Restart-Service -Name TermService -Force
}

# Install Failover Clustering and Hyper-V followed by a reboot.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
bcdedit /SET HYPERVISORLAUNCHTYPE AUTO
Install-WindowsFeature -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools
Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools -restart
}

### END OF RUN ONCE SECTION ###

### OPTIONAL SECTION ###

# Install App Compat FOD (Minimum Shell) for the ease of troubelshooting. It adds support for Explorer.exe and MMC.exe (Optional and requires Reboot)
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
#Add-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
cmd /c dism /online /Add-Capability /CapabilityName:ServerCore.AppCompatibility~~~~0.0.1.0
Restart-Computer
}

### END OF OPTIONAL SECTION ###

### ARC ENROLL + UN-ENROLL SECTION ###

# Run the sub-sections as needed.

# Update the module AzsHCI.ARCinstaller module if already installed.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
Install-Module AzsHCI.ARCinstaller -FORCE
}

#Install the required PS Modules.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
#Register PSGallery as a trusted repo
#Register-PSRepository -Default -InstallationPolicy Trusted
#Install Arc registration script from PSGallery 
Install-Module AzsHCI.ARCinstaller -FORCE
#Install required PowerShell modules in your node for registration
Install-Module Az.Accounts -Force
Install-Module Az.ConnectedMachine -Force
Install-Module Az.Resources -Force
}

# Enroll machines in Arc. **** Change the values of variables defined below.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
$Subscription = "b37c2031-xxxx-xxxx-xxxx-403dbf403410"
$RG = "WORKSPACE-23H2"
$Tenant = "f67bb77d-xxxx-xxxx-xxxx-92300e68498a"
Connect-AzAccount -SubscriptionId $Subscription -TenantId $Tenant -DeviceCode

#Register Resource Providers on the Subscription
Register-AzResourceProvider -ProviderNamespace "Microsoft.HybridCompute"
Register-AzResourceProvider -ProviderNamespace "Microsoft.GuestConfiguration"
Register-AzResourceProvider -ProviderNamespace "Microsoft.HybridConnectivity"
Register-AzResourceProvider -ProviderNamespace "Microsoft.AzureStackHCI"

$ARMtoken = (Get-AzAccessToken).Token
$id = (Get-AzContext).Account.Id
Invoke-AzStackHciArcInitialization -SubscriptionID $Subscription -ResourceGroup $RG -TenantID $Tenant -Region WESTEUROPE -Cloud "AzureCloud" -ArmAccessToken $ARMtoken -AccountID $id -VERBOSE
}

# Remove Arc Enrollment of the Machines. **** Change the values of variables defined below.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
$Subscription = "b37c2031-xxxx-xxxx-xxxx-403dbf403410"
$RG = "WORKSPACE-23H2"
$Tenant = "f67bb77d-xxxx-xxxx-xxxx-92300e68498a"
Connect-AzAccount -SubscriptionId $Subscription -TenantId $Tenant -DeviceCode

$ARMtoken = (Get-AzAccessToken).Token
$id = (Get-AzContext).Account.Id
Remove-AzStackHciArcInitialization -SubscriptionID $Subscription -ResourceGroup $RG -TenantID $Tenant -Cloud AzureCloud -ArmAccessToken $ARMtoken -AccountID $id
Remove-AzResourceGroup -NAME $RG -FORCE
}

# Uninstall Azure Connected Machine Agent (AZCMAGENT \ Arc Agent)
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
cmd /c MsiExec.exe /q /x "{3B803BB6-5030-4949-9410-A3293889D71F}"
}

#Reset VLAN ID On Storage Adapters if its nested Virtualization POC deployment when the Deployment has failed at Validating Cluster before Creation. Replace SMB with common text in adapter names.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
Get-NetAdapterAdvancedProperty -Name SMB* -DisplayName 'VLAN ID'
#Set-NetIntent -Name smb -StorageVlans 0
#Reset-NetAdapterAdvancedProperty -DisplayName 'VLAN ID' -Name SMB*
#Get-NetAdapterAdvancedProperty -Name SMB* -DisplayName 'VLAN ID'
Restart-NetAdapter -Name SMB1
Pause
Restart-NetAdapter -Name SMB2
}
