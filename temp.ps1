powershell -Command "Start-Process 'steam://rungameid/APP_ID'; while (!(Get-Process EXE_NAME -ErrorAction SilentlyContinue)) { Start-Sleep 1 }; (Get-Process EXE_NAME).WaitForExit()"
