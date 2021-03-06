# For more information on the VSTS Task SDK:
# https://github.com/Microsoft/vsts-task-lib

[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    # Import the localized strings.
    Import-VstsLocStrings "$PSScriptRoot\task.json"

    # Load utility functions
    . "$PSScriptRoot\utilities.ps1"
    Import-Module $PSScriptRoot\ps_modules\ServiceFabricHelpers

    # Get inputs.
    $serviceConnectionName = Get-VstsInput -Name serviceConnectionName -Require
    $connectedServiceEndpoint = Get-VstsEndpoint -Name $serviceConnectionName -Require
    $composeFilePath = Get-SinglePathOfType (Get-VstsInput -Name composeFilePath -Require) Leaf -Require
    $applicationName = Get-VstsInput -Name applicationName -Require
    $deployTimeoutSec = Get-VstsInput -Name deployTimeoutSec
    $removeTimeoutSec = Get-VstsInput -Name removeTimeoutSec
    $getStatusTimeoutSec = Get-VstsInput -Name getStatusTimeoutSec

    $deployParameters = @{
        'ApplicationName' = $applicationName
        'Compose' = $composeFilePath
    }
    $removeParameters = @{
        'Force' = $true
    }
    $getStatusParameters = @{
        'ApplicationName' = $applicationName
    }

    $usePreviewApi = $false
    $regKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Service Fabric\' -ErrorAction SilentlyContinue
    if ($regKey)
    {
        if ($regKey.FabricVersion.StartsWith('255.255'))
        {
            $usePreviewApi = $true
            Write-Verbose (Get-VstsLocString -Key UsingPreviewAPI)
        }
    }

    # Test the compose file
    Write-Host (Get-VstsLocString -Key CheckingComposeFile)
    $valid = Test-ServiceFabricApplicationPackage -ComposeFilePath $composeFilePath -ErrorAction Stop

    # Connect to the cluster
    $clusterConnectionParameters = @{}
    Connect-ServiceFabricClusterFromServiceEndpoint -ClusterConnectionParameters $clusterConnectionParameters -ConnectedServiceEndpoint $connectedServiceEndpoint

    $registryCredentials = Get-VstsInput -Name registryCredentials -Require
    switch ($registryCredentials) {
        "ContainerRegistryEndpoint"
        {
            $dockerRegistryEndpointName = Get-VstsInput -Name dockerRegistryEndpointName -Require
            $dockerRegistryEndpoint = Get-VstsEndpoint -Name $dockerRegistryEndpointName -Require
            $authParams = $dockerRegistryEndpoint.Auth.Parameters
            $username = $authParams.username
            $password = $authParams.password
            $isEncrypted = $false
        }
        "AzureResourceManagerEndpoint"
        {
            $azureSubscriptionEndpointName = Get-VstsInput -Name azureSubscriptionEndpoint -Require
            $azureSubscriptionEndpoint = Get-VstsEndpoint -Name $azureSubscriptionEndpointName -Require
            $authParams = $azureSubscriptionEndpoint.Auth.Parameters
            $username = $authParams.serviceprincipalid
            $password = $authParams.serviceprincipalkey
            $isEncrypted = $false
        }
        "UsernamePassword"
        {
            $username = Get-VstsInput -Name registryUserName -Require
            $password = Get-VstsInput -Name registryPassword -Require
            $isEncrypted = (Get-VstsInput -Name passwordEncrypted -Require) -eq "true"
        }
    }

    if ($registryCredentials -ne "None")
    {
        if (-not $isEncrypted)
        {
            Write-Host (Get-VstsLocString -Key EncryptingPassword)
            $password = Get-ServiceFabricEncryptedText -Text $password -ClusterConnectionParameters $clusterConnectionParameters
            $isEncrypted = $true
        }

        if ($usePreviewApi)
        {
            $deployParameters['RepositoryUserName'] = $username
            $deployParameters['RepositoryPassword'] = $password
        }
        else
        {
            $deployParameters['RegistryUserName'] = $username
            $deployParameters['RegistryPassword'] = $password
        }

        $deployParameters['PasswordEncrypted'] = $isEncrypted
    }

    if ($deployTimeoutSec)
    {
        $deployParameters['TimeoutSec'] = $deployTimeoutSec
    }
    if ($removeTimeoutSec)
    {
        $removeParameters['TimeoutSec'] = $removeTimeoutSec
    }
    if ($getStatusTimeoutSec)
    {
        $getStatusParameters['TimeoutSec'] = $getStatusTimeoutSec
    }

    $existingApplication = Get-ServiceFabricComposeApplicationStatusHelper -UsePreviewAPI $usePreviewAPI -GetStatusParameters $getStatusParameters
    if ($existingApplication -ne $null)
    {
        Write-Host (Get-VstsLocString -Key RemovingApplication -ArgumentList $applicationName)
        $removeParameters['ApplicationName'] = $applicationName
        Remove-ServiceFabricComposeApplication @removeParameters

        do
        {
            Write-Host (Get-VstsLocString -Key CurrentStatus -ArgumentList $existingApplication.ComposeApplicationStatus)
            Start-Sleep -Seconds 3
            $existingApplication = Get-ServiceFabricComposeApplicationStatusHelper -UsePreviewAPI $usePreviewAPI -GetStatusParameters $getStatusParameters

        }
        while ($existingApplication -ne $null)
        Write-Host (Get-VstsLocString -Key ApplicationRemoved)
    }

    Write-Host (Get-VstsLocString -Key CreatingApplication)
    New-ServiceFabricComposeApplication @deployParameters

    Write-Host (Get-VstsLocString -Key WaitingForDeploy)
    $newApplication = Get-ServiceFabricComposeApplicationStatusHelper -UsePreviewAPI $usePreviewAPI -GetStatusParameters $getStatusParameters
    while (($newApplication -eq $null) -or `
           ($newApplication.ComposeApplicationStatus -eq 'Provisioning') -or `
           ($newApplication.ComposeApplicationStatus -eq 'Creating'))
    {
        if ($newApplication -eq $null)
        {
            Write-Host (Get-VstsLocString -Key WaitingForDeploy)
        }
        else
        {
            Write-Host (Get-VstsLocString -Key CurrentStatus -ArgumentList $newApplication.ComposeApplicationStatus)
        }
        Start-Sleep -Seconds 3
        $newApplication = Get-ServiceFabricComposeApplicationStatusHelper -UsePreviewAPI $usePreviewAPI -GetStatusParameters $getStatusParameters
    }
    Write-Host (Get-VstsLocString -Key CurrentStatus -ArgumentList $newApplication.ComposeApplicationStatus)

    if ($newApplication.ComposeApplicationStatus -ne 'Created')
    {
        Write-Error (Get-VstsLocString -Key DeployFailed -ArgumentList @($newApplication.ComposeApplicationStatus.ToString(), $newApplication.StatusDetails))
    }
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}