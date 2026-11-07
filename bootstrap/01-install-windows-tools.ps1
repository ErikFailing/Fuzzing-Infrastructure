#Requires -Version 5.1
<#
========================================================================================================================
                                              01-install-windows-tools.ps1
========================================================================================================================
The first bootstrap script: installs, and keeps up to date, everything the Windows side of the fuzzing workstation
needs. That's WSL2 and
an Ubuntu 24.04 distro (the Linux host the fuzzing runs in; a later script installs Docker inside it), plus
the tools for working with it: Windows Terminal, VS Code with its WSL and Dev Containers extensions, Git for Windows
and PowerShell 7.

  powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\01-install-windows-tools.ps1 -WhatIf   # dry run
  powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\01-install-windows-tools.ps1

Run it from a normal (not admin) PowerShell. The installers that need admin (WSL, Git, PowerShell 7) ask for it
themselves through UAC. It needs network access to the winget source, the Microsoft Store and api.github.com.

Exit codes: 0 done (an update waiting on a running app still counts as done); 3010 reboot Windows, then run the
same command again (it picks up where it stopped); 1 something failed or was skipped, and the summary says what.

----- Check first, then install or update -----
Everything is checked before anything changes. Something missing is installed; something installed is updated when
a newer version is waiting, and otherwise left alone. Nothing is ever reinstalled over a good install. Keeping these
current is free, because none of them can change a fuzzing result: what can (compilers, fuzzers, sanitizers) is
pinned inside the toolchain image later, so these aren't pinned here at all.

An app that's running is never updated, since its installer would close it, or close this very window when the
script runs inside Windows Terminal or PowerShell 7. Its update waits, and the summary says what to close.

----- Why Windows PowerShell 5.1 -----
A fresh Windows machine only has Windows PowerShell 5.1 (this script is what installs PowerShell 7), so it has to run
there: no PowerShell 7 syntax, and plain ASCII only, since 5.1 reads a file without a byte order mark in the ANSI
code page.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'An interactive setup script: the output is for a person, not the pipeline')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Don't ask before updating WSL stops running distros (and whatever campaigns are running in them).
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'



# ========== Settings ==================================================================================================

# The oldest Windows build with "wsl --install": Windows 10 2004. Windows 11 is well past it.
$MinimumWindowsBuild = 19041

# The Linux distro to install, as "wsl --list --online" names it. Plain "Ubuntu" means the newest release (26.04
# now), so the release is named explicitly: 24.04 is the one Docker, LLVM and AFL++ have the longest track record on.
$DistroName = 'Ubuntu-24.04'

# Where we look up WSL's latest release, to decide whether "wsl --update" is needed at all (so it never runs, or asks
# for admin, when there's nothing to update). This only lists full releases, never pre-releases.
$WslLatestReleaseUrl = 'https://api.github.com/repos/microsoft/WSL/releases/latest'

# The apps, by winget ID, in the order they're installed. VS Code is installed per user (Microsoft's recommendation),
# so it updates itself without admin; the rest use their installer's default. Processes are the app's own windows,
# which must all be closed before it can be updated (Git's are Git Bash's mintty windows), and Close says what to
# close in words.
$WingetPackages = @(
    [pscustomobject]@{
        Id = 'Microsoft.WindowsTerminal'; Name = 'Windows Terminal'; Scope = ''
        Processes = @('WindowsTerminal'); Close = 'every Windows Terminal window'
    },
    [pscustomobject]@{
        Id = 'Git.Git'; Name = 'Git for Windows'; Scope = ''
        Processes = @('mintty', 'git-bash'); Close = 'every Git Bash window'
    },
    [pscustomobject]@{
        Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Scope = ''
        Processes = @('pwsh'); Close = 'every PowerShell 7 window'
    },
    [pscustomobject]@{
        Id = 'Microsoft.VisualStudioCode'; Name = 'VS Code'; Scope = 'user'
        Processes = @('Code'); Close = 'VS Code'
    }
)

# The VS Code extensions: WSL (edit and run inside Ubuntu as if it were local) and Dev Containers (attach to the
# fuzzing toolchain's container).
$VSCodeExtensions = @('ms-vscode-remote.remote-wsl', 'ms-vscode-remote.remote-containers')

# winget's exit code for "no installed package matched" (0x8A150014, APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND).
# Any other nonzero code from "winget list" means winget itself had a problem, not that the app is missing.
$WingetNotInstalled = -1978335212

# The exit code for "done, but Windows needs a reboot", the same one Windows installers use.
$RebootNeeded = 3010



# ========== State =====================================================================================================

# The script's own cmdlet object, so helper functions can reach -WhatIf (see Test-ShouldChange).
$script:Cmdlet = $PSCmdlet

# What this run found up to date, installed, updated, left waiting on a running app, or couldn't do, for the summary
# at the end. The names end in "Items" because PowerShell variable names ignore case: a plain $installed anywhere in
# the script would replace them.
$script:UpToDateItems = New-Object System.Collections.Generic.List[string]
$script:InstalledItems = New-Object System.Collections.Generic.List[string]
$script:UpdatedItems = New-Object System.Collections.Generic.List[string]
$script:WaitingItems = New-Object System.Collections.Generic.List[string]
$script:ProblemItems = New-Object System.Collections.Generic.List[string]

# The wsl.exe that ships with Windows. Once the WSL package is installed, it hands every command to the package's own
# wsl.exe, so it's the right one to call either way. wsl.exe writes UTF-16 to a pipe unless WSL_UTF8 is set.
$Wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$env:WSL_UTF8 = '1'

# Load the modules the checks use now, with -WhatIf off. Loaded on first use instead, they'd inherit -WhatIf and
# print a "What if: Set Alias" line for every alias they define.
$whatIfWanted = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets
Import-Module Appx -ErrorAction SilentlyContinue
$WhatIfPreference = $whatIfWanted



# ========== Output ====================================================================================================

# A heading for each phase.
function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

# Something already installed and up to date, which we leave alone.
function Write-UpToDate([string]$Text) {
    Write-Host "    ok         $Text" -ForegroundColor Green
    $script:UpToDateItems.Add($Text)
}

# Something this run installed.
function Write-Installed([string]$Text) {
    Write-Host "    installed  $Text" -ForegroundColor Yellow
    $script:InstalledItems.Add($Text)
}

# Something this run updated to a newer version.
function Write-Updated([string]$Text) {
    Write-Host "    updated    $Text" -ForegroundColor Yellow
    $script:UpdatedItems.Add($Text)
}

# An update that's waiting because the app is running. Not a problem: the next run with the app closed does it.
function Write-Waiting([string]$Text) {
    Write-Host "    waiting    $Text" -ForegroundColor Yellow
    $script:WaitingItems.Add($Text)
}

# Something that failed or had to be skipped. The run carries on with everything that doesn't depend on it.
function Write-Problem([string]$Text) {
    Write-Host "    PROBLEM    $Text" -ForegroundColor Magenta
    $script:ProblemItems.Add($Text)
}

# A note that isn't a result, e.g. that a UAC prompt is coming.
function Write-Note([string]$Text) { Write-Host "    note       $Text" }

# Prints one line of the summary, if the list has anything in it.
function Write-SummaryLine([string]$Label, [System.Collections.Generic.List[string]]$List, [string]$Color = 'Gray') {
    if ($List.Count -gt 0) { Write-Host "$Label ($($List.Count)): $($List -join ', ')" -ForegroundColor $Color }
}

# Stops the script with a "FAILED:" line, for problems nothing after them can work around.
function Exit-Bootstrap([string]$Text) {
    Write-Host ''
    Write-Host "FAILED: $Text" -ForegroundColor Red
    exit 1
}



# ========== Checks ====================================================================================================

# Asks the script's own -WhatIf handling whether to go ahead with an install or update, so -WhatIf reaches every
# helper. Under -WhatIf it also adds the change to $List (the installed or updated list), so the summary can show
# everything that would change.
function Test-ShouldChange {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Delegates to the script-level ShouldProcess')]
    param([string]$Target, [string]$Action, [System.Collections.Generic.List[string]]$List)
    if ($script:Cmdlet.ShouldProcess($Target, $Action)) { return $true }
    if ($WhatIfPreference -and $null -ne $List) { $List.Add($Target) }
    return $false
}

# Returns whether this PowerShell is running elevated.
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns the installed WSL package's version, or $null if there isn't one. It reads the registry and the app list
# rather than asking wsl.exe, because on a machine without WSL the built-in wsl.exe can offer to install it.
function Get-WslPackageVersion {
    # 1: The MSI package (what "wsl --install" and "wsl --update" put there) records its version in the registry.
    try {
        $msi = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\MSI' -ErrorAction Stop
        if ($msi.PSObject.Properties['Version']) { return [version][string]$msi.Version }
    } catch { $null = $_ }
    # 2: Older installs came from the Microsoft Store as an app package instead.
    $package = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction SilentlyContinue
    if ($package) { return [version][string]$package.Version }
    return $null
}

# Returns whether the Virtual Machine Platform Windows feature, which WSL2 runs on, is enabled. InstallState 1 is
# enabled; a feature turned on but waiting for a reboot doesn't count yet. Reading it doesn't need admin.
function Test-VirtualMachinePlatform {
    $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'"
    return ($null -ne $feature -and [int]$feature.InstallState -eq 1)
}

# Returns whether Windows has a reboot pending from installing or enabling something.
function Test-RebootPending {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    return (Test-Path -LiteralPath $key)
}

# Returns a version with all four parts filled in, so 3.0.3 and 3.0.3.0 compare as equal.
function ConvertTo-FullVersion([version]$Version) {
    $parts = @($Version.Major, $Version.Minor, [math]::Max(0, $Version.Build), [math]::Max(0, $Version.Revision))
    return New-Object -TypeName Version -ArgumentList $parts
}

# Returns the latest full WSL release's version from GitHub (e.g. 3.0.3), or $null if it can't be looked up.
function Get-LatestWslVersion {
    # 1: Windows PowerShell 5.1 on an older Windows 10 may not offer TLS 1.2 by default, and GitHub requires it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12
    # 2: The release's tag is its version number.
    try {
        $release = Invoke-RestMethod -Uri $WslLatestReleaseUrl -TimeoutSec 30
        if ([string]$release.tag_name -match '^v?(\d+(\.\d+){1,3})$') { return [version]$Matches[1] }
    } catch { $null = $_ }
    return $null
}

# Returns the names of the registered WSL distros. Only call it once the WSL package is installed.
function Get-WslDistro {
    # Windows PowerShell 5.1 turns a redirected stderr line into a terminating error under 'Stop', so relax it here
    # (it's local to this function).
    $ErrorActionPreference = 'Continue'
    $output = & $Wsl --list --quiet 2>$null
    return @($output | ForEach-Object { ([string]$_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

# Returns the names of the WSL distros that are running right now.
function Get-RunningWslDistro {
    $ErrorActionPreference = 'Continue'
    $output = & $Wsl --list --running --quiet 2>$null
    return @($output | ForEach-Object { ([string]$_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

# Returns whether winget has a package installed, whether or not winget installed it (it also recognizes apps
# installed by hand or that came with Windows). Throws if winget can't tell, so a broken winget never looks like a
# missing app and leads to a second install.
function Test-WingetPackage([string]$Id) {
    $ErrorActionPreference = 'Continue'
    $null = & winget.exe list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq $WingetNotInstalled) { return $false }
    throw "winget list failed for $Id (exit $LASTEXITCODE)"
}

# Installs a winget package silently and returns winget's exit code. --no-upgrade makes sure that, if the app turns
# out to be installed after all, winget leaves it alone: updating is a separate, deliberate step (Invoke-WingetUpgrade).
function Install-WingetPackage([string]$Id, [string]$Scope) {
    $arguments = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--no-upgrade',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Scope) { $arguments += @('--scope', $Scope) }
    # Its output goes straight to the console; otherwise it would become part of this function's return value.
    & winget.exe @arguments | Out-Host
    return $LASTEXITCODE
}

# Returns the update winget has waiting for an installed package, as its installed and available versions, or $null
# if it's up to date. "winget list --upgrade-available" exits 0 either way (seen with winget 1.29), so the answer is
# whether the package's own row is in its table, not the exit code.
function Get-WingetUpgrade([string]$Id) {
    $ErrorActionPreference = 'Continue'
    $arguments = @('list', '--id', $Id, '--exact', '--upgrade-available', '--accept-source-agreements',
        '--disable-interactivity')
    $output = & winget.exe @arguments 2>&1
    # The table's columns are Name, Id, Version, Available and Source. A name can have spaces but an ID can't, so find
    # the row by the field that is the ID, and take the two versions right after it.
    foreach ($line in @($output | ForEach-Object { [string]$_ })) {
        $fields = @($line.Trim() -split '\s+')
        for ($index = 0; $index -lt $fields.Count - 2; $index++) {
            if ($fields[$index] -eq $Id) {
                return [pscustomobject]@{ Installed = $fields[$index + 1]; Available = $fields[$index + 2] }
            }
        }
    }
    return $null
}

# Updates a winget package silently to its latest version and returns winget's exit code. An app installed per user
# stays per user.
function Invoke-WingetUpgrade([string]$Id) {
    $arguments = @('upgrade', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    & winget.exe @arguments | Out-Host
    return $LASTEXITCODE
}

# Returns the names of the given processes that are running right now (an empty list if none are).
function Get-RunningProcessName([string[]]$Names) {
    return @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
}

# Returns the path of VS Code's "code" command, or $null if VS Code isn't installed. It looks in the install folders
# first, since a VS Code installed a moment ago isn't on this session's PATH yet.
function Find-CodeCommand {
    $candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    $command = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
    if ($command) { return $command.Path }
    return $null
}

# Returns the installed VS Code extensions as a hashtable of ID (lower-cased, since extension IDs aren't case
# sensitive) to version, from the "id@version" lines "code --list-extensions --show-versions" prints.
function Get-VSCodeExtension([string]$Code) {
    $ErrorActionPreference = 'Continue'
    $extensions = @{}
    foreach ($line in @(& $Code --list-extensions --show-versions 2>$null)) {
        if ([string]$line -match '^\s*([^@\s]+)@(\S+)\s*$') {
            $extensions[$Matches[1].ToLowerInvariant()] = $Matches[2]
        }
    }
    return $extensions
}

# Installs a VS Code extension, or with -Update, updates an installed one to its latest version, and returns the exit
# code. "--install-extension --force" only downloads anything when the marketplace has a newer version: on an extension
# that's already current it just says so (seen with VS Code 1.145). The output is dropped (it's mostly a Node
# deprecation warning), since the result is checked and reported anyway.
function Install-VSCodeExtension([string]$Code, [string]$Id, [switch]$Update) {
    $ErrorActionPreference = 'Continue'
    $arguments = @('--install-extension', $Id)
    if ($Update) { $arguments += '--force' }
    $null = & $Code @arguments 2>&1
    return $LASTEXITCODE
}



# ========== 1. Preflight ==============================================================================================

Write-Step '1. Preflight'

# 1: A normal PowerShell, not an admin one. VS Code's per-user install and the Ubuntu distro have to belong to your
# own account, and the installers that need admin ask for it themselves.
if (Test-IsAdmin) {
    Exit-Bootstrap 'run this from a normal (not admin) PowerShell; installers that need admin ask for it themselves.'
}

# 2: A 64-bit PowerShell, since 32-bit processes can't see wsl.exe at all.
if (-not [Environment]::Is64BitProcess) { Exit-Bootstrap 'this is a 32-bit PowerShell; use the 64-bit one.' }

# 3: A Windows new enough for "wsl --install".
$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([int]$os.BuildNumber -lt $MinimumWindowsBuild) {
    Exit-Bootstrap "Windows build $($os.BuildNumber) is too old: WSL2 needs build $MinimumWindowsBuild or later."
}
Write-Note "$($os.Caption), build $($os.BuildNumber)"

# 4: CPU virtualization, which WSL2 can't start without. When a hypervisor is already running it's clearly on;
# otherwise the firmware says whether it's been turned off in the BIOS/UEFI.
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
if (-not $computer.HypervisorPresent) {
    $firmware = @(Get-CimInstance -ClassName Win32_Processor | ForEach-Object { $_.VirtualizationFirmwareEnabled })
    if ($firmware -contains $false) {
        Write-Problem 'CPU virtualization is turned off in the BIOS/UEFI; WSL2 will not start until it is turned on'
    }
}

# 5: winget, which installs the apps. On a fresh Windows it can be missing until App Installer registers, which
# usually happens on its own a few minutes after the first sign-in, and can be asked for.
$haveWinget = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
if (-not $haveWinget) {
    Write-Note 'winget not found; asking Windows to register App Installer'
    try {
        $appInstaller = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        Add-AppxPackage -RegisterByFamilyName -MainPackage $appInstaller -ErrorAction Stop
    } catch { $null = $_ }
    $haveWinget = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
}
if ($haveWinget) { Write-Note "winget $(& winget.exe --version)" }
else { Write-Problem 'winget is not available, so no apps can be installed (update App Installer from the Store)' }



# ========== 2. Windows apps ===========================================================================================

Write-Step '2. Windows apps'
if (-not $haveWinget) {
    Write-Problem 'apps skipped (no winget)'
} else {
    foreach ($package in $WingetPackages) {
        # 1: Is it installed at all? If winget can't tell, skip the app rather than risk installing it twice.
        try { $isInstalled = Test-WingetPackage $package.Id }
        catch { Write-Problem "$($package.Name): $($_.Exception.Message)"; continue }
        # 2: Missing: install it, then check winget now sees it, rather than trusting the installer's exit code.
        if (-not $isInstalled) {
            $action = "winget install --id $($package.Id)"
            $target = $package.Name
            if (-not (Test-ShouldChange -Target $target -Action $action -List $script:InstalledItems)) { continue }
            $exitCode = Install-WingetPackage $package.Id $package.Scope
            if ((Test-WingetPackage $package.Id)) { Write-Installed $package.Name }
            else { Write-Problem "$($package.Name) did not install (winget exit $exitCode)" }
            continue
        }
        # 3: Installed: leave it alone unless winget has a newer version waiting.
        $upgrade = Get-WingetUpgrade $package.Id
        if (-not $upgrade) { Write-UpToDate "$($package.Name) (up to date)"; continue }
        $change = "$($package.Name) $($upgrade.Installed) -> $($upgrade.Available)"
        # 4: A running app waits for the next run, since its installer would close it (or this window, when the script
        # runs inside Windows Terminal or PowerShell 7).
        if (@(Get-RunningProcessName $package.Processes).Count -gt 0) {
            Write-Waiting "$change (close $($package.Close), then run this again)"
            continue
        }
        # 5: Update it, then check winget has nothing newer waiting any more.
        $action = "winget upgrade --id $($package.Id)"
        if (-not (Test-ShouldChange -Target $change -Action $action -List $script:UpdatedItems)) { continue }
        $exitCode = Invoke-WingetUpgrade $package.Id
        if (-not (Get-WingetUpgrade $package.Id)) { Write-Updated $change }
        else { Write-Problem "$($package.Name) did not update (winget exit $exitCode)" }
    }
}



# ========== 3. VS Code extensions =====================================================================================

Write-Step '3. VS Code extensions'
$code = Find-CodeCommand
if (-not $code) {
    # Under -WhatIf, VS Code may simply not have been installed yet.
    if ($WhatIfPreference) { Write-Note 'VS Code is not installed yet, so its extensions would come after it' }
    else { Write-Problem 'VS Code is not installed, so its extensions were skipped' }
} else {
    $extensions = Get-VSCodeExtension $code
    foreach ($extension in $VSCodeExtensions) {
        $key = $extension.ToLowerInvariant()
        # 1: Missing: install it, then check VS Code lists it.
        if (-not $extensions.ContainsKey($key)) {
            $action = 'code --install-extension'
            if (-not (Test-ShouldChange -Target $extension -Action $action -List $script:InstalledItems)) { continue }
            $exitCode = Install-VSCodeExtension $code $extension
            $after = Get-VSCodeExtension $code
            if ($after.ContainsKey($key)) { Write-Installed "$extension $($after[$key])" }
            else { Write-Problem "$extension did not install (exit $exitCode)" }
            continue
        }
        # 2: Installed: update it if the marketplace has something newer. Only asking the marketplace can tell, and
        # that's exactly what the update does, so -WhatIf can only say it would check.
        $before = $extensions[$key]
        $action = 'check for an update (code --install-extension --force)'
        if (-not (Test-ShouldChange -Target "$extension $before" -Action $action -List $null)) { continue }
        $exitCode = Install-VSCodeExtension $code $extension -Update
        $after = (Get-VSCodeExtension $code)[$key]
        if ($exitCode -ne 0) { Write-Problem "$extension $before`: the update check failed (exit $exitCode)" }
        elseif ($after -and $after -ne $before) { Write-Updated "$extension $before -> $after" }
        else { Write-UpToDate "$extension $before (up to date)" }
    }
}



# ========== 4. WSL platform ===========================================================================================

Write-Step '4. WSL platform'

# 1: WSL needs both its package and the Virtual Machine Platform feature. "wsl --install --no-distribution" sets up
# whichever is missing (it asks for admin through UAC), without installing a distro yet.
$wslVersion = Get-WslPackageVersion
$platformEnabled = Test-VirtualMachinePlatform
if ($wslVersion -and $platformEnabled) {
    Write-UpToDate "WSL $wslVersion installed (Virtual Machine Platform enabled)"
} elseif ((Test-RebootPending) -and -not $WhatIfPreference) {
    # 2: A reboot left over from an earlier run (or anything else) has to happen first: the feature only turns on
    # once Windows restarts.
    Write-Host ''
    Write-Host 'REBOOT NEEDED: Windows has a reboot pending. Restart, then run this script again.' `
        -ForegroundColor Yellow
    exit $RebootNeeded
} elseif (Test-ShouldChange -Target 'WSL' -Action 'wsl --install --no-distribution' -List $script:InstalledItems) {
    Write-Note 'installing WSL; Windows asks for admin (UAC)'
    & $Wsl --install --no-distribution
    $installExitCode = $LASTEXITCODE
    # 3: "wsl --install" can succeed and still need a reboot before the feature is on, so decide from the machine's
    # state afterwards, not from the exit code.
    $wslVersion = Get-WslPackageVersion
    if ($wslVersion -and (Test-VirtualMachinePlatform)) {
        Write-Installed "WSL $wslVersion"
    } elseif ($wslVersion -or (Test-RebootPending)) {
        Write-Installed 'WSL (finishes after a reboot)'
        Write-Host ''
        Write-Host 'REBOOT NEEDED: restart Windows, then run this script again to finish.' -ForegroundColor Yellow
        exit $RebootNeeded
    } else {
        Exit-Bootstrap "wsl --install --no-distribution failed (exit $installExitCode); see its output above."
    }
}



# ========== 5. WSL version ============================================================================================

Write-Step '5. WSL version'
if (-not $wslVersion) {
    Write-Note 'WSL is not installed yet (-WhatIf), so there is nothing to update'
} else {
    # 1: Compare with the latest full release. If GitHub can't be reached, leave WSL as it is rather than run an
    # update that may not be needed.
    $latest = Get-LatestWslVersion
    if (-not $latest) {
        Write-Problem "could not look up the latest WSL release; WSL $wslVersion left as it is (wsl --update by hand)"
    } elseif ((ConvertTo-FullVersion $wslVersion) -ge (ConvertTo-FullVersion $latest)) {
        Write-UpToDate "WSL $wslVersion (the latest release)"
    } else {
        # 2: Updating restarts WSL, which stops every running distro and whatever is running in it (later on, that's
        # fuzzing campaigns), so ask first when any are running.
        $running = @(Get-RunningWslDistro)
        $goAhead = $true
        if ($running.Count -gt 0 -and -not $Force -and -not $WhatIfPreference) {
            $question = "Updating WSL stops these running distros: $($running -join ', '). Continue?"
            $goAhead = $PSCmdlet.ShouldContinue($question, 'Update WSL')
        }
        $updateTarget = "WSL $wslVersion -> $latest"
        if (-not $goAhead) {
            Write-Problem "WSL $wslVersion not updated to $latest (declined because distros were running)"
        } elseif (Test-ShouldChange -Target $updateTarget -Action 'wsl --update' -List $script:UpdatedItems) {
            # 3: Update, then read the version back. "wsl --update" gets its build from the Microsoft Store, which
            # can be a little behind GitHub, so landing below the GitHub release is a note, not a failure.
            Write-Note "updating WSL $wslVersion to $latest; Windows asks for admin (UAC)"
            & $Wsl --update
            $updateExitCode = $LASTEXITCODE
            $newVersion = Get-WslPackageVersion
            if ($newVersion -and (ConvertTo-FullVersion $newVersion) -gt (ConvertTo-FullVersion $wslVersion)) {
                Write-Updated "WSL $wslVersion -> $newVersion"
                if ((ConvertTo-FullVersion $newVersion) -lt (ConvertTo-FullVersion $latest)) {
                    Write-Note "the update channel is behind GitHub's latest ($latest); run this again later"
                }
                $wslVersion = $newVersion
            } else {
                Write-Problem "wsl --update did not change WSL $wslVersion (exit $updateExitCode)"
            }
        }
    }
}



# ========== 6. Ubuntu =================================================================================================

Write-Step "6. $DistroName"
$distroAction = "wsl --install $DistroName --no-launch"
if (-not $wslVersion) {
    Write-Note "WSL is not installed yet (-WhatIf), so $DistroName would come after it"
} elseif ((Get-WslDistro) -contains $DistroName) {
    Write-UpToDate "$DistroName installed"
} elseif (Test-ShouldChange -Target $DistroName -Action $distroAction -List $script:InstalledItems) {
    # 1: Install without launching it. Ubuntu's own first-run setup asks for a Linux user name and password the first
    # time you open it, which is yours to do (see the end of this script), not something to type into a script.
    & $Wsl --install $DistroName --no-launch
    $installExitCode = $LASTEXITCODE
    # 2: Check it's really registered, rather than trusting the exit code.
    if ((Get-WslDistro) -contains $DistroName) { Write-Installed $DistroName }
    else { Write-Problem "$DistroName did not install (wsl exit $installExitCode)" }
}



# ========== Summary ===================================================================================================

# 1: What this run found, did, left waiting and couldn't do.
Write-Host ''
$installVerb = $(if ($WhatIfPreference) { 'Would install' } else { 'Installed' })
$updateVerb = $(if ($WhatIfPreference) { 'Would update' } else { 'Updated' })
Write-SummaryLine $installVerb $script:InstalledItems
Write-SummaryLine $updateVerb $script:UpdatedItems
Write-SummaryLine 'Already in place' $script:UpToDateItems
Write-SummaryLine -Label 'Update waiting on a running app' -List $script:WaitingItems -Color 'Yellow'
if ($script:ProblemItems.Count -gt 0) {
    Write-Host "Problems ($($script:ProblemItems.Count)):" -ForegroundColor Magenta
    foreach ($problem in $script:ProblemItems) { Write-Host "  - $problem" -ForegroundColor Magenta }
}

# 2: The next step: Ubuntu's first-run setup, which creates your Linux user.
if ($wslVersion -and -not $WhatIfPreference) {
    Write-Host ''
    $next = "Next: open '$DistroName' in Windows Terminal (or run: wsl -d $DistroName) once, and create your"
    Write-Host $next -ForegroundColor Cyan
    Write-Host 'Linux user and password when Ubuntu asks. Script 02 picks up from there.' -ForegroundColor Cyan
}
if ($script:ProblemItems.Count -gt 0) { exit 1 }
exit 0
