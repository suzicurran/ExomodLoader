<#
ExomodLoader Copyright (C) 2022  Suzi Curran

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#>

# User settings, persisting between runs
[string] $settingsPath = ".\settings.json"
[string] $defaultPathToGameFolder = "$(${ENV:ProgramFiles(x86)})\Steam\steamapps\common\Exocolonist"
[string] $storiesFolderPathSuffix = "Exocolonist_Data\StreamingAssets\Stories"

class ExomodLoaderSettingsFile {
    [int] $SettingsVersion
    [string] $PathToGameStoriesFolder
}

# ModGoesHere
[string] $modGoesHereFolderName = "ModGoesHere"
[string] $modGoesHerePathWindows = ".\$modGoesHereFolderName"
[string] $modGoesHerePathUnix = "./$modGoesHereFolderName"


# Assumptions we're making
[int] $EXPECTED_EXO_FILE_COUNT = 29;
[string] $GIT_EXE_PATH = ".\src\PortableGit\bin\sh.exe"

# Structure for temp files
[string] $hashFileName = "storiesHash"
[string] $tempFolderName = "temp"
[string] $tempPathWindows = ".\$tempFolderName\"
[string] $baseStoriesFolderName = "Stories"

[string] $outputPatchName = "exomod.patch"
[string] $manifestFileName = "exomod_manifest.json"

class ExomodPackagerManifestFile {
    [int] $ManifestVersion
    [string] $Name
    [string] $Author
    [string] $Description
    [string] $StoriesChecksum
}

function applyPatch() {
    param (
        [Parameter(Mandatory = $true)]
        [string] $exomodPatchPath
    )

    Write-Host $exomodPatchPath
    & "$GIT_EXE_PATH" -c "patch -p1 < $exomodPatchPath"
    $patchExitCode = $LASTEXITCODE
    if ($patchExitCode -ne 0) {
        Write-Warning "Mod was not able to be applied properly. This would be a great thing to file a bug report about!"
        Exit 1
    }

    try {
    # Overwrite game Stories with patched copy
    Copy-Item -Path "$tempPathWindows$baseStoriesFolderName\*" -Destination $settings.PathToGameStoriesFolder -Force
    } catch {
        Write-Warning "Something went wrong while updating your game's files. Please validate your game's integrity and file a bug report for this issue!"
        Exit 1
    }
}

function validateStoriesFolderPath() {
    param (
        [string] $inputExoStoriesPath
    )

    [bool] $isValidFolderPath = Test-Path -Path "$inputExoStoriesPath" -PathType Container
    if ($isValidFolderPath) {
        $matchingFiles = Get-ChildItem -Path "$inputExoStoriesPath\*" -Include "*.exo"
        if ($matchingFiles.count -ne $EXPECTED_EXO_FILE_COUNT) {
            Write-Warning "Did not find expected story files in folder. Check the provided location and try again."
            Exit 1
        }
    }
    else {
        Write-Warning "Could not validate path to stories folder. Check the provided location and try again."
        Exit 1
    }
}

function cleanUpTempFiles() {
    if (Test-Path -Path "$tempPathWindows" -PathType Container) {
        Write-Host "Cleaning up temp files..."
        Remove-Item "$tempPathWindows" -Recurse -Force
    }
}

function setUpTempStoriesCopy() {
    param (
        [Parameter(Mandatory = $true)]
        [ExomodLoaderSettingsFile] $settings
    )

    # Clean up just in case, though this should also happen at the end of each run
    cleanUpTempFiles

    # Set up folders
    New-Item -Path "$tempPathWindows" -ItemType Directory | Out-Null

    # Copy stories over from game
    Copy-Item -Path $settings.PathToGameStoriesFolder -Destination "$tempPathWindows$baseStoriesFolderName" -Recurse
}

function getTempBaseStoriesChecksum() {
    $exoFileList = Get-ChildItem "$tempPathWindows$baseStoriesFolderName\*.exo" | Select-Object -Property Name, FullName | Sort-Object
    $exoHashes = "";
    foreach ($exoFile in $exoFileList) {
        $fileHash = (Get-FileHash $exoFile.FullName -Algorithm MD5).Hash
        $exoHashes = "$exoHashes $fileHash $($exoFile.Name)"
    }
    $tempHashFilePath = "$tempPathWindows$hashFileName"
    Out-File -FilePath "$tempHashFilePath" -InputObject $exoHashes -NoClobber
    if (Test-Path -Path "$tempHashFilePath" -PathType Leaf) {
        return (Get-FileHash -Path "$tempHashFilePath" -Algorithm MD5).Hash
    }
    else {
        Write-Warning "Failed while generating hash to validate base stories folder."
        Exit 1
    }
}

function getModFolderName() {
    [bool] $isModGoesHerePresent = Test-Path -Path "$modGoesHerePathWindows" -PathType Container
    if (!$isModGoesHerePresent) {
        Write-Warning "Expected Mod Goes Here folder is missing. Consider re-downloading this loader."
        Exit 1
    }
    
    $directories = Get-ChildItem "$modGoesHerePathWindows" -Directory | Select-Object -Property Name
    if ($directories.count -gt 1) {
        Write-Warning "You have more than one folder in ModGoesHere. At this time, loading only one mod is supported."
        Exit 1
    }
    return $directories[0].Name
}

function getManifestFromPath() {
    param (
        [Parameter(Mandatory = $true)]
        [string] $modManifestPath
    )

    [bool] $isModManifestPresent = Test-Path -Path "$modManifestPath" -PathType Leaf
    if (!$isModManifestPresent) {
        Write-Warning "Mod is missing expected exomod_manifest.json and will not be loaded."
        Exit 1
    }
    try {
        $modManifestFileContent = ConvertFrom-Json (Get-Content -Path "$modManifestPath" -Raw)
        $modManifest = [ExomodPackagerManifestFile]::new()
        $modManifest.ManifestVersion = $modManifestFileContent.ManifestVersion
        if ($modManifest.ManifestVersion -ne 1) {throw}
        $modManifest.StoriesChecksum = $modManifestFileContent.StoriesChecksum
        $modManifest.Name = $modManifestFileContent.Name
        $modManifest.Author = $modManifestFileContent.Author
        Write-Host "Loading '$($modManifest.Name)' by $($modManifest.Author)!"
        return $modManifest
    } catch {
        Write-Warning "Unable to load exomod_manifest.json."
        Exit 1
    }
}

function getSettings() {
    [bool] $isSettingsFromFile = $false
    # Check if settings already exist
    if (Test-Path -Path "$settingsPath" -PathType Leaf) {
        # Load and populate settings from file
        Write-Host "Found settings.json, loading settings from it..."
        $settingsFileContent = ConvertFrom-Json (Get-Content -Path "$settingsPath" -Raw)
        if ($settingsFileContent.SettingsVersion -eq 1) {
            try {
                $loadedSettings = [ExomodLoaderSettingsFile]::new()
                $loadedSettings.PathToGameStoriesFolder = $settingsFileContent.PathToGameStoriesFolder
                Write-Host $loadedSettings.PathToGameStoriesFolder
                validateStoriesFolderPath($loadedSettings.PathToGameStoriesFolder)
                Write-Host "Settings loaded from file look good!"
                $isSettingsFromFile = $true
            }
            catch {
                Write-Warning "Could not parse settings file for expected values. File may be corrupt: consider deleting it and re-running the script."
                Exit 1
            }
        }
        else {
            Write-Warning "Additional settings schema versions haven't been implemented. What are you even doing?"
            Write-Warning "Version $($isSettingsFromFile.SettingsVersion)"
            Exit 1
        }
    }

    # If not, create a new settings file and populate it
    if (!$isSettingsFromFile) {
        $newSettings = [ExomodLoaderSettingsFile]::new()
        $newSettings.SettingsVersion = 1;

        # Prompt the user for the path to their game folder. Use the default path if none is provided.
        $userGameDirectory = Read-Host -Prompt "Please enter the path of your game directory. Press enter to use the default value: $($defaultPathToGameFolder)"

        # Append the Stories folder to the base game path
        if ($userGameDirectory -eq "") {
            $newSettings.PathToGameStoriesFolder = "$defaultPathToGameFolder\$storiesFolderPathSuffix"
        } else {
            $newSettings.PathToGameStoriesFolder = "$userGameDirectory\$storiesFolderPathSuffix"
        }

        validateStoriesFolderPath($newSettings.PathToGameStoriesFolder)
        Write-Host "New loader settings look good! Saving to settings.json for future use..."

        # Save them down immediately if validated
        [string] $newSettingsJson = ConvertTo-Json $newSettings
        Out-File -FilePath ".\settings.json" -InputObject $newSettingsJson -NoClobber
    }
    if ($isSettingsFromFile) { return $loadedSettings } else { return $newSettings }
}

function displayIntroText() {
    Write-Host -ForegroundColor Magenta "Welcome to ExomodLoader!"
    Write-Host "Before using this tool:" 
    Write-Host "1. Remember to back up your save data, usually found in /Documents/Exocolonist."
    Write-Host "2. Verify your game files are up to date. See README if you need help with this."
    Write-Host "This program comes with ABSOLUTELY NO WARRANTY."
    Write-Host "This is free software, and you are welcome to redistribute it under certain conditions."
    Write-Host "See LICENSE for details."
}


# ===== START =====
displayIntroText

[ExomodLoaderSettingsFile] $settings = getSettings

[string] $modFolderName = getModFolderName
if ($modFolderName.Contains(" ")) {
    Write-Warning "Mod folder is improperly formed. If you would like to try anyway, remove all spaces from mod folder name and try again."
    Exit 1
}

[string] $modManifestPath = "$modGoesHerePathWindows\$modFolderName\$manifestFileName"
[ExomodPackagerManifestFile] $modManifest = getManifestFromPath($modManifestPath)

# Prepare to modddd
setUpTempStoriesCopy($settings)

# Check the version we're about to patch matches the version the mod intends to apply to
[string] $tempStoriesChecksum = getTempBaseStoriesChecksum
if ($tempStoriesChecksum -ne $modManifest.StoriesChecksum) {
    Write-Warning "This mod was created using a different version of Stories than the one you've supplied. It will not be applied."
    Exit 1
}

applyPatch("$modGoesHerePathUnix/$modFolderName/$outputPatchName")
cleanUpTempFiles
Write-Host -ForegroundColor Magenta "Patch applied to I Was a Teenage Colonist! Enjoy!"
Exit 0