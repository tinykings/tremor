<#
.SYNOPSIS
    Scans for installed Steam games and adds them to Apollo/Sunshine apps.json, using local Steam cover art.

.DESCRIPTION
    This script finds the Steam installation path, locates all library folders, scans for installed games,
    copies existing cover art from Steam's local library cache, and updates the Apollo/Sunshine configuration file.

.PARAMETER ApolloConfigPath
    Path to the apps.json file. Defaults to "C:\Program Files\Apollo\config\apps.json".

.PARAMETER CoverArtPath
    Directory to save copied cover art. Defaults to "C:\Program Files\Apollo\covers".

.PARAMETER ForceUpdate
    If specified, updates existing games and refreshes their cover art.

.EXAMPLE
    .\Get-SteamGamesForApollo.ps1
#>

param(
    [string]$ApolloConfigPath = "C:\Program Files\Apollo\config\apps.json",

    [string]$CoverArtPath = "C:\Program Files\Apollo\covers",

    [switch]$ForceUpdate
)

# Function to get Steam Path from Registry
function Get-SteamPath {
    try {
        $steamPath = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction Stop
        return $steamPath.SteamPath -replace "/", "\"
    }
    catch {
        Write-Warning "Could not find Steam path in Registry."
        return $null
    }
}

# Function to parse VDF file for library folders
function Get-SteamLibraryFolders {
    param($SteamPath)

    $folders = @($SteamPath)
    $vdfPath = Join-Path $SteamPath "steamapps\libraryfolders.vdf"

    if (Test-Path $vdfPath) {
        $content = Get-Content $vdfPath -Raw
        # Regex to find "path" "..."
        $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
        foreach ($match in $matches) {
            $path = $match.Groups[1].Value -replace "\\\\", "\"
            if ($path -ne $SteamPath -and (Test-Path $path)) {
                $folders += $path
            }
        }
    }

    return $folders | Select-Object -Unique
}

# Function to parse VDF file for App Manifest
function Get-SteamAppInfo {
    param($ManifestPath)

    if (-not (Test-Path $ManifestPath)) { return $null }

    $content = Get-Content $ManifestPath -Raw

    $nameMatch = [regex]::Match($content, '"name"\s+"([^"]+)"')
    $appIdMatch = [regex]::Match($content, '"appid"\s+"(\d+)"')

    if ($nameMatch.Success -and $appIdMatch.Success) {
        $name = $nameMatch.Groups[1].Value
        $appId = $appIdMatch.Groups[1].Value

        # --- Filtering Logic ---

        # Blacklisted App IDs (Tools, Runtimes, etc.)
        $blacklistedIds = @(
            '228980',  # Steamworks Common Redistributables
            '1070560', # Steam Linux Runtime
            '1391110', # Steam Linux Runtime - Soldier
            '1628350', # Steam Linux Runtime - Sniper
            '250820'   # SteamVR
        )

        if ($blacklistedIds -contains $appId) {
            Write-Verbose "Skipping known tool/runtime: $name ($appId)"
            return $null
        }

        # Keyword Filtering (Case-insensitive)
        $toolKeywords = @(
            'Steamworks',
            'Redistributables',
            'DirectX',
            'Proton',
            'Runtime',
            'Dedicated Server',
            'Benchmark',
            ' SDK',
            ' Driver'
        )

        foreach ($keyword in $toolKeywords) {
            if ($name -match $keyword) {
                Write-Verbose "Skipping tool by keyword '$keyword': $name"
                return $null
            }
        }

        # --- End Filtering ---

        return [PSCustomObject]@{
            Name  = $name
            AppId = $appId
            Path  = $ManifestPath
        }
    }

    return $null
}

# Main Script Logic
Write-Host "Checking for Administrator privileges..."
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script may need Administrator privileges to write to '$ApolloConfigPath'."
}

$steamPath = Get-SteamPath
if (-not $steamPath) {
    Write-Error "Steam installation not found."
    exit
}

Write-Host "Found Steam at: $steamPath"

# Define local library cache path.
# Steam stores cover art flat in this folder as: {AppID}_library_600x900.jpg, {AppID}_header.jpg, etc.
# There are NO per-AppID subdirectories.
$libraryCachePath = Join-Path $steamPath "appcache\librarycache"
if (-not (Test-Path $libraryCachePath)) {
    Write-Warning "Steam library cache not found at '$libraryCachePath'. Cover art may not be available."
} else {
    Write-Host "Steam library cache found at: $libraryCachePath"
}

$libraryFolders = Get-SteamLibraryFolders -SteamPath $steamPath
Write-Host "Found $($libraryFolders.Count) library folder(s)."

$installedGames = @()
foreach ($folder in $libraryFolders) {
    $steamAppsPath = Join-Path $folder "steamapps"
    if (Test-Path $steamAppsPath) {
        $manifests = Get-ChildItem -Path $steamAppsPath -Filter "appmanifest_*.acf"
        foreach ($manifest in $manifests) {
            $gameInfo = Get-SteamAppInfo -ManifestPath $manifest.FullName
            if ($gameInfo) {
                $installedGames += $gameInfo
            }
        }
    }
}

Write-Host "Found $($installedGames.Count) installed game(s)."

# Ensure cover directory exists
if (-not (Test-Path $CoverArtPath)) {
    try {
        New-Item -ItemType Directory -Path $CoverArtPath -Force | Out-Null
    }
    catch {
        Write-Error "Failed to create cover directory at '$CoverArtPath'. Check permissions."
        exit
    }
}

# Load existing apps.json
$config = @{ apps = @() }
if (Test-Path $ApolloConfigPath) {
    try {
        $jsonContent = Get-Content $ApolloConfigPath -Raw
        $config = $jsonContent | ConvertFrom-Json
        if (-not $config.apps) { $config.apps = @() }
    }
    catch {
        Write-Warning "Could not parse existing apps.json. Starting with empty configuration."
    }
} else {
    Write-Host "Creating new configuration file..."
}

# Convert to ArrayList for easier manipulation
$appsList = [System.Collections.ArrayList]::new()
if ($config.apps) {
    $config.apps | ForEach-Object { $appsList.Add($_) } | Out-Null
}

$newGamesCount = 0

foreach ($game in $installedGames) {
    # Check if game already exists
    $existingApp = $appsList | Where-Object { $_.name -eq $game.Name }

    if ($existingApp -and $ForceUpdate) {
        Write-Host "Updating existing game: $($game.Name)"
        $appsList.Remove($existingApp)
        $existingApp = $null
    }

    if (-not $existingApp) {
        if (-not $ForceUpdate) {
            Write-Host "Adding new game: $($game.Name)"
        }

        $imagePath = ""

        # Local Steam Asset Search
        # Files live flat in librarycache\ named {AppID}_library_600x900.jpg, etc.
        $localCoverSource = $null

        if (Test-Path $libraryCachePath) {
            # Priority 1: Vertical Library Cover (600x900) — best for Apollo
            $localCoverSource = Get-ChildItem -Path $libraryCachePath -Filter "$($game.AppId)_library_600x900*.jpg" -File -ErrorAction SilentlyContinue | Select-Object -First 1

            # Priority 2: Legacy capsule cover
            if (-not $localCoverSource) {
                $localCoverSource = Get-ChildItem -Path $libraryCachePath -Filter "$($game.AppId)_library_capsule*.jpg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }

            # Priority 3: Header image fallback (horizontal, but better than nothing)
            if (-not $localCoverSource) {
                $localCoverSource = Get-ChildItem -Path $libraryCachePath -Filter "$($game.AppId)_header.jpg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }

        if ($localCoverSource) {
            $fileName = "$($game.AppId)$($localCoverSource.Extension)"
            $destPath = Join-Path $CoverArtPath $fileName

            try {
                Copy-Item -Path $localCoverSource.FullName -Destination $destPath -Force
                $imagePath = $destPath
                Write-Host "  Copied local cover art: $fileName (from $($localCoverSource.Name))"
            }
            catch {
                Write-Warning "  Failed to copy cover art for $($game.Name)."
            }
        } else {
            Write-Host "  No local cover art found in Steam cache for $($game.Name)."
        }

        $newApp = [ordered]@{
            name              = $game.Name
            output            = ""
            cmd               = ""
            detached          = @("steam://rungameid/$($game.AppId)")
            "image-path"      = $imagePath
            "virtual-display" = $true
        }

        $appsList.Add($newApp) | Out-Null
        $newGamesCount++
    }
    else {
        Write-Verbose "Skipping $($game.Name) (already exists)"
    }
}

if ($newGamesCount -gt 0) {
    $config.apps = $appsList

    try {
        $jsonOutput = $config | ConvertTo-Json -Depth 5
        $jsonOutput | Set-Content -Path $ApolloConfigPath -Encoding UTF8
        Write-Host "Successfully added $newGamesCount new game(s) to '$ApolloConfigPath'."
        Write-Host "Please restart Apollo/Sunshine service for changes to take effect."
    }
    catch {
        Write-Error "Failed to save configuration file: $_"
    }
} else {
    Write-Host "No new games found to add."
}
