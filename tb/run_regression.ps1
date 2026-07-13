param(
  [string[]] $Tests = @(),
  [string[]] $Variants = @("default"),
  [switch] $KeepGoing
)

$ErrorActionPreference = "Stop"

$tbDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rtlDir = Resolve-Path (Join-Path $tbDir "..\rtl")
$pkgPath = Join-Path $rtlDir "pkg_cpu.sv"
$origPkg = Get-Content -Raw $pkgPath

$allTests = @(
  "tb_alu",
  "tb_mul",
  "tb_div",
  "tb_decode",
  "tb_instr_mem",
  "tb_fetch",
  "tb_fetch_bundle",
  "tb_ifq",
  "tb_dispatch_reg",
  "tb_arf",
  "tb_rat",
  "tb_rat_bundle",
  "tb_rob",
  "tb_rob_bundle",
  "tb_rename_dispatch",
  "tb_rename_dispatch_bundle",
  "tb_cdb_arbiter",
  "tb_rs",
  "tb_lsq",
  "tb_lsq_ooo",
  "tb_lsq_ooo_stress",
  "tb_lsq_bundle",
  "tb_dram_model",
  "tb_dram_model_banked",
  "tb_mem_arbiter",
  "tb_dcache",
  "tb_icache",
  "tb_branch_path",
  "tb_backend",
  "tb_core",
  "tb_core_mem_order",
  "tb_core_branch_flush"
)

if ($Tests.Count -eq 0) {
  $Tests = $allTests
}

$Tests = @($Tests | ForEach-Object { $_ -split "," } | Where-Object { $_ -ne "" })
$Variants = @($Variants | ForEach-Object { $_ -split "," } | Where-Object { $_ -ne "" })

function Set-Param {
  param(
    [string] $Text,
    [string] $Name,
    [int] $Value
  )
  $pattern = "(localparam\s+int\s+$Name\s*=\s*)\d+(\s*;)"
  if ($Text -notmatch $pattern) {
    throw "Could not find localparam int $Name in pkg_cpu.sv"
  }
  return [regex]::Replace($Text, $pattern, "`${1}$Value`${2}")
}

function Apply-Variant {
  param([string] $Variant)

  $text = $origPkg
  switch ($Variant) {
    "default" {
      # Leave pkg_cpu.sv exactly as checked in (WIDTH=4 / CDB_WIDTH=4).
    }
    "w1" {
      $text = Set-Param $text "WIDTH" 1
      $text = Set-Param $text "CDB_WIDTH" 2
    }
    "w2" {
      $text = Set-Param $text "WIDTH" 2
      $text = Set-Param $text "CDB_WIDTH" 2
    }
    "w4" {
      $text = Set-Param $text "WIDTH" 4
      $text = Set-Param $text "CDB_WIDTH" 4
    }
    "w4_cdb2" {
      $text = Set-Param $text "WIDTH" 4
      $text = Set-Param $text "CDB_WIDTH" 2
    }
    default {
      throw "Unknown variant '$Variant'. Known variants: default, w1, w2, w4, w4_cdb2"
    }
  }
  Set-Content -NoNewline -Path $pkgPath -Value $text
}

function Invoke-Tool {
  param(
    [string] $Label,
    [string[]] $ToolArgs
  )
  $cmd = $ToolArgs[0]
  $cmdArgs = @()
  if ($ToolArgs.Count -gt 1) {
    $cmdArgs = $ToolArgs[1..($ToolArgs.Count - 1)]
  }
  $output = & $cmd @cmdArgs 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "$Label failed with exit code $code"
  }
  return $output
}

$failures = @()

try {
  Push-Location $tbDir

  foreach ($variant in $Variants) {
    Write-Host ""
    Write-Host "=== Variant: $variant ==="
    Apply-Variant $variant

    $rtlFiles = @(Join-Path $rtlDir "pkg_cpu.sv")
    $rtlFiles += Get-ChildItem $rtlDir -Filter *.sv |
      Where-Object { $_.Name -ne "pkg_cpu.sv" } |
      Sort-Object Name |
      ForEach-Object { $_.FullName }
    $memDir = Join-Path $rtlDir "mem"
    if (Test-Path $memDir) {
      $rtlFiles += Get-ChildItem $memDir -Filter *.sv |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
    }

    foreach ($test in $Tests) {
      $tbFile = Join-Path $tbDir "$test.sv"
      if (!(Test-Path $tbFile)) {
        throw "Missing testbench $tbFile"
      }

      $snapshot = "${test}_${variant}_sim"
      Write-Host ("[{0}] {1}" -f $variant, $test)

      try {
        Invoke-Tool "xvlog $test" (@("xvlog", "-sv") + $rtlFiles + @($tbFile)) | Out-Null
        Invoke-Tool "xelab $test" @("xelab", $test, "-s", $snapshot) | Out-Null
        $simOut = Invoke-Tool "xsim $test" @("xsim", $snapshot, "-runall")

        $text = ($simOut -join "`n")
        # Match real failure markers; ignore Vivado "Errors: 0" style summaries.
        if ($text -match "(^|\n)\s*FAIL\b" -or $text -match "(^|\n).*FATAL" -or $text -match "(^|\n)ERROR:") {
          throw "Simulation printed FAIL/FATAL/ERROR"
        }
      } catch {
        $failures += [pscustomobject]@{
          Variant = $variant
          Test    = $test
          Error   = $_.Exception.Message
        }
        Write-Host ("FAILED: {0}" -f $_.Exception.Message)
        if (!$KeepGoing) {
          throw
        }
      }
    }
  }
} finally {
  Set-Content -NoNewline -Path $pkgPath -Value $origPkg
  Pop-Location
}

Write-Host ""
if ($failures.Count -eq 0) {
  Write-Host "RTL_V2_REGRESSION: PASS"
  exit 0
}

Write-Host "RTL_V2_REGRESSION: FAIL"
$failures | Format-Table -AutoSize
exit 1
