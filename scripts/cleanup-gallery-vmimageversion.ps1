param(
    [String] [Parameter (Mandatory=$true)] $ClientId,
    [String] [Parameter (Mandatory=$true)] $ClientSecret,
    [String] [Parameter (Mandatory=$true)] $SubscriptionId,
    [String] [Parameter (Mandatory=$true)] $TenantId,
    [String] [Parameter (Mandatory=$true)] $GalleryName,
    [String] [Parameter (Mandatory=$true)] $GalleryResourceGroup,
    [int] [Parameter (Mandatory=$true)] $GalleryImagesToKeep,
    [Array] [Parameter (Mandatory=$true)] $ImageDefinitions
)

# Variables
$ImageCountThreshold = $GalleryImagesToKeep + 1

# install required modules
install-module Az.Compute -Scope CurrentUser -AllowClobber -Force
import-module Az.Compute

# Login using service principal
$securePassword = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
$credentials = New-Object -TypeName PSCredential -ArgumentList $ClientId, $securePassword
Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credentials -Subscription $SubscriptionId

# Get the gallery
try {
    $gallery = Get-AzGallery -Name $GalleryName -ResourceGroupName $GalleryResourceGroup 
    }
catch  {
    Write-Host "##vso[task.logissue type=error;] Gallery '$GalleryName' not found"
    Write-Host "##vso[task.complete result=Failed;]Task failed!"
    exit 1

}

$needToWait = $false
$JobList = @()
if ($gallery) {
    # Loop through the image definitions
    foreach ($imageDefinition in $ImageDefinitions) {
        # Get the image definition
        try {
        $imageDef = Get-AzGalleryImageDefinition  -ResourceGroupName $GalleryResourceGroup -GalleryName $gallery.Name  -GalleryImageDefinitionName $imageDefinition
            }
        catch {
            Write-Host "##vso[task.logissue type=error;] Imagedefinition '$imageDefinition' not found"
            Write-Host "##vso[task.complete result=Failed;]Task failed!"
            exit 1
        }
                
        if ($imageDef) {
            # Get all images of the image definition
            $images = Get-AzGalleryImageVersion -ResourceGroupName $GalleryResourceGroup -GalleryImageDefinitionName $imageDef.Name  -GalleryName $gallery.Name

            # Filter to succeeded versions only and sort by published date ascending (oldest first)
            $succeededImages = $images | Where-Object { $_.ProvisioningState -eq 'Succeeded' } | Sort-Object -Property { $_.PublishingProfile.PublishedDate }
               
            if ($succeededImages.Count -ge $ImageCountThreshold) {
                # Remove all succeeded images except the most recent ones
                $imagesToRemove = $succeededImages[0..($succeededImages.Count - $GalleryImagesToKeep - 1)]
                foreach ($imageToRemove in $imagesToRemove) {
                    Write-Host "##[section]Removing image version for image definition '$imageDefinition': $($imageToRemove.Name) with $($imageToRemove.PublishingProfile.PublishedDate)"
                    $JobList += Remove-AzGalleryImageVersion -ResourceGroupName $GalleryResourceGroup -GalleryName $gallery.Name -GalleryImageDefinitionName $imageDefinition -Name $imageToRemove.Name -Force -AsJob
                    $needToWait = $true
                }
            } else {
                Write-Host "##[section]The number of succeeded images for image definition '$imageDefinition' is $($succeededImages.Count), which is no more than $GalleryImagesToKeep. No images will be removed."
            }
        }
   }
} 

if ($needToWait) {
    Write-Host "##[section]Waiting for the image removal jobs to finish."
    $JobList | Wait-Job | Receive-Job | Format-Table -AutoSize
}
else {
    Write-Host "##[section]No image removal jobs were started."
}
