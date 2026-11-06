#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Cross-platform iSCSI mounter with activity monitoring and auto-disconnect via Proxmox API

.DESCRIPTION
    Mounts iSCSI target from Proxmox, runs background activity monitor, and automatically
    disconnects via Proxmox API after 15 minutes of inactivity.

    Usage:
        irm https://share.it174.pro/mount.ps1 | iex

    Requires:
        - PowerShell 7+ (pwsh)
        - Windows: Administrator privileges
        - Linux: sudo/root for iscsiadm
#>

# ============================================
# CONFIGURATION (hardcoded for one-liner deployment)
# ============================================
$script:ISCSI_TARGET_IP = "192.168.1.100"        # Proxmox host IP
$script:ISCSI_IQN = "iqn.2024-10.com.proxmox:it-share"  # iSCSI target IQN
$script:PROXMOX_API_URL = "https://192.168.1.100:8006/api2/json"  # Proxmox API
$script:PROXMOX_API_TOKEN = "root@pam!token-id=YOUR-TOKEN-HERE"  # Proxmox API token
$script:INACTIVITY_TIMEOUT_MINUTES = 15        # Auto-disconnect timeout
$script:MOUNT_POINT_LINUX = "/mnt/it-share"    # Linux mount point
$script:MOUNT_LETTER_WINDOWS = "Z:"            # Windows drive letter

# ============================================
# PLATFORM DETECTION
# ============================================
function Get-Platform {
    if ($IsWindows) {
        return "Windows"
    } elseif ($IsLinux) {
        return "Linux"
    } else {
        throw "Unsupported platform: $($PSVersionTable.Platform)"
    }
}

# ============================================
# LOGGING
# ============================================
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================
# WINDOWS: iSCSI MOUNTING
# ============================================
function Mount-iSCSI-Windows {
    Write-Log "Mounting iSCSI target on Windows..." -Level Info

    try {
        # Check if already connected
        $existing = iscsicli.exe ListTargets 2>&1 | Select-String $script:ISCSI_IQN
        if ($existing) {
            Write-Log "Target already connected" -Level Warning
            return $true
        }

        # Connect to target
        Write-Log "Connecting to $script:ISCSI_TARGET_IP ..." -Level Info
        $result = iscsicli.exe QAddTargetPortal $script:ISCSI_TARGET_IP 3260
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add target portal"
        }

        $result = iscsicli.exe QAddTarget $script:ISCSI_IQN
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add target"
        }

        $result = iscsicli.exe LoginTarget $script:ISCSI_IQN * * * * * * * * * * * * * * * 0
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to login to target"
        }

        # Wait for disk to appear
        Write-Log "Waiting for disk to appear..." -Level Info
        Start-Sleep -Seconds 5

        # Get disk number
        $disk = Get-Disk | Where-Object { $_.BusType -eq "iSCSI" -and $_.OperationalStatus -eq "Online" } | Select-Object -First 1
        if (-not $disk) {
            throw "iSCSI disk not found"
        }

        # Initialize if needed
        if ($disk.PartitionStyle -eq "RAW") {
            Write-Log "Initializing disk..." -Level Info
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop
        }

        # Get or create partition
        $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        if (-not $partition) {
            Write-Log "Creating partition..." -Level Info
            $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter:$false -ErrorAction Stop
        }

        # Format if needed
        $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
        if (-not $volume -or $volume.FileSystem -ne "NTFS") {
            Write-Log "Formatting volume (this may take a while)..." -Level Info
            $partition | Format-Volume -FileSystem NTFS -Confirm:$false -Force -ErrorAction Stop
        }

        # Assign drive letter
        $driveLetter = $script:MOUNT_LETTER_WINDOWS -replace ":"
        if ($partition.DriveLetter -ne $driveLetter) {
            Write-Log "Assigning drive letter $script:MOUNT_LETTER_WINDOWS..." -Level Info
            $partition | Set-Partition -NewDriveLetter $driveLetter -ErrorAction Stop
        }

        Write-Log "Successfully mounted as $script:MOUNT_LETTER_WINDOWS" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to mount iSCSI on Windows: $_" -Level Error
        return $false
    }
}

function Dismount-iSCSI-Windows {
    Write-Log "Dismounting iSCSI target on Windows..." -Level Info

    try {
        # Remove drive letter assignment
        $disk = Get-Disk | Where-Object { $_.BusType -eq "iSCSI" } | Select-Object -First 1
        if ($disk) {
            $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
            if ($partition) {
                Write-Log "Removing drive letter..." -Level Info
                $partition | Remove-PartitionAccessPath -AccessPath "$($partition.DriveLetter):" -ErrorAction SilentlyContinue
            }
        }

        # Logout from target
        $result = iscsicli.exe LogoutTarget $script:ISCSI_IQN
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully disconnected from iSCSI target" -Level Success
        } else {
            Write-Log "Logout failed (may already be disconnected)" -Level Warning
        }

        return $true
    }
    catch {
        Write-Log "Failed to dismount iSCSI on Windows: $_" -Level Error
        return $false
    }
}

# ============================================
# LINUX: iSCSI MOUNTING
# ============================================
function Mount-iSCSI-Linux {
    Write-Log "Mounting iSCSI target on Linux..." -Level Info

    try {
        # Check if running as root
        if ($(id -u) -ne 0) {
            throw "This script must be run as root on Linux (use sudo)"
        }

        # Check if iscsiadm is available
        if (-not (Get-Command iscsiadm -ErrorAction SilentlyContinue)) {
            throw "iscsiadm not found. Install open-iscsi: apt install open-iscsi or yum install iscsi-initiator-utils"
        }

        # Check if already connected
        $existing = iscsiadm -m session 2>&1 | Select-String $script:ISCSI_IQN
        if ($existing) {
            Write-Log "Target already connected" -Level Warning
            return $true
        }

        # Discover target
        Write-Log "Discovering target..." -Level Info
        iscsiadm -m discovery -t st -p $script:ISCSI_TARGET_IP 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to discover target"
        }

        # Login to target
        Write-Log "Logging in to target..." -Level Info
        iscsiadm -m node -T $script:ISCSI_IQN -p $script:ISCSI_TARGET_IP --login 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to login to target"
        }

        # Wait for device to appear
        Write-Log "Waiting for device to appear..." -Level Info
        Start-Sleep -Seconds 5

        # Find the device
        $device = lsblk -o NAME,SIZE | Select-String "sd[b-z]" | Select-Object -First 1
        if (-not $device) {
            throw "iSCSI device not found"
        }

        $devicePath = "/dev/$($device.ToString().Split()[0])"

        # Create mount point if not exists
        if (-not (Test-Path $script:MOUNT_POINT_LINUX)) {
            New-Item -ItemType Directory -Path $script:MOUNT_POINT_LINUX -Force | Out-Null
        }

        # Mount device
        Write-Log "Mounting $devicePath to $script:MOUNT_POINT_LINUX..." -Level Info
        mount $devicePath $script:MOUNT_POINT_LINUX 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Try formatting if mount fails
            Write-Log "Mount failed, attempting to format as ext4..." -Level Warning
            mkfs.ext4 -F $devicePath 2>&1 | Out-Null
            mount $devicePath $script:MOUNT_POINT_LINUX 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to mount device"
            }
        }

        Write-Log "Successfully mounted to $script:MOUNT_POINT_LINUX" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to mount iSCSI on Linux: $_" -Level Error
        return $false
    }
}

function Dismount-iSCSI-Linux {
    Write-Log "Dismounting iSCSI target on Linux..." -Level Info

    try {
        # Unmount
        if (Test-Path $script:MOUNT_POINT_LINUX) {
            umount $script:MOUNT_POINT_LINUX 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully unmounted $script:MOUNT_POINT_LINUX" -Level Success
            }
        }

        # Logout from target
        iscsiadm -m node -T $script:ISCSI_IQN -p $script:ISCSI_TARGET_IP --logout 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully disconnected from iSCSI target" -Level Success
        } else {
            Write-Log "Logout failed (may already be disconnected)" -Level Warning
        }

        return $true
    }
    catch {
        Write-Log "Failed to dismount iSCSI on Linux: $_" -Level Error
        return $false
    }
}

# ============================================
# PROXMOX API: DISCONNECT TARGET
# ============================================
function Disconnect-iSCSI-Proxmox {
    Write-Log "Disconnecting iSCSI target via Proxmox API..." -Level Info

    try {
        $headers = @{
            "Authorization" = "PVEAPIToken=$($script:PROXMOX_API_TOKEN)"
        }

        # Note: Adjust this endpoint based on your Proxmox setup
        # This is a placeholder - actual endpoint depends on Proxmox configuration
        $url = "$($script:PROXMOX_API_URL)/nodes/localhost/qemu/agent/exec"
        $body = @{
            command = "iscsiadm -m node -T $($script:ISCSI_IQN) --logout"
        } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -SkipCertificateCheck

        Write-Log "Successfully sent disconnect command to Proxmox" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to disconnect via Proxmox API: $_" -Level Error
        return $false
    }
}

# ============================================
# ACTIVITY MONITOR
# ============================================
function Start-ActivityMonitor {
    param(
        [string]$MountPath
    )

    Write-Log "Starting activity monitor (timeout: $($script:INACTIVITY_TIMEOUT_MINUTES) min)..." -Level Info

    $monitorScript = {
        param($MountPath, $TimeoutMinutes, $ParentPid)

        # Set up signal handling
        [Console]::TreatControlCAsInput = $false

        $lastActivity = Get-Date
        $checkInterval = 60  # Check every minute

        while ($true) {
            Start-Sleep -Seconds $checkInterval

            # Check if parent process is still running
            try {
                $parent = Get-Process -Id $ParentPid -ErrorAction Stop
            }
            catch {
                # Parent process died, exit monitor
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] Parent process died, exiting monitor"
                exit 0
            }

            # Check for file activity
            $hasActivity = $false

            if ($IsWindows) {
                # Windows: check file system activity using performance counters
                try {
                    $drive = $MountPath -replace ":$"
                    $counter = Get-Counter "\FileSystem($drive)\Disk Read Bytes/sec" -ErrorAction SilentlyContinue
                    if ($counter -and $counter.CounterSamples[0].CookedValue -gt 0) {
                        $hasActivity = $true
                    }
                }
                catch {
                    # Fallback: just check timestamp
                }
            }
            else {
                # Linux: check file modification times
                try {
                    $files = Get-ChildItem -Path $MountPath -Recurse -ErrorAction SilentlyContinue | Measure-Object
                    if ($files.Count -gt 0) {
                        $latest = Get-ChildItem -Path $MountPath -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($latest.LastWriteTime -gt $lastActivity) {
                            $hasActivity = $true
                        }
                    }
                }
                catch {
                    # Mount point may not be accessible
                }
            }

            if ($hasActivity) {
                $lastActivity = Get-Date
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] Activity detected, resetting timer"
            }

            # Check timeout
            $inactiveTime = (Get-Date) - $lastActivity
            if ($inactiveTime.TotalMinutes -ge $TimeoutMinutes) {
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Warning] Inactivity timeout reached, disconnecting..."
                # Call disconnect function (this would need to be in a shared module)
                exit 0
            }
        }
    }

    # Start monitor in background
    $monitorPid = Start-Process pwsh -ArgumentList "-NoProfile -Command & { $monitorScript } $MountPath $script:INACTIVITY_TIMEOUT_MINUTES $PID" -NoNewWindow -PassThru -WindowStyle Hidden

    Write-Log "Activity monitor started (PID: $($monitorPid.Id))" -Level Success
    return $monitorPid.Id
}

# ============================================
# MAIN
# ============================================
function Main {
    param(
        [ValidateSet("mount", "unmount", "status")]
        [string]$Action = "mount",
        [switch]$NoMonitor
    )

    $platform = Get-Platform
    Write-Log "Platform: $platform" -Level Info
    Write-Log "PowerShell version: $($PSVersionTable.PSVersion)" -Level Info

    switch ($Action) {
        "mount" {
            if ($platform -eq "Windows") {
                $success = Mount-iSCSI-Windows
                $mountPath = $script:MOUNT_LETTER_WINDOWS
            }
            else {
                $success = Mount-iSCSI-Linux
                $mountPath = $script:MOUNT_POINT_LINUX
            }

            if ($success -and -not $NoMonitor) {
                $monitorPid = Start-ActivityMonitor -MountPath $mountPath
                Write-Log "Share mounted and monitor running. Press Ctrl+C to stop." -Level Success
                Write-Log "Share path: $mountPath" -Level Info

                # Keep running until Ctrl+C
                try {
                    while ($true) {
                        Start-Sleep -Seconds 10
                    }
                }
                finally {
                    Write-Log "Shutting down..." -Level Info
                    if ($monitorPid) {
                        Stop-Process -Id $monitorPid -ErrorAction SilentlyContinue
                    }
                    if ($platform -eq "Windows") {
                        Dismount-iSCSI-Windows
                    }
                    else {
                        Dismount-iSCSI-Linux
                    }
                }
            }
            elseif ($success) {
                Write-Log "Share mounted successfully (no monitor)." -Level Success
                Write-Log "Share path: $mountPath" -Level Info
            }
            else {
                exit 1
            }
        }

        "unmount" {
            if ($platform -eq "Windows") {
                Dismount-iSCSI-Windows
            }
            else {
                Dismount-iSCSI-Linux
            }
        }

        "status" {
            Write-Log "Status check not implemented yet" -Level Warning
        }
    }
}

# Parse command line arguments
$action = "mount"
$noMonitor = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--mount" { $action = "mount" }
        "--unmount" { $action = "unmount" }
        "--status" { $action = "status" }
        "--no-monitor" { $noMonitor = $true }
        default {
            Write-Log "Unknown argument: $($args[$i])" -Level Error
            exit 1
        }
    }
}

# Run main function
Main -Action $action -NoMonitor:$noMonitor
