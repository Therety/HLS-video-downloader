# Edit output path:
$outputDir = "C:\Documents\"

# Include path of video and audio here:
$videoPlaylistUrl = "PASTE_VIDEO_M3U8_URL_HERE"
$audioPlaylistUrl = "PASTE_AUDIO_M3U8_URL_HERE"

# ffmpeg location
$ffmpegPath = "ffmpeg.exe"

# parallel downloads per track
$maxParallel = 10

# output file
$finalOutput = Join-Path $outputDir "final_with_audio.mp4"

function Ensure-Dir([string]$dir) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

function Download-With-Retries([string]$url, [string]$outFile, [int]$maxRetries = 3) {
    $attempt = 0
    while ($attempt -lt $maxRetries) {
        $attempt++
        try {
            Invoke-WebRequest $url -OutFile $outFile -ErrorAction Stop
            return $true
        } catch {
            if (Test-Path $outFile) { Remove-Item $outFile -ErrorAction SilentlyContinue }
            if ($attempt -lt $maxRetries) { Start-Sleep -Seconds 2 }
        }
    }
    return $false
}

function Parse-BaseUrlAndToken([string]$playlistUrl) {
    $baseUrl = $playlistUrl -replace "index\.fmp4\.m3u8.*$", ""
    $token = ""
    if ($playlistUrl -match "\?(token=.*)$") {
        $token = "?" + $matches[1]
    }
    return @{
        BaseUrl = $baseUrl
        Token   = $token
    }
}

function Build-Local-PlaylistAndSegments {
    param(
        [Parameter(Mandatory=$true)][string]$playlistUrl,
        [Parameter(Mandatory=$true)][string]$trackDir,  
        [Parameter(Mandatory=$true)][string]$trackName,
        [Parameter(Mandatory=$true)][int]$maxParallel
    )

    Ensure-Dir $trackDir

    $playlistFile = Join-Path $trackDir "playlist.m3u8"
    Write-Host "`n[$trackName] Downloading playlist -> $playlistFile"
    Invoke-WebRequest $playlistUrl -OutFile $playlistFile -ErrorAction Stop

    $parsed = Parse-BaseUrlAndToken $playlistUrl
    $baseUrl = $parsed.BaseUrl
    $token   = $parsed.Token

    Write-Host "[$trackName] Base URL: $baseUrl"
    Write-Host "[$trackName] Token:    $token"

    $originalLines = Get-Content $playlistFile

    # ---- Find/init download (EXT-X-MAP) ----
    $initFile = Join-Path $trackDir "init.mp4"
    $initUrl  = $null

    foreach ($line in $originalLines) {
        if ($line.Trim().StartsWith("#EXT-X-MAP:")) {
            if ($line -match 'URI="([^"]+)"') {
                $uri = $matches[1]
                if ($uri.StartsWith("http")) {
                    $initUrl = $uri
                } else {
                    $initUrl = $baseUrl + $uri
                    if ($initUrl -notmatch "\?token=") { $initUrl += $token }
                }
            }
            break
        }
    }

    if ($initUrl) {
        if (Test-Path $initFile) {
            Write-Host "[$trackName] Skipping init.mp4 (already exists)"
        } else {
            Write-Host "[$trackName] Downloading INIT -> init.mp4"
            $ok = Download-With-Retries -url $initUrl -outFile $initFile -maxRetries 3
            if (-not $ok) { Write-Host "[$trackName] WARNING: Failed to download init segment" }
        }
    } else {
        Write-Host "[$trackName] WARNING: Playlist has no EXT-X-MAP (no init segment)"
    }

    # ---- Parse segment URIs ----
    $lines = $originalLines | Where-Object { -not $_.StartsWith("#") -and $_.Trim() -ne "" }

    $segments = @()
    $index = 0
    foreach ($line in $lines) {
        $index++
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith("http")) {
            $segUrl = $trimmed
        } else {
            $segUrl = $baseUrl + $trimmed
            if ($segUrl -notmatch "\?token=") { $segUrl += $token }
        }

        $outFile = Join-Path $trackDir ("seg-$index.mp4")

        $segments += [PSCustomObject]@{
            Index   = $index
            Url     = $segUrl
            OutFile = $outFile
        }
    }

    Write-Host "[$trackName] Total segments listed: $($segments.Count)"

    # ---- Parallel download ----
    $jobs = @()

    foreach ($seg in $segments) {
        if (Test-Path $seg.OutFile) {
            Write-Host "[$trackName] Skipping $(Split-Path $seg.OutFile -Leaf) (already exists)"
            continue
        }

        while (@(Get-Job -State Running).Count -ge $maxParallel) {
            Start-Sleep -Seconds 1
        }

        Write-Host "[$trackName] Starting job: $(Split-Path $seg.OutFile -Leaf)"

        $job = Start-Job -Name "${trackName}_seg_$($seg.Index)" -ScriptBlock {
            param($url, $filePath)

            $maxRetries = 3
            $attempt = 0
            while ($attempt -lt $maxRetries) {
                $attempt++
                try {
                    Invoke-WebRequest $url -OutFile $filePath -ErrorAction Stop
                    return
                } catch {
                    if (Test-Path $filePath) { Remove-Item $filePath -ErrorAction SilentlyContinue }
                    if ($attempt -lt $maxRetries) { Start-Sleep -Seconds 2 }
                }
            }

            throw "Failed to download $url after $maxRetries attempts"
        } -ArgumentList $seg.Url, $seg.OutFile

        $jobs += $job
    }

    if ($jobs.Count -gt 0) {
        Write-Host "[$trackName] Waiting for $($jobs.Count) jobs..."
        Wait-Job -Job $jobs | Out-Null

        $failed = $jobs | Where-Object { $_.State -ne "Completed" }
        if ($failed) {
            Write-Host "[$trackName] Some jobs FAILED:"
            foreach ($j in $failed) {
                Write-Host "  Job $($j.Name): $($j.State)"
                if ($j.Error) {
                    $j.Error | ForEach-Object { Write-Host "    $($_.Exception.Message)" }
                }
            }
            $jobs | Remove-Job -Force
            throw "[$trackName] Aborting due to failed segment downloads."
        } else {
            Write-Host "[$trackName] All jobs completed successfully."
        }

        $jobs | Remove-Job -Force
    }

    # ---- Build local.m3u8 ----
    $newLines = [System.Collections.Generic.List[string]]::new()
    $segIdx = 0

    foreach ($line in $originalLines) {
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith("#EXT-X-MAP:")) {
            $newLines.Add('#EXT-X-MAP:URI="init.mp4"')
        }
        elseif ($trimmed.StartsWith("#")) {
            $newLines.Add($line)
        }
        elseif ($trimmed -ne "") {
            if ($segIdx -lt $segments.Count) {
                $localName = Split-Path $segments[$segIdx].OutFile -Leaf
                $newLines.Add($localName)
                $segIdx++
            } else {
                $newLines.Add($line)
            }
        }
    }

    $localPlaylist = Join-Path $trackDir "local.m3u8"
    $newLines | Set-Content $localPlaylist

    Write-Host "[$trackName] local.m3u8 created -> $localPlaylist"

    return @{
        TrackDir      = $trackDir
        LocalPlaylist = $localPlaylist
    }
}

# MAIN
Ensure-Dir $outputDir

$videoDir = Join-Path $outputDir "video"
$audioDir = Join-Path $outputDir "audio"
Ensure-Dir $videoDir
Ensure-Dir $audioDir

$video = Build-Local-PlaylistAndSegments -playlistUrl $videoPlaylistUrl -trackDir $videoDir -trackName "video" -maxParallel $maxParallel
$audio = Build-Local-PlaylistAndSegments -playlistUrl $audioPlaylistUrl -trackDir $audioDir -trackName "audio" -maxParallel $maxParallel

# Run ffmpeg once to mux tracks into a single MP4
Write-Host "`n[MUX] Building final MP4 -> $finalOutput"

& $ffmpegPath `
  -y `
  -protocol_whitelist file,crypto,tcp,udp,http,https,tls `
  -allowed_extensions ALL `
  -i $video.LocalPlaylist `
  -i $audio.LocalPlaylist `
  -map 0:v:0 -map 1:a:0 `
  -c copy `
  $finalOutput

if ($LASTEXITCODE -ne 0) {
    throw "[MUX] ffmpeg failed with exit code $LASTEXITCODE"
}

Write-Host "[DONE] Created: $finalOutput"
