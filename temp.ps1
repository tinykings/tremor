#
.SYNOPSIS
    Scans for installed Steam games and adds them to Apollo/Sunshine apps.json with cover art from SteamGridDB.

.DESCRIPTION
    This script finds the Steam installation path, locates all library folders, scans for installed games,
    fetches cover art from SteamGridDB (requires API Key), and updates the Apollo/Sunshine configuration file.

.PARAMETER SteamGridDBApiKey
    Your personal API Key from SteamGridDB (https://www.steamgriddb.com/profile/preferences/api).
    Required for cover art downloading.

.PARAMETER ApolloConfigPath
    Path to the apps.json file. Defaults to "C:\Program Files\Apollo\config\apps.json".

.PARAMETER CoverArtPath
    Directory to save downloaded cover art. Defaults to "C:\Program Files\Apollo\covers".

.EXAMPLE
    .\Get-SteamGamesForApollo.ps1 -SteamGridDBApiKey "YOUR_API_KEY"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SteamGridDBApiKey,

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

# Function to get cover art URL from SteamGridDB using Steam AppID directly
function Get-SteamGridDBCover {
    param($AppId)

    if (-not $SteamGridDBApiKey -or -not $AppId) { return $null }

    $headers = @{ "Authorization" = "Bearer $SteamGridDBApiKey" }

    # Try 1: Prefer vertical grids (600x900) looked up by Steam AppID
    $url = "https://www.steamgriddb.com/api/v2/grids/steam/$($AppId)?dimensions=600x900&styles=alternate,official,white_logo,material"

    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        if ($response.success -and $response.data.Count -gt 0) {
            return $response.data[0].url
        }
    }
    catch {
        Write-Verbose "  Specific dimension search failed for Steam AppID $AppId. Trying fallback..."
    }

    # Try 2: Fallback to ANY grid for this Steam AppID
    $fallbackUrl = "https://www.steamgriddb.com/api/v2/grids/steam/$($AppId)?styles=alternate,official,white_logo,material"

    try {
        $response = Invoke-RestMethod -Uri $fallbackUrl -Headers $headers -Method Get -ErrorAction Stop
        if ($response.success -and $response.data.Count -gt 0) {
            return $response.data[0].url
        }
    }
    catch {
        Write-Warning "  Failed to get cover for Steam AppID '$AppId': $($_.Exception.Message)"
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

        # SteamGridDB Integration — look up directly by Steam AppID (no search step needed)
        if ($SteamGridDBApiKey) {
            Write-Host "  Fetching cover art from SteamGridDB..."
            $imageUrl = Get-SteamGridDBCover -AppId $game.AppId

            if ($imageUrl) {
                $fileName = "$($game.AppId).png"
                $localImagePath = Join-Path $CoverArtPath $fileName

                try {
                    Invoke-WebRequest -Uri $imageUrl -OutFile $localImagePath
                    $imagePath = $localImagePath
                    Write-Host "  Downloaded cover art to: $imagePath"
                }
                catch {
                    Write-Warning "  Failed to download cover art."
                }
            } else {
                Write-Host "  No cover art found on SteamGridDB."
            }
        }

        $newApp = [ordered]@{
            name             = $game.Name
            output           = ""
            cmd              = ""
            detached         = @("steam://rungameid/$($game.AppId)")
            "image-path"     = $imagePath
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
