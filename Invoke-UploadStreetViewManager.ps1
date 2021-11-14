[CmdletBinding(SupportsShouldProcess = $true)]
Param(
	[string] $ClientPath = (Resolve-Path "$PSScriptRoot\..\street-view-manager"),

	[switch] $OpenLogs,
	[switch] $OpenStagingPath,

	[switch] $Prod,
	[switch] $KeepStagingFiles,
	[switch] $SkipAppKey,
	[switch] $SkipUpload,
	[switch] $TestsOnly,
	[switch] $SkipTests
)

Write-Verbose "`$ClientPath = $ClientPath"

Write-Verbose "`$OpenLogs = $OpenLogs"
Write-Verbose "`$OpenStagingPath = $OpenStagingPath"

Write-Verbose "`$Prod = $Prod"
Write-Verbose "`$KeepStagingFiles = $KeepStagingFiles"
Write-Verbose "`$SkipUpload = $SkipUpload"

$configFilePath = "$PSScriptRoot\config.json"
Write-Verbose "`$configFilePath = '$configFilePath'"

$stagingPath = "$PSScriptRoot\build\staging"
Write-Verbose "`$stagingPath = '$stagingPath'"

if ($OpenStagingPath) {
	explorer (Join-Path $stagingPath "..")
	return
}

$configs = ConvertFrom-Json -AsHashtable (Get-Content -Raw $configFilePath)

if ($Prod) {
	$configName = 'prod'
} else {
	$configName = 'dev'
}

$config = $configs[$configName]
if (!$config) {
	throw "Configuration '$configName' not found in '$configFilePath'"	
}

$appClientId = $config['clientId']
if (!$appClientId) {
	throw "Configuration has an invalid clientId: '$appClientId'"
}

$appKey = $config['key']
if (!$appKey -and !$SkipAppKey) {
	throw "Configuration has an invalid key: '$appKey'"
}

$lambdaFunctionName = $config['lambdaFunctionName']
if (!$lambdaFunctionName) {
	throw "Configuration is missing required lambda function name"
}

if ($OpenLogs) {
	Start-Process "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/`$252Faws`$252Flambda`$252F$lambdaFunctionName"
	return
}

try {
	$initAppClientId = $env:REACT_APP_CLIENT_ID
	$initAppKey = $env:REACT_APP_KEY

	if (Test-Path $stagingPath) {
		Remove-Item -Force -Recurse $stagingPath
	}

	$env:REACT_APP_CLIENT_ID = $appClientId
	Write-Verbose "`$env:REACT_APP_CLIENT_ID = '$env:REACT_APP_CLIENT_ID'"

	$env:REACT_APP_KEY = $appKey
	Write-Verbose "`$env:REACT_APP_KEY = '$env:REACT_APP_KEY'"

	Push-Location $ClientPath

	try {
		if (!$SkipTests) {
			yarn test --watchAll=false --verbose
			if (!$?) {
				Write-Error "Unit tests failed"
				return 1
			}
		}
	
		if (!$SkipTests) {
			yarn cypress run --browser chrome
			if (!$?) {
				Write-Error "Integration tests failed"
				return 1
			}	
		}

		if ($TestsOnly) {
			Pop-Location
			return
		}
	
		yarn build
		Write-Verbose "Command 'yarn build' completed"
		yarn git-hash
		Write-Verbose "Command 'yarn git-hash' completed"
	} catch {
		throw $_
	} finally {
		Pop-Location
	}

	$clientBuildPath = "$ClientPath\build"
	Write-Verbose "`$clientBuildPath = '$clientBuildPath'"
	Copy-Item -Recurse $clientBuildPath "$stagingPath\build"

	$lambdaPath = "$PSScriptRoot"
	Write-Verbose "`$lambdaPath = '$lambdaPath'"
	Copy-Item -Recurse "$lambdaPath\src\**" $stagingPath
	Copy-Item -Recurse "$lambdaPath\node_modules" $stagingPath

	Remove-Item "$stagingPath\.gitignore" -ErrorAction SilentlyContinue

	$uploadPackagePath = Join-Path $stagingPath "..\$lambdaFunctionName.zip"
	Write-Verbose "`$uploadPackagePath = '$uploadPackagePath'"
	if (Test-Path $uploadPackagePath) {
		Remove-Item -Force $uploadPackagePath
	}

	$7zPath = "$env:ProgramFiles\7-Zip\7z.exe"
	if (Test-Path $7zPath)	{
		Write-Verbose "Compressing with '$7zPath'"

		& $7zPath a -tzip -mx=9 $uploadPackagePath "$stagingPath\**"
	} else {
		Write-Verbose "Compressing with built-in functionality"

		Compress-Archive -Force -Path "$stagingPath\**" -DestinationPath $uploadPackagePath
	}

	if (!$SkipUpload) {
		$functionNames = aws lambda list-functions
			| ConvertFrom-Json -AsHashtable
			| Select-Object -ExpandProperty Functions
			| Select-Object -ExpandProperty FunctionName
			| Sort-Object

		Write-Verbose "Found $($functionNames.length) functions associated with the current AWS account:`n$($functionNames -Join "`n")"

		if (!$functionNames.Contains($lambdaFunctionName)) {
			throw "Lambda function with name '$lambdaFunctionName' is not associated with the current AWS account"
		}

		$uploadRes = aws lambda update-function-code --function-name $lambdaFunctionName --zip-file "fileb://$uploadPackagePath"
		Write-Verbose "AWS lambda code update response:`n$($uploadRes | ConvertFrom-Json | ConvertTo-Json)"

		Write-Host "Lambda function '$lambdaFunctionName' updated"
	}

	if (!$KeepStagingFiles) {
		Remove-Item -Force -Recurse (Join-Path $stagingPath "..")
		Write-Verbose "Removed all files in path '$stagingPath'"
	}
} finally {
	$env:REACT_APP_CLIENT_ID = $initAppClientId
	$env:REACT_APP_KEY = $initAppKey
}
