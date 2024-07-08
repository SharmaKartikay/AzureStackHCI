#####
##### Run parts from this script from a management machine in the network pointing to the HCI 23H2 nodes using their IP Addresses to curb any DNS issues since the nodes are not domain joined.
#####

### START OF RUN ONCE SECTION ###

# Enable WinRM CredSSP and Setting Trusted Hosts to any for sending credentials when using IP Address instead of Hostname.
    Enable-WSManCredSSP -Role Client -DelegateComputer * -Force
    Enable-WSManCredSSP -Role Server -Force
    cmd /c winrm set winrm/config/client '@{TrustedHosts="*"}'

# Supply the Local Administrator Credentials of the baremetal installed nodes.
    $CREDS=(Get-Credential -Message "Local Administrator Account and Password")

# Supply the IP Addresses of the Nodes *** User Modification Required to change IP Addresses ***
    $Nodes = @("10.1.1.11", "10.1.1.12", "10.1.1.13")

# Rename Computers *** User Modification Required rename the nodes ***
    Invoke-Command -Credential $CREDS -ComputerName 10.1.1.11 -ScriptBlock {Rename-Computer -NewName L231 -Restart}
    Invoke-Command -Credential $CREDS -ComputerName 10.1.1.12 -ScriptBlock {Rename-Computer -NewName L232 -Restart}
    Invoke-Command -Credential $CREDS -ComputerName 10.1.1.13 -ScriptBlock {Rename-Computer -NewName L233 -Restart}

# Enable RDP (Optional, Security baseline will disable it during deployment from Azure Portal)
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
    $tsRegPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
    Set-ItemProperty -Path $tsRegPath -Name "fDenyTSConnections" -Value 0
    Set-ItemProperty -Path "$tsRegPath\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
    Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*Remote Desktop*"} | Enable-NetFirewallRule
    Restart-Service -Name TermService -Force
    }

#Change BCD and Reboot for Virtualized LABs
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
    bcdedit /SET HYPERVISORLAUNCHTYPE AUTO
    Restart-Computer -Force
    }

# Install Failover Clustering and Hyper-V followed by a reboot.
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
    Install-WindowsFeature -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools
    Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools -restart
    }

#Rename NICs to the names used on Hyper-V VM Settings for the Network Adapters.
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
        # Get the advanced properties of the network adapters
            $netAdapters = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayName -eq "Hyper-V Network Adapter Name" }

        # Rename the network adapters based on their Hyper-V Network Adapter Name
            foreach ($netAdapter in $netAdapters) {
                $newName = $netAdapter.DisplayValue
                $oldName = $netAdapter.InterfaceAlias
                Rename-NetAdapter -ifAlias $oldName -NewName $newName
            }

        # Display the updated advanced properties of the network adapters
            Get-NetAdapterAdvancedProperty | ft -AutoSize | findstr HyperVNetworkAdapterName

}

# Setting Static IP on SMB Adapters.
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
    Remove-NetIPAddress -InterfaceAlias SMB*
    Get-NetAdapterAdvancedProperty -Name smb* -DisplayName "VLAN ID"
    }

Invoke-Command -Credential $CREDS -ComputerName 10.1.1.11 -ScriptBlock {New-NetIPAddress -InterfaceAlias SMB1 -IPAddress 1.1.1.1 -PrefixLength 28
                                                                        New-NetIPAddress -InterfaceAlias SMB2 -IPAddress 2.2.2.1 -PrefixLength 28}
Invoke-Command -Credential $CREDS -ComputerName 10.1.1.12 -ScriptBlock {New-NetIPAddress -InterfaceAlias SMB1 -IPAddress 1.1.1.2 -PrefixLength 28
                                                                        New-NetIPAddress -InterfaceAlias SMB2 -IPAddress 2.2.2.2 -PrefixLength 28}
Invoke-Command -Credential $CREDS -ComputerName 10.1.1.13 -ScriptBlock {New-NetIPAddress -InterfaceAlias SMB1 -IPAddress 1.1.1.3 -PrefixLength 28
                                                                        New-NetIPAddress -InterfaceAlias SMB2 -IPAddress 2.2.2.3 -PrefixLength 28}

### END OF RUN ONCE SECTION ###

### OPTIONAL SECTION ###

# Install App Compat FOD (Minimum Shell) for the ease of troubelshooting. It adds support for Explorer.exe and MMC.exe (Optional and requires Reboot)
    Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
    
    #Run Either of the below commands below that are commented via Console \ RDP on the Nodes as they can not be run remotely over Remote PS Session.

    ## Add-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
    
    ## Cmd.exe /c dism.exe /online /Add-Capability /CapabilityName:ServerCore.AppCompatibility~~~~0.0.1.0

    Restart-Computer -Force
    }

### END OF OPTIONAL SECTION ###

### ARC ENROLL + UN-ENROLL SECTION ###

# Run the sub-sections as needed.

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
$RG = "LAB1"
$Tenant = "f67bb77d-xxxx-xxxx-xxxx-92300e68498a"
Connect-AzAccount -SubscriptionId $Subscription -TenantId $Tenant -DeviceCode -SkipContextPopulation -Environment AzureCloud -Force -AccountId admin@theqtz.com
Update-AzConfig -EnableLoginByWam $false -Scope CurrentUser
##Register Resource Providers on the Subscription by Executing these lines on any one node when logged on to Azure. (This is a Tenant Level Change)
#Register-AzResourceProvider -ProviderNamespace "Microsoft.HybridCompute"
#Register-AzResourceProvider -ProviderNamespace "Microsoft.GuestConfiguration"
#Register-AzResourceProvider -ProviderNamespace "Microsoft.HybridConnectivity"
#Register-AzResourceProvider -ProviderNamespace "Microsoft.AzureStackHCI"

$ARMtoken = (Get-AzAccessToken).Token
sleep 5
$id = (Get-AzContext).Account.Id
sleep 5
Invoke-AzStackHciArcInitialization -SubscriptionID $Subscription -ResourceGroup $RG -TenantID $Tenant -Region WESTEUROPE -Cloud "AzureCloud" -ArmAccessToken $ARMtoken -AccountID $id -VERBOSE
}


#
# Remove Arc Enrollment of the Machines. **** Change the values of variables defined below.
#
#
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


#Virtualized LAB POC must have these registry for Enabling Bitlocker where TPM is already enabled on all VMs during creation.
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\FVE"

$NameValuePairs = @{
    "OSRecovery" = 1
    "OSManageDRA" = 1
    "OSRecoveryPassword" = 2
    "OSRecoveryKey" = 2
    "OSHideRecoveryPage" = 0
    "OSActiveDirectoryBackup" = 1
    "OSActiveDirectoryInfoToStore" = 1
    "OSRequireActiveDirectoryBackup" = 1
    "FDVRecovery" = 1
    "FDVManageDRA" = 1
    "FDVRecoveryPassword" = 2
    "FDVRecoveryKey" = 2
    "FDVHideRecoveryPage" = 0
    "FDVActiveDirectoryBackup" = 1
    "FDVActiveDirectoryInfoToStore" = 1
    "FDVRequireActiveDirectoryBackup" = 1
}

if (!(Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

foreach ($entry in $NameValuePairs.GetEnumerator()) {
    New-ItemProperty -Path $registryPath -Name $entry.Key -Value $entry.Value -PropertyType DWORD -Force | Out-Null
}
}

#
#
# DURING DEPLOYMENT TO AVOID FAILURES Reset VLAN ID On Storage Adapters if its nested Virtualization POC deployment when the Deployment has failed at Validating Cluster before Creation. Replace SMB with common text in adapter names.
#
#
Invoke-Command -ComputerName $Nodes -Credential $CREDS -ScriptBlock{
Get-NetAdapterAdvancedProperty -Name SMB* -DisplayName 'VLAN ID'
#Set-NetIntent -Name smb -StorageVlans 0
#Reset-NetAdapterAdvancedProperty -DisplayName 'VLAN ID' -Name SMB*
#Get-NetAdapterAdvancedProperty -Name SMB* -DisplayName 'VLAN ID'
Restart-NetAdapter -Name SMB1
Pause
Restart-NetAdapter -Name SMB2
}
