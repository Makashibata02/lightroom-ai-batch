param(
    [string]$Version = "",
    [switch]$SkipBinary
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$package = Get-Content -LiteralPath (Join-Path $repoRoot "server\package.json") -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$package.version }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid release version: $Version" }
if ([string]$package.version -ne $Version) { throw "package.json is $($package.version), not $Version" }

$buildRoot = Join-Path $repoRoot "build"
$stageRoot = Join-Path $buildRoot "release-stage\v$Version"
$outRoot = Join-Path $buildRoot "release"
$resolvedBuild = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
$resolvedStage = [IO.Path]::GetFullPath($stageRoot)
if (-not $resolvedStage.StartsWith($resolvedBuild, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean stage outside build directory: $resolvedStage"
}
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stageRoot, $outRoot -Force | Out-Null

$pluginFiles = @(
    "AiState.lua", "BatchJobStore.lua", "BatchPipeline.lua", "HandlerBatch.lua",
    "HandlerCollections.lua", "HandlerDevelop.lua", "HandlerExport.lua", "HandlerImport.lua",
    "HandlerMetadata.lua", "HandlerOrganization.lua", "HandlerSearch.lua", "HandlerSelection.lua",
    "Info.lua", "JSON.lua", "LandscapePreset.lua", "Log.lua", "MenuAIBatchCancel.lua",
    "MenuAIBatchDenoise.lua", "MenuAIBatchPrepare.lua", "MenuAIBatchStatus.lua",
    "MenuBatchCommon.lua", "MenuShowStatus.lua", "MetadataProvider.lua", "PhotoLookup.lua",
    "PipelineCollections.lua", "PipelineConfig.lua", "PipelineState.lua", "PluginInfoProvider.lua",
    "PluginInit.lua", "SubjectPreset.lua", "TranslatedStrings_en.txt", "TranslatedStrings_zh_cn.txt"
)

function Copy-Plugin([string]$Destination) {
    $source = Join-Path $repoRoot "plugin\LightroomMCP.lrplugin"
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($name in $pluginFiles) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $Destination $name)
    }
    $configDir = Join-Path $Destination "config"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "config\pipeline.json") -Destination (Join-Path $configDir "pipeline.json")
}

function Copy-CommonDocs([string]$Destination) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $Destination
    Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE.md") -Destination $Destination
}

if (-not $SkipBinary) {
    & node (Join-Path $repoRoot "scripts\build-binary.mjs") --targets=bun-windows-x64
    if ($LASTEXITCODE -ne 0) { throw "Windows MCP binary build failed" }
}

$pluginStage = Join-Path $stageRoot "plugin"
$pluginBundle = Join-Path $pluginStage "LightroomMCP.lrplugin"
New-Item -ItemType Directory -Path $pluginStage -Force | Out-Null
Copy-Plugin $pluginBundle
Copy-CommonDocs $pluginStage
Copy-Item -LiteralPath (Join-Path $repoRoot "release\INSTALL.zh-CN.md") -Destination $pluginStage
Copy-Item -LiteralPath (Join-Path $repoRoot "release\INSTALL.en.md") -Destination $pluginStage

$mcpStage = Join-Path $stageRoot "mcp-windows-x64"
New-Item -ItemType Directory -Path $mcpStage -Force | Out-Null
$binarySource = Join-Path $buildRoot "bin\lightroom-ai-batch-mcp-windows-x64.exe"
if (-not (Test-Path -LiteralPath $binarySource -PathType Leaf)) { throw "Missing binary: $binarySource" }
Copy-Item -LiteralPath $binarySource -Destination (Join-Path $mcpStage "lightroom-ai-batch-mcp.exe")
Copy-Plugin (Join-Path $mcpStage "LightroomMCP.lrplugin")
Copy-CommonDocs $mcpStage
Copy-Item -LiteralPath (Join-Path $repoRoot "release\MCP_SETUP.zh-CN.md") -Destination $mcpStage
Copy-Item -LiteralPath (Join-Path $repoRoot "release\MCP_SETUP.en.md") -Destination $mcpStage
Copy-Item -LiteralPath (Join-Path $repoRoot "release\mcp-config.example.json") -Destination $mcpStage

$pluginZip = Join-Path $outRoot "lightroom-ai-batch-plugin-v$Version.zip"
$mcpZip = Join-Path $outRoot "lightroom-ai-batch-mcp-windows-x64-v$Version.zip"
foreach ($zip in @($pluginZip, $mcpZip)) { if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force } }
Compress-Archive -Path (Join-Path $pluginStage "*") -DestinationPath $pluginZip -CompressionLevel Optimal
Compress-Archive -Path (Join-Path $mcpStage "*") -DestinationPath $mcpZip -CompressionLevel Optimal

$sums = Join-Path $outRoot "SHA256SUMS"
@($pluginZip, $mcpZip) | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($_))"
} | Set-Content -LiteralPath $sums -Encoding ascii

Write-Host "Release artifacts:"
Get-Item -LiteralPath $pluginZip, $mcpZip, $sums | Select-Object Name, Length, FullName | Format-Table -AutoSize
