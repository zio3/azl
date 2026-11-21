<#
.SYNOPSIS
  azl dispatcher — routes subcommands to individual azl-*.ps1 scripts.
.DESCRIPTION
  Uses $args (not named parameters) so flags such as -Verbose
  are forwarded verbatim to child scripts.
#>

function Show-Help {
@"
azl — Azure CLI login assistant (assisted user login + SP aliases)

USAGE:
  azl                     Assisted login: sign in as yourself, pick tenant/subscription
  azl -Graph              Assisted login, also acquiring the Microsoft Graph scope
  azl <name>              Log in with SP alias <name> (unattended; for LLM/CI)
  azl login <name>        Log in with alias <name>
  azl list                List registered aliases
  azl status              Current az login as one line (alias / sp|user / tenant / sub)
                          -Json for machine-readable output. Never changes login state.
  azl show <name>         Show alias metadata from the vault (secret never shown)
                          -Live also logs in as the SP for live info (switches session!)
  azl register            Register a new alias (paste appId/tenantId/secret)
  azl rotate <name>       Rotate SP secret (paste a secret produced elsewhere)
  azl renew <name>        Auto-generate a fresh SP secret via Graph and store it
                          (needs 'azl <name> -Graph' first; admin/owner rights)
  azl remove <name>       Remove an alias
  azl -help, --help, -h   Show this message

LOGIN FLAGS (after alias name):
  -Verbose                Verbose step-by-step output
  -User                   Interactive user login using the alias's tenantId
                          (instead of the stored service principal), ARM scope.
                          Useful for occasional RBAC / invitation work.
  -Graph                  User login that acquires BOTH ARM and Microsoft Graph
                          scopes (ARM is always needed for subscription listing),
                          so 'az ad ...' commands work. Use when you hit
                          AccountUnusable on Graph calls. Implies -User.

EXAMPLES:
  azl                     # assisted login: pick tenant/subscription as yourself
  azl -Graph              # assisted login + Graph scope (az ad ... works)
  azl zio3
  azl zio3 -User          # one-off interactive login (ARM: RBAC etc.)
  azl zio3 -Graph         # one-off interactive login (Graph: az ad ...)
  azl zio3 -User -Graph   # both scopes in turn (may prompt twice)
  azl login zio3 -Verbose
  azl register
  azl list

FIRST TIME:
  Just run 'azl' — assisted login gets you onto the right tenant/subscription
  as yourself. That is often all you need.

  For unattended use (LLM/CI, no browser), set up an SP alias once:
  1. Log in with 'azl' (or 'azl -Graph'), then create a service principal:
       az ad sp create-for-rbac --name "claude-work" --role Contributor --scopes /subscriptions/<SUB_ID>
     Note the output: appId, password (=secret), tenant
  2. Register the alias:
       azl register
     Prompts for: tenantId, appId, secret; picks a subscription from the list;
     then asks tenantName (friendly label) and finally the alias name.
  3. Log in unattended:
       azl <alias>

NOTES:
  - 'azl' (no args), -User and -Graph open a BROWSER and wait for a human.
    Do not run them from an LLM; a human should run them (e.g. '! azl work -Graph'
    in Claude Code). Unattended logins are 'azl <name>' (SP) only.
  - Secrets are stored in PowerShell SecretStore (DPAPI-encrypted, per-Windows-user).
  - 'azl login' auto-checks SP secret expiration and warns if <= 30 days left.
  - -Verbose is primarily for debugging login issues (module/cred/network).
"@ | Write-Host
}

# Self-repair PSModulePath: when launched from pwsh 7 (e.g. LLM tools), the child
# powershell.exe inherits pwsh's PSModulePath, which lacks the 5.1 user module dir
# (Documents\WindowsPowerShell\Modules) where SecretManagement lives.
$ps51UserModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
if ((Test-Path $ps51UserModules) -and
    (($env:PSModulePath -split ';') -notcontains $ps51UserModules)) {
    $env:PSModulePath = "$ps51UserModules;$env:PSModulePath"
}

$scriptDir = Split-Path -Parent $PSCommandPath

function Invoke-Child {
    param(
        [string]$ChildScript,
        [object[]]$ChildArgs = @()
    )
    $path = Join-Path $scriptDir $ChildScript
    if (-not (Test-Path $path)) {
        Write-Error "Internal error: $ChildScript not found at $path"
        exit 127
    }
    # Splatting a plain ARRAY passes '-Flag' tokens as positional strings, not as
    # named parameters (PS 5.1 and 7 alike), so child scripts would silently drop
    # or reject them. Rebuild: dash tokens become real named parameters (hashtable
    # splat), everything else stays positional. Alias names cannot start with '-'
    # (rejected at registration), so a dash token is always a flag here.
    $positional = @()
    $named = @{}
    $valueFlags = @('years')   # flags that take a value; all others are switches
    for ($i = 0; $i -lt $ChildArgs.Count; $i++) {
        $tok = [string]$ChildArgs[$i]
        if ($tok.StartsWith('-')) {
            $flagName = $tok.TrimStart('-')
            if (($valueFlags -contains $flagName.ToLower()) -and ($i + 1 -lt $ChildArgs.Count)) {
                $named[$flagName] = $ChildArgs[$i + 1]
                $i++
            } else {
                $named[$flagName] = $true
            }
        } else {
            $positional += ,$ChildArgs[$i]
        }
    }
    & $path @positional @named
    exit $LASTEXITCODE
}

function Pick-Alias {
    param([string]$Command)
    if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
        Write-Host "Microsoft.PowerShell.SecretManagement not installed."
        exit 1
    }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    $entries = @(Get-SecretInfo -Vault 'azl' -ErrorAction SilentlyContinue)
    if ($entries.Count -eq 0) {
        Write-Host "No aliases registered. Run 'azl register' first."
        exit 1
    }
    if ($entries.Count -eq 1) {
        Write-Host ("Using alias: {0}" -f $entries[0].Name)
        return $entries[0].Name
    }
    Write-Host "Select alias for '$Command':"
    for ($i = 0; $i -lt $entries.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $entries[$i].Name)
    }
    # Non-interactive callers (LLM shells, CI) cannot answer Read-Host; fail fast
    # with the list above instead of hanging on stdin.
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        Write-Host "Non-interactive session: cannot prompt. Run 'azl $Command <name>' with one of the names above."
        exit 2
    }
    $sel = Read-Host "Number [1]"
    if (-not $sel) { $sel = "1" }
    $selInt = 0
    if (-not [int]::TryParse($sel, [ref]$selInt) -or $selInt -lt 1 -or $selInt -gt $entries.Count) {
        Write-Host "Invalid selection: $sel"
        exit 2
    }
    return $entries[$selInt - 1].Name
}

function Resolve-NameArg {
    param([string]$Command, [object[]]$RestArgs)
    if ($RestArgs.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$RestArgs[0])) {
        return ,$RestArgs  # already has name; return as-is (preserve any extra flags)
    }
    $picked = Pick-Alias -Command $Command
    return ,@($picked)
}

$argsList = @($args)

if ($argsList.Count -eq 0) {
    # No args = assisted login (sign in as yourself, pick tenant/subscription)
    Invoke-Child 'azl-assisted.ps1' @()
}

# Handle help flags anywhere
foreach ($a in $argsList) {
    if ([string]$a -in @('-h', '-help', '--help')) {
        Show-Help
        exit 0
    }
}

# Normalize: move only the known value-less switches to the end so that
# `azl -Verbose zio3` behaves identically to `azl zio3 -Verbose`.
# IMPORTANT: only these switches are moved. Value-taking flags (e.g. -Tenant <id>)
# must keep their position and their following value adjacent, so we leave every
# other token (and its order) untouched.
$movableSwitches = @('-verbose', '-user', '-graph')
$flags = @()
$nonFlags = @()
foreach ($a in $argsList) {
    if (([string]$a).ToLower() -in $movableSwitches) {
        $flags += $a
    } else {
        $nonFlags += $a
    }
}
$argsList = @($nonFlags + $flags)

if ($argsList.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$argsList[0])) {
    Invoke-Child 'azl-assisted.ps1' @()
}

# Flags only (e.g. `azl -Graph`) = assisted login with those flags
if (([string]$argsList[0]).StartsWith('-')) {
    Invoke-Child 'azl-assisted.ps1' $argsList
}

$command = [string]$argsList[0]
$rest = if ($argsList.Count -gt 1) { $argsList[1..($argsList.Count - 1)] } else { @() }

switch -Exact ($command) {
    '-h'       { Show-Help; exit 0 }
    '--help'   { Show-Help; exit 0 }
    'help'     { Show-Help; exit 0 }
    'login' {
        $resolved = Resolve-NameArg 'login' $rest
        Invoke-Child 'azl-login.ps1' $resolved
    }
    'list'     { Invoke-Child 'azl-list.ps1'     $rest }
    'status'   { Invoke-Child 'azl-status.ps1'   $rest }
    'show' {
        $resolved = Resolve-NameArg 'show' $rest
        Invoke-Child 'azl-show.ps1' $resolved
    }
    'register' {
        if ($rest.Count -gt 0) {
            Write-Host "Note: 'azl register' no longer takes a positional name. Ignoring: $($rest -join ' ')"
        }
        Invoke-Child 'azl-register.ps1' @()
    }
    'rotate' {
        $resolved = Resolve-NameArg 'rotate' $rest
        Invoke-Child 'azl-rotate.ps1' $resolved
    }
    'renew' {
        $resolved = Resolve-NameArg 'renew' $rest
        Invoke-Child 'azl-renew.ps1' $resolved
    }
    'remove' {
        $resolved = Resolve-NameArg 'remove' $rest
        Invoke-Child 'azl-remove.ps1' $resolved
    }
    default {
        if ($command.StartsWith('-')) {
            Write-Host "azl: unknown option: $command"
            Write-Host ''
            Show-Help
            exit 2
        }
        # Shortcut: treat first arg as alias name -> login
        Invoke-Child 'azl-login.ps1' $argsList
    }
}
