@echo off
setlocal ENABLEDELAYEDEXPANSION

for /F "tokens=*" %%F in ('go env GOOS') do (
    set GOOS=%%F
)

for /F "tokens=*" %%F in ('go env GOARCH') do (
    set GOARCH=%%F
)

set SCRIPT_DIR=%~dp0
set OUTPUT=%SCRIPT_DIR%..\configuration\terraform.d\plugins\example.local\mvromer\example\0.0.1\%GOOS%_%GOARCH%\terraform-provider-example_v0.0.1.exe

go build -o %OUTPUT%

endlocal
